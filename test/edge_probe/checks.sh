#!/bin/sh
set -u

SIDE="$1"
GROUP="$2"
GATE_MESSAGE="This route is not available from your network"
TOKEN="$(cat /work/token)"
SCHEME=https
NAME="$API_HOST"
PORT=8443
pass=0
fail=0

ok() {
  echo "  ok    $*"
  pass=$((pass + 1))
}

bad() {
  echo "  FAIL  $*"
  fail=$((fail + 1))
}

target() {
  SCHEME="$1"
  NAME="$2"
  PORT="$3"
}

call() {
  method="$1"
  path="$2"
  auth="$3"
  shift 3
  if [ "$auth" = token ]; then
    set -- -H "Authorization: Bearer $TOKEN" "$@"
  fi

  status="$(curl -sS --path-as-is --max-time 10 \
    --cacert /work/tls.pem \
    --resolve "$NAME:$PORT:$GATEWAY_ADDRESS" \
    -D /tmp/headers \
    -o /tmp/body \
    -w '%{http_code}' \
    -X "$method" \
    "$@" \
    "$SCHEME://$NAME:$PORT$path")"
}

header() {
  tr -d '\r' < /tmp/headers | grep -i "^$1:" | head -n 1 | cut -d' ' -f2-
}

message() {
  jq -r '.message // empty' /tmp/body 2>/dev/null
}

echoed() {
  jq -r '"\(.request.port) \(.request.method) \(.request.path)"' /tmp/body 2>/dev/null
}

listener_matches() {
  limit="$(header x-ratelimit-limit-minute)"
  if [ "$SCHEME" = https ]; then
    [ -n "$limit" ]
  else
    [ -z "$limit" ]
  fi
}

reaches() {
  call "$1" "$2" "$3"
  got="$(echoed)"
  if [ "$status" = 200 ] && [ "$got" = "$4 $1 $5" ] && listener_matches; then
    ok "$SCHEME $1 $2 -> :$4 $5 (rate limit: ${limit:-none})"
  else
    bad "$SCHEME $1 $2 -> $status ${got:-$(head -c 200 /tmp/body)} rate limit '${limit:-}' (wanted :$4 $1 $5)"
  fi
}

token_not_read_from_query_or_cookie() {
  call "$1" "$2?jwt=$TOKEN" none
  if [ "$status" = 401 ] \
    && [ "$(message)" = Unauthorized ] \
    && [ "$(header www-authenticate)" = Bearer ] \
    && [ "$(jq -r 'has("request")' /tmp/body 2>/dev/null)" = false ]; then
    ok "$SCHEME $1 $2?jwt=<valid token> -> 401 Unauthorized, Bearer: no token is read from the query"
  else
    bad "$SCHEME $1 $2?jwt=<valid token> -> $status $(head -c 200 /tmp/body) WWW-Authenticate '$(header www-authenticate)' (wanted jwt's 401 for a missing token)"
  fi

  call "$1" "$2" none -H "Cookie: jwt=$TOKEN"
  if [ "$status" = 401 ] && [ "$(message)" = Unauthorized ] && [ "$(header www-authenticate)" = Bearer ]; then
    ok "$SCHEME $1 $2 with the valid token in a jwt cookie -> 401 Unauthorized: no token is read from a cookie"
  else
    bad "$SCHEME $1 $2 with the valid token in a jwt cookie -> $status $(head -c 200 /tmp/body) (wanted jwt's 401 for a missing token)"
  fi
}

upgrade() {
  path="$1"
  shift
  call GET "$path?vsn=2.0.0&token=probe" none \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "$@"
}

