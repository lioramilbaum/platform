#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" tar openssl jq
require_platform

if [[ ! "${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  die "VERSION must be semver without a leading 'v' (got: ${VERSION:-<unset>})"
fi

RELEASE_DIR="${RELEASE_DIR:-$BUILD_DIR/release}"
PUBLIC_KEY="${VERIFY_KEY:-$BUILD_DIR/keys/public.pem}"

[[ -d "$CTF" ]] || die "CTF directory not found at $CTF — run 'make build' first"
[[ -f "$PUBLIC_KEY" ]] || die "Public key not found at $PUBLIC_KEY — run 'make sign' first"

work="$(mktemp -d "$BUILD_DIR/.package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out"

# Write a fresh verify config pointing at the key we're about to publish
TEMP_VERIFY_CONFIG="$work/verify.ocmconfig"
cat > "$TEMP_VERIFY_CONFIG" <<EOF
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
            publicKeyPEMFile: ${PUBLIC_KEY}
EOF

# Verify the CTF against the exact public key being published
VERIFY_CONFIG="$TEMP_VERIFY_CONFIG" bash "$(dirname "$0")/verify.sh"

# Stage and archive
mkdir -p "$work/stage"
"$OCM" transfer cv "$(cv_ref)" "ctf::$work/stage/ctf" --recursive --copy-resources
"$OCM" verify cv --config "$TEMP_VERIFY_CONFIG" "ctf::$work/stage/ctf//$ROOT_COMPONENT:$VERSION"
original="$("$OCM" get cv "$(cv_ref)" -o json | jq -S '.[0].component.resources')"
transported="$("$OCM" get cv "ctf::$work/stage/ctf//$ROOT_COMPONENT:$VERSION" -o json | jq -S '.[0].component.resources')"
[[ "$original" == "$transported" ]] || die "Transport changed resource inventory"
COPYFILE_DISABLE=1 tar -czf "$work/out/platform-ctf-${VERSION}.tar.gz" -C "$work/stage" ctf

# Self-check: extract and verify the archive
mkdir -p "$work/check"
tar -xzf "$work/out/platform-ctf-${VERSION}.tar.gz" -C "$work/check"
"$OCM" verify cv \
  --config "$TEMP_VERIFY_CONFIG" \
  "ctf::$work/check/ctf//${ROOT_COMPONENT}:${VERSION}"

# Copy the remaining assets
cp "$PUBLIC_KEY" "$work/out/platform-signing-key.pub.pem"
cp "$ROOT/scripts/bootstrap.sh" "$work/out/bootstrap.sh"

# Complete offline package: bootstrap binary is independently pinned by the consumer.
[[ -f "$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE" ]] || die "Bootstrap OCM missing"
[[ "$(sha256 "$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE")" == "$OCM_CLI_SHA256" ]] || die "Bootstrap OCM checksum mismatch"
mkdir -p "$work/stage/bootstrap"
cp "$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE" "$work/stage/bootstrap/ocm"
chmod 0755 "$work/stage/bootstrap/ocm"
cp "$ROOT/scripts/bootstrap.sh" "$work/stage/bootstrap.sh"
cp "$ROOT/scripts/offline-run.sh" "$work/stage/offline-run.sh"
# Read source provenance from the signed descriptor, not an environment override.
revision="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].component.labels[] | select(.name=="platform.lioramilbaum.github.com/source-revision") | .value')"
jq -n --arg version "$VERSION" --arg sourceRevision "$revision" --arg os "$PLATFORM_OS" --arg architecture "$PLATFORM_ARCH" --arg rootComponent "$ROOT_COMPONENT" \
  '{version:$version,sourceRevision:$sourceRevision,os:$os,architecture:$architecture,rootComponent:$rootComponent}' > "$work/stage/metadata.json"
cp "$work/stage/metadata.json" "$work/out/metadata.json"
COPYFILE_DISABLE=1 tar -czf "$work/out/platform-airgap-${VERSION}-${PLATFORM_OS}-${PLATFORM_ARCH}.tar.gz" -C "$work/stage" .
# Portable SHA256SUMS, informational (trust comes from the signature and pinned binary).
(cd "$work/out"; for file in *; do printf '%s  %s\n' "$(sha256 "$file")" "$file"; done) > "$work/SHA256SUMS"
mv "$work/SHA256SUMS" "$work/out/SHA256SUMS"

# Atomic swap
rm -rf "$RELEASE_DIR"
mkdir -p "$(dirname "$RELEASE_DIR")"
mv "$work/out" "$RELEASE_DIR"

echo "Release assets written to $RELEASE_DIR:"
ls -lh "$RELEASE_DIR"
