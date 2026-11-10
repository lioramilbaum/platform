#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

mkdir -p "$BUILD_DIR/deploy"
cp "$ROOT/components/kind/cluster.yaml" "$BUILD_DIR/deploy/kind-cluster.yaml"

echo "Kind cluster config written to $BUILD_DIR/deploy/kind-cluster.yaml"
