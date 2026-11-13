#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKL_BIN="${PKL_BIN:-$(which pkl 2>/dev/null || echo "/opt/homebrew/bin/pkl")}"

if [ ! -x "$PKL_BIN" ]; then
  echo "Error: pkl executable not found. Install pkl or set PKL_BIN." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/kx-envoy-test-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass=0
fail=0

ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail + 1)); }

ONION_HOST="kinetixgatewayciabcdefghijklmnopqrstuvwxyz234567abcdefgh.onion"
API_HOST="api.ci.invalid"
BACKOFFICE_HOST="backoffice.ci.invalid"
SELLER_HOST="seller.ci.invalid"
STORAGE_HOST="storage.ci.invalid"

echo "==> Generating throwaway cryptographic material..."
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP_DIR/jwt-private.pem" 2>/dev/null
openssl pkey -in "$TMP_DIR/jwt-private.pem" -pubout -out "$TMP_DIR/jwt-public.pem" 2>/dev/null

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj "/CN=$ONION_HOST" -addext "subjectAltName=DNS:$ONION_HOST" \
  -keyout "$TMP_DIR/onion.key" -out "$TMP_DIR/onion.pem" 2>/dev/null

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj "/CN=$BACKOFFICE_HOST" -addext "subjectAltName=DNS:$BACKOFFICE_HOST" \
  -keyout "$TMP_DIR/backoffice.key" -out "$TMP_DIR/backoffice.pem" 2>/dev/null

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj "/CN=$API_HOST" -addext "subjectAltName=DNS:$API_HOST" \
  -keyout "$TMP_DIR/gateway-tls.key" -out "$TMP_DIR/gateway-tls.crt" 2>/dev/null

render_envoy() {
  local storage_arg=""
  if [ -n "${1:-}" ]; then
    storage_arg="-p storageHost=$1"
  fi
  local out_file="$2"

  "$PKL_BIN" eval \
    -p identityJwtPublicKey="$(cat "$TMP_DIR/jwt-public.pem")" \
    -p jwtIssuer="https://identity.ci.invalid" \
    -p corsOrigins="https://app.ci.invalid,https://seller.ci.invalid" \
    -p staffRanges="10.8.0.0/24,192.168.1.0/24" \
    -p publicApiHost="$API_HOST" \
    -p backofficeHost="$BACKOFFICE_HOST" \
    -p sellerHost="$SELLER_HOST" \
    -p backofficeOnionHost="$ONION_HOST" \
    -p backofficeOnionTlsCertFile="$TMP_DIR/onion.pem" \
    -p backofficeOnionTlsKeyFile="$TMP_DIR/onion.key" \
    -p backofficeTlsCertFile="$TMP_DIR/backoffice.pem" \
    -p backofficeTlsKeyFile="$TMP_DIR/backoffice.key" \
    $storage_arg \
    -f yaml \
    -o "$out_file" \
    "$HERE/config/envoy.pkl"
}

echo "==> Rendering Envoy configuration with storage..."
render_envoy "$STORAGE_HOST" "$TMP_DIR/envoy-full.yaml"
ok "Pkl evaluation succeeded (rendered $(wc -l < "$TMP_DIR/envoy-full.yaml") lines)"

echo "==> Verifying structural invariants..."

expected_clusters=(
  "envoy_admin"
  "edge_service"
  "backoffice_app"
  "identity_service"
  "catalog_service"
  "search_service"
  "warehouse_service"
  "matching_service"
  "matching_merchant_socket"
  "pricing_service"
  "order_service"
  "review_service"
  "payment_service"
  "notary_service"
  "seal_service"
  "notification_service"
  "storage_service"
)

for cluster in "${expected_clusters[@]}"; do
  if grep -q "name: $cluster" "$TMP_DIR/envoy-full.yaml"; then
    ok "Cluster '$cluster' is defined"
  else
    bad "Cluster '$cluster' is missing"
  fi
done

expected_listeners=(
  "public_tls"
  "internal_http"
  "onion_redirect"
  "onion_tls"
  "status_http"
)

for listener in "${expected_listeners[@]}"; do
  if grep -q "name: $listener" "$TMP_DIR/envoy-full.yaml"; then
    ok "Listener '$listener' is defined"
  else
    bad "Listener '$listener' is missing"
  fi
done

if grep -q "envoy.filters.http.jwt_authn" "$TMP_DIR/envoy-full.yaml"; then
  ok "JWT authn filter is present"
