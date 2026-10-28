#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: test/edge_probe.sh <gateway image>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="kxprobe-$$"
STAFF_PREFIX="${EDGE_PROBE_STAFF_PREFIX:-10.231.10}"
OUTSIDE_PREFIX="${EDGE_PROBE_OUTSIDE_PREFIX:-10.231.20}"
INTERNAL_PREFIX="${EDGE_PROBE_INTERNAL_PREFIX:-10.231.40}"
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
  kinetix-notification-service
  kinetix-object-store
  kinetix-edge-service
  kinetix-backoffice
)
UPSTREAM_PORTS="0.0.0.0:5000, 0.0.0.0:8000, 0.0.0.0:8088, 0.0.0.0:3000, 0.0.0.0:4000, 0.0.0.0:6000"
UPSTREAM_PORTS="$UPSTREAM_PORTS, 0.0.0.0:8001, 0.0.0.0:8002, 0.0.0.0:8003, 0.0.0.0:8010, 0.0.0.0:8004"
UPSTREAM_PORTS="$UPSTREAM_PORTS, 0.0.0.0:9000, 0.0.0.0:8080"

work="$(mktemp -d)"
chmod 0755 "$work"

cleanup() {
  docker rm -f "$RUN-gateway" "$RUN-echo" "$RUN-refused" >/dev/null 2>&1 || true
  docker network rm "$RUN-staff" "$RUN-outside" "$RUN-internal" >/dev/null 2>&1 || true
  docker image rm "$PROBE_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

docker build -q -t "$PROBE_IMAGE" - >/dev/null <<'DOCKERFILE'
FROM alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412
RUN apk add --no-cache curl jq openssl
DOCKERFILE

cp "$HERE/edge_probe/echo.yml" "$HERE/edge_probe/material.sh" "$HERE/edge_probe/checks.sh" "$work/"
chmod 0644 "$work/echo.yml"
docker run --rm \
  -v "$work:/work" \
  -e API_HOST="$API_HOST" \
  -e BACKOFFICE_NAME="$BACKOFFICE_NAME" \
  -e SELLER_NAME="$SELLER_NAME" \
  -e STORAGE_HOST="$STORAGE_HOST" \
  -e ISSUER="$ISSUER" \
  "$PROBE_IMAGE" sh /work/material.sh

jwt_key="$(base64 < "$work/jwt-public.pem" | tr -d '\n')"
tls_cert="$(base64 < "$work/tls.pem" | tr -d '\n')"
tls_key="$(base64 < "$work/tls.key" | tr -d '\n')"

failures=0

refuses_to_start() {
  local label="$1"
  local expected="$2"
  shift 2

  local output
  if output="$(docker run --name "$RUN-refused" \
    -e KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64="$jwt_key" \
    -e KINETIX_JWT_ISSUER="$ISSUER" \
    -e KINETIX_GATEWAY_CORS_ORIGINS= \
    -e KINETIX_GATEWAY_TLS_CERT_B64="$tls_cert" \
    -e KINETIX_GATEWAY_TLS_KEY_B64="$tls_key" \
    "$@" \
    "$IMAGE" kong version 2>&1)"; then
    echo "  FAIL  the gateway started $label"
    failures=$((failures + 1))
  elif printf '%s' "$output" | grep -q "$expected"; then
    echo "  ok    the gateway refuses to start $label"
  else
    echo "  FAIL  the gateway refused to start $label, but not for that reason: $(printf '%s' "$output" | tail -n 3)"
    failures=$((failures + 1))
  fi

  docker rm -f "$RUN-refused" >/dev/null 2>&1 || true
}

echo "── the gateway fails fast without its staff range and its hosts"
refuses_to_start "without a staff range" "KINETIX_GATEWAY_STAFF_RANGES is required" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME"
refuses_to_start "with a staff range of everyone" "Type constraint" \
  -e KINETIX_GATEWAY_STAFF_RANGES=0.0.0.0/0 \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME"
refuses_to_start "without its public host" "KINETIX_PUBLIC_API_HOST is required" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME"
refuses_to_start "without the backoffice host" "KINETIX_BACKOFFICE_HOST is required" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME"
refuses_to_start "without the seller host" "KINETIX_SELLER_HOST is required" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME"
refuses_to_start "with the backoffice on the API's host" "must all differ" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$API_HOST:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME"
refuses_to_start "without the onion address" "KINETIX_BACKOFFICE_ONION_HOST is required" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME"
refuses_to_start "with an onion address that is not one" "Type constraint" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="http://$ONION_NAME"

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
  -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/echo.yml \
  -e KONG_PROXY_LISTEN="$UPSTREAM_PORTS" \
  -e KONG_ADMIN_LISTEN=off \
  -e KONG_ADMIN_GUI_LISTEN=off \
  --entrypoint /docker-entrypoint.sh \
  "$IMAGE" kong docker-start >/dev/null

docker run -d --name "$RUN-gateway" \
  --network "$RUN-staff" \
  --ip "$STAFF_PREFIX.10" \
  -e KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64="$jwt_key" \
  -e KINETIX_JWT_ISSUER="$ISSUER" \
  -e KINETIX_GATEWAY_CORS_ORIGINS="$BROWSER_ORIGIN" \
  -e KINETIX_GATEWAY_STAFF_RANGES="$STAFF_PREFIX.0/24" \
  -e KINETIX_PUBLIC_API_HOST="$API_HOST" \
  -e KINETIX_BACKOFFICE_HOST="$BACKOFFICE_NAME:8443" \
  -e KINETIX_SELLER_HOST="$SELLER_NAME" \
  -e KINETIX_BACKOFFICE_ONION_HOST="$ONION_NAME" \
  -e KINETIX_STORAGE_HOST="$STORAGE_HOST" \
  -e KINETIX_GATEWAY_TLS_CERT_B64="$tls_cert" \
  -e KINETIX_GATEWAY_TLS_KEY_B64="$tls_key" \
  -e KONG_STATUS_LISTEN=0.0.0.0:8100 \
  -e KONG_DNS_VALID_TTL=5 \
  "$IMAGE" >/dev/null
docker network connect --ip "$OUTSIDE_PREFIX.10" "$RUN-outside" "$RUN-gateway"
docker network connect --ip "$INTERNAL_PREFIX.10" "$RUN-internal" "$RUN-gateway"

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
    -e EXPECTED_TWINS="${expected_twins:-0}" \
    "$PROBE_IMAGE" sh /work/checks.sh "$side" "$group"
}

