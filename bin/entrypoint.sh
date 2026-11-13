#!/usr/bin/env sh
set -eu

if [ -z "${KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64:-}" ]; then
  echo "KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64 is required: the gateway cannot verify tokens without identity's public key." >&2
  exit 1
fi
if [ -z "${KINETIX_JWT_ISSUER:-}" ]; then
  echo "KINETIX_JWT_ISSUER is required: it is the one issuer this gateway trusts." >&2
  exit 1
fi
if [ -z "${KINETIX_GATEWAY_CORS_ORIGINS+set}" ]; then
  echo "KINETIX_GATEWAY_CORS_ORIGINS must be set. Empty is allowed, and means no browser origin is trusted." >&2
  exit 1
fi
if [ -z "${KINETIX_GATEWAY_STAFF_RANGES:-}" ]; then
  echo "KINETIX_GATEWAY_STAFF_RANGES is required: the CIDRs the admin-only routes accept. There is no default." >&2
  exit 1
fi
if [ -z "${KINETIX_PUBLIC_API_HOST:-}" ]; then
  echo "KINETIX_PUBLIC_API_HOST is required: the host this gateway serves, which security.txt names." >&2
  exit 1
fi
if [ -z "${KINETIX_BACKOFFICE_HOST:-}" ]; then
  echo "KINETIX_BACKOFFICE_HOST is required: the backoffice's host, whose /bff/ goes to the edge." >&2
  exit 1
fi
if [ -z "${KINETIX_SELLER_HOST:-}" ]; then
  echo "KINETIX_SELLER_HOST is required: the seller web app's host, whose /bff/ goes to the edge." >&2
  exit 1
fi
if [ -z "${KINETIX_BACKOFFICE_ONION_HOST:-}" ]; then
  echo "KINETIX_BACKOFFICE_ONION_HOST is required: the backoffice's onion address, served on the onion listener." >&2
  exit 1
fi
if [ -z "${KINETIX_BACKOFFICE_ONION_TLS_CERT_B64:-}" ]; then
  echo "KINETIX_BACKOFFICE_ONION_TLS_CERT_B64 is required: the onion address's certificate, served on the onion's TLS listener." >&2
  exit 1
fi
if [ -z "${KINETIX_BACKOFFICE_ONION_TLS_KEY_B64:-}" ]; then
  echo "KINETIX_BACKOFFICE_ONION_TLS_KEY_B64 is required: the private key of the onion address's certificate." >&2
  exit 1
fi
if [ -z "${KINETIX_BACKOFFICE_TLS_CERT_B64:-}" ]; then
  echo "KINETIX_BACKOFFICE_TLS_CERT_B64 is required: the backoffice host's certificate, served to its name on the public listener." >&2
  exit 1
fi
if [ -z "${KINETIX_BACKOFFICE_TLS_KEY_B64:-}" ]; then
  echo "KINETIX_BACKOFFICE_TLS_KEY_B64 is required: the private key of the backoffice host's certificate." >&2
  exit 1
fi

CONFIG="${ENVOY_CONFIG_FILE:-/var/lib/envoy/envoy.yaml}"
umask 077

public_key=""
onion_cert=""
onion_key=""
backoffice_cert=""
backoffice_key=""

cleanup_temps() {
  rm -f "$public_key" "$onion_cert" "$onion_key" "$backoffice_cert" "$backoffice_key"
}
trap cleanup_temps EXIT

assert_cert_matches_key() {
  cert_path="$1"
  key_path="$2"
  label="$3"
  cert_pub="$(openssl x509 -in "$cert_path" -noout -pubkey 2>/dev/null || true)"
  key_pub="$(openssl pkey -in "$key_path" -pubout 2>/dev/null || true)"
  if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
    echo "$label: certificate does not match key" >&2
    exit 1
  fi
}

public_key="$(mktemp)"
printf '%s' "$KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64" | base64 -d > "$public_key" 2>/dev/null || true
if ! grep -q "BEGIN PUBLIC KEY" "$public_key"; then
  echo "KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64 did not decode to a PEM public key" >&2
  exit 1