upgrade_reaches() {
  upgrade "$1"
  got="$(jq -r '"\(.request.port) \(.request.path) \(.request.query.vsn) \(.request.headers.upgrade) \(.request.headers["x-forwarded-proto"])"' /tmp/body 2>/dev/null)"
  want="4000 $2 2.0.0 websocket https"
  if [ "$status" = 200 ] && [ "$got" = "$want" ] && listener_matches; then
    ok "$SCHEME upgrade $1 (Host $NAME) -> :4000 $2 with its query, Upgrade and X-Forwarded-Proto https (rate limit: ${limit:-none})"
  else
    bad "$SCHEME upgrade $1 (Host $NAME) -> $status '$got' rate limit '${limit:-}' (wanted '$want')"
  fi
}

refused() {
  call "$@"
  if [ "$status" = 403 ] && [ "$(message)" = "$GATE_MESSAGE" ]; then
    ok "$1 $2 -> 403 from the staff gate"
  else
    bad "$1 $2 -> $status $(head -c 200 /tmp/body) (wanted the staff gate's 403)"
  fi
}

misdirected() {
  call "$@"
  misdirected_answer "$1" "$2"
}

misdirected_answer() {
  if [ "$status" = 421 ] \
    && [ "$(message)" = "Misdirected Request" ] \
    && [ "$(jq -r 'has("request")' /tmp/body 2>/dev/null)" = false ]; then
    ok "TLS $1 $2 naming the internal host -> 421 from the twin's guard, never proxied"
  else
    bad "TLS $1 $2 naming the internal host -> $status $(head -c 200 /tmp/body) (wanted 421)"
  fi
}

needs_tls() {
  call "$@"
  needs_tls_answer "$1" "$2"
}

needs_tls_answer() {
  if [ "$status" = 426 ] && [ "$(message)" = "Please use HTTPS protocol" ]; then
    ok "plaintext $1 $2 (Host $NAME) -> 426: only a TLS route matches, no twin"
  else
    bad "plaintext $1 $2 (Host $NAME) -> $status $(head -c 200 /tmp/body) (wanted 426)"
  fi
}

unrouted() {
  call "$@"
  if [ "$status" = 404 ] && [ "$(message)" = "Not found" ] && [ "$(jq -r 'has("request")' /tmp/body 2>/dev/null)" = false ]; then
    ok "$NAME $1 $2 -> 404, nothing but /bff/ is routed on this host"
  else
    bad "$NAME $1 $2 -> $status $(head -c 200 /tmp/body) (wanted the browser-app host's 404)"
  fi
}

reaches_edge() {
  method="$1"
  path="$2"
  shift 2
  call "$method" "$path" none "$@"
  got="$(jq -r '"\(.request.port) \(.request.method) \(.request.path) \(.request.headers.host)"' /tmp/body 2>/dev/null)"
  want="8080 $method $path $NAME:$PORT"
  if [ "$status" = 200 ] \
    && [ "$got" = "$want" ] \
    && [ "$(header x-ratelimit-limit-minute)" = 100 ] \
    && [ -z "$(header access-control-allow-origin)" ]; then
    ok "$NAME $method $path -> the edge :8080 with Host $NAME:$PORT, the per-address limit, no CORS"
  else
    bad "$NAME $method $path -> $status '$got' limit '$(header x-ratelimit-limit-minute)' acao '$(header access-control-allow-origin)' (wanted '$want')"
  fi
}

