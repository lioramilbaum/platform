#!/usr/bin/env bash
# bootstrap.sh — zero-to-cluster from a signed OCM component.
#
# Usage:
#   OCM_REPO=ghcr.io/lioramilbaum/ocm \
#   VERIFY_CONFIG=/path/to/verify.ocmconfig \
#   bash bootstrap.sh
#
# Optional:
#   VERSION=0.1.0     (default: 0.1.0)
#   BUILD_DIR=/tmp/x  (default: $PWD/build)
#   OCM_BOOTSTRAP_BASE_URL=file:///path  (for offline testing)
set -euo pipefail

# Pinned bootstrap OCM — Renovate manages this value.
OCM_BOOTSTRAP_VERSION="v0.19.1"
OCM_BOOTSTRAP_SHA256_LINUX_ARM64="697e44f71ab0dbd02287c6544fa17be0c73c0a9d6e873f9a2c91fd92c9acbc86"
OCM_BOOTSTRAP_SHA256_DARWIN_ARM64="ae87ac4943e81396054367315395787fb7b71a697d946f8bb62de67bcb93e544"
OCM_BOOTSTRAP_BASE_URL="${OCM_BOOTSTRAP_BASE_URL:-https://github.com/open-component-model/open-component-model/releases/download}"

# Inputs
OCM_REPO="${OCM_REPO:?OCM_REPO is required (e.g. ghcr.io/lioramilbaum/ocm or ctf::/path)}"
VERIFY_CONFIG="${VERIFY_CONFIG:?VERIFY_CONFIG is required}"
VERSION="${VERSION:-0.1.0}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
ROOT_COMPONENT="github.com/lioramilbaum/platform"

# Clear any environment that could weaken or redirect the deployment
unset SKIP_VERIFY CTF OCM KIND_VERSION KIND_SHA256_DARWIN_ARM64
unset KIND_SHA256_LINUX_ARM64 KIND_SHA256 OCM_CLI_SHA256_LINUX_ARM64 OCM_CLI_SHA256
unset KIND_DIST_DIR KIND_DIST_FILE KIND_BIN
unset OCM_CLI_VERSION OCM_CLI_SHA256_DARWIN_ARM64 OCM_CLI_DIST_DIR OCM_CLI_DIST_FILE

# Standalone helpers
die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Required tool not found: $bin"
  done
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "No sha256 tool found (shasum or sha256sum)"
  fi
}

platform_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
[[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] || die "Only arm64 is supported"
case "$platform_os" in
  darwin) bootstrap_sha="$OCM_BOOTSTRAP_SHA256_DARWIN_ARM64" ;;
  linux) bootstrap_sha="$OCM_BOOTSTRAP_SHA256_LINUX_ARM64" ;;
  *) die "Unsupported OS: $platform_os" ;;
esac
require jq
[[ "${OFFLINE:-0}" == "1" ]] || require curl

[[ -f "$VERIFY_CONFIG" ]] || die "VERIFY_CONFIG not found: $VERIFY_CONFIG"

# ── Step 1: install bootstrap OCM ──────────────────────────────────────────
boot_dir="$BUILD_DIR/bootstrap/bin"
boot_ocm="${BOOTSTRAP_OCM:-$boot_dir/ocm}"
if [[ "${OFFLINE:-0}" == "1" ]]; then
  [[ -f "$boot_ocm" && "$(sha256 "$boot_ocm")" == "$bootstrap_sha" ]] || die "Offline bootstrap OCM missing or checksum mismatch"
fi
mkdir -p "$boot_dir"

if [[ -f "$boot_ocm" ]] && [[ "$(sha256 "$boot_ocm")" == "$bootstrap_sha" ]]; then
  echo "bootstrap ocm $OCM_BOOTSTRAP_VERSION already cached"
else
  tmp_ocm="$(mktemp "$boot_dir/.ocm.XXXXXX")"
  trap 'rm -f "$tmp_ocm"' EXIT
  echo "Downloading bootstrap OCM $OCM_BOOTSTRAP_VERSION ..."
  curl -sSfL "${OCM_BOOTSTRAP_BASE_URL}/${OCM_BOOTSTRAP_VERSION}/ocm-${platform_os}-arm64" -o "$tmp_ocm"
  actual="$(sha256 "$tmp_ocm")"
  [[ "$actual" == "$bootstrap_sha" ]] || \
    die "bootstrap ocm checksum mismatch (expected $bootstrap_sha, got $actual)"
  chmod 0755 "$tmp_ocm"
  mv -f "$tmp_ocm" "$boot_ocm"
  trap - EXIT
