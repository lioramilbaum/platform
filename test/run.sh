#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  # shellcheck disable=SC2030
  if (set -euo pipefail; export BUILD_DIR="$tmp" CTF="$tmp/ctf"; "$2" "$tmp"); then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
  trap - EXIT
  rm -rf "$tmp"
}

assert_eq() {
  local got="$1" expected="$2"
  if [[ "$got" != "$expected" ]]; then
    echo "  assert_eq failed: got '$got', expected '$expected'" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  if ! grep -qF "$needle" <<< "$haystack"; then
    echo "  assert_contains failed: '$needle' not found in output" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if grep -qF "$needle" <<< "$haystack"; then
    echo "  assert_not_contains failed: '$needle' was found in output" >&2
    return 1
  fi
}

assert_fails() {
  if "$@"; then
    echo "  assert_fails: command succeeded unexpectedly: $*" >&2
    return 1
  fi
}

_build() {
  bash "$ROOT/scripts/build.sh" >/dev/null
}

_sign() {
  bash "$ROOT/scripts/sign.sh" >/dev/null
}

_verify() {
  bash "$ROOT/scripts/verify.sh" >/dev/null
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_build_produces_platform_tree() {
  local tmp="$1"
  _build
  local count
  count=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    --recursive -o json 2>/dev/null | jq 'length')
  assert_eq "$count" "1"
  local resource_names
  resource_names=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq -r '.[0].component.resources[].name' | sort | paste -sd, -)
  assert_eq "$resource_names" "kind,kind-cluster"
  local ref_count
  ref_count=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq '.[0].component.componentReferences // [] | length')
  assert_eq "$ref_count" "0"
}

test_platform_resources() {
  local tmp="$1"
  _build
  local resources
  resources=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq -r '.[0].component.resources')

  local kind_cluster_type
  kind_cluster_type=$(jq -r '.[] | select(.name=="kind-cluster") | .type' <<< "$resources")
  assert_eq "$kind_cluster_type" "blob"

  local kind_type
  kind_type=$(jq -r '.[] | select(.name=="kind") | .type' <<< "$resources")
  assert_eq "$kind_type" "executable"

  local kind_os
  kind_os=$(jq -r '.[] | select(.name=="kind") | .extraIdentity.os' <<< "$resources")
  assert_eq "$kind_os" "darwin"

  local kind_arch
  kind_arch=$(jq -r '.[] | select(.name=="kind") | .extraIdentity.architecture' <<< "$resources")
  assert_eq "$kind_arch" "arm64"
}

test_sign_and_verify() {
  local tmp="$1"
  _build
  _sign
  [[ -f "$tmp/sign.ocmconfig" ]] || { echo "  sign.ocmconfig not created" >&2; return 1; }
  _verify
}

test_verify_rejects_wrong_key() {
  local tmp="$1"
  _build
  _sign

  # Generate a different keypair
  local alt_dir="$tmp/alt-keys"
  mkdir -p "$alt_dir"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$alt_dir/private.pem" 2>/dev/null
  openssl rsa -pubout -in "$alt_dir/private.pem" \
    -out "$alt_dir/public.pem" 2>/dev/null

  cat > "$tmp/verify-wrong.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: ${alt_dir}/public.pem
EOF

  VERIFY_CONFIG="$tmp/verify-wrong.ocmconfig" assert_fails bash "$ROOT/scripts/verify.sh" \
    2>/dev/null
}

test_version_is_propagated() {
  local tmp="$1"
  export VERSION=9.9.9
  _build
  local cv_out
  cv_out=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:9.9.9" \
    -o json 2>/dev/null)
  local component_version
  component_version=$(jq -r '.[0].component.version' <<< "$cv_out")
  assert_eq "$component_version" "9.9.9"
  local kind_cluster_version
  kind_cluster_version=$(jq -r '.[0].component.resources[] | select(.name=="kind-cluster") | .version' <<< "$cv_out")
  assert_eq "$kind_cluster_version" "9.9.9"
  local kind_version
  kind_version=$(jq -r '.[0].component.resources[] | select(.name=="kind") | .version' <<< "$cv_out")
  assert_eq "$kind_version" "$KIND_VERSION"
}

test_kind_cluster_resource() {
  local tmp="$1"
  _build

  SKIP_VERIFY=1 bash "$ROOT/scripts/kind-config.sh" >/dev/null

  local config
  config=$(cat "$tmp/deploy/kind-cluster.yaml")

  assert_contains "$config" "kind: Cluster"
  assert_contains "$config" "apiVersion: kind.x-k8s.io/v1alpha4"
  assert_contains "$config" "name: ocm-platform"
  assert_contains "$config" "role: control-plane"
}

