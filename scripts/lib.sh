#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export OCM="${OCM:-ocm}"
export VERSION="${VERSION:-0.1.0}"
export BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
export CTF="${CTF:-$BUILD_DIR/ctf}"
export ROOT_COMPONENT="github.com/lmilbaum/platform"

cv_ref() {
  local component="${1:-$ROOT_COMPONENT}"
  echo "ctf::${CTF}//${component}:${VERSION}"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Required tool not found: $bin"
  done
}
