#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require openssl

KEYS_DIR="$BUILD_DIR/keys"
mkdir -p "$KEYS_DIR"

PRIVATE_KEY="${SIGNING_KEY:-$KEYS_DIR/private.pem}"
PUBLIC_KEY="${VERIFY_KEY:-$KEYS_DIR/public.pem}"

[[ -z "${SIGNING_KEY:-}" || -f "$SIGNING_KEY" ]] || die "SIGNING_KEY not found: $SIGNING_KEY"
[[ -z "${VERIFY_KEY:-}" || -f "$VERIFY_KEY" ]] || die "VERIFY_KEY not found: $VERIFY_KEY"

if [[ ! -f "$PRIVATE_KEY" ]]; then
  [[ -z "${VERIFY_KEY:-}" ]] || die "VERIFY_KEY requires an existing signing key"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" 2>/dev/null
fi
if [[ ! -f "$PUBLIC_KEY" ]]; then
  openssl rsa -pubout -in "$PRIVATE_KEY" -out "$PUBLIC_KEY" 2>/dev/null
fi
# Refuse mismatched existing keys before generating a signing configuration.
private_public="$(openssl pkey -in "$PRIVATE_KEY" -pubout 2>/dev/null)"
verify_public="$(openssl pkey -pubin -in "$PUBLIC_KEY" -pubout 2>/dev/null)"
[[ "$private_public" == "$verify_public" ]] || die "Signing and verification keys do not match"

cat > "$BUILD_DIR/sign.ocmconfig" <<EOF
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
            privateKeyPEMFile: ${PRIVATE_KEY}
            publicKeyPEMFile: ${PUBLIC_KEY}
EOF

cat > "$BUILD_DIR/verify.ocmconfig" <<EOF
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
