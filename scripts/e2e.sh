#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

bash "$(dirname "$0")/deploy.sh"

require "$KIND_BIN"

KIND_CLUSTER="$(awk '/^name:/{print $2}' "$BUILD_DIR/deploy/kind-cluster.yaml")"

if [[ "${KEEP_CLUSTER:-0}" != "1" ]]; then
  trap '"$KIND_BIN" delete cluster --name "$KIND_CLUSTER" 2>/dev/null || true' EXIT
fi

"$KIND_BIN" get nodes --name "$KIND_CLUSTER" | grep -q control-plane
echo "kind cluster $KIND_CLUSTER is healthy"
