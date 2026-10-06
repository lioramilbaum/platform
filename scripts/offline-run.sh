#!/usr/bin/env bash
# Run from a trusted checkout (or independently authenticated entrypoint).
# Usage: offline-run.sh PACKAGE.tar.gz TRUSTED_PUBLIC_KEY.pem
set -euo pipefail
package="${1:?Usage: offline-run.sh PACKAGE.tar.gz TRUSTED_PUBLIC_KEY.pem}"
key="${2:?An independently trusted public key is required}"
die() { echo "ERROR: $*" >&2; exit 1; }
for tool in python3 jq tar; do command -v "$tool" >/dev/null || die "Required tool missing: $tool"; done
[[ -f "$package" && -f "$key" ]] || die "Package or trusted public key missing"
package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
key="$(cd "$(dirname "$key")" && pwd)/$(basename "$key")"
BUILD_DIR="${BUILD_DIR:-$PWD/build/offline}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
work="$(mktemp -d "$BUILD_DIR/.offline.XXXXXX")"
cleanup() {
  if [[ "${KEEP_CLUSTER:-1}" == "0" && -x "$BUILD_DIR/deploy/bin/kind" ]]; then
    local cluster_name
    cluster_name=$(awk '/^name:/{print $2; exit}' "$BUILD_DIR/deploy/kind-cluster.yaml" 2>/dev/null) || true
    if [[ -n "$cluster_name" ]]; then
      "$BUILD_DIR/deploy/bin/kind" delete cluster --name "$cluster_name" 2>/dev/null || true
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT
# Reject traversal, links and special files before extraction, including duplicate paths.
python3 - "$package" "$work" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    seen = set()
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()) or path in seen:
            raise SystemExit('Unsafe or duplicate package member: ' + member.name)
        seen.add(path)
    # Every member was checked above; only regular files/directories are allowed.
    archive.extractall(sys.argv[2])
PY
[[ -f "$work/metadata.json" && -d "$work/ctf" && -f "$work/bootstrap/ocm" ]] || die "Incomplete offline package"
# Check transport bytes before OCM can satisfy reads from a local digest cache.
python3 - "$work/ctf/blobs" <<'PYBLOBS'
import hashlib, pathlib, re, sys
for path in pathlib.Path(sys.argv[1]).iterdir():
    match = re.fullmatch(r'sha256\.([a-f0-9]{64})', path.name)
    if not path.is_file() or not match:
        raise SystemExit('Unexpected CTF blob: ' + path.name)
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != match.group(1):
        raise SystemExit('CTF blob digest mismatch: ' + path.name)
PYBLOBS
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
[[ "$arch" == aarch64 ]] && arch=arm64
[[ "$arch" == arm64 && ( "$os" == linux || "$os" == darwin ) ]] || die "Unsupported runner architecture"
jq -e --arg os "$os" --arg arch "$arch" '.os==$os and .architecture==$arch and .rootComponent=="github.com/lioramilbaum/platform"' "$work/metadata.json" >/dev/null || die "Package architecture or component mismatch"
version="$(jq -er '.version' "$work/metadata.json")"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || die "Invalid package version"
[[ -z "${EXPECTED_VERSION:-}" || "$version" == "$EXPECTED_VERSION" ]] || die "Unexpected package version"
case "$os" in
  darwin) pin=ae87ac4943e81396054367315395787fb7b71a697d946f8bb62de67bcb93e544 ;;
  linux) pin=697e44f71ab0dbd02287c6544fa17be0c73c0a9d6e873f9a2c91fd92c9acbc86 ;;
esac
actual="$(python3 - "$work/bootstrap/ocm" <<'PY'
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    digest = hashlib.sha256()
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        digest.update(chunk)
    print(digest.hexdigest())
PY
)"
[[ "$actual" == "$pin" ]] || die "Bundled bootstrap OCM checksum mismatch"
chmod 0755 "$work/bootstrap/ocm"
key_yaml="$(jq -Rn --arg key "$key" '$key')"
cat > "$work/verify.ocmconfig" <<CONFIG
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: $key_yaml
CONFIG
ref="ctf::$work/ctf//github.com/lioramilbaum/platform:$version"
"$work/bootstrap/ocm" verify cv --config "$work/verify.ocmconfig" "$ref"
"$work/bootstrap/ocm" get cv "$ref" -o json > "$work/descriptor.json"
# Every signed resource must have its bytes physically present in the package.
python3 - "$work/ctf/blobs" "$work/descriptor.json" "$os" <<'PYCLOSURE'
import json, pathlib, re, sys
blobs = pathlib.Path(sys.argv[1])
component = json.loads(pathlib.Path(sys.argv[2]).read_text())[0]['component']
resources = component.get('resources', [])
required = {'kind', 'ocm', 'kind-node-image', 'kind-cluster', 'component-constructor',
            'script-lib', 'script-verify', 'script-kind-config', 'script-kind-bin', 'script-deploy', 'script-bootstrap'}
if {r['name'] for r in resources} != required or len(resources) != len(required):
    raise SystemExit('Offline component resource inventory mismatch')
for resource in resources:
    access = resource.get('access', {})
    reference = access.get('localReference', '')
    if access.get('type') != 'LocalBlob/v1' or not re.fullmatch(r'sha256:[a-f0-9]{64}', reference):
        raise SystemExit('Offline resources must be local SHA256 blobs')
    if not (blobs / reference.replace(':', '.', 1)).is_file():
        raise SystemExit('Missing package blob for ' + resource['name'])
    expected_os = 'linux' if resource['name'] == 'kind-node-image' else sys.argv[3]
    if resource['name'] in {'kind', 'ocm', 'kind-node-image'} and resource.get('extraIdentity') != {'os': expected_os, 'architecture': 'arm64'}:
        raise SystemExit('Signed resource platform mismatch: ' + resource['name'])
PYCLOSURE
revision="$(jq -er '.[0].component.labels[] | select(.name=="platform.lioramilbaum.github.com/source-revision") | .value' "$work/descriptor.json")"
[[ "$revision" == "$(jq -er '.sourceRevision' "$work/metadata.json")" ]] || die "Metadata does not match signed source revision"
[[ -z "${EXPECTED_SOURCE_REVISION:-}" || "$revision" == "$EXPECTED_SOURCE_REVISION" ]] || die "Unexpected signed source revision"
# The bootstrap implementation comes from the trusted harness; package scripts run only
# after their signed resource digests have been verified by bootstrap.
bootstrap="$(dirname "$0")/bootstrap.sh"
OFFLINE=1 BOOTSTRAP_OCM="$work/bootstrap/ocm" OCM_REPO="ctf::$work/ctf" \
  VERIFY_CONFIG="$work/verify.ocmconfig" VERSION="$version" BUILD_DIR="$BUILD_DIR" \
  bash "$bootstrap"
