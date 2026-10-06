#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
# Unit fixtures exercise signed resource transport without pulling a multi-GB image.
# The isolated workflow tests the real digest-pinned Docker image.
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
  if (set -euo pipefail; export BUILD_DIR="$tmp" CTF="$tmp/ctf"; "$2" "$tmp"); then
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

_build() {
  bash "$ROOT/scripts/build.sh" >/dev/null
}

_sign() {
  bash "$ROOT/scripts/sign.sh" >/dev/null
}

_verify() {
  bash "$ROOT/scripts/verify.sh" >/dev/null
}

_download_bundle() {
  local dest="$1"
  mkdir -p "$dest/scripts"
  local s
  for s in lib verify kind-config kind-bin deploy bootstrap; do
    # ocm v0.17 appends to existing output files
    rm -f "$dest/scripts/$s.sh"
    "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
      --identity "name=script-$s" --output "$dest/scripts/$s.sh"
  done
  rm -f "$dest/component-constructor.yaml"
  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity name=component-constructor --output "$dest/component-constructor.yaml"
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
  # Also stub ocm to detect if bootstrap ever falls back to PATH ocm
  cat > "$dir/stub-bin/ocm" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../ocm.log"
exit 1
EOF
  chmod 0755 "$dir/stub-bin/ocm"
  echo "$dir/stub-bin"
}

_bootstrap_pin() {
  local var="$1"
  awk -F'"' "/^${var}=/{print \$2}" "$ROOT/scripts/bootstrap.sh"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_build_produces_platform_tree() {
  local tmp="$1"
  _build
  local count
  count=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/platform:${VERSION:-0.1.0}" \
    --recursive -o json 2>/dev/null | jq 'length')
  assert_eq "$count" "1"
  local resource_names
  resource_names=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq -r '.[0].component.resources[].name' | sort | paste -sd, -)
  assert_eq "$resource_names" "component-constructor,kind,kind-cluster,kind-node-image,ocm,script-bootstrap,script-deploy,script-kind-bin,script-kind-config,script-lib,script-verify"
  local ref_count
  ref_count=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq '.[0].component.componentReferences // [] | length')
  assert_eq "$ref_count" "0"
}

test_platform_resources() {
  local tmp="$1"
  _build
  local resources
  resources=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/platform:${VERSION:-0.1.0}" \
    -o json 2>/dev/null | jq -r '.[0].component.resources')

  local kind_cluster_type
  kind_cluster_type=$(jq -r '.[] | select(.name=="kind-cluster") | .type' <<< "$resources")
  assert_eq "$kind_cluster_type" "blob"

  local kind_type
  kind_type=$(jq -r '.[] | select(.name=="kind") | .type' <<< "$resources")
  assert_eq "$kind_type" "executable"

  local kind_os
  kind_os=$(jq -r '.[] | select(.name=="kind") | .extraIdentity.os' <<< "$resources")
  assert_eq "$kind_os" "$PLATFORM_OS"

  local kind_arch
  kind_arch=$(jq -r '.[] | select(.name=="kind") | .extraIdentity.architecture' <<< "$resources")
  assert_eq "$kind_arch" "arm64"

  local ocm_type
  ocm_type=$(jq -r '.[] | select(.name=="ocm") | .type' <<< "$resources")
  assert_eq "$ocm_type" "executable"

  local ocm_os
  ocm_os=$(jq -r '.[] | select(.name=="ocm") | .extraIdentity.os' <<< "$resources")
  assert_eq "$ocm_os" "$PLATFORM_OS"

  local ocm_arch
  ocm_arch=$(jq -r '.[] | select(.name=="ocm") | .extraIdentity.architecture' <<< "$resources")
  assert_eq "$ocm_arch" "arm64"
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
  cv_out=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/platform:9.9.9" \
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
  assert_eq "$os" "$PLATFORM_OS"
  assert_eq "$arch" "arm64"
  # Verify digest matches the pinned sha256 from constructor
  assert_eq "$digest" "$KIND_SHA256"
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

test_build_rejects_kind_dist_dir_outside_root() {
  local tmp="$1"
  KIND_DIST_DIR="$tmp/dist" assert_fails bash "$ROOT/scripts/build.sh" || return 1
}

test_kind_bin_installs_verified_executable() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || { echo "SKIP (not darwin/arm64)"; return 0; }
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
  [[ "$actual" == "$KIND_SHA256" ]] || return 1
  # shellcheck disable=SC2031
  "$BUILD_DIR/deploy/bin/kind" version 2>&1 | grep -q "kind $KIND_VERSION" || return 1
}