admin_table() {
  cat <<'ROUTES'
GET /api/v1/sellers/applications token 5000 /api/v1/sellers/applications
POST /api/v1/sellers/7/verify token 5000 /api/v1/sellers/7/verify
POST /api/v1/sellers/7/reject token 5000 /api/v1/sellers/7/reject
GET /api/v1/couriers/applications token 5000 /api/v1/couriers/applications
POST /api/v1/couriers/0b0e7f6e-1b7a-4c5e-9c1e-1f2a3b4c5d6e/approve token 5000 /api/v1/couriers/0b0e7f6e-1b7a-4c5e-9c1e-1f2a3b4c5d6e/approve
POST /api/v1/couriers/register/approve token 5000 /api/v1/couriers/register/approve
POST /api/v1/sellers//7/verify token 5000 /api/v1/sellers/7/verify
POST /api/v1/categories none 8000 /api/categories
POST /api/v1/categories/ none 8000 /api/categories/
PUT /api/v1/categories/3 none 8000 /api/categories/3
PUT /api/v1/categories/3/ none 8000 /api/categories/3/
PATCH /api/v1/categories/3 none 8000 /api/categories/3
DELETE /api/v1/categories/3 none 8000 /api/categories/3
POST /api/v1/warehouse/bins none 3000 /api/v1/bins
POST /api/v1/warehouse/bins/ none 3000 /api/v1/bins/
POST /api/v1/warehouse/stock_receipts none 3000 /api/v1/stock_receipts
POST /api/v1/warehouse/stock_adjustments none 3000 /api/v1/stock_adjustments
POST /api/v1/warehouse//bins none 3000 /api/v1/bins
POST /api/v1/warehouse/x/../bins none 3000 /api/v1/bins
POST /api/v1/warehouse/%62ins none 3000 /api/v1/bins
GET /api/v1/matching/drivers token 4000 /api/v1/drivers
GET /api/v1/matching/drivers/nearby token 4000 /api/v1/drivers/nearby
GET /api/v1/matching/drivers/42 token 4000 /api/v1/drivers/42
GET /api/v1/matching//drivers token 4000 /api/v1/drivers
GET /api/v1/matching/backoffice/dispatches token 4000 /api/v1/backoffice/dispatches
POST /api/v1/matching/backoffice/dispatches/9/assign token 4000 /api/v1/backoffice/dispatches/9/assign
GET /api/v1/orders/sagas/needs-attention none 8001 /api/v1/orders/sagas/needs-attention
GET /api/v1/orders/sagas/needs-attention/count none 8001 /api/v1/orders/sagas/needs-attention/count
GET /api/v1/orders/SAGAS/needs-attention none 8001 /api/v1/orders/SAGAS/needs-attention
GET /api/v1/orders/returns/needs-attention none 8001 /api/v1/orders/returns/needs-attention
POST /api/v1/orders/returns/RET-1/reject none 8001 /api/v1/orders/returns/RET-1/reject
POST /api/v1/orders/Returns/RET-1/Reject none 8001 /api/v1/orders/Returns/RET-1/Reject
POST /api/v1/orders/ORD-1/complete none 8001 /api/v1/orders/ORD-1/complete
POST /api/v1/orders/ORD-1/Complete none 8001 /api/v1/orders/ORD-1/Complete
ROUTES
}

public_table() {
  cat <<'ROUTES'
POST /api/v1/auth/login none 5000 /api/v1/auth/login
POST /api/v1/couriers/register none 5000 /api/v1/couriers/register
GET /.well-known/jwks.json none 5000 /.well-known/jwks.json
GET /api/v1/auth/me token 5000 /api/v1/auth/me
GET /api/v1/users/7/profile token 5000 /api/v1/users/7/profile
GET /api/v1/sellers/7/application token 5000 /api/v1/sellers/7/application
POST /api/v1/sellers/7/onboard token 5000 /api/v1/sellers/7/onboard
GET /api/v1/categories none 8000 /api/categories
GET /api/v1/categories/ none 8000 /api/categories/
GET /api/v1/categories/3 none 8000 /api/categories/3
GET /api/v1/products none 8000 /api/products
GET /api/v1/products/SKU-1 none 8000 /api/products/SKU-1
POST /api/v1/products/create/ none 8000 /api/products/create/
GET /api/v1/products/search none 8088 /api/v1/products/search
GET /api/v1/warehouse/fulfillment_tasks none 3000 /api/v1/fulfillment_tasks
GET /api/v1/warehouse/merchants/me none 3000 /api/v1/merchants/me
POST /api/v1/warehouse/returns/RET-1/received none 3000 /api/v1/returns/RET-1/received
GET /api/v1/matching/driver/me token 4000 /api/v1/driver/me
POST /api/v1/matching/merchant/orders token 4000 /api/v1/merchant/orders
POST /api/v1/matching/shipping/options token 4000 /api/v1/shipping/options
GET /api/v1/pricing/vouchers none 6000 /api/v1/vouchers
POST /api/v1/cart/items none 8001 /api/v1/cart/items
POST /api/v1/orders/checkout none 8001 /api/v1/orders/checkout
GET /api/v1/orders/my-orders none 8001 /api/v1/orders/my-orders
GET /api/v1/orders/0b0e7f6e-1b7a-4c5e-9c1e-1f2a3b4c5d6e none 8001 /api/v1/orders/0b0e7f6e-1b7a-4c5e-9c1e-1f2a3b4c5d6e
GET /api/v1/reviews/products/SKU-1 none 8002 /api/v1/reviews/products/SKU-1
POST /api/v1/payment/gateway/midtrans/notifications none 8003 /api/v1/payment/gateway/midtrans/notifications
GET /api/v1/payment/wallet/customer/balance token 8003 /api/v1/payment/wallet/customer/balance
GET /api/v1/proofs/liabilities/latest token 8010 /api/v1/proofs/liabilities/latest
GET /api/v1/proofs/registrations token 8010 /api/v1/proofs/registrations
POST /api/v1/notifications/devices token 8004 /api/v1/notifications/devices
ROUTES
}

