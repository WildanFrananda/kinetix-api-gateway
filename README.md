# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

The **Kinetix API Gateway** is the single entry point for all external client REST and WebSocket traffic into the **Kinetix Real-Time E-Commerce & Fulfillment Ecosystem**. Built on **Kong Gateway DB-less Mode** (`kong:3.9`, pinned by digest) with a declarative configuration rendered from **Apple Pkl** (`config/gateway.pkl`).

---

## 🏛️ Stack & Architecture

- **Gateway Engine**: **Kong Gateway (DB-less Mode)** listening on port `:8443`, TLS only.
- **Configuration Engine**: **Apple Pkl (`config/gateway.pkl`)** rendered to `/usr/local/kong/declarative/kong.yml` by `bin/entrypoint.sh` **when the container starts**, from `KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64`, `KINETIX_JWT_ISSUER` and `KINETIX_GATEWAY_CORS_ORIGINS`. The image carries no key, issuer, origin or certificate, so one digest runs in every environment.
- **TLS**: `KINETIX_GATEWAY_TLS_CERT_FILE` + `_KEY_FILE` (production, Let's Encrypt on disk) or `KINETIX_GATEWAY_TLS_CERT_B64` + `_KEY_B64` (the lab, from the SOPS store) — exactly one pair.
- **Security & Plugins**:
  - CORS from `KINETIX_GATEWAY_CORS_ORIGINS`, never with credentials. Empty leaves the `cors` plugin out, because Kong's plugin with no origins answers `*`.
  - Global Rate Limiting (`rate-limiting` plugin, 100 req/min).
  - Static Health Check route (`request-termination` plugin).

---

## 🗺️ Route Mapping Summary

| External Path | Target Internal Microservice | Protocol | Path Rewrite |
| :--- | :--- | :--- | :--- |
| `GET /health` | Internal Static Response | HTTP | Returns JSON 200 OK |
| `POST /api/v1/auth/login`, `/register`, `/refresh`, `/2fa/verify`; `POST /api/v1/couriers/register` | `kinetix-identity-service:5000` | HTTP REST (public) | none — identity serves `/api/v1/...` itself |
| `GET /.well-known/jwks.json` | `kinetix-identity-service:5000` | HTTP (public) | none |
| `/api/v1/auth/*` (the rest: `me`, `logout`, `2fa/setup\|enable\|disable/{id}`), `/api/v1/users/{id}/profile` | `kinetix-identity-service:5000` | HTTP REST (JWT) | none |
| `GET /api/v1/sellers/applications`, `GET /api/v1/sellers/{id}/application`, `POST /api/v1/sellers/{id}/onboard`, `/verify`, `/reject` | `kinetix-identity-service:5000` | HTTP REST (JWT) | none |
| `GET /api/v1/couriers/applications`, `POST /api/v1/couriers/{principalId}/approve` | `kinetix-identity-service:5000` | HTTP REST (JWT) | none |
| `/api/v1/products[/]`, `/products/create[/]`, `/products/manage/{id}[/]`, `/products/{sku}[/]`, `/api/v1/categories[/]`, `/categories/{id}[/]` | `kinetix-catalog-service:8000/api/*` | HTTP REST | `/api/v1/*` ➔ `/api/*`; a trailing slash, present or absent, reaches catalog as sent |
| `/api/v1/products/search`, `/api/v1/products/suggest` | `kinetix-search-service:8088` | HTTP REST | none — the paths are the service's own |
| `/api/v1/pricing/*` (`vouchers`, `vouchers/apply`, `vouchers/{code}`, `discounts`, `flash-sales`, `flash-sales/{product_id}`) | `kinetix-pricing-service:6000/api/v1/*` | HTTP REST | `/api/v1/pricing` ➔ `/api/v1`; creates answer 201 and need an `Idempotency-Key` |
| `/api/v1/cart/*` (incl. `POST`/`DELETE /api/v1/cart/voucher`), `/api/v1/orders/*` | `kinetix-order-service:8001` | HTTP REST | none |
| `/api/v1/reviews/*` | `kinetix-review-service:8002` | HTTP REST | none |
| `/api/v1/payment/*` | `kinetix-payment-service:8003` | HTTP REST (JWT) | none |
| `POST /api/v1/payment/gateway/midtrans/notifications` | `kinetix-payment-service:8003` | HTTP REST (public, 600/min per IP) | none — Midtrans' server-to-server callback |
| `/api/v1/warehouse/*` | `kinetix-warehouse-service:3000/api/v1/*` | HTTP REST | `/api/v1/warehouse` ➔ `/api/v1` |
| `/api/v1/matching/*` | `kinetix-matching-service:4000/api/v1/*` | HTTP REST (JWT) | `/api/v1/matching` ➔ `/api/v1` |
| `/ws/v1/matching/driver` | `kinetix-matching-service:4000/driver/websocket` | WebSockets | Forwarded `Upgrade`; matching checks the access token and the courier role |
| `/ws/v1/matching/merchant` | `kinetix-matching-service:4000/merchant/websocket` | WebSockets | Forwarded `Upgrade`; matching checks the access token and the seller role |
| `GET /api/v1/proofs/liabilities/{epoch\|latest}`, `GET /api/v1/proofs/evidence/orders/{order}`, `GET /api/v1/proofs/evidence/reviews/{review}` | `kinetix-notary-service:8010` | HTTP REST (JWT) | none — an account holder's own proofs |
| `GET`/`POST /api/v1/proofs/registrations` | `kinetix-notary-service:8010` | HTTP REST (JWT) | none — GET serves the registration template, POST registers the address an account holder will request statements from |
| `POST`/`DELETE /api/v1/notifications/devices`, `POST /api/v1/notifications/devices/verify` | `kinetix-notification-service:8004` | HTTP REST (JWT) | none — registers, verifies or forgets the caller's own handset for push; the principal is the token's `sub` |
| any path on the host `KINETIX_STORAGE_HOST` | `kinetix-object-store:9000` | HTTP (presigned) | none — `Host` preserved for the signature, 16 MB per request; rendered only when the host is set |

"(JWT)" means Kong's `jwt` plugin checks the token's signature and `exp` before the request leaves the
gateway; every service still verifies the token itself. The notary and notification routes accept only the
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

## 🌐 Browser Access (CORS)

When `KINETIX_GATEWAY_CORS_ORIGINS` names origins, the `cors` plugin lets a page read these response headers
besides the CORS-safelisted ones: `X-Request-Id` (the correlation id), `Allow` (on a service's 405),
`Idempotent-Replayed` (pricing's replay of an earlier create), `Location` (on a 201) and `Retry-After` (on a
503 from a service, and on Kong's own 429). A page may send `Accept`, `Authorization`, `Content-Type`,
`Idempotency-Key`, `X-Request-Id` and `X-Requested-With`.

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
  -e KINETIX_GATEWAY_TLS_CERT_B64="$(base64 < server.pem)" \
  -e KINETIX_GATEWAY_TLS_KEY_B64="$(base64 < server.key)" \
  kinetix-api-gateway

# 3. Verify the health route
curl -k https://localhost:8443/health
```