test_kind_resource_identity_and_digest() {
  local tmp="$1"
  _build
  local os arch digest
  os="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].component.resources[] | select(.name=="kind") | .extraIdentity.os')" || return 1
  arch="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].component.resources[] | select(.name=="kind") | .extraIdentity.architecture')" || return 1
  digest="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].component.resources[] | select(.name=="kind") | .digest.value')" || return 1
  assert_eq "$os" "darwin"
  assert_eq "$arch" "arm64"
  # Verify digest matches the pinned sha256 from constructor
  assert_eq "$digest" "$KIND_SHA256_DARWIN_ARM64"
}

test_fetch_kind_rejects_bad_checksum() {
  local tmp="$1"
  # Serve a real binary from a file:// URL, but with a wrong KIND_SHA256_DARWIN_ARM64.
  # fetch-kind.sh must reject it.
  mkdir -p "$tmp/release/$KIND_VERSION"
  echo "fakebinary" > "$tmp/release/$KIND_VERSION/kind-darwin-arm64"

  # Pre-create the dest file
  mkdir -p "$tmp/dist"
  echo "previous" > "$tmp/dist/$KIND_DIST_FILE"

  # Test that fetch-kind.sh rejects the bad checksum
  KIND_BASE_URL="file://$tmp/release" KIND_DIST_DIR="$tmp/dist" \
    assert_fails bash "$ROOT/scripts/fetch-kind.sh" || return 1

  # Verify the dest file is either gone or unchanged (checksum mismatch prevented overwrite)
  if [[ -f "$tmp/dist/$KIND_DIST_FILE" ]]; then
    [[ "$(cat "$tmp/dist/$KIND_DIST_FILE")" == "previous" ]] || return 1
  fi
}

test_build_rejects_kind_dist_dir_outside_root() {
  local tmp="$1"
  KIND_DIST_DIR="$tmp/dist" assert_fails bash "$ROOT/scripts/build.sh" || return 1
}

test_kind_bin_installs_verified_executable() {
  local tmp="$1"
  [[ "$(host_os)" == "darwin" && "$(host_arch)" == "arm64" ]] || { echo "SKIP (not darwin/arm64)"; return 0; }
  _build
  SKIP_VERIFY=1 bash "$ROOT/scripts/sign.sh"
  unset KIND_BIN
  SKIP_VERIFY=1 bash "$ROOT/scripts/kind-bin.sh"
  # shellcheck disable=SC2031
  [[ -x "$BUILD_DIR/deploy/bin/kind" ]] || return 1
  local actual
  # shellcheck disable=SC2031
  actual="$(sha256 "$BUILD_DIR/deploy/bin/kind")" || return 1
  # Verify hash matches the pinned sha256 from constructor
  [[ "$actual" == "$KIND_SHA256_DARWIN_ARM64" ]] || return 1
  # shellcheck disable=SC2031
  "$BUILD_DIR/deploy/bin/kind" version 2>&1 | grep -q "kind $KIND_VERSION" || return 1
}

test_kind_bin_is_idempotent() {
  local tmp="$1"
  [[ "$(host_os)" == "darwin" && "$(host_arch)" == "arm64" ]] || { echo "SKIP (not darwin/arm64)"; return 0; }
  _build
  SKIP_VERIFY=1 bash "$ROOT/scripts/sign.sh"
  unset KIND_BIN
  SKIP_VERIFY=1 bash "$ROOT/scripts/kind-bin.sh"
  unset KIND_BIN
  SKIP_VERIFY=1 bash "$ROOT/scripts/kind-bin.sh"
  local actual
  # shellcheck disable=SC2031
  actual="$(sha256 "$BUILD_DIR/deploy/bin/kind")" || return 1
  # Verify hash is a valid 64-character hex string (SHA256)
  [[ "$actual" =~ ^[a-f0-9]{64}$ ]] || return 1
}

test_kind_config_is_idempotent() {
  local tmp="$1"
  _build
  SKIP_VERIFY=1 bash "$ROOT/scripts/kind-config.sh"
  SKIP_VERIFY=1 bash "$ROOT/scripts/kind-config.sh"
  local count
  # shellcheck disable=SC2031
  count="$(grep -c '^kind: Cluster' "$BUILD_DIR/deploy/kind-cluster.yaml")" || return 1
  [[ "$count" -eq 1 ]] || return 1
}

# ── Run all tests ─────────────────────────────────────────────────────────────

run_test "build produces platform tree" test_build_produces_platform_tree
run_test "platform resources are correct" test_platform_resources
run_test "sign and verify succeed" test_sign_and_verify
run_test "verify rejects wrong key" test_verify_rejects_wrong_key
run_test "version is propagated to component and resources" test_version_is_propagated
run_test "kind cluster resource in component" test_kind_cluster_resource
run_test "kind resource identity and digest" test_kind_resource_identity_and_digest
run_test "fetch kind rejects bad checksum" test_fetch_kind_rejects_bad_checksum
run_test "build rejects kind dist dir outside root" test_build_rejects_kind_dist_dir_outside_root
run_test "kind bin installs verified executable" test_kind_bin_installs_verified_executable
run_test "kind bin is idempotent" test_kind_bin_is_idempotent
run_test "kind config is idempotent" test_kind_config_is_idempotent

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