driver_socket_table() {
  cat <<'ROUTES'
GET /ws/v1/matching/driver none 4000 /driver/websocket
GET /ws/v1/matching/driver/websocket none 4000 /driver/websocket
ROUTES
}

merchant_socket_table() {
  cat <<'ROUTES'
GET /ws/v1/matching/merchant none 4000 /merchant/websocket
GET /ws/v1/matching/merchant/websocket none 4000 /merchant/websocket
ROUTES
}

socket_table() {
  driver_socket_table
  merchant_socket_table
}

admin_routes() {
  admin_table > /tmp/admin_table
  while read -r method path auth port upstream; do
    [ -z "$method" ] && continue
    if [ "$SIDE" = staff ]; then
      reaches "$method" "$path" "$auth" "$port" "$upstream"
    else
      refused "$method" "$path" "$auth"
    fi
    if [ "$auth" = token ]; then
      token_not_read_from_query_or_cookie "$method" "$path"
    fi
  done < /tmp/admin_table
}

public_routes() {
  public_table > /tmp/public_table
  socket_table >> /tmp/public_table
  while read -r method path auth port upstream; do
    [ -z "$method" ] && continue
    reaches "$method" "$path" "$auth" "$port" "$upstream"
    if [ "$auth" = token ]; then
      token_not_read_from_query_or_cookie "$method" "$path"
    fi
  done < /tmp/public_table
}