fi

onion_cert="$(mktemp)"
onion_key="$(mktemp)"
backoffice_cert="$(mktemp)"
backoffice_key="$(mktemp)"

printf '%s' "$KINETIX_BACKOFFICE_ONION_TLS_CERT_B64" | base64 -d > "$onion_cert" 2>/dev/null || true
printf '%s' "$KINETIX_BACKOFFICE_ONION_TLS_KEY_B64" | base64 -d > "$onion_key" 2>/dev/null || true
if ! grep -q "BEGIN CERTIFICATE" "$onion_cert"; then
  echo "KINETIX_BACKOFFICE_ONION_TLS_CERT_B64 did not decode to a PEM certificate" >&2
  exit 1
fi
if ! grep -q "PRIVATE KEY" "$onion_key"; then
  echo "KINETIX_BACKOFFICE_ONION_TLS_KEY_B64 did not decode to a PEM private key" >&2
  exit 1
fi
assert_cert_matches_key "$onion_cert" "$onion_key" "KINETIX_BACKOFFICE_ONION_TLS"

printf '%s' "$KINETIX_BACKOFFICE_TLS_CERT_B64" | base64 -d > "$backoffice_cert" 2>/dev/null || true
printf '%s' "$KINETIX_BACKOFFICE_TLS_KEY_B64" | base64 -d > "$backoffice_key" 2>/dev/null || true
if ! grep -q "BEGIN CERTIFICATE" "$backoffice_cert"; then
  echo "KINETIX_BACKOFFICE_TLS_CERT_B64 did not decode to a PEM certificate" >&2
  exit 1
fi
if ! grep -q "PRIVATE KEY" "$backoffice_key"; then
  echo "KINETIX_BACKOFFICE_TLS_KEY_B64 did not decode to a PEM private key" >&2
  exit 1
fi
assert_cert_matches_key "$backoffice_cert" "$backoffice_key" "KINETIX_BACKOFFICE_TLS"

files="${KINETIX_GATEWAY_TLS_CERT_FILE:-}${KINETIX_GATEWAY_TLS_KEY_FILE:-}"
inline="${KINETIX_GATEWAY_TLS_CERT_B64:-}${KINETIX_GATEWAY_TLS_KEY_B64:-}"

if [ -n "$files" ] && [ -n "$inline" ]; then
  echo "TLS is configured twice: set either the _FILE pair or the _B64 pair, not both." >&2
  exit 1
fi

if [ -n "$files" ]; then
  if [ -z "${KINETIX_GATEWAY_TLS_CERT_FILE:-}" ] || [ -z "${KINETIX_GATEWAY_TLS_KEY_FILE:-}" ]; then
    echo "KINETIX_GATEWAY_TLS_CERT_FILE and KINETIX_GATEWAY_TLS_KEY_FILE must be set together." >&2
    exit 1
  fi
  grep -q "BEGIN CERTIFICATE" "$KINETIX_GATEWAY_TLS_CERT_FILE" 2>/dev/null || {
    echo "$KINETIX_GATEWAY_TLS_CERT_FILE is not readable by $(id -un) or is not a PEM certificate" >&2
    exit 1
  }
  grep -q "PRIVATE KEY" "$KINETIX_GATEWAY_TLS_KEY_FILE" 2>/dev/null || {
    echo "$KINETIX_GATEWAY_TLS_KEY_FILE is not readable by $(id -un) or is not a PEM private key" >&2
    exit 1
  }
  gateway_tls_cert="$KINETIX_GATEWAY_TLS_CERT_FILE"
  gateway_tls_key="$KINETIX_GATEWAY_TLS_KEY_FILE"
