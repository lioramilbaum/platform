#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker jq
require_platform
bash "$(dirname "$0")/kind-config.sh"
bash "$(dirname "$0")/kind-bin.sh"
require "$KIND_BIN"
KIND_CLUSTER="$(kind_cluster_name)" && [[ -n "$KIND_CLUSTER" ]] || die "Cluster config has no cluster name"
image="$(awk '/^[[:space:]]+image:/{print $2; exit}' "$BUILD_DIR/deploy/kind-cluster.yaml")"
[[ -n "$image" ]] || die "Cluster config has no node image"
[[ -f "$KIND_IMAGE_ARCHIVE" ]] || die "Node image archive missing; run make fetch-image"
docker load -i "$KIND_IMAGE_ARCHIVE"
docker image inspect "$image" | jq -e 'length == 1 and .[0].Os == "linux" and .[0].Architecture == "arm64"' >/dev/null || die "Loaded node image has wrong platform"
if ! "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  "$KIND_BIN" create cluster --config "$BUILD_DIR/deploy/kind-cluster.yaml" --image "$image" --wait "${READY_TIMEOUT:-180s}"
fi
node="${KIND_CLUSTER}-control-plane"
docker exec "$node" kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout="${READY_TIMEOUT:-180s}"
docker exec "$node" kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system rollout status deployment/coredns --timeout="${READY_TIMEOUT:-180s}"
docker exec "$node" kubectl --kubeconfig=/etc/kubernetes/admin.conf -n local-path-storage rollout status deployment/local-path-provisioner --timeout="${READY_TIMEOUT:-180s}"
echo "kind cluster $KIND_CLUSTER is ready (kubeconfig context kind-$KIND_CLUSTER)"