edge_cases() {
  call GET /health none
  if [ "$status" = 200 ] && [ "$(cat /tmp/body)" = '{"status":"ok"}' ]; then
    ok "GET /health -> 200 {\"status\":\"ok\"}"
  else
    bad "GET /health -> $status $(cat /tmp/body)"
  fi

  printf '%s\n' \
    "Contact: https://github.com/WildanFrananda/kinetix-docs/security/advisories/new" \
    "Expires: 2027-10-21T00:00:00.000Z" \
    "Preferred-Languages: en, id" \
    "Canonical: https://$PUBLIC_API_HOST/.well-known/security.txt" \
    "Policy: https://docs.wildanfrananda.my.id/reference/report-a-vulnerability/" > /tmp/security.txt
  call GET /.well-known/security.txt none
  if [ "$status" = 200 ] \
    && [ "$(header content-type)" = "text/plain; charset=utf-8" ] \
    && cmp -s /tmp/security.txt /tmp/body; then
    ok "GET /.well-known/security.txt -> 200 text/plain, the RFC 9116 body byte for byte"
  else
    bad "GET /.well-known/security.txt -> $status $(header content-type) $(head -c 300 /tmp/body)"
  fi

  for socket in driver merchant; do
    upgrade_reaches "/ws/v1/matching/$socket/websocket" "/$socket/websocket"
    upgrade_reaches "/ws/v1/matching/$socket" "/$socket/websocket"
  done

  target https "$STORAGE_HOST" 8443
  call PUT /kinetix-uploads/probe.jpg none
  got="$(jq -r '"\(.request.port) \(.request.path) \(.request.headers.host)"' /tmp/body 2>/dev/null)"
  if [ "$status" = 200 ] && [ "$got" = "9000 /kinetix-uploads/probe.jpg $STORAGE_HOST:8443" ]; then
    ok "the storage host reaches :9000 with its Host kept"
  else
    bad "storage host -> $status $got"
  fi
  target https "$API_HOST" 8443

  call OPTIONS /api/v1/products none \
    -H "Origin: $BROWSER_ORIGIN" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: authorization,x-kinetix-client,x-firebase-appcheck"
  allowed="$(header access-control-allow-headers)"
  case "$status,$allowed" in
    200,*X-Kinetix-Client*X-Firebase-AppCheck*)
      ok "a CORS preflight is allowed X-Kinetix-Client and X-Firebase-AppCheck ($allowed)" ;;
    *)
      bad "CORS preflight -> $status, Access-Control-Allow-Headers: $allowed" ;;
  esac

  call OPTIONS /api/v1/sellers/applications none \
    -H "Origin: $BROWSER_ORIGIN" \
    -H "Access-Control-Request-Method: GET"
  if [ "$status" = 200 ] && [ "$(header access-control-allow-origin)" = "$BROWSER_ORIGIN" ]; then
    ok "a preflight to an admin-only route is answered by the cors plugin, which runs before the gate"
  else
    bad "preflight to an admin-only route -> $status"
  fi

  if [ "$SIDE" = staff ]; then
    call GET /api/v1/orders/sagas/needs-attention none
    if [ "$status" = 200 ] \
      && [ "$(header x-ratelimit-limit-minute)" = 100 ] \
      && [ -n "$(header x-request-id)" ]; then
      ok "an admin-only route keeps the per-address rate limit and the request id"
    else
      bad "admin-only route lost a plugin: $status limit=$(header x-ratelimit-limit-minute) id=$(header x-request-id)"
    fi

    call POST /api/v1/payment/gateway/midtrans/notifications none
    if [ "$status" = 200 ] && [ "$(header x-ratelimit-limit-minute)" = 600 ]; then
      ok "Midtrans' route keeps its own 600 a minute"
    else
      bad "Midtrans' route -> $status limit=$(header x-ratelimit-limit-minute)"
    fi

    call GET /api/v1/sellers/applications none
    if [ "$status" = 401 ]; then
      ok "an admin-only identity route still needs a token from the staff network (401)"
    else
      bad "GET /api/v1/sellers/applications without a token -> $status"
    fi
  else
    call GET /api/v1/sellers/applications none
    if [ "$status" = 401 ]; then
      ok "without a token, jwt answers 401 before the gate is consulted"
    else
      bad "GET /api/v1/sellers/applications without a token from outside -> $status"
    fi

    refused POST /api/v1/orders/ORD-1/complete none -H "X-Forwarded-For: $STAFF_ADDRESS"
    refused POST /api/v1/orders/ORD-1/complete none -H "X-Real-IP: $STAFF_ADDRESS"

    call GET /api/v1/orders/returns/needs-attention none
    if [ -n "$(jq -r '.request_id // empty' /tmp/body 2>/dev/null)" ] \
      && [ "$(jq -r 'keys | join(",")' /tmp/body 2>/dev/null)" = "message,request_id" ]; then
      ok "the gate's body is Kong's error shape: {message, request_id}, no address"
    else
      bad "the gate's body: $(head -c 300 /tmp/body)"
    fi
  fi
}

