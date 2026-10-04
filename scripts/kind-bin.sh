#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq
require_darwin_arm64

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  # shellcheck source=scripts/verify.sh
  source "$(dirname "$0")/verify.sh"
fi

# OCM v0.17 uses genericBlobDigest/v1: descriptor .digest.value is the raw SHA-256 of the file bytes
expected="$("$OCM" get cv "$(cv_ref)" -o json \
  | jq -r '.[0].component.resources[]
    | select(.name=="kind"
      and .extraIdentity.os=="darwin"
      and .extraIdentity.architecture=="arm64")
    | .digest.value')"

[[ "$expected" == "$KIND_SHA256_DARWIN_ARM64" ]] \
  || die "kind descriptor digest ($expected) does not match pinned checksum ($KIND_SHA256_DARWIN_ARM64)"

mkdir -p "$(dirname "$KIND_BIN")"
tmpdir="$(mktemp -d "$(dirname "$KIND_BIN")/.kind.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

"$OCM" download resource \
  "$(cv_ref)" \
  --identity "name=kind,os=darwin,architecture=arm64" \
  --output "$tmpdir/kind"

# OCM v0.17 uses genericBlobDigest/v1 normalization for file-input resources,
# meaning the descriptor .digest.value is the plain SHA-256 of the raw file bytes.
actual="$(sha256 "$tmpdir/kind")"
[[ "$actual" == "$expected" ]] \
  || die "kind download digest mismatch (expected $expected, got $actual)"

chmod 0755 "$tmpdir/kind"
mv -f "$tmpdir/kind" "$KIND_BIN"
echo "kind $KIND_VERSION darwin/arm64 installed at $KIND_BIN"
