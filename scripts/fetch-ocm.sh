#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require curl
require_platform

mkdir -p "$OCM_CLI_DIST_DIR"

dest="$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$OCM_CLI_SHA256" ]]; then
  echo "ocm $OCM_CLI_VERSION ${PLATFORM_OS}/arm64 already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$OCM_CLI_DIST_DIR/.ocm.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

curl -sSfL "${OCM_CLI_BASE_URL}/${OCM_CLI_VERSION}/ocm-${PLATFORM_OS}-arm64" -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$OCM_CLI_SHA256" ]]; then
  die "ocm checksum mismatch (expected $OCM_CLI_SHA256, got $actual)"
fi

mv -f "$tmp" "$dest"
trap - EXIT
echo "ocm $OCM_CLI_VERSION ${PLATFORM_OS}/arm64 cached at $dest"