unrouted_table() {
  cat <<'ROUTES'
GET / none
GET /bff none
GET /bffx none
GET /BFF/session none
GET /bff/../api/v1/products none
GET /bff/%2e%2e/api/v1/products none
GET /health none
GET /.well-known/security.txt none
GET /.well-known/jwks.json none
GET /api/v1/products none
GET /api/v1/products/search none
POST /api/v1/categories none
POST /api/v1/auth/login none
POST /api/v1/payment/gateway/midtrans/notifications none
GET /api/v1/proofs/liabilities/latest token
POST /api/v1/notifications/devices token
GET /api/v1/sellers/applications token
GET /api/v1/matching/drivers token
POST /api/v1/orders/ORD-1/complete none
GET /api/v1/matching/driver/me token
GET /ws/v1/matching/driver/websocket none
ROUTES
}

browser_apps() {
  unrouted_table > /tmp/unrouted_table
  for app in "$BACKOFFICE_NAME" "$SELLER_NAME"; do
    target https "$app" 8443
    while read -r method path auth; do
      [ -z "$method" ] && continue
      unrouted "$method" "$path" "$auth"
    done < /tmp/unrouted_table

    unrouted GET /api/v1/products none -H "Host: $app"
    unrouted GET /api/v1/products none -H "Host: $app:9999"

    if [ "$app" = "$BACKOFFICE_NAME" ] && [ "$SIDE" != staff ]; then
      refused GET /bff/session none
      refused POST /bff/login none -H "Content-Type: application/json" -d '{}'
      refused POST /bff/login none -H "X-Forwarded-For: $STAFF_ADDRESS"
      refused POST /bff/login none -H "X-Real-IP: $STAFF_ADDRESS"
      refused GET /bff/session none -H "Host: $app"

      upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
      call GET /bff/session none -H "Host: $upper:8443"
      if [ "$status" != 200 ] && [ "$(jq -r 'has("request")' /tmp/body 2>/dev/null)" != true ]; then
        ok "$upper:8443/bff/session from outside -> $status, not the edge"
      else
        bad "$upper:8443/bff/session from outside reached the edge"
      fi
      continue
    fi

    reaches_edge GET /bff/session
    reaches_edge POST /bff/login -H "Content-Type: application/json" -d '{}'
    reaches_edge POST /bff/2fa/verify -H "Origin: $BROWSER_ORIGIN"
    reaches_edge DELETE /bff/api/v1/notifications/devices
    reaches_edge GET /bff/api/v1/orders/ORD-1 -H "Origin: $BROWSER_ORIGIN"
    reaches_edge OPTIONS /bff/login \
      -H "Origin: $BROWSER_ORIGIN" \
      -H "Access-Control-Request-Method: POST"

    call GET /bff/session none -H "Host: $app"
    if [ "$status" = 200 ] && [ "$(jq -r '"\(.request.port) \(.request.headers.host)"' /tmp/body)" = "8080 $app" ]; then
      ok "$app without a port in Host still reaches the edge, Host kept"
    else
      bad "$app without a port in Host -> $status $(head -c 200 /tmp/body)"
    fi

    call GET /bff/session token
    if [ "$status" = 200 ] && [ "$(jq -r '.request.headers.authorization' /tmp/body)" = "Bearer $TOKEN" ]; then
      ok "$app /bff/ carries no jwt plugin: the edge decides (a bearer passes through untouched)"
    else
      bad "$app /bff/session with a bearer -> $status"
    fi
  done
}