test_kind_bin_is_idempotent() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || { echo "SKIP (not darwin/arm64)"; return 0; }
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

test_script_resources_metadata() {
  local tmp="$1"
  _build
  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

  # Check each script resource
  local s
  for s in lib verify kind-config kind-bin deploy bootstrap; do
    local rname="script-$s"
    local rtype mediatype rversion
    rtype="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .type')"
    mediatype="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .access.mediaType')"
    rversion="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .version')"
    local digest expected_digest
    digest="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .digest.value')"
    expected_digest="$(sha256 "$ROOT/scripts/$s.sh")"

    assert_eq "$rtype" "blob" "script-$s type"
    assert_eq "$mediatype" "text/x-shellscript" "script-$s mediaType"
    assert_eq "$rversion" "$VERSION" "script-$s version"
    assert_eq "$digest" "$expected_digest" "script-$s digest"
  done

  # Check component-constructor resource
  local ctype cmedia cdigest cexpected
  ctype="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="component-constructor") | .type')"
  cmedia="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="component-constructor") | .access.mediaType')"
  cdigest="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="component-constructor") | .digest.value')"
  cexpected="$(sha256 "$ROOT/component-constructor.yaml")"
  assert_eq "$ctype" "blob" "component-constructor type"
  assert_eq "$cmedia" "application/yaml" "component-constructor mediaType"
  assert_eq "$cdigest" "$cexpected" "component-constructor digest"

  # Verify build-time scripts are NOT in the component
  for excl in build sign publish fetch-kind fetch-ocm keys e2e package; do
    local count
    count="$(echo "$cv_json" | jq -r --arg n "script-$excl" '[.[0].component.resources[] | select(.name==$n)] | length')"
    assert_eq "$count" "0" "script-$excl must be absent"
  done
}

test_script_resources_download_identical() {
  local tmp="$1"
  _build
  local bundle
  # shellcheck disable=SC2031
  bundle="$(mktemp -d "$BUILD_DIR/bundle.XXXXXX")"
  _download_bundle "$bundle"
  local s
  for s in lib verify kind-config kind-bin deploy bootstrap; do
    cmp "$bundle/scripts/$s.sh" "$ROOT/scripts/$s.sh" || \
      die "script-$s download differs from repo source"
  done
  cmp "$bundle/component-constructor.yaml" "$ROOT/component-constructor.yaml" || \
    die "component-constructor download differs from repo source"
}

test_deploy_verifies_before_deploying() {
  [[ -f "$ROOT/scripts/deploy.sh" ]] || return 1
  _build
  _sign

  # Generate a wrong-key verify config in a temp dir
  local tmpdir
  # shellcheck disable=SC2031
  tmpdir="$(mktemp -d "$BUILD_DIR/wrongkey.XXXXXX")"
  local wrong_dir="$tmpdir/alt-keys"
  mkdir -p "$wrong_dir"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$wrong_dir/private.pem" 2>/dev/null
  openssl rsa -pubout -in "$wrong_dir/private.pem" \
    -out "$wrong_dir/public.pem" 2>/dev/null

  local wrong_config="$tmpdir/verify.ocmconfig"
  cat > "$wrong_config" <<EOF
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
            publicKeyPEMFile: ${wrong_dir}/public.pem
EOF

  # deploy.sh must fail when the verify config has a wrong key
  local stub
  stub="$(_stub_docker "$tmpdir")"

  PATH="$stub:$PATH" VERIFY_CONFIG="$wrong_config" \
    assert_fails bash "$ROOT/scripts/deploy.sh" || return 1
}