else
  bad "JWT authn filter is missing"
fi

if grep -q "envoy.filters.http.rbac" "$TMP_DIR/envoy-full.yaml"; then
  ok "RBAC filter is present"
else
  bad "RBAC filter is missing"
fi

if grep -q "envoy.filters.http.local_ratelimit" "$TMP_DIR/envoy-full.yaml"; then
  ok "Local rate limiting filter is present"
else
  bad "Local rate limiting filter is missing"
fi

if grep -q "status: 200" "$TMP_DIR/envoy-full.yaml" && grep -q '{"status":"ok"}' "$TMP_DIR/envoy-full.yaml"; then
  ok "Health direct response is present"
else
  bad "Health direct response is missing"
fi

if grep -q "Contact: https://github.com/WildanFrananda" "$TMP_DIR/envoy-full.yaml"; then
  ok "security.txt direct response is present"
else
  bad "security.txt direct response is missing"
fi

if grep -q "upgrade_type: websocket" "$TMP_DIR/envoy-full.yaml"; then
  ok "WebSocket upgrade configs are present"
else
  bad "WebSocket upgrade configs are missing"
fi

echo "==> Validating configuration with Envoy v1.31..."
chmod -R a+rX "$TMP_DIR"
if command -v envoy >/dev/null 2>&1; then
  if envoy_out=$(envoy --mode validate -c "$TMP_DIR/envoy-full.yaml" 2>&1); then
    ok "Envoy binary validated envoy.yaml successfully"
  else
    bad "Envoy binary validation failed: $envoy_out"
  fi
elif command -v docker >/dev/null 2>&1; then
  if docker_out=$(docker run --rm \
    -u 0:0 \
    -v "$TMP_DIR/envoy-full.yaml:/etc/envoy/envoy.yaml:ro" \
    -v "$TMP_DIR/gateway-tls.crt:/etc/kinetix/tls/tls.crt:ro" \
    -v "$TMP_DIR/gateway-tls.key:/etc/kinetix/tls/tls.key:ro" \
    envoyproxy/envoy:v1.31-latest envoy --mode validate -c /etc/envoy/envoy.yaml 2>&1); then
    ok "Envoy v1.31 container validated envoy.yaml successfully"
  else
    bad "Envoy container validation failed:"
    printf '%s\n' "$docker_out" >&2
  fi
else
  echo "Warning: neither envoy nor docker found; skipping formal validation" >&2
fi

echo "==> Testing negative assertions (refusals)..."
refuses() {
  local desc="$1"; shift
  if "$PKL_BIN" eval \
    -p identityJwtPublicKey="$(cat "$TMP_DIR/jwt-public.pem")" \
    -p jwtIssuer="https://identity.ci.invalid" \
    -p corsOrigins="" \
    -p publicApiHost="$API_HOST" \
    -p backofficeOnionTlsCertFile="$TMP_DIR/onion.pem" \
    -p backofficeOnionTlsKeyFile="$TMP_DIR/onion.key" \
    -p backofficeTlsCertFile="$TMP_DIR/backoffice.pem" \
    -p backofficeTlsKeyFile="$TMP_DIR/backoffice.key" \
    "$@" \
    -f yaml \
    -o /dev/null \
    "$HERE/config/envoy.pkl" >/dev/null 2>&1; then
    bad "Refusal test failed: accepted invalid configuration ($desc)"
  else
    ok "Refusal test passed: rejected ($desc)"
  fi
}

refuses "missing staffRanges" \
  -p backofficeHost="$BACKOFFICE_HOST" \
  -p sellerHost="$SELLER_HOST" \
  -p backofficeOnionHost="$ONION_HOST"

refuses "duplicate hostnames (publicApiHost == backofficeHost)" \
  -p staffRanges="10.8.0.0/24" \
  -p backofficeHost="$API_HOST" \
  -p sellerHost="$SELLER_HOST" \
  -p backofficeOnionHost="$ONION_HOST"

refuses "invalid onion host (not .onion)" \
  -p staffRanges="10.8.0.0/24" \
  -p backofficeHost="$BACKOFFICE_HOST" \
  -p sellerHost="$SELLER_HOST" \
  -p backofficeOnionHost="invalid-onion-domain.com"

echo ""
echo "Summary: $pass passed, $fail failed."
if [ "$fail" -gt 0 ]; then
  exit 1
fi