misdirected_twins() {
  misdirected GET /api/v1/products none -H "Host: $INTERNAL_HOST"
  misdirected GET /api/v1/products none -H "Host: $INTERNAL_HOST:8000"
  misdirected POST /api/v1/orders/ORD-1/complete none -H "Host: $INTERNAL_HOST"
  misdirected POST /api/v1/categories none -H "Host: $INTERNAL_HOST"
  misdirected GET /api/v1/sellers/applications none -H "Host: $INTERNAL_HOST"
  misdirected GET /api/v1/matching/drivers token -H "Host: $INTERNAL_HOST"
  misdirected POST /api/v1/warehouse/bins none -H "Host: $INTERNAL_HOST:8000"
  upgrade /ws/v1/matching/merchant/websocket -H "Host: $INTERNAL_HOST"
  misdirected_answer GET /ws/v1/matching/merchant/websocket
  upgrade /ws/v1/matching/merchant -H "Host: $INTERNAL_HOST:8000"
  misdirected_answer GET /ws/v1/matching/merchant

  call POST /api/v1/orders/ORD-1/complete none -H "Host: KINETIX-API-GATEWAY"
  if [ "$status" = 421 ] || { [ "$status" = 403 ] && [ "$SIDE" != staff ]; } || { [ "$status" = 200 ] && [ "$SIDE" = staff ] && listener_matches; }; then
    ok "TLS naming the internal host in capitals -> $status: a twin's guard or the TLS route, never a twin's upstream"
  else
    bad "TLS naming the internal host in capitals -> $status $(head -c 200 /tmp/body)"
  fi
}

plaintext_twins() {
  target http "$INTERNAL_HOST" 8000
  admin_table > /tmp/plain_table
  public_table >> /tmp/plain_table
  while read -r method path auth port upstream; do
    [ -z "$method" ] && continue
    reaches "$method" "$path" "$auth" "$port" "$upstream"
    if [ "$auth" = token ]; then
      call "$method" "$path" none
      if [ "$status" = 401 ]; then
        ok "plaintext $method $path without a token -> 401 from the twin's jwt"
      else
        bad "plaintext $method $path without a token -> $status $(head -c 200 /tmp/body)"
      fi
      token_not_read_from_query_or_cookie "$method" "$path"
    fi
  done < /tmp/plain_table

  merchant_socket_table > /tmp/socket_table
  while read -r method path auth port upstream; do
    [ -z "$method" ] && continue
    reaches "$method" "$path" "$auth" "$port" "$upstream"
  done < /tmp/socket_table
  upgrade_reaches /ws/v1/matching/merchant/websocket /merchant/websocket
  upgrade_reaches /ws/v1/matching/merchant /merchant/websocket

  driver_socket_table > /tmp/socket_table
  while read -r method path auth port upstream; do
    [ -z "$method" ] && continue
    needs_tls "$method" "$path" "$auth"
    socket="$path"
    upgrade "$socket"
    needs_tls_answer GET "$socket (upgrade)"
  done < /tmp/socket_table
  needs_tls GET /health none
  needs_tls GET /.well-known/security.txt none

  for name in "$API_HOST" "$STORAGE_HOST" "$BACKOFFICE_NAME" "$SELLER_NAME"; do
    target http "$name" 8000
    if [ "$name" = "$API_HOST" ]; then
      needs_tls GET /api/v1/products none
      needs_tls POST /api/v1/orders/ORD-1/complete none
    elif [ "$name" = "$STORAGE_HOST" ]; then
      needs_tls PUT /kinetix-uploads/probe.jpg none
    else
      needs_tls GET /bff/session none
      needs_tls GET /api/v1/products none
    fi
    if [ "$name" != "$STORAGE_HOST" ]; then
      upgrade /ws/v1/matching/merchant/websocket
      needs_tls_answer GET "/ws/v1/matching/merchant/websocket (upgrade)"
    fi
  done
  target http "$INTERNAL_HOST" 8000

  call GET /bff/session none
  if [ "$status" = 404 ] && [ "$(message)" = "no Route matched with those values" ]; then
    ok "plaintext /bff/ on the internal host -> Kong's 404: the edge is never reached through the twins"
  else
    bad "plaintext /bff/session on the internal host -> $status $(head -c 200 /tmp/body)"
  fi

  call GET /api/v1/products none -H "X-Forwarded-For: 198.51.100.23" -H "X-Request-Id: probe-forwarded-1"
  got="$(jq -r '"\(.request.headers["x-forwarded-for"])|\(.request.headers["x-real-ip"])|\(.request.headers["x-request-id"])|\(.request.headers["x-forwarded-proto"])"' /tmp/body 2>/dev/null)"
  if [ "$status" = 200 ] && [ "$got" = "198.51.100.23, $CLIENT_ADDRESS|$CLIENT_ADDRESS|probe-forwarded-1|https" ]; then
    ok "the edge's X-Forwarded-For reaches the upstream intact with Kong's peer appended, X-Forwarded-Proto https ($got)"
  else
    bad "forwarded headers through a twin: $status '$got'"
  fi

  call GET /api/v1/products none -H "X-Forwarded-For: 198.51.100.23, 203.0.113.9"
  got="$(jq -r '.request.headers["x-forwarded-for"]' /tmp/body 2>/dev/null)"
  if [ "$got" = "198.51.100.23, 203.0.113.9, $CLIENT_ADDRESS" ]; then
    ok "a longer X-Forwarded-For is kept whole, Kong only appends ($got)"
  else
    bad "a longer X-Forwarded-For -> '$got'"
  fi

  limited=0
  attempt=0
  while [ "$attempt" -lt 120 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      --resolve "$NAME:$PORT:$GATEWAY_ADDRESS" \
      "$SCHEME://$NAME:$PORT/api/v1/pricing/vouchers")"
    [ "$code" = 200 ] || limited=$((limited + 1))
    attempt=$((attempt + 1))
  done
  if [ "$limited" -eq 0 ]; then
    ok "120 plaintext requests in a burst from one address: none limited (twins carry no rate limit)"
  else
    bad "$limited of 120 plaintext requests were not 200"
  fi
}