test_deploy_runs_all_steps() {
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || return 0
  [[ -f "$ROOT/scripts/deploy.sh" ]] || return 1
  _build
  _sign

  local tmpdir
  # shellcheck disable=SC2031
  tmpdir="$(mktemp -d "$BUILD_DIR/deploysteps.XXXXXX")"
  local stub
  stub="$(_stub_docker "$tmpdir")"

  # deploy.sh should fail at cluster creation (fake docker), but run all prior steps
  unset KIND_BIN
  PATH="$stub:$PATH" SKIP_VERIFY=1 \
    assert_fails bash "$ROOT/scripts/deploy.sh" || return 1

  # kind-cluster.yaml must have been written
  # shellcheck disable=SC2031
  grep -q "kind: Cluster" "$BUILD_DIR/deploy/kind-cluster.yaml" || \
    die "kind-config step did not run"

  # kind binary must be installed with correct sha256
  local actual
  # shellcheck disable=SC2031
  actual="$(sha256 "$BUILD_DIR/deploy/bin/kind")"
  assert_eq "$actual" "$KIND_SHA256" "kind binary sha256 after deploy"

  # docker must have been invoked (reached cluster creation)
  [[ -s "$tmpdir/docker.log" ]] || \
    die "docker was not invoked; deploy did not reach cluster creation"
}

test_bundle_is_self_contained() {
  local tmp="$1"
  _build
  _sign
  local bundle
  # shellcheck disable=SC2031
  bundle="$(mktemp -d "$BUILD_DIR/bundle.XXXXXX")"
  _download_bundle "$bundle"

  # Assert deploy.sh and bootstrap.sh are present and e2e.sh is absent in bundle
  [[ -f "$bundle/scripts/deploy.sh" ]] || die "deploy.sh missing from bundle"
  [[ -f "$bundle/scripts/bootstrap.sh" ]] || die "bootstrap.sh missing from bundle"
  [[ ! -f "$bundle/scripts/e2e.sh" ]] || die "e2e.sh should not be in bundle"

  # Capture pinned values from repo environment before unsetting
  local pinned_version pinned_sha256 pinned_ocm_version pinned_ocm_sha256
  pinned_version="$KIND_VERSION"
  pinned_sha256="$KIND_SHA256"
  pinned_ocm_version="$OCM_CLI_VERSION"
  pinned_ocm_sha256="$OCM_CLI_SHA256"

  # Capture outer scope variables before subshells
  # shellcheck disable=SC2031
  local ocm_bin="$OCM"
  # shellcheck disable=SC2031
  local ctf_path="$CTF"
  # shellcheck disable=SC2031
  local build_dir_path="$BUILD_DIR"

  # Run in a subshell with env vars unset so bundled lib.sh reads the constructor
  # shellcheck disable=SC2031
  (
    unset KIND_VERSION KIND_SHA256_DARWIN_ARM64 KIND_DIST_FILE KIND_DIST_DIR KIND_BIN
    unset OCM_CLI_VERSION OCM_CLI_SHA256_DARWIN_ARM64 OCM_CLI_DIST_FILE OCM_CLI_DIST_DIR
    # shellcheck source=/dev/null
    source "$bundle/scripts/lib.sh"
    assert_eq "$KIND_VERSION" "$pinned_version" "bundled lib.sh reads KIND_VERSION"
    assert_eq "$KIND_SHA256" "$pinned_sha256" "bundled lib.sh reads KIND_SHA256"
    assert_eq "$OCM_CLI_VERSION" "$pinned_ocm_version" "bundled lib.sh reads OCM_CLI_VERSION"
    assert_eq "$OCM_CLI_SHA256" "$pinned_ocm_sha256" "bundled lib.sh reads OCM_CLI_SHA256"

    rm -f "$BUILD_DIR/deploy/kind-cluster.yaml"
    env -i HOME="$HOME" PATH="$PATH" SKIP_VERIFY=1 \
      OCM="$ocm_bin" CTF="$ctf_path" BUILD_DIR="$build_dir_path" \
      bash "$bundle/scripts/kind-config.sh"
    grep -q "kind: Cluster" "$BUILD_DIR/deploy/kind-cluster.yaml" || \
      die "bundled kind-config.sh did not produce a valid Cluster manifest"
  )

  if [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]]; then
    (
      unset KIND_VERSION KIND_SHA256_DARWIN_ARM64 KIND_DIST_FILE KIND_DIST_DIR KIND_BIN
      unset OCM_CLI_VERSION OCM_CLI_SHA256_DARWIN_ARM64 OCM_CLI_DIST_FILE OCM_CLI_DIST_DIR
      # shellcheck source=/dev/null
      source "$bundle/scripts/lib.sh"
      local tmpdir
      tmpdir="$(mktemp -d "$tmp/bundleselfcontained.XXXXXX")"
      local stub_dir
      stub_dir="$(_stub_docker "$tmpdir")"
      # deploy.sh should fail because docker is stubbed, but should run prior steps
      if env -i HOME="$HOME" PATH="$stub_dir:$PATH" SKIP_VERIFY=1 \
        OCM="$ocm_bin" CTF="$ctf_path" BUILD_DIR="$build_dir_path" \
        bash "$bundle/scripts/deploy.sh" 2>/dev/null; then
        die "deploy.sh should fail with stub docker"
      fi
      local actual_sha
      actual_sha="$(sha256 "$build_dir_path/deploy/bin/kind")"
      assert_eq "$actual_sha" "$pinned_sha256" "bundled deploy.sh installs correct kind"
    )
  fi
}

