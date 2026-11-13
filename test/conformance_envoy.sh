#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PKL_BIN="${PKL_BIN:-$(command -v pkl 2>/dev/null || echo "/opt/homebrew/bin/pkl")}"
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.31-latest}"
KONG_ECHO_IMAGE="${KONG_ECHO_IMAGE:-kong:3.9@sha256:aa4a4687b1330e427ad0d3b27a0606b833894297c78abf1a212edc9ba73c8620}"

RUN="kxenvoyprobe-$$"
STAFF_PREFIX="${EDGE_PROBE_STAFF_PREFIX:-10.232.10}"
OUTSIDE_PREFIX="${EDGE_PROBE_OUTSIDE_PREFIX:-10.232.20}"
INTERNAL_PREFIX="${EDGE_PROBE_INTERNAL_PREFIX:-10.232.40}"
API_HOST="api.probe.invalid"
BACKOFFICE_NAME="backoffice.probe.invalid"
SELLER_NAME="seller.probe.invalid"
ONION_NAME="kinetixgatewayprobeabcdefghijklmnopqrstuvwxyz234567abcde.onion"
STORAGE_HOST="storage.probe.invalid"
INTERNAL_HOST="kinetix-api-gateway"
ISSUER="https://identity.probe.invalid"
BROWSER_ORIGIN="https://backoffice.probe.invalid"
PROBE_IMAGE="$RUN-client"

UPSTREAMS=(
  kinetix-identity-service
  kinetix-catalog-service
  kinetix-search-service
  kinetix-warehouse-service
  kinetix-matching-service
  kinetix-pricing-service
  kinetix-order-service
  kinetix-review-service
  kinetix-payment-service
  kinetix-notary-service
  kinetix-seal-service
  kinetix-notification-service
  kinetix-object-store
  kinetix-edge-service
  kinetix-backoffice
)
UPSTREAM_PORTS="0.0.0.0:5000, 0.0.0.0:8000, 0.0.0.0:8088, 0.0.0.0:3000, 0.0.0.0:4000, 0.0.0.0:6000"
UPSTREAM_PORTS="$UPSTREAM_PORTS, 0.0.0.0:8001, 0.0.0.0:8002, 0.0.0.0:8003, 0.0.0.0:8010, 0.0.0.0:8004"
UPSTREAM_PORTS="$UPSTREAM_PORTS, 0.0.0.0:8012, 0.0.0.0:9000, 0.0.0.0:8080"

work="$(mktemp -d /tmp/kx-envoy-conformance-XXXXXX)"
chmod 0755 "$work"

