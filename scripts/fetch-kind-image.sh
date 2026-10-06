#!/usr/bin/env bash
# Connected-side only: save the pinned node image under the tag kind uses offline.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker tar jq
require_platform
[[ "$KIND_NODE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Missing pinned kind node image digest"
mkdir -p "$(dirname "$KIND_IMAGE_ARCHIVE")"
work="$(mktemp -d "$(dirname "$KIND_IMAGE_ARCHIVE")/.image.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ref="$KIND_NODE_IMAGE@$KIND_NODE_DIGEST"
docker pull --platform linux/arm64 "$ref"
docker tag "$ref" "$KIND_NODE_IMAGE"
docker save -o "$work/image.tar" "$KIND_NODE_IMAGE"
tar -xOf "$work/image.tar" manifest.json | jq -e --arg tag "$KIND_NODE_IMAGE" \
  'length == 1 and (.[0].RepoTags | index($tag) != null)' >/dev/null || die "Saved image is missing runtime tag"
config="$(tar -xOf "$work/image.tar" manifest.json | jq -r '.[0].Config')"
tar -xOf "$work/image.tar" "$config" | jq -e '.os == "linux" and .architecture == "arm64"' >/dev/null || die "Saved image has wrong architecture"
mv "$work/image.tar" "$KIND_IMAGE_ARCHIVE"
echo "Pinned kind node image saved to $KIND_IMAGE_ARCHIVE"