test_ocm_resource_identity_and_digest() {
  local tmp="$1"
  _build
  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"
  local rtype os arch version digest
  rtype="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="ocm") | .type')"
  os="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="ocm") | .extraIdentity.os')"
  arch="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="ocm") | .extraIdentity.architecture')"
  version="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="ocm") | .version')"
  digest="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="ocm") | .digest.value')"
  assert_eq "$rtype" "executable" "ocm resource type"
  assert_eq "$os" "$PLATFORM_OS" "ocm extraIdentity.os"
  assert_eq "$arch" "arm64" "ocm extraIdentity.architecture"
  assert_eq "$version" "$OCM_CLI_VERSION" "ocm resource version"
  assert_eq "$digest" "$OCM_CLI_SHA256" "ocm resource digest"
}

test_fetch_ocm_rejects_bad_checksum() {
  local tmp="$1"
  local tmpdir
  tmpdir="$(mktemp -d "$tmp/fetchocm.XXXXXX")"
  mkdir -p "$tmpdir/release/${OCM_CLI_VERSION}"
  # Serve a wrong binary
  echo "not-ocm" > "$tmpdir/release/${OCM_CLI_VERSION}/ocm-${PLATFORM_OS}-arm64"
  local dest="$tmpdir/dist/$OCM_CLI_DIST_FILE"
  mkdir -p "$tmpdir/dist"
  echo "previous" > "$dest"

  OCM_CLI_BASE_URL="file://$tmpdir/release" \
    OCM_CLI_DIST_DIR="$tmpdir/dist" \
    assert_fails bash "$ROOT/scripts/fetch-ocm.sh" || return 1

  # Verify the dest file is either gone or unchanged (checksum mismatch prevented overwrite)
  if [[ -f "$dest" ]]; then
    [[ "$(cat "$dest")" == "previous" ]] || return 1
  fi
}

test_build_rejects_ocm_dist_dir_outside_root() {
  local tmp="$1"
  OCM_CLI_DIST_DIR="$tmp/../outside" assert_fails bash "$ROOT/scripts/build.sh"
}

test_ocm_version_pins_consistent() {
  local tmp="$1"
  # Constructor version (lib.sh-derived, unset first to force re-read)
  local constructor_version constructor_sha bootstrap_version bootstrap_sha
  constructor_version="$(
    unset OCM_CLI_VERSION OCM_CLI_SHA256_DARWIN_ARM64
    # shellcheck source=/dev/null
    source "$ROOT/scripts/lib.sh"
    echo "$OCM_CLI_VERSION"
  )"
  constructor_sha="$(
    unset OCM_CLI_VERSION OCM_CLI_SHA256_DARWIN_ARM64
    # shellcheck source=/dev/null
    source "$ROOT/scripts/lib.sh"
    echo "$OCM_CLI_SHA256"
  )"
  bootstrap_version="$(_bootstrap_pin OCM_BOOTSTRAP_VERSION)"
  bootstrap_sha="$(_bootstrap_pin "OCM_BOOTSTRAP_SHA256_$(echo "$PLATFORM_OS" | tr '[:lower:]' '[:upper:]')_ARM64")"

  assert_eq "$bootstrap_version" "$constructor_version" "bootstrap version matches constructor"
  assert_eq "$bootstrap_sha" "$constructor_sha" "bootstrap sha256 matches constructor label"
  local offline_pin
  offline_pin="$(sed -n "s/^[[:space:]]*$PLATFORM_OS) pin=\([a-f0-9]*\) ;;$/\1/p" "$ROOT/scripts/offline-run.sh")"
  assert_eq "$offline_pin" "$constructor_sha" "offline entrypoint pin matches constructor"

}

