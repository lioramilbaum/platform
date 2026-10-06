#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require "$OCM" docker jq
require_platform
# shellcheck source=scripts/verify.sh
source "$(dirname "$0")/verify.sh"
SKIP_VERIFY=1 bash "$(dirname "$0")/kind-config.sh"
SKIP_VERIFY=1 bash "$(dirname "$0")/kind-bin.sh"
require "$KIND_BIN"
KIND_CLUSTER="$(kind_cluster_name)" && [[ -n "$KIND_CLUSTER" ]] || die "Verified cluster config has no cluster name"
image="$(awk '/^[[:space:]]+image:/{print $2; exit}' "$BUILD_DIR/deploy/kind-cluster.yaml")"
[[ -n "$image" ]] || die "Verified cluster config has no node image"
archive="$BUILD_DIR/deploy/kind-node.tar"
rm -f "$archive"
expected="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].component.resources[] | select(.name=="kind-node-image") | .digest.value')"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || die "Signed node image resource missing"
"$OCM" download resource "$(cv_ref)" --identity name=kind-node-image,os=linux,architecture=arm64 --output "$archive"
[[ "$(sha256 "$archive")" == "$expected" ]] || die "Node image archive digest mismatch"
docker load -i "$archive"
docker image inspect "$image" | jq -e 'length == 1 and .[0].Os == "linux" and .[0].Architecture == "arm64"' >/dev/null || die "Loaded node image has wrong platform"
if ! "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  "$KIND_BIN" create cluster --config "$BUILD_DIR/deploy/kind-cluster.yaml" --image "$image" --wait "${READY_TIMEOUT:-180s}"
fi
node="${KIND_CLUSTER}-control-plane"
docker exec "$node" kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout="${READY_TIMEOUT:-180s}"
docker exec "$node" kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system rollout status deployment/coredns --timeout="${READY_TIMEOUT:-180s}"
docker exec "$node" kubectl --kubeconfig=/etc/kubernetes/admin.conf -n local-path-storage rollout status deployment/local-path-provisioner --timeout="${READY_TIMEOUT:-180s}"
echo "kind cluster $KIND_CLUSTER is ready (kubeconfig context kind-$KIND_CLUSTER)"