probe() {
  run_checks "$@" || failures=$((failures + 1))
}

if ! run_checks staff wait 20; then
  echo "── echo upstream log (tail)"
  docker logs "$RUN-echo" 2>&1 | tail -n 20
  echo "── gateway log (tail)"
  docker logs "$RUN-gateway" 2>&1 | tail -n 20
  exit 1
fi

expected_twins="$(docker exec "$RUN-gateway" grep -c -- '-internal$' /usr/local/kong/declarative/kong.yml || true)"
if [ "${expected_twins:-0}" -eq 0 ]; then
  echo "  FAIL  the rendered config has no internal twins"
  failures=$((failures + 1))
fi

for side in staff outside; do
  echo "── TLS, from the $side network"
  probe "$side" admin 21
  probe "$side" public 22
  probe "$side" edge 23
  probe "$side" browser 24
  probe "$side" misdirected 25
done

echo "── TLS, from the internal network (outside the staff range)"
probe internal admin 21
probe internal misdirected 25

echo "── which routes answered the TLS listener"
probe staff metrics-tls 26

echo "── plaintext, from the internal network: the $expected_twins internal twins"
probe internal plaintext 22

echo "── the onion listener, from the internal network (outside the staff range, as the tor container is)"
probe internal onion 27

echo "── which routes answered the plaintext and onion listeners"
probe staff metrics-plaintext 26

if [ "$failures" -ne 0 ]; then
  echo "── gateway log (tail)"
  docker logs "$RUN-gateway" 2>&1 | tail -n 40
  echo "$failures probe group(s) failed"
  exit 1
fi

echo "every probe group passed"
