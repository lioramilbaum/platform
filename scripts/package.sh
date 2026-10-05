#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" tar openssl

if [[ ! "${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  die "VERSION must be semver without a leading 'v' (got: ${VERSION:-<unset>})"
fi

RELEASE_DIR="${RELEASE_DIR:-$BUILD_DIR/release}"
PUBLIC_KEY="${VERIFY_KEY:-$BUILD_DIR/keys/public.pem}"

[[ -d "$CTF" ]] || die "CTF directory not found at $CTF — run 'make build' first"
[[ -f "$PUBLIC_KEY" ]] || die "Public key not found at $PUBLIC_KEY — run 'make sign' first"

work="$(mktemp -d "$BUILD_DIR/.package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out"

# Write a fresh verify config pointing at the key we're about to publish
TEMP_VERIFY_CONFIG="$work/verify.ocmconfig"
cat > "$TEMP_VERIFY_CONFIG" <<EOF
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
            publicKeyPEMFile: ${PUBLIC_KEY}
EOF

# Verify the CTF against the exact public key being published
VERIFY_CONFIG="$TEMP_VERIFY_CONFIG" bash "$(dirname "$0")/verify.sh"

# Stage and archive
mkdir -p "$work/stage"
cp -R "$CTF" "$work/stage/ctf"
COPYFILE_DISABLE=1 tar -czf "$work/out/platform-ctf-${VERSION}.tar.gz" -C "$work/stage" ctf

# Self-check: extract and verify the archive
mkdir -p "$work/check"
tar -xzf "$work/out/platform-ctf-${VERSION}.tar.gz" -C "$work/check"
"$OCM" verify cv \
  --config "$TEMP_VERIFY_CONFIG" \
  "ctf::$work/check/ctf//${ROOT_COMPONENT}:${VERSION}"

# Copy the remaining assets
cp "$PUBLIC_KEY" "$work/out/platform-signing-key.pub.pem"
cp "$ROOT/scripts/bootstrap.sh" "$work/out/bootstrap.sh"

# Write SHA256SUMS from inside the output directory
(cd "$work/out" && \
  shasum -a 256 "platform-ctf-${VERSION}.tar.gz" "platform-signing-key.pub.pem" "bootstrap.sh" \
  > SHA256SUMS)

# Atomic swap
rm -rf "$RELEASE_DIR"
mkdir -p "$(dirname "$RELEASE_DIR")"
mv "$work/out" "$RELEASE_DIR"

echo "Release assets written to $RELEASE_DIR:"
ls -lh "$RELEASE_DIR"
