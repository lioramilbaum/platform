#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require curl

mkdir -p "$OCM_CLI_DIST_DIR"

dest="$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$OCM_CLI_SHA256_DARWIN_ARM64" ]]; then
  echo "ocm $OCM_CLI_VERSION darwin/arm64 already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$OCM_CLI_DIST_DIR/.ocm.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

curl -sSfL "${OCM_CLI_BASE_URL}/${OCM_CLI_VERSION}/ocm-darwin-arm64" -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$OCM_CLI_SHA256_DARWIN_ARM64" ]]; then
  die "ocm checksum mismatch (expected $OCM_CLI_SHA256_DARWIN_ARM64, got $actual)"
fi

mv -f "$tmp" "$dest"
trap - EXIT
echo "ocm $OCM_CLI_VERSION darwin/arm64 cached at $dest"
