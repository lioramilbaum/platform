#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_platform

bash "$(dirname "$0")/fetch-kind.sh"
src="$KIND_DIST_DIR/$KIND_DIST_FILE"
[[ "$(sha256 "$src")" == "$KIND_SHA256" ]] || die "kind checksum mismatch for $src (expected $KIND_SHA256)"

mkdir -p "$(dirname "$KIND_BIN")"
tmp="$(mktemp "$(dirname "$KIND_BIN")/.kind.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

cp "$src" "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" "$KIND_BIN"
echo "kind $KIND_VERSION ${PLATFORM_OS}/arm64 installed at $KIND_BIN"