elif [ -n "${KINETIX_GATEWAY_TLS_CERT_B64:-}" ] && [ -n "${KINETIX_GATEWAY_TLS_KEY_B64:-}" ]; then
  TLS_DIR="${ENVOY_TLS_DIR:-/tmp/envoy-tls}"
  mkdir -p "$TLS_DIR"
  chmod 700 "$TLS_DIR"

  printf '%s' "$KINETIX_GATEWAY_TLS_CERT_B64" | base64 -d > "$TLS_DIR/server.pem" 2>/dev/null || true
  printf '%s' "$KINETIX_GATEWAY_TLS_KEY_B64" | base64 -d > "$TLS_DIR/server.key" 2>/dev/null || true

  grep -q "BEGIN CERTIFICATE" "$TLS_DIR/server.pem" || {
    echo "KINETIX_GATEWAY_TLS_CERT_B64 did not decode to a PEM certificate" >&2
    exit 1
  }
  grep -q "PRIVATE KEY" "$TLS_DIR/server.key" || {
    echo "KINETIX_GATEWAY_TLS_KEY_B64 did not decode to a PEM private key" >&2
    exit 1
  }
  assert_cert_matches_key "$TLS_DIR/server.pem" "$TLS_DIR/server.key" "KINETIX_GATEWAY_TLS"
  gateway_tls_cert="$TLS_DIR/server.pem"
  gateway_tls_key="$TLS_DIR/server.key"
else
  echo "TLS is required: set KINETIX_GATEWAY_TLS_CERT_FILE and _KEY_FILE, or KINETIX_GATEWAY_TLS_CERT_B64 and _KEY_B64." >&2
  echo "The public listener is TLS only; the gateway never falls back to plaintext." >&2
  exit 1
fi

pkl eval \
  -p identityJwtPublicKey="$(cat "$public_key")" \
  -p jwtIssuer="$KINETIX_JWT_ISSUER" \
  -p corsOrigins="$KINETIX_GATEWAY_CORS_ORIGINS" \
  -p storageHost="${KINETIX_STORAGE_HOST:-}" \
  -p staffRanges="$KINETIX_GATEWAY_STAFF_RANGES" \
  -p publicApiHost="$KINETIX_PUBLIC_API_HOST" \
  -p backofficeHost="$KINETIX_BACKOFFICE_HOST" \
  -p sellerHost="$KINETIX_SELLER_HOST" \
  -p backofficeOnionHost="$KINETIX_BACKOFFICE_ONION_HOST" \
  -p backofficeOnionTlsCertFile="$onion_cert" \
  -p backofficeOnionTlsKeyFile="$onion_key" \
  -p backofficeTlsCertFile="$backoffice_cert" \
  -p backofficeTlsKeyFile="$backoffice_key" \
  -p gatewayTlsCertFile="$gateway_tls_cert" \
  -p gatewayTlsKeyFile="$gateway_tls_key" \
  -f yaml /etc/kinetix/envoy/envoy.pkl -o "$CONFIG"

if ! openssl x509 -in "$onion_cert" -noout -checkhost "$KINETIX_BACKOFFICE_ONION_HOST" 2>/dev/null \
  | grep -q " does match "; then
  echo "KINETIX_BACKOFFICE_ONION_TLS_CERT_B64 is not a certificate for KINETIX_BACKOFFICE_ONION_HOST" >&2
  exit 1
fi
if ! openssl x509 -in "$backoffice_cert" -noout -checkhost "${KINETIX_BACKOFFICE_HOST%%:*}" 2>/dev/null \
  | grep -q " does match "; then
  echo "KINETIX_BACKOFFICE_TLS_CERT_B64 is not a certificate for KINETIX_BACKOFFICE_HOST" >&2
  exit 1
fi

cleanup_temps

if ! grep -q "identity_provider" "$CONFIG"; then
  echo "the rendered config carries no verification key" >&2
  exit 1
fi
if ! grep -q "staff_ranges" "$CONFIG"; then
  echo "the rendered config carries no staff gate on the admin-only routes" >&2
  exit 1
fi

envoy --mode validate -c "$CONFIG" >/dev/null

if [ "$#" -gt 0 ] && [ "$1" = "envoy" ] && [ -n "${ENVOY_CONCURRENCY:-}" ]; then
  exec "$@" --concurrency "$ENVOY_CONCURRENCY"
fi

exec "$@"
