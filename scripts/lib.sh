#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Required tool not found: $bin"
  done
}

export OCM="${OCM:-ocm}"
export SOURCE_REVISION="${SOURCE_REVISION:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
export VERSION="${VERSION:-0.1.0}"
export BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
export CTF="${CTF:-$BUILD_DIR/ctf}"
export ROOT_COMPONENT="github.com/lioramilbaum/platform"

host_os() {
  uname -s | tr '[:upper:]' '[:lower:]'
}

host_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64)          echo amd64 ;;
    aarch64|arm64)   echo arm64 ;;
    *)               echo "$m"  ;;
  esac
}

PLATFORM_OS="$(host_os)"
PLATFORM_ARCH="$(host_arch)"
export PLATFORM_OS PLATFORM_ARCH
export KIND_VERSION="${KIND_VERSION:-$(awk '/name: kind$/{f=1} f && /version:/{gsub(/.*: /, ""); print; exit}' "$ROOT/component-constructor.yaml")}"
export KIND_SHA256_DARWIN_ARM64="${KIND_SHA256_DARWIN_ARM64:-$(awk '/kind\.lioramilbaum\.github\.com\/sha256sum-darwin-arm64/{getline; gsub(/.*value: "|"/, ""); print; exit}' "$ROOT/component-constructor.yaml")}"
export KIND_BASE_URL="${KIND_BASE_URL:-https://github.com/kubernetes-sigs/kind/releases/download}"
export KIND_DIST_DIR="${KIND_DIST_DIR:-$ROOT/bin/dist}"
export KIND_SHA256_LINUX_ARM64="${KIND_SHA256_LINUX_ARM64:-$(awk '/kind\.lioramilbaum\.github\.com\/sha256sum-linux-arm64/{getline; gsub(/.*value: "|"/, ""); print; exit}' "$ROOT/component-constructor.yaml")}"
export KIND_DIST_FILE="kind-${KIND_VERSION}-${PLATFORM_OS}-arm64"
export KIND_BIN="${KIND_BIN:-$BUILD_DIR/deploy/bin/kind}"

export OCM_CLI_VERSION="${OCM_CLI_VERSION:-$(awk '/name: ocm$/{f=1} f && /version:/{gsub(/.*: /, ""); print; exit}' "$ROOT/component-constructor.yaml")}"
export OCM_CLI_SHA256_DARWIN_ARM64="${OCM_CLI_SHA256_DARWIN_ARM64:-$(awk '/ocm\.lioramilbaum\.github\.com\/sha256sum-darwin-arm64/{getline; gsub(/.*value: "|"/, ""); print; exit}' "$ROOT/component-constructor.yaml")}"
export OCM_CLI_BASE_URL="${OCM_CLI_BASE_URL:-https://github.com/open-component-model/open-component-model/releases/download}"
export OCM_CLI_DIST_DIR="${OCM_CLI_DIST_DIR:-$ROOT/bin/dist}"
export OCM_CLI_SHA256_LINUX_ARM64="${OCM_CLI_SHA256_LINUX_ARM64:-$(awk '/ocm\.lioramilbaum\.github\.com\/sha256sum-linux-arm64/{getline; gsub(/.*value: "|"/, ""); print; exit}' "$ROOT/component-constructor.yaml")}"
case "$PLATFORM_OS" in
  darwin) export KIND_SHA256="$KIND_SHA256_DARWIN_ARM64" OCM_CLI_SHA256="$OCM_CLI_SHA256_DARWIN_ARM64" ;;
  linux) export KIND_SHA256="$KIND_SHA256_LINUX_ARM64" OCM_CLI_SHA256="$OCM_CLI_SHA256_LINUX_ARM64" ;;
  *) die "Unsupported operating system: $PLATFORM_OS" ;;
esac
export OCM_CLI_DIST_FILE="ocm-${OCM_CLI_VERSION}-${PLATFORM_OS}-arm64"
export KIND_IMAGE_ARCHIVE="${KIND_IMAGE_ARCHIVE:-$ROOT/bin/dist/kind-node-linux-arm64.tar}"
KIND_NODE_IMAGE="$(awk '/^[[:space:]]+image:/{print $2; exit}' "$ROOT/components/kind/cluster.yaml" 2>/dev/null || true)"
KIND_NODE_DIGEST="$(awk '/# digest:/{print $3; exit}' "$ROOT/components/kind/cluster.yaml" 2>/dev/null || true)"

export KIND_NODE_IMAGE KIND_NODE_DIGEST

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "No sha256 tool found (shasum or sha256sum)"
  fi
}

require_platform() {
  [[ ( "$PLATFORM_OS" == "darwin" || "$PLATFORM_OS" == "linux" ) && "$PLATFORM_ARCH" == "arm64" ]] || \
    die "This target only works on darwin/arm64 or linux/arm64 (detected: $(host_os)/$(host_arch))"
}

cv_ref() {
  local component="${1:-$ROOT_COMPONENT}"
  echo "ctf::${CTF}//${component}:${VERSION}"
}

kind_cluster_name() {
  local config="${1:-$BUILD_DIR/deploy/kind-cluster.yaml}"
  [[ -f "$config" ]] || return 1
  awk '/^name:/{print $2; exit}' "$config"
}
