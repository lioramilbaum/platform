#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
# Unit fixtures exercise the kind node image archive without pulling a multi-GB image.
# The e2e target tests the real digest-pinned Docker image.
fixture_dir="$(mktemp -d "$ROOT/bin/dist/.test-image.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
printf '[{"Config":"config.json","RepoTags":["kindest/node:v1.37.0"],"Layers":[]}]' > "$fixture_dir/manifest.json"
printf '{"os":"linux","architecture":"arm64"}' > "$fixture_dir/config.json"
tar -cf "$fixture_dir/image.tar" -C "$fixture_dir" manifest.json config.json
export KIND_IMAGE_ARCHIVE="$fixture_dir/image.tar"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp' '$fixture_dir'" EXIT
  # shellcheck disable=SC2030
  if (set -euo pipefail; export BUILD_DIR="$tmp"; "$2" "$tmp"); then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
  trap 'rm -rf "$fixture_dir"' EXIT
  rm -rf "$tmp"
}

assert_eq() {
  local got="$1" expected="$2" msg="${3:-}"
  if [[ "$got" != "$expected" ]]; then
    echo "  assert_eq failed${msg:+ ($msg)}: got '$got', expected '$expected'" >&2
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

_stub_docker() {
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../docker.log"
exit 1
EOF
  chmod 0755 "$dir/stub-bin/docker"
  echo "$dir/stub-bin"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_kind_cluster_resource() {
  local tmp="$1"
  bash "$ROOT/scripts/kind-config.sh" >/dev/null

  local config
  config=$(cat "$tmp/deploy/kind-cluster.yaml")

  assert_contains "$config" "kind: Cluster"
  assert_contains "$config" "apiVersion: kind.x-k8s.io/v1alpha4"
  assert_contains "$config" "name: platform"
  assert_contains "$config" "role: control-plane"
}

test_fetch_kind_rejects_bad_checksum() {
  local tmp="$1"
  # Serve a real binary from a file:// URL, but with a wrong KIND_SHA256_DARWIN_ARM64.
  # fetch-kind.sh must reject it.
  mkdir -p "$tmp/release/$KIND_VERSION"
  echo "fakebinary" > "$tmp/release/$KIND_VERSION/kind-${PLATFORM_OS}-arm64"

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

test_kind_bin_installs_verified_executable() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || { echo "SKIP (not darwin/arm64)"; return 0; }
  unset KIND_BIN
  bash "$ROOT/scripts/kind-bin.sh" >/dev/null
  [[ -x "$tmp/deploy/bin/kind" ]] || return 1
  local actual
  actual="$(sha256 "$tmp/deploy/bin/kind")" || return 1
  # Verify hash matches the pinned sha256 from lib.sh
  [[ "$actual" == "$KIND_SHA256" ]] || return 1
  "$tmp/deploy/bin/kind" version 2>&1 | grep -q "kind $KIND_VERSION" || return 1
}

test_kind_bin_is_idempotent() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || { echo "SKIP (not darwin/arm64)"; return 0; }
  unset KIND_BIN
  bash "$ROOT/scripts/kind-bin.sh" >/dev/null
  bash "$ROOT/scripts/kind-bin.sh" >/dev/null
  local actual
  actual="$(sha256 "$tmp/deploy/bin/kind")" || return 1
  # Verify hash is a valid 64-character hex string (SHA256)
  [[ "$actual" =~ ^[a-f0-9]{64}$ ]] || return 1
}

test_kind_config_is_idempotent() {
  local tmp="$1"
  bash "$ROOT/scripts/kind-config.sh" >/dev/null
  bash "$ROOT/scripts/kind-config.sh" >/dev/null
  local count
  count="$(grep -c '^kind: Cluster' "$tmp/deploy/kind-cluster.yaml")" || return 1
  [[ "$count" -eq 1 ]] || return 1
}

test_deploy_runs_all_steps() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || return 0
  unset KIND_BIN

  local stub
  stub="$(_stub_docker "$tmp")"

  # deploy.sh should fail at docker load (fake docker), but run all prior steps
  PATH="$stub:$PATH" \
    assert_fails bash "$ROOT/scripts/deploy.sh" || return 1

  # kind-cluster.yaml must have been written
  grep -q "kind: Cluster" "$tmp/deploy/kind-cluster.yaml" || \
    { echo "  kind-config step did not run" >&2; return 1; }

  # kind binary must be installed with correct sha256
  local actual
  actual="$(sha256 "$tmp/deploy/bin/kind")"
  assert_eq "$actual" "$KIND_SHA256" "kind binary sha256 after deploy" || return 1

  # docker must have been invoked with the node image archive
  [[ -s "$tmp/docker.log" ]] || { echo "  docker was not invoked" >&2; return 1; }
  assert_contains "$(cat "$tmp/docker.log")" "load -i $KIND_IMAGE_ARCHIVE"
}

