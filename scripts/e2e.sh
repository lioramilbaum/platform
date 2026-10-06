#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# shellcheck disable=SC2329
cleanup_cluster() {
  local name
  name="$(kind_cluster_name 2>/dev/null)" || return 0
  [[ -n "$name" ]] && "$KIND_BIN" delete cluster --name "$name" 2>/dev/null || true
}
if [[ "${KEEP_CLUSTER:-0}" != "1" ]]; then
  trap cleanup_cluster EXIT
fi

bash "$(dirname "$0")/deploy.sh"
KIND_CLUSTER="$(kind_cluster_name)"
require "$KIND_BIN"
"$KIND_BIN" get nodes --name "$KIND_CLUSTER" | grep -q control-plane
echo "kind cluster $KIND_CLUSTER is healthy"