metrics_after() {
  curl -sS --max-time 10 "http://$GATEWAY_ADDRESS:8100/metrics" | grep '^kong_http_requests_total{' > /tmp/metrics
  twins_served="$(grep 'route="[^"]*-internal"' /tmp/metrics | grep -v 'code="421"' | wc -l | tr -d ' ')"
  twins_refused="$(grep 'route="[^"]*-internal"' /tmp/metrics | grep -c 'code="421"')"
  public_served="$(grep -v 'route="[^"]*-internal"' /tmp/metrics | grep -c 'code="200"')"
  case "$1" in
    tls)
      if [ "$twins_served" = 0 ] && [ "$twins_refused" -gt 0 ] && [ "$public_served" -gt 0 ]; then
        ok "after every TLS group: $public_served TLS route series served, no twin served anything, $twins_refused twin series only refused 421"
      else
        bad "after the TLS groups the twins served $twins_served series: $(grep 'route="[^"]*-internal"' /tmp/metrics | grep -v 'code="421"' | head -n 3)"
      fi ;;
    plaintext)
      served="$(grep 'route="[^"]*-internal"' /tmp/metrics | grep 'code="200"' | sed 's/.*route="\([^"]*\)".*/\1/' | sort -u | wc -l | tr -d ' ')"
      if [ "$EXPECTED_TWINS" -gt 0 ] && [ "$served" = "$EXPECTED_TWINS" ]; then
        ok "every one of the $EXPECTED_TWINS twins served the plaintext listener"
      else
        bad "$served of $EXPECTED_TWINS twins served a plaintext request"
      fi ;;
  esac
}

wait_for_gateway() {
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    call GET /api/v1/products none
    if [ "$status" = 200 ]; then
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  echo "the gateway never routed a request to the echo upstream (last status $status)"
  return 1
}

case "$GROUP" in
  wait) wait_for_gateway; exit $? ;;
  admin) admin_routes ;;
  public) public_routes ;;
  edge) edge_cases ;;
  browser) browser_apps ;;
  misdirected) misdirected_twins ;;
  plaintext) plaintext_twins ;;
  metrics-tls) metrics_after tls ;;
  metrics-plaintext) metrics_after plaintext ;;
  *) echo "unknown group $GROUP"; exit 2 ;;
esac

echo "  $SIDE/$GROUP: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