test_bootstrap_rejects_bad_ocm_checksum() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || return 0
  _build
  _sign

  local tmpdir
  tmpdir="$(mktemp -d "$tmp/bstrap.XXXXXX")"
  local bootstrap_ver
  bootstrap_ver="$(_bootstrap_pin OCM_BOOTSTRAP_VERSION)"
  mkdir -p "$tmpdir/release/$bootstrap_ver"
  echo "fake-ocm" > "$tmpdir/release/$bootstrap_ver/ocm-${PLATFORM_OS}-arm64"

  local stub
  stub="$(_stub_docker "$tmpdir")"

  local boot_dir="$tmpdir/boot"
  # shellcheck disable=SC2031,SC2097,SC2098
  OCM_BOOTSTRAP_BASE_URL="file://$tmpdir/release" \
    OCM_REPO="ctf::$CTF" \
    VERIFY_CONFIG="$BUILD_DIR/verify.ocmconfig" \
    BUILD_DIR="$boot_dir" \
    PATH="$stub:$PATH" \
    assert_fails bash "$ROOT/scripts/bootstrap.sh"

  [[ ! -f "$boot_dir/bootstrap/bin/ocm" ]] || die "bootstrap ocm must not exist after checksum failure"
  [[ ! -d "$boot_dir/ctf" ]] || die "CTF must not be created after checksum failure"
  [[ ! -s "$tmpdir/docker.log" ]] || die "docker must not be invoked after checksum failure"
}

test_bootstrap_rejects_wrong_key() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || return 0
  _build
  _sign

  local tmpdir
  tmpdir="$(mktemp -d "$tmp/bstrap_key.XXXXXX")"
  mkdir -p "$tmpdir/release/${OCM_CLI_VERSION}"
  cp "$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE" \
    "$tmpdir/release/${OCM_CLI_VERSION}/ocm-${PLATFORM_OS}-arm64"

  # Wrong verify config
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmpdir/wrong.priv" 2>/dev/null
  openssl rsa -pubout -in "$tmpdir/wrong.priv" -out "$tmpdir/wrong.pub" 2>/dev/null
  cat > "$tmpdir/wrong.ocmconfig" <<CONFIG
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
            publicKeyPEMFile: $tmpdir/wrong.pub
CONFIG

  local stub
  stub="$(_stub_docker "$tmpdir")"

  local boot_dir="$tmpdir/boot"
  # shellcheck disable=SC2031,SC2097,SC2098
  OCM_BOOTSTRAP_BASE_URL="file://$tmpdir/release" \
    OCM_REPO="ctf::$CTF" \
    VERIFY_CONFIG="$tmpdir/wrong.ocmconfig" \
    BUILD_DIR="$boot_dir" \
    PATH="$stub:$PATH" \
    assert_fails bash "$ROOT/scripts/bootstrap.sh"

  [[ ! -f "$boot_dir/deploy/bin/ocm" ]] || die "component ocm must not be installed after verify failure"
  [[ ! -s "$tmpdir/docker.log" ]] || die "docker must not be invoked after verify failure"
}

