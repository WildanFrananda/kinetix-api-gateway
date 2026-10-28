# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

The **Kinetix API Gateway** is the single entry point for all external client REST and WebSocket traffic into the **Kinetix Real-Time E-Commerce & Fulfillment Ecosystem**. Built on **Kong Gateway DB-less Mode** (`kong:3.9`, pinned by digest) with a declarative configuration rendered from **Apple Pkl** (`config/gateway.pkl`).

---

## 🏛️ Stack & Architecture

- **Gateway Engine**: **Kong Gateway (DB-less Mode)**. The public listener is `:8443`, TLS only. A plaintext listener on `:8000` serves only the edge's calls on the Docker network and is never published (see "Internal listener" below).
- **Configuration Engine**: **Apple Pkl (`config/gateway.pkl`)** rendered to `/usr/local/kong/declarative/kong.yml` by `bin/entrypoint.sh` **when the container starts**, from `KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64`, `KINETIX_JWT_ISSUER`, `KINETIX_GATEWAY_CORS_ORIGINS`, `KINETIX_GATEWAY_STAFF_RANGES`, `KINETIX_PUBLIC_API_HOST`, `KINETIX_BACKOFFICE_HOST` and `KINETIX_SELLER_HOST` (and the optional `KINETIX_STORAGE_HOST`). The image carries no key, issuer, origin, address range, host or certificate, so one digest runs in every environment.
- **TLS**: `KINETIX_GATEWAY_TLS_CERT_FILE` + `_KEY_FILE` (production, Let's Encrypt on disk) or `KINETIX_GATEWAY_TLS_CERT_B64` + `_KEY_B64` (the lab, from the SOPS store) — exactly one pair.
- **Security & Plugins**:
  - CORS from `KINETIX_GATEWAY_CORS_ORIGINS`, never with credentials, on every TLS route except the browser apps' `/bff/`. Empty leaves the `cors` plugin out, because Kong's plugin with no origins answers `*`.
  - Rate Limiting (`rate-limiting` plugin, 100 req/min per address and per route; Midtrans' callback 600) on every TLS route, none on the internal twins.
  - Static Health Check route and `/.well-known/security.txt` (`request-termination` plugin).
  - Admin-only routes accept only the staff network (`ip-restriction`, allowed ranges from `KINETIX_GATEWAY_STAFF_RANGES`, no default). See "Staff-only routes" below and `CLAUDE.md`.

---

## 🗺️ Route Mapping Summary

| External Path | Target Internal Microservice | Protocol | Path Rewrite |
| :--- | :--- | :--- | :--- |
| `GET /health` | Internal Static Response | HTTP | Returns `{"status":"ok"}` |
| `GET /.well-known/security.txt` | Internal Static Response | HTTP | RFC 9116, `text/plain; charset=utf-8`; `Canonical` names `KINETIX_PUBLIC_API_HOST` |
| `POST /api/v1/auth/login`, `/register`, `/refresh`, `/2fa/verify`; `POST /api/v1/couriers/register` | `kinetix-identity-service:5000` | HTTP REST (public) | none — identity serves `/api/v1/...` itself |
| `GET /.well-known/jwks.json` | `kinetix-identity-service:5000` | HTTP (public) | none |
| `/api/v1/auth/*` (the rest: `me`, `logout`, `2fa/setup\|enable\|disable/{id}`), `/api/v1/users/{id}/profile` | `kinetix-identity-service:5000` | HTTP REST (JWT) | none |
| `GET /api/v1/sellers/{id}/application`, `POST /api/v1/sellers/{id}/onboard` | `kinetix-identity-service:5000` | HTTP REST (JWT) | none |
| `GET /api/v1/sellers/applications`, `POST /api/v1/sellers/{id}/verify`, `/reject` | `kinetix-identity-service:5000` | HTTP REST (JWT, staff network only) | none |
| `GET /api/v1/couriers/applications`, `POST /api/v1/couriers/{principalId}/approve` | `kinetix-identity-service:5000` | HTTP REST (JWT, staff network only) | none |
| `/api/v1/products[/]`, `/products/create[/]`, `/products/manage/{id}[/]`, `/products/{sku}[/]`, `/api/v1/categories[/]`, `/categories/{id}[/]` | `kinetix-catalog-service:8000/api/*` | HTTP REST | `/api/v1/*` ➔ `/api/*`; a trailing slash, present or absent, reaches catalog as sent |
| `/api/v1/products/search`, `/api/v1/products/suggest` | `kinetix-search-service:8088` | HTTP REST | none — the paths are the service's own |
| `/api/v1/pricing/*` (`vouchers`, `vouchers/apply`, `vouchers/{code}`, `discounts`, `flash-sales`, `flash-sales/{product_id}`) | `kinetix-pricing-service:6000/api/v1/*` | HTTP REST | `/api/v1/pricing` ➔ `/api/v1`; creates answer 201 and need an `Idempotency-Key` |
| `/api/v1/cart/*` (incl. `POST`/`DELETE /api/v1/cart/voucher`), `/api/v1/orders/*` | `kinetix-order-service:8001` | HTTP REST | none |
| `/api/v1/reviews/*` | `kinetix-review-service:8002` | HTTP REST | none |
| `/api/v1/payment/*` | `kinetix-payment-service:8003` | HTTP REST (JWT) | none |
| `POST /api/v1/payment/gateway/midtrans/notifications` | `kinetix-payment-service:8003` | HTTP REST (public, 600/min per IP) | none — Midtrans' server-to-server callback |
| `/api/v1/warehouse/*` | `kinetix-warehouse-service:3000/api/v1/*` | HTTP REST | `/api/v1/warehouse` ➔ `/api/v1` |
| `/api/v1/matching/*` | `kinetix-matching-service:4000/api/v1/*` | HTTP REST (JWT) | `/api/v1/matching` ➔ `/api/v1` |
| `/ws/v1/matching/driver`, `/ws/v1/matching/driver/websocket` | `kinetix-matching-service:4000/driver/websocket` | WebSockets | Forwarded `Upgrade`; matching checks the access token and the courier role. The second path is the one phoenix.js dials |
| `/ws/v1/matching/merchant`, `/ws/v1/matching/merchant/websocket` | `kinetix-matching-service:4000/merchant/websocket` | WebSockets | Forwarded `Upgrade`; matching checks the access token and the seller role. The second path is the one phoenix.js dials. Also on the internal listener, for the edge. Read and write timeouts 90 s |
| `GET /api/v1/proofs/liabilities/{epoch\|latest}`, `GET /api/v1/proofs/evidence/orders/{order}`, `GET /api/v1/proofs/evidence/reviews/{review}` | `kinetix-notary-service:8010` | HTTP REST (JWT) | none — an account holder's own proofs |
| `GET`/`POST /api/v1/proofs/registrations` | `kinetix-notary-service:8010` | HTTP REST (JWT) | none — GET serves the registration template, POST registers the address an account holder will request statements from |
| `POST`/`DELETE /api/v1/notifications/devices`, `POST /api/v1/notifications/devices/verify` | `kinetix-notification-service:8004` | HTTP REST (JWT) | none — registers, verifies or forgets the caller's own handset for push; the principal is the token's `sub` |
| any path on the host `KINETIX_STORAGE_HOST` | `kinetix-object-store:9000` | HTTP (presigned) | none — `Host` preserved for the signature, 16 MB per request; rendered only when the host is set |
| `/bff/*` on the host `KINETIX_BACKOFFICE_HOST` | `kinetix-edge-service:8080` | HTTP (staff network only, no JWT, no CORS) | none — `Host` preserved; the edge's browser token handler. Read and write timeouts 90 s |
| `/bff/*` on the host `KINETIX_SELLER_HOST` | `kinetix-edge-service:8080` | HTTP and WebSockets (no JWT, no CORS) | none — `Host` preserved. Read and write timeouts 90 s: the edge holds the merchant socket with 90 s idle timeouts |
| any other path on the host `KINETIX_BACKOFFICE_HOST` | `kinetix-backoffice:8080` | HTTP (staff network only, no JWT, no CORS) | none — the backoffice's static app (`kinetix-backoffice`); no API route answers on its origin |
| any other path on the host `KINETIX_SELLER_HOST` | Internal Static Response | HTTP | `404 {"message":"Not found"}` — no API route answers on a browser app's origin |

"(JWT)" means Kong's `jwt` plugin checks the token's signature and `exp` before the request leaves the
gateway; every service still verifies the token itself. Kong reads the token from `Authorization: Bearer`
only: a token in a `?jwt=` query or in a cookie is not read, and the request gets `401
{"message":"Unauthorized"}` with `WWW-Authenticate: Bearer`, as if it carried none. The notary and notification routes accept only the
methods listed, plus `OPTIONS`: a method a route does not list gets Kong's 404 `no Route matched`, not the
service's 405. `OPTIONS` is listed because a route that refuses it answers a browser's preflight with that
404 before the `cors` plugin runs; the `jwt` plugins skip `OPTIONS` (`run_on_preflight = false`).


Search sits **under** catalog's prefix deliberately: these are product URLs, and a customer typing
into a search box should not have to know which service answers. Kong matches plain prefixes
longest-first, so `/api/v1/products/search` beats `/api/v1/products` — verified against the pinned
Kong image with both upstreams standing in for themselves, and verified in the other direction too:
with the search route removed, the same request reaches catalog, which reads it as
`products/<str:sku>/` with sku `search` and answers 404. Not an error anyone would chase — a search
box that simply finds nothing.

---

## 🔐 Staff-only routes

The paths only an admin may call are served by dedicated routes that also check the caller's address: Kong's
`ip-restriction` allows only `KINETIX_GATEWAY_STAFF_RANGES`, the staff network. Everything else about them
(upstream, path rewrite, `jwt`, CORS, rate limits) is the route they were split from.

| Paths | Service |
| :--- | :--- |
| `GET /api/v1/sellers/applications`, `POST /api/v1/sellers/{id}/verify`, `POST /api/v1/sellers/{id}/reject`, `GET /api/v1/couriers/applications`, `POST /api/v1/couriers/{principalId}/approve` | identity |
| `POST`, `PUT`, `PATCH`, `DELETE` on `/api/v1/categories` and `/api/v1/categories/{id}` (`GET` stays public) | catalog |
| `/api/v1/warehouse/bins`, `/api/v1/warehouse/stock_receipts`, `/api/v1/warehouse/stock_adjustments` | warehouse |
| `/api/v1/matching/drivers` and below, `/api/v1/matching/backoffice` and below | matching |
| `/api/v1/orders/sagas` and below, `GET /api/v1/orders/returns/needs-attention`, `POST /api/v1/orders/returns/{returnNumber}/reject`, `POST /api/v1/orders/{orderNumber}/complete` | order |
| `/bff/` and below on `KINETIX_BACKOFFICE_HOST` (the backoffice's sign-in and every call it makes) | edge |
| every other path on `KINETIX_BACKOFFICE_HOST` (the backoffice's own pages and assets) | backoffice |

From any other address they answer `403 {"message":"This route is not available from your network","request_id":"…"}`.
On identity's and matching's, a request without a valid token gets the `jwt` plugin's `401` first. Staff reach
them over WireGuard to the server's tunnel address with the public host name
(`curl --resolve <api host>:443:<tunnel address> https://<api host>/…`); `CLAUDE.md` explains why Kong then sees
the tunnel address, and what a proxy in front would change. Endpoints that a user or an admin may call are not
fenced.

---

## 🔌 Internal listener (plaintext, for the edge)

`kinetix-edge-service` calls the API at `http://kinetix-api-gateway:8000`, on the Docker network only. Every API
route above has an internal twin, `<route>-internal`, generated from the same definition: the same paths,
methods, service, path rewrite and JWT check, without the staff gate, the rate limit or CORS. A twin answers only
plaintext requests on port 8000 that name the host `kinetix-api-gateway`; a TLS request that names that host gets
`421 Misdirected Request`, and a plaintext request for anything else gets Kong's `426`. The seller's socket
(`/ws/v1/matching/merchant` and `/websocket`) has a twin too: the edge proxies the seller web's WebSocket through
it, and matching checks the token. `/health`, `security.txt`, the courier socket, storage and `/bff/` have no
twin. Upstreams see `X-Forwarded-For: <what the edge
sent>, <the edge's address>` and `X-Forwarded-Proto: https` (the browser's hop). Why, and what someone on the network could do with
it: `CLAUDE.md`, "The internal listener and the twins".

---

## 🌐 Browser Access (CORS)

When `KINETIX_GATEWAY_CORS_ORIGINS` names origins, the `cors` plugin lets a page read these response headers
besides the CORS-safelisted ones: `X-Request-Id` (the correlation id), `Allow` (on a service's 405),
`Idempotent-Replayed` (pricing's replay of an earlier create), `Location` (on a 201) and `Retry-After` (on a
503 from a service, and on Kong's own 429). A page may send `Accept`, `Authorization`, `Content-Type`,
`Idempotency-Key`, `X-Request-Id`, `X-Requested-With`, `X-Kinetix-Client` (the client's name) and
`X-Firebase-AppCheck` (its App Check proof).

---

## 📜 Access Log

Kong's proxy access log uses the `kinetix` format from `config/access_log.conf`, included into nginx's `http`
block through `KONG_NGINX_HTTP_INCLUDE` and selected by `KONG_PROXY_ACCESS_LOG` (both set in the Dockerfile):

```
172.21.0.1 [21/Oct/2026:07:28:27 +0000] "GET /api/v1/products/SKU-1 HTTP/1.1" 200 282 "curl/8.7.1" request_id: "7527339d-6441-4f40-a97a-3eb00ac0001a" kong_request_id: "c2fce27814b1560db93aa45d6bf25548"
```

- The path is logged **without its query string**. The courier and merchant sockets still carry the access
  token as `?token=`, and Kong's default format (`$request`) wrote it to stdout, journald and Loki. The path
  comes from `$request_uri` through a `map`, not from `$uri`: on any answer nginx produces through
  `error_page` (a 502 when an upstream refuses the connection, for example) `$uri` is `/kong_error_handler`.
- `request_id` is the `X-Request-Id` the `correlation-id` plugin sets or keeps, the id each service logs and
  the client sees. `kong_request_id` is Kong's own, the `request_id` on Kong's error-log lines and the
  `X-Kong-Request-Id` header. nginx's `$request_id` is a third id that nothing else carries, so it is not logged.
- Nothing downstream parses these lines: Promtail ships them unparsed and Grafana parses at query time.
- Kong's **error log** still carries the full request line and the upstream URL, query string included,
  whenever nginx logs an error for a request (an upstream that refuses, times out or resets): six lines per
  failed socket attempt, from the initial try and five retries. No nginx setting changes that format. It
  ends when the apps send the token in `Sec-WebSocket-Protocol` and matching stops accepting `?token=`.

---

## ⚡ Local Build & Execution Guide

```bash
# 1. Build the image. It carries no key, issuer, origin or certificate.
docker build -t kinetix-api-gateway .

# 2. Run it. Kong's config and TLS material are produced from the environment at start.
docker run -p 8443:8443 \
  -e KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64="$(base64 < identity-public.pem)" \
  -e KINETIX_JWT_ISSUER=https://identity.kinetix.local \
  -e KINETIX_GATEWAY_CORS_ORIGINS='*' \
  -e KINETIX_GATEWAY_STAFF_RANGES=172.17.0.1/32 \
  -e KINETIX_PUBLIC_API_HOST=localhost:8443 \
  -e KINETIX_BACKOFFICE_HOST=backoffice.localhost:8443 \
  -e KINETIX_SELLER_HOST=seller.localhost:8443 \
  -e KINETIX_GATEWAY_TLS_CERT_B64="$(base64 < server.pem)" \
  -e KINETIX_GATEWAY_TLS_KEY_B64="$(base64 < server.key)" \
  kinetix-api-gateway

# 3. Verify the health route
curl -k https://localhost:8443/health
```
