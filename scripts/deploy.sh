#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" docker

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  # shellcheck source=scripts/verify.sh
  source "$(dirname "$0")/verify.sh"
fi

SKIP_VERIFY=1 bash "$(dirname "$0")/kind-config.sh"
SKIP_VERIFY=1 bash "$(dirname "$0")/kind-bin.sh"

require "$KIND_BIN"

KIND_CLUSTER="$(awk '/^name:/{print $2}' "$BUILD_DIR/deploy/kind-cluster.yaml")"

if ! "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  "$KIND_BIN" create cluster --config "$BUILD_DIR/deploy/kind-cluster.yaml"
fi

echo "kind cluster $KIND_CLUSTER deployed (kubeconfig context kind-$KIND_CLUSTER)"