test_bootstrap_deploys_with_component_ocm() {
  local tmp="$1"
  [[ ( "$(host_os)" == "darwin" || "$(host_os)" == "linux" ) && "$(host_arch)" == "arm64" ]] || return 0
  _build
  _sign

  local tmpdir
  tmpdir="$(mktemp -d "$tmp/bstrap_full.XXXXXX")"
  mkdir -p "$tmpdir/release/${OCM_CLI_VERSION}"
  cp "$OCM_CLI_DIST_DIR/$OCM_CLI_DIST_FILE" \
    "$tmpdir/release/${OCM_CLI_VERSION}/ocm-${PLATFORM_OS}-arm64"

  local stub
  stub="$(_stub_docker "$tmpdir")"

  local boot_dir="$tmpdir/boot"
  # shellcheck disable=SC2031,SC2097,SC2098
  OCM_BOOTSTRAP_BASE_URL="file://$tmpdir/release" \
    OCM_REPO="ctf::$CTF" \
    VERIFY_CONFIG="$BUILD_DIR/verify.ocmconfig" \
    BUILD_DIR="$boot_dir" \
    PATH="$stub:$PATH" \
    assert_fails bash "$ROOT/scripts/bootstrap.sh"  # fails at cluster creation (stub docker)

  # Bootstrap OCM sha matches pin
  local bootstrap_sha_pin
  bootstrap_sha_pin="$(_bootstrap_pin "OCM_BOOTSTRAP_SHA256_$(echo "$PLATFORM_OS" | tr '[:lower:]' '[:upper:]')_ARM64")"
  assert_eq "$(sha256 "$boot_dir/bootstrap/bin/ocm")" "$bootstrap_sha_pin" \
    "bootstrap ocm sha256"

  # Component OCM installed and sha matches pin
  assert_eq "$(sha256 "$boot_dir/deploy/bin/ocm")" "$OCM_CLI_SHA256" \
    "component ocm sha256"

  # kind binary installed
  assert_eq "$(sha256 "$boot_dir/deploy/bin/kind")" "$KIND_SHA256" \
    "kind binary sha256 via bootstrap"

  # kind-cluster.yaml written
  grep -q "kind: Cluster" "$boot_dir/deploy/kind-cluster.yaml" || \
    die "kind-cluster.yaml not written by bootstrap"

  # docker was invoked (reached cluster creation)
  [[ -s "$tmpdir/docker.log" ]] || die "docker not invoked during bootstrap"

  # ocm from PATH was never used
  [[ ! -s "$tmpdir/ocm.log" ]] || die "PATH ocm was used during bootstrap"

  # Bundle scripts match repo sources
  for s in lib verify kind-config kind-bin deploy; do
    cmp "$boot_dir/bundle/scripts/$s.sh" "$ROOT/scripts/$s.sh" || \
      die "bundle script $s.sh differs from repo"
  done
  cmp "$boot_dir/bundle/component-constructor.yaml" "$ROOT/component-constructor.yaml" || \
    die "bundle component-constructor.yaml differs from repo"
}

test_package_rejects_non_semver_version() {
  [[ -f "$ROOT/scripts/package.sh" ]] || return 1
  local out
  out="$(VERSION=v0.1.0 bash "$ROOT/scripts/package.sh" 2>&1)" && return 1
  assert_contains "$out" "semver"
}

test_package_rejects_unsigned_component() {
  local tmp="$1"
  [[ -f "$ROOT/scripts/package.sh" ]] || return 1
  _build
  bash "$ROOT/scripts/keys.sh"
  assert_fails bash "$ROOT/scripts/package.sh"
  [[ ! -d "$tmp/release" ]] || { echo "FAIL: release directory should not exist" >&2; return 1; }
}

test_package_rejects_mismatched_public_key() {
  [[ -f "$ROOT/scripts/package.sh" ]] || return 1
  _build
  _sign
  local alt
  alt="$(mktemp -d)"
  trap 'rm -rf "$alt"' RETURN
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$alt/private.pem" 2>/dev/null
  openssl rsa -in "$alt/private.pem" -pubout -out "$alt/public.pem" 2>/dev/null
  VERIFY_KEY="$alt/public.pem" assert_fails bash "$ROOT/scripts/package.sh"
}