test_lib_dies_on_unsupported_os() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/stub"
  # Stub uname: -s prints FreeBSD, -m prints arm64
  cat > "$tmpdir/stub/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in -s) echo FreeBSD;; -m) echo arm64;; esac
EOF
  chmod +x "$tmpdir/stub/uname"
  local out
  out="$(PATH="$tmpdir/stub:$PATH" bash -c 'source "$1"' _ "$ROOT/scripts/lib.sh" 2>&1)" \
    && return 1  # should have exited non-zero
  assert_contains "$out" "ERROR: Unsupported operating system"
}

test_e2e_cleanup_uses_configured_cluster_name() {
  local tmpdir="$1"
  mkdir -p "$tmpdir/scripts" "$tmpdir/deploy"
  cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/e2e.sh" "$tmpdir/scripts/"
  # Stub deploy.sh: writes a cluster config with a different name then exits 1
  cat > "$tmpdir/scripts/deploy.sh" <<'DEPLOY'
#!/usr/bin/env bash
mkdir -p "$BUILD_DIR/deploy"
printf 'kind: Cluster\nname: renamed-cluster\n' > "$BUILD_DIR/deploy/kind-cluster.yaml"
exit 1
DEPLOY
  chmod +x "$tmpdir/scripts/deploy.sh"
  # Stub kind: log every invocation
  cat > "$tmpdir/kind" <<'KIND'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/kind.log"
KIND
  chmod +x "$tmpdir/kind"
  BUILD_DIR="$tmpdir" KIND_BIN="$tmpdir/kind" KEEP_CLUSTER=0 \
    bash "$tmpdir/scripts/e2e.sh" >/dev/null 2>&1 || true
  assert_contains "$(cat "$tmpdir/kind.log" 2>/dev/null)" "delete cluster --name renamed-cluster"
}

test_no_ocm_references() {
  local out status=0
  # Tracked files only: git grep skips untracked and ignored paths.
  out="$(git -C "$ROOT" grep -nIi -e open-component-model -e component-constructor -e ocmconfig -e 'ctf::' -e 'OCM_' -- . ':!test/run.sh')" || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "$out" >&2
    echo "  OCM reference found" >&2
    return 1
  fi
  [[ "$status" -eq 1 ]] || { echo "  git grep failed (status $status)" >&2; return 1; }

  status=0
  out="$(git -C "$ROOT" grep -nIiw ocm -- . ':!test/run.sh')" || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "$out" >&2
    echo "  OCM reference found" >&2
    return 1
  fi
  [[ "$status" -eq 1 ]] || { echo "  git grep failed (status $status)" >&2; return 1; }
}

# ── Run all tests ─────────────────────────────────────────────────────────────

run_test "kind cluster resource in config" test_kind_cluster_resource
run_test "fetch kind rejects bad checksum" test_fetch_kind_rejects_bad_checksum
run_test "kind bin installs verified executable" test_kind_bin_installs_verified_executable
run_test "kind bin is idempotent" test_kind_bin_is_idempotent
run_test "kind config is idempotent" test_kind_config_is_idempotent
run_test "deploy runs all steps" test_deploy_runs_all_steps
run_test "lib dies on unsupported os" test_lib_dies_on_unsupported_os
run_test "e2e cleanup uses configured cluster name" test_e2e_cleanup_uses_configured_cluster_name
run_test "no ocm references in tracked files" test_no_ocm_references

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