cleanup() {
  docker rm -f "$RUN-gateway" "$RUN-echo" >/dev/null 2>&1 || true
  docker network rm "$RUN-staff" "$RUN-outside" "$RUN-internal" >/dev/null 2>&1 || true
  docker image rm "$PROBE_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

docker build -q -t "$PROBE_IMAGE" - >/dev/null <<'DOCKERFILE'
FROM alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412
RUN apk add --no-cache curl jq openssl
DOCKERFILE

cp \
  "$HERE/edge_probe/echo.yml" \
  "$HERE/edge_probe/tiles.conf" \
  "$HERE/edge_probe/material.sh" \
  "$HERE/edge_probe/checks.sh" \
  "$work/"
chmod 0644 "$work/echo.yml" "$work/tiles.conf"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$work:/work" \
  -e API_HOST="$API_HOST" \
  -e BACKOFFICE_NAME="$BACKOFFICE_NAME" \
  -e SELLER_NAME="$SELLER_NAME" \
  -e STORAGE_HOST="$STORAGE_HOST" \
  -e ONION_NAME="$ONION_NAME" \
  -e ISSUER="$ISSUER" \
  "$PROBE_IMAGE" sh /work/material.sh

"$PKL_BIN" eval \
  -p identityJwtPublicKey="$(cat "$work/jwt-public.pem")" \
  -p jwtIssuer="$ISSUER" \
  -p corsOrigins="$BROWSER_ORIGIN" \
  -p staffRanges="$STAFF_PREFIX.0/24" \
  -p publicApiHost="$API_HOST" \
  -p backofficeHost="$BACKOFFICE_NAME:8443" \
  -p sellerHost="$SELLER_NAME" \
  -p backofficeOnionHost="$ONION_NAME" \
  -p storageHost="$STORAGE_HOST" \
  -p backofficeOnionTlsCertFile="$work/onion.pem" \
  -p backofficeOnionTlsKeyFile="$work/onion.key" \
  -p backofficeTlsCertFile="$work/backoffice.pem" \
  -p backofficeTlsKeyFile="$work/backoffice.key" \
  -f yaml "$ROOT/config/envoy.pkl" -o "$work/envoy.yaml"

chmod -R a+rX "$work"

docker network create --subnet "$STAFF_PREFIX.0/24" "$RUN-staff" >/dev/null
docker network create --subnet "$OUTSIDE_PREFIX.0/24" "$RUN-outside" >/dev/null
docker network create --subnet "$INTERNAL_PREFIX.0/24" "$RUN-internal" >/dev/null

aliases=()
for upstream in "${UPSTREAMS[@]}"; do
  aliases+=(--network-alias "$upstream")
done

docker run -d --name "$RUN-echo" \
  --network "$RUN-staff" \
  --ip "$STAFF_PREFIX.30" \
  "${aliases[@]}" \
  -v "$work/echo.yml:/echo.yml:ro" \
  -v "$work/tiles.conf:/tiles.conf:ro" \
  -v "$ROOT/config/access_log.conf:/usr/local/kong/kinetix/access_log.conf:ro" \
  -v "$work/app:/srv:ro" \
  -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/echo.yml \
  -e KONG_NGINX_HTTP_INCLUDE=/tiles.conf \
  -e KONG_PROXY_LISTEN="$UPSTREAM_PORTS" \
  -e KONG_ADMIN_LISTEN=off \
  -e KONG_ADMIN_GUI_LISTEN=off \
  --entrypoint /docker-entrypoint.sh \
  "$KONG_ECHO_IMAGE" kong docker-start >/dev/null

docker run -d --name "$RUN-gateway" \
  -u 0:0 \
  --network "$RUN-staff" \
  --ip "$STAFF_PREFIX.10" \
  -v "$work/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
  -v "$work/tls.pem:/etc/kinetix/tls/tls.crt:ro" \
  -v "$work/tls.key:/etc/kinetix/tls/tls.key:ro" \
  "$ENVOY_IMAGE" envoy -c /etc/envoy/envoy.yaml >/dev/null

docker network connect --ip "$OUTSIDE_PREFIX.10" "$RUN-outside" "$RUN-gateway"
docker network connect --ip "$INTERNAL_PREFIX.10" "$RUN-internal" "$RUN-gateway"

failures=0

run_checks() {
  local side="$1"
  local group="$2"
  local host="$3"
  local prefix="$STAFF_PREFIX"

  case "$side" in
    outside) prefix="$OUTSIDE_PREFIX" ;;
    internal) prefix="$INTERNAL_PREFIX" ;;
  esac

  docker run --rm \
    --network "$RUN-$side" \
    --ip "$prefix.$host" \
    -v "$work:/work:ro" \
    -e API_HOST="$API_HOST" \
    -e PUBLIC_API_HOST="$API_HOST" \
    -e BACKOFFICE_NAME="$BACKOFFICE_NAME" \
    -e SELLER_NAME="$SELLER_NAME" \
    -e ONION_NAME="$ONION_NAME" \
    -e STORAGE_HOST="$STORAGE_HOST" \
    -e INTERNAL_HOST="$INTERNAL_HOST" \
    -e GATEWAY_ADDRESS="$prefix.10" \
    -e CLIENT_ADDRESS="$prefix.$host" \
    -e BROWSER_ORIGIN="$BROWSER_ORIGIN" \
    -e STAFF_ADDRESS="$STAFF_PREFIX.21" \
    "$PROBE_IMAGE" sh /work/checks.sh "$side" "$group"
}

probe() {
  run_checks "$@" || failures=$((failures + 1))
}

if ! run_checks staff wait 20; then
  echo "── echo upstream log (tail)"
  docker logs "$RUN-echo" 2>&1 | tail -n 20
  echo "── envoy gateway log (tail)"
  docker logs "$RUN-gateway" 2>&1 | tail -n 20
  exit 1
fi

for side in staff outside; do
  echo "── Envoy TLS, from the $side network"
  probe "$side" admin 21
  probe "$side" public 22
  probe "$side" edge 23
  probe "$side" browser 24
  probe "$side" misdirected 25
done

echo "── Envoy TLS, from the internal network (outside the staff range)"
probe internal admin 21
probe internal misdirected 25

echo "── Envoy plaintext, from the internal network: the internal twins"
probe internal plaintext 22

echo "── Envoy onion listener, from the internal network"
probe internal onion 27

if [ "$failures" -ne 0 ]; then
  echo "── envoy gateway log (tail)"
  docker logs "$RUN-gateway" 2>&1 | tail -n 40
  echo "$failures probe group(s) failed"
  exit 1
fi

echo "every Envoy conformance probe group passed"
