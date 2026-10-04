#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  # shellcheck source=scripts/verify.sh
  source "$(dirname "$0")/verify.sh"
fi

mkdir -p "$BUILD_DIR/deploy"

# ocm v0.17 appends to an existing output file instead of truncating it.
rm -f "$BUILD_DIR/deploy/kind-cluster.yaml"

"$OCM" download resource \
  "$(cv_ref "$ROOT_COMPONENT")" \
  --identity name=kind-cluster \
  --output "$BUILD_DIR/deploy/kind-cluster.yaml"

echo "Kind cluster config written to $BUILD_DIR/deploy/kind-cluster.yaml"
