#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM"

# resource digests in the descriptor are covered by the component signature
# (ocm v0.17 has no --recursive flag for sign cv)

"$OCM" sign cv \
  --config "$BUILD_DIR/sign.ocmconfig" \
  "$(cv_ref "$ROOT_COMPONENT")"
