#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

# OCM file inputs are confined to the constructor directory; KIND_DIST_DIR and OCM_CLI_DIST_DIR must be inside ROOT.
case "$(cd "$KIND_DIST_DIR" 2>/dev/null && pwd || echo "$KIND_DIST_DIR")" in
  "$ROOT"/*)  ;;
  *)          die "KIND_DIST_DIR must be inside \$ROOT ($KIND_DIST_DIR is not under $ROOT)" ;;
esac

case "$(cd "$OCM_CLI_DIST_DIR" 2>/dev/null && pwd || echo "$OCM_CLI_DIST_DIR")" in
  "$ROOT"/*)  ;;
  *)          die "OCM_CLI_DIST_DIR must be inside \$ROOT ($OCM_CLI_DIST_DIR is not under $ROOT)" ;;
esac

bash "$(dirname "$0")/fetch-kind.sh"
bash "$(dirname "$0")/fetch-ocm.sh"

mkdir -p "$BUILD_DIR"
rm -rf "$CTF"

# OCM_ADD_FLAGS is a user-supplied, space-separated list of extra flags;
# word splitting is intentional and an unset value must add no argument.
# shellcheck disable=SC2086
"$OCM" add cv \
  --repository "ctf::${CTF}" \
  --constructor "$ROOT/component-constructor.yaml" \
  --blob-cache-directory "$BUILD_DIR/.ocm-cache" \
  ${OCM_ADD_FLAGS:-}

"$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" --recursive -o tree
