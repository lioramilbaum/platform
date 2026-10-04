#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require curl

mkdir -p "$KIND_DIST_DIR"

dest="$KIND_DIST_DIR/$KIND_DIST_FILE"

# Use the pinned sha256 from the constructor
expected="$KIND_SHA256_DARWIN_ARM64"
[[ -n "$expected" ]] || die "No pinned checksum available (KIND_SHA256_DARWIN_ARM64 is empty)"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$expected" ]]; then
  echo "kind $KIND_VERSION darwin/arm64 already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$KIND_DIST_DIR/.kind.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Fetching kind $KIND_VERSION darwin/arm64 ..."
curl -sSfL \
  "${KIND_BASE_URL}/${KIND_VERSION}/kind-darwin-arm64" \
  -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$expected" ]]; then
  die "kind checksum mismatch (expected $expected, got $actual)"
fi

mv -f "$tmp" "$dest"
echo "kind $KIND_VERSION darwin/arm64 fetched to $dest"