test_package_produces_verifiable_release() {
  local tmp="$1"
  [[ -f "$ROOT/scripts/package.sh" ]] || return 1
  _build
  _sign
  local rel="$tmp/release"
  RELEASE_DIR="$rel" bash "$ROOT/scripts/package.sh" >/dev/null

  # All four assets exist
  [[ -f "$rel/platform-ctf-${VERSION}.tar.gz" ]] || { echo "FAIL: platform-ctf tarball not found" >&2; return 1; }
  [[ -f "$rel/platform-signing-key.pub.pem" ]] || { echo "FAIL: platform-signing-key.pub.pem not found" >&2; return 1; }
  [[ -f "$rel/bootstrap.sh" ]] || { echo "FAIL: bootstrap.sh not found" >&2; return 1; }
  [[ -f "$rel/SHA256SUMS" ]] || { echo "FAIL: SHA256SUMS not found" >&2; return 1; }

  # SHA256SUMS has exactly 5 lines and each hash is correct
  local lines
  lines="$(wc -l < "$rel/SHA256SUMS" | tr -d ' ')"
  [[ "$lines" -eq 5 ]] || { echo "FAIL: SHA256SUMS has $lines lines, expected 5" >&2; return 1; }
  (cd "$rel" && shasum -a 256 -c SHA256SUMS >/dev/null)

  # bootstrap.sh and public key match source files
  cmp "$rel/bootstrap.sh" "$ROOT/scripts/bootstrap.sh"
  cmp "$rel/platform-signing-key.pub.pem" "$tmp/keys/public.pem"

  # Tarball extracts with ctf/ prefix
  local extract="$tmp/extract"
  mkdir -p "$extract"
  tar -xzf "$rel/platform-ctf-${VERSION}.tar.gz" -C "$extract"
  [[ -d "$extract/ctf" ]] || { echo "FAIL: extracted ctf directory not found" >&2; return 1; }

  # Extracted CTF verifies with the published key
  local vcfg="$tmp/pkg-verify.ocmconfig"
  cat > "$vcfg" <<EOF
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
            publicKeyPEMFile: ${rel}/platform-signing-key.pub.pem
EOF
  "$OCM" verify cv --config "$vcfg" "ctf::$extract/ctf//${ROOT_COMPONENT}:${VERSION}"
  "$OCM" get cv "ctf::$extract/ctf//${ROOT_COMPONENT}:${VERSION}" -o json \
    | jq -r '.[0].component.version' | grep -qx "$VERSION"
}

test_offline_package_boundaries() {
  local tmp="$1"
  _build || return 1
  _sign || return 1
  bash "$ROOT/scripts/package.sh" >/dev/null || return 1
  local archive="$tmp/release/platform-airgap-${VERSION}-${PLATFORM_OS}-arm64.tar.gz"
  local stub
  stub="$(_stub_docker "$tmp")"
  cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
echo attempted >> "$(dirname "$0")/../network.log"
exit 99
STUB
  chmod +x "$stub/curl"
  # Authentic package proceeds to docker load, without curl, PATH ocm, or docker pull.
  PATH="$stub:$PATH" BUILD_DIR="$tmp/offline" EXPECTED_SOURCE_REVISION="$SOURCE_REVISION" \
    assert_fails bash "$ROOT/scripts/offline-run.sh" "$archive" "$tmp/keys/public.pem" || return 1
  grep -q '^load -i ' "$tmp/docker.log" || return 1
  [[ ! -s "$tmp/network.log" && ! -s "$tmp/ocm.log" ]] || return 1
  ! grep -q '^pull ' "$tmp/docker.log" || return 1
  local variant dir
  for variant in bootstrap image tamper architecture provenance wrong-key; do
    dir="$tmp/variant-$variant"
    mkdir -p "$dir"
    tar -xzf "$archive" -C "$dir"
    case "$variant" in
      bootstrap) rm "$dir/bootstrap/ocm" ;;
      image|tamper)
        local digest
        digest="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].component.resources[] | select(.name=="kind-node-image") | .digest.value')"
        python3 - "$dir/ctf" "$digest" "$variant" <<'PY' || return 1
import pathlib, hashlib, sys
for path in pathlib.Path(sys.argv[1]).rglob('*'):
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == sys.argv[2]:
        if sys.argv[3] == 'image': path.unlink()
        else:
            path.chmod(0o600)
            path.write_bytes(b'tampered')
        break