fi

# ── Step 2: pull component into local CTF ──────────────────────────────────
if [[ "${OFFLINE:-0}" == "1" ]]; then
  [[ "$OCM_REPO" == ctf::* ]] || die "Offline mode requires a local CTF"
  local_ctf="${OCM_REPO#ctf::}"
  [[ -d "$local_ctf" ]] || die "Offline CTF missing"
else
  local_ctf="$BUILD_DIR/ctf"
  [[ "$OCM_REPO" != "ctf::$local_ctf" ]] || \
    die "OCM_REPO resolves to the local CTF destination ($local_ctf) — it would overwrite itself"
  rm -rf "$local_ctf"
  echo "Transferring component from $OCM_REPO ..."
  "$boot_ocm" transfer cv \
    "$OCM_REPO//$ROOT_COMPONENT:$VERSION" \
    "ctf::$local_ctf" \
    --copy-resources

fi

# ── Step 3: verify component signature ────────────────────────────────────
echo "Verifying component signature ..."
"$boot_ocm" verify cv \
  --config "$VERIFY_CONFIG" \
  "ctf::$local_ctf//$ROOT_COMPONENT:$VERSION"

# ── Step 4: digest-checked download of all resources ──────────────────────
cv_ref="ctf::${local_ctf}//${ROOT_COMPONENT}:${VERSION}"
cv_json="$("$boot_ocm" get cv "$cv_ref" -o json)"

fetch_verified() {
  local identity="$1" dest="$2"
  local expected
  local resource_name
  # Extract the resource name from the identity string (first value after "name=")
  resource_name="$(echo "$identity" | grep -o 'name=[^,]*' | cut -d= -f2)"
  expected="$(echo "$cv_json" | jq -r \
    --arg name "$resource_name" \
    '[.[0].component.resources[] |
      select(.name == $name)
    ] | .[0].digest.value')"
  [[ -n "$expected" && "$expected" != "null" ]] || \
    die "resource '$identity' not found in component descriptor"

  local tmpdir
  tmpdir="$(mktemp -d "$(dirname "$dest")/.fetch.XXXXXX")"
  trap 'rm -rf "$tmpdir"' RETURN
  "$boot_ocm" download resource "$cv_ref" \
    --identity "$identity" \
    --output "$tmpdir/blob"
  local actual
  actual="$(sha256 "$tmpdir/blob")"
  [[ "$actual" == "$expected" ]] || \
    die "digest mismatch for '$identity' (expected $expected, got $actual)"
  mv -f "$tmpdir/blob" "$dest"
}

# OCM binary
mkdir -p "$BUILD_DIR/deploy/bin"
rm -f "$BUILD_DIR/deploy/bin/ocm"
fetch_verified "name=ocm,os=${platform_os},architecture=arm64" "$BUILD_DIR/deploy/bin/ocm"
chmod 0755 "$BUILD_DIR/deploy/bin/ocm"
component_ocm="$BUILD_DIR/deploy/bin/ocm"

# Scripts bundle
bundle_dir="$BUILD_DIR/bundle"
rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/scripts"
for s in lib verify kind-config kind-bin deploy; do
  fetch_verified "name=script-$s" "$bundle_dir/scripts/$s.sh"
done
fetch_verified "name=component-constructor" "$bundle_dir/component-constructor.yaml"

# ── Step 5: cross-check component OCM digest against constructor label ─────
label_sha="$(awk -v label="ocm.lioramilbaum.github.com/sha256sum-${platform_os}-arm64" '$0 ~ label {getline; gsub(/.*value: "|"/, ""); print; exit}' "$bundle_dir/component-constructor.yaml")"
actual_ocm_sha="$(sha256 "$component_ocm")"
[[ "$actual_ocm_sha" == "$label_sha" ]] || \
  die "component OCM digest ($actual_ocm_sha) does not match constructor label ($label_sha)"
"$component_ocm" version >/dev/null || die "component OCM smoke test failed"
echo "component OCM verified: $("$component_ocm" version | head -1)"

# ── Step 6: hand off to deploy.sh ─────────────────────────────────────────
echo "Handing off to deploy.sh ..."
exec env \
  OCM="$component_ocm" \
  CTF="$local_ctf" \
  BUILD_DIR="$BUILD_DIR" \
  VERSION="$VERSION" \
  VERIFY_CONFIG="$VERIFY_CONFIG" \
  bash "$bundle_dir/scripts/deploy.sh"
