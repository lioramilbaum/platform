#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
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
  count=$("${OCM:-ocm}" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    --recursive -o json 2>/dev/null | jq 'length')
  assert_eq "$count" "1"
  local resource_names
  resource_names=$("${OCM:-ocm}" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq -r '.[0].component.resources[].name' | sort | paste -sd, -)
  assert_eq "$resource_names" "kind-cluster"
  local ref_count
  ref_count=$("${OCM:-ocm}" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq '.[0].component.componentReferences // [] | length')
  assert_eq "$ref_count" "0"
}

test_platform_resources() {
  local tmp="$1"
  _build
  local resources
  resources=$("${OCM:-ocm}" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq -r '.[0].component.resources')

  local kind_cluster_type
  kind_cluster_type=$(jq -r '.[] | select(.name=="kind-cluster") | .type' <<< "$resources")
  assert_eq "$kind_cluster_type" "blob"
}

test_sign_and_verify() {
  local tmp="$1"
  _build
  _sign
  [[ -f "$BUILD_DIR/sign.ocmconfig" ]] || { echo "  sign.ocmconfig not created" >&2; return 1; }
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
  cv_out=$("${OCM:-ocm}" get cv "ctf::${tmp}/ctf//github.com/lmilbaum/platform:9.9.9" \
    -o json 2>/dev/null)
  local component_version
  component_version=$(jq -r '.[0].component.version' <<< "$cv_out")
  assert_eq "$component_version" "9.9.9"
  local kind_cluster_version
  kind_cluster_version=$(jq -r '.[0].component.resources[] | select(.name=="kind-cluster") | .version' <<< "$cv_out")
  assert_eq "$kind_cluster_version" "9.9.9"
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

# ── Run all tests ─────────────────────────────────────────────────────────────

run_test "build produces platform tree" test_build_produces_platform_tree
run_test "platform resources are correct" test_platform_resources
run_test "sign and verify succeed" test_sign_and_verify
run_test "verify rejects wrong key" test_verify_rejects_wrong_key
run_test "version is propagated to component and resources" test_version_is_propagated
run_test "kind cluster resource in component" test_kind_cluster_resource

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