else: raise SystemExit('image blob not found')
PY
        ;;
      architecture) jq '.architecture="amd64"' "$dir/metadata.json" > "$dir/m"; mv "$dir/m" "$dir/metadata.json" ;;
      provenance) jq '.sourceRevision="wrong"' "$dir/metadata.json" > "$dir/m"; mv "$dir/m" "$dir/metadata.json" ;;
      wrong-key) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/private" 2>/dev/null
        openssl rsa -pubout -in "$dir/private" -out "$dir/public" 2>/dev/null ;;
    esac
    tar -czf "$tmp/$variant.tar.gz" -C "$dir" .
    rm -f "$tmp/docker.log"
    local key="$tmp/keys/public.pem"
    [[ "$variant" != wrong-key ]] || key="$dir/public"
    PATH="$stub:$PATH" BUILD_DIR="$tmp/reject-$variant" \
      assert_fails bash "$ROOT/scripts/offline-run.sh" "$tmp/$variant.tar.gz" "$key" || return 1
    [[ ! -s "$tmp/docker.log" && ! -s "$tmp/network.log" ]] || return 1
  done
}

test_explicit_missing_keys_fail() {
  local tmp="$1"
  SIGNING_KEY="$tmp/missing-private" assert_fails bash "$ROOT/scripts/keys.sh" || return 1
  VERIFY_KEY="$tmp/missing-public" assert_fails bash "$ROOT/scripts/keys.sh" || return 1
  [[ ! -f "$tmp/missing-private" && ! -f "$tmp/missing-public" ]] || return 1
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/supplied-private" 2>/dev/null
  local before
  before="$(sha256 "$tmp/supplied-private")"
  SIGNING_KEY="$tmp/supplied-private" bash "$ROOT/scripts/keys.sh" || return 1
  assert_eq "$(sha256 "$tmp/supplied-private")" "$before" "explicit private key preserved"
  openssl rsa -pubout -in "$tmp/supplied-private" -out "$tmp/expected-public" 2>/dev/null
  cmp "$tmp/expected-public" "$tmp/keys/public.pem" || return 1
  VERIFY_KEY="$tmp/expected-public" BUILD_DIR="$tmp/public-only" \
    assert_fails bash "$ROOT/scripts/keys.sh" || return 1
  [[ ! -f "$tmp/public-only/keys/private.pem" ]] || return 1
}

# ── Run all tests ─────────────────────────────────────────────────────────────

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
run_test "script resources metadata" test_script_resources_metadata
run_test "script resources download identical" test_script_resources_download_identical
run_test "deploy verifies before deploying" test_deploy_verifies_before_deploying
run_test "deploy runs all steps" test_deploy_runs_all_steps
run_test "bundle is self-contained" test_bundle_is_self_contained
run_test "ocm resource identity and digest" test_ocm_resource_identity_and_digest
run_test "fetch ocm rejects bad checksum" test_fetch_ocm_rejects_bad_checksum
run_test "build rejects ocm dist dir outside root" test_build_rejects_ocm_dist_dir_outside_root
run_test "ocm version pins consistent" test_ocm_version_pins_consistent
run_test "bootstrap rejects bad ocm checksum" test_bootstrap_rejects_bad_ocm_checksum
run_test "bootstrap rejects wrong key" test_bootstrap_rejects_wrong_key
run_test "bootstrap deploys with component ocm" test_bootstrap_deploys_with_component_ocm
run_test "package rejects non-semver version" test_package_rejects_non_semver_version
run_test "package rejects unsigned component" test_package_rejects_unsigned_component
run_test "package rejects mismatched public key" test_package_rejects_mismatched_public_key
run_test "package produces verifiable release" test_package_produces_verifiable_release

echo ""
run_test "offline package rejects incomplete, tampered or untrusted inputs without downloads" test_offline_package_boundaries
run_test "missing explicitly supplied keys fail" test_explicit_missing_keys_fail
run_test "lib dies on unsupported os" test_lib_dies_on_unsupported_os
run_test "e2e cleanup uses configured cluster name" test_e2e_cleanup_uses_configured_cluster_name

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
