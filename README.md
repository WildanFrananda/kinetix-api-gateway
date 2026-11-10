# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

The **Kinetix API Gateway** is the single entry point for all external client REST and WebSocket traffic into the **Kinetix Real-Time E-Commerce & Fulfillment Ecosystem**. Built on **Kong Gateway DB-less Mode** (`kong:3.9`, pinned by digest) with a declarative configuration rendered from **Apple Pkl** (`config/gateway.pkl`).

---

## 🏛️ Stack & Architecture

- **Gateway Engine**: **Kong Gateway (DB-less Mode)**. The public listener is `:8443`, TLS only. A plaintext listener on `:8000` serves only the edge's calls on the Docker network; a TLS listener on `:8444` serves the backoffice's onion address for the `tor` container, and a plaintext listener on `:8081` only redirects that address to HTTPS. None of the three is ever published (see "Internal listener" and "Onion listeners" below). `KONG_PROXY_LISTEN` is `0.0.0.0:8443 ssl, 0.0.0.0:8000, 0.0.0.0:8081, 0.0.0.0:8444 ssl`, and Kong's admin API is off (`KONG_ADMIN_LISTEN=off`): its default listener holds `127.0.0.1:8444`.
- **Configuration Engine**: **Apple Pkl (`config/gateway.pkl`)** rendered to `/usr/local/kong/declarative/kong.yml` by `bin/entrypoint.sh` **when the container starts**, from `KINETIX_IDENTITY_JWT_PUBLIC_KEY_B64`, `KINETIX_JWT_ISSUER`, `KINETIX_GATEWAY_CORS_ORIGINS`, `KINETIX_GATEWAY_STAFF_RANGES`, `KINETIX_PUBLIC_API_HOST`, `KINETIX_BACKOFFICE_HOST`, `KINETIX_BACKOFFICE_TLS_CERT_B64`, `KINETIX_BACKOFFICE_TLS_KEY_B64`, `KINETIX_BACKOFFICE_ONION_HOST`, `KINETIX_BACKOFFICE_ONION_TLS_CERT_B64`, `KINETIX_BACKOFFICE_ONION_TLS_KEY_B64` and `KINETIX_SELLER_HOST` (and the optional `KINETIX_STORAGE_HOST`). The image carries no key, issuer, origin, address range, host or certificate, so one digest runs in every environment.
- **TLS**: `KINETIX_GATEWAY_TLS_CERT_FILE` + `_KEY_FILE` (production, Let's Encrypt on disk) or `KINETIX_GATEWAY_TLS_CERT_B64` + `_KEY_B64` (the lab, from the SOPS store) — exactly one pair. The onion address has its own certificate, `KINETIX_BACKOFFICE_ONION_TLS_CERT_B64` + `_KEY_B64` (base64 PEM, issued by our own CA, from the store), required, served to the onion address's SNI only; the entrypoint refuses to start when it is missing, is not a PEM certificate and private key, or does not name `KINETIX_BACKOFFICE_ONION_HOST`, and Kong refuses a key that is not the certificate's. The backoffice host has its own certificate the same way, `KINETIX_BACKOFFICE_TLS_CERT_B64` + `_KEY_B64` (base64 PEM, from a second CA of our own, name-constrained to that host), required, served to the backoffice host's SNI only (its name without the port); the entrypoint refuses to start when it is missing, is not a PEM certificate and private key, or does not name `KINETIX_BACKOFFICE_HOST`. See "Backoffice over WireGuard, by name" below.
- **Security & Plugins**:
  - CORS from `KINETIX_GATEWAY_CORS_ORIGINS`, never with credentials, on every TLS route except the browser apps' `/bff/`. Empty leaves the `cors` plugin out, because Kong's plugin with no origins answers `*`.
  - Rate Limiting (`rate-limiting` plugin, 100 req/min per address and per route; Midtrans' callback 600; the backoffice's map tiles, `/tiles/`, 1200) on every TLS route and the onion routes, none on the internal twins.
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
| `GET /api/v1/couriers/applications`, `POST /api/v1/couriers/{principalId}/approve`, `POST /api/v1/couriers/{principalId}/reject` | `kinetix-identity-service:5000` | HTTP REST (JWT, staff network only) | none |
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
| `POST /api/v1/seal/courier-credentials`, `GET /api/v1/seal/courier-credentials/{id}` | `kinetix-seal-service:8012` | HTTP REST (JWT) | none — a courier asks for a credential of their own facts and follows its issuance; seal checks the token's use and role |
| `GET /api/v1/seal/holder`, `GET /api/v1/seal/holder/{digest}/{file}` | `kinetix-seal-service:8012` | HTTP (public) | none — the holder runtime the courier app's hidden WebView loads: page, script, WASM and the `present` key material, immutable per build |
| `GET /api/v1/seal/verify`, `GET /api/v1/seal/verify/assets/{digest}/{file}` | `kinetix-seal-service:8012` | HTTP (public) | none — the public page where anyone checks a courier's credential (S1g), and its immutable script and style |
| `GET /api/v1/seal/presentations/{challenge}` | `kinetix-seal-service:8012` | HTTP REST (public) | none — whether the registry has recorded the answer to a verifier's challenge |
| `POST /api/v1/seal/presentations` | `kinetix-seal-service:8012` | HTTP REST (public, 20 a minute per address) | none — a verifier relays a holder's proven presentation for the sponsor to pay (SEAL-D18); no token, and seal logs no address |
| `GET /api/v1/seal/registry/snapshot` | `kinetix-seal-service:8012` | HTTP REST (public) | none — the active registry's state, which a holder proves against; the app fetches it on its own schedule |
| `GET /api/v1/seal/predicates`, `GET /api/v1/seal/predicates/{id}` | `kinetix-seal-service:8012` | HTTP REST (public) | none — the approved predicates and their registry rows, for holders and verifiers; no token |
| `POST /api/v1/seal/predicates`, `DELETE /api/v1/seal/predicates/{id}` | `kinetix-seal-service:8012` | HTTP REST (JWT, staff network only) | none — an admin approves or withdraws a predicate; seal checks the admin role |
| `POST`/`DELETE /api/v1/notifications/devices`, `POST /api/v1/notifications/devices/verify` | `kinetix-notification-service:8004` | HTTP REST (JWT) | none — registers, verifies or forgets the caller's own handset for push; the principal is the token's `sub` |
| any path on the host `KINETIX_STORAGE_HOST` | `kinetix-object-store:9000` | HTTP (presigned) | none — `Host` preserved for the signature, 16 MB per request; rendered only when the host is set |
| `/bff/*` on the host `KINETIX_BACKOFFICE_HOST` | `kinetix-edge-service:8080` | HTTPS (the backoffice host's own certificate, staff network only, no JWT, no CORS) | none — `Host` preserved; the edge's browser token handler. Read and write timeouts 90 s |
| `/bff/*` on the host `KINETIX_SELLER_HOST` | `kinetix-edge-service:8080` | HTTP and WebSockets (no JWT, no CORS) | none — `Host` preserved. Read and write timeouts 90 s: the edge holds the merchant socket with 90 s idle timeouts |
| `/tiles/*` on the host `KINETIX_BACKOFFICE_HOST` | `kinetix-backoffice:8080` | HTTPS (the backoffice host's own certificate, staff network only, no JWT, no CORS), 1200 a minute per address | none — the street map's PMTiles archive and its manifest; `Range`, `If-Range`, `If-None-Match` and the app's `206`, `304` and `ETag` pass through as sent |
| any other path on the host `KINETIX_BACKOFFICE_HOST` | `kinetix-backoffice:8080` | HTTPS (the backoffice host's own certificate, staff network only, no JWT, no CORS) | none — the backoffice's static app (`kinetix-backoffice`); no API route answers on its origin |
| any other path on the host `KINETIX_SELLER_HOST` | Internal Static Response | HTTP | `404 {"message":"Not found"}` — no API route answers on a browser app's origin |
| `/bff/*` on the host `KINETIX_BACKOFFICE_ONION_HOST`, onion TLS listener `:8444` only | `kinetix-edge-service:8080` | HTTPS (from `tor`, the onion's own certificate, no staff gate, no JWT, no CORS) | none — `Host` preserved; the same edge as the backoffice host. Read and write timeouts 90 s |
| `/tiles/*` on the host `KINETIX_BACKOFFICE_ONION_HOST`, onion TLS listener `:8444` only | `kinetix-backoffice:8080` | HTTPS (from `tor`, the onion's own certificate, no staff gate, no JWT, no CORS), 1200 a minute, one budget for every onion visitor | none — the same map archive and manifest, ranges and conditionals as sent |
| any other path on the host `KINETIX_BACKOFFICE_ONION_HOST`, onion TLS listener `:8444` only | `kinetix-backoffice:8080` | HTTPS (from `tor`, the onion's own certificate, no staff gate, no JWT, no CORS) | none — the backoffice's static app |
| any path on the host `KINETIX_BACKOFFICE_ONION_HOST`, plaintext `:8081` | Internal Static Response | HTTP (from `tor`) | `308` to `https://<onion address><path and query>`, no port; nothing is forwarded |

"(JWT)" means Kong's `jwt` plugin checks the token's signature and `exp` before the request leaves the
gateway; every service still verifies the token itself. Kong reads the token from `Authorization: Bearer`
only: a token in a `?jwt=` query or in a cookie is not read, and the request gets `401
{"message":"Unauthorized"}` with `WWW-Authenticate: Bearer`, as if it carried none. The notary, seal and notification routes accept only the
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
| `GET /api/v1/sellers/applications`, `POST /api/v1/sellers/{id}/verify`, `POST /api/v1/sellers/{id}/reject`, `GET /api/v1/couriers/applications`, `POST /api/v1/couriers/{principalId}/approve`, `POST /api/v1/couriers/{principalId}/reject` | identity |
| `POST`, `PUT`, `PATCH`, `DELETE` on `/api/v1/categories` and `/api/v1/categories/{id}` (`GET` stays public) | catalog |
| `/api/v1/warehouse/bins`, `/api/v1/warehouse/stock_receipts`, `/api/v1/warehouse/stock_adjustments` | warehouse |
| `/api/v1/matching/drivers` and below, `/api/v1/matching/backoffice` and below | matching |
| `/api/v1/orders/sagas` and below, `GET /api/v1/orders/returns/needs-attention`, `POST /api/v1/orders/returns/{returnNumber}/reject`, `POST /api/v1/orders/{orderNumber}/complete` | order |
| `POST /api/v1/seal/predicates`, `DELETE /api/v1/seal/predicates/{id}` (`GET` stays public) | seal |
| `/bff/` and below on `KINETIX_BACKOFFICE_HOST` (the backoffice's sign-in and every call it makes) | edge |
| `/tiles/` and below on `KINETIX_BACKOFFICE_HOST` (the street map's archive) | backoffice |
| every other path on `KINETIX_BACKOFFICE_HOST` (the backoffice's own pages and assets) | backoffice |

From any other address they answer `403 {"message":"This route is not available from your network","request_id":"…"}`.
On identity's, matching's and seal's, a request without a valid token gets the `jwt` plugin's `401` first. Staff reach
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

## 🧅 Onion listeners (HTTPS on 8444, a redirect on 8081, for `tor`)

The backoffice is reached over Tor (infra `docs/BACKOFFICE.md` §10, and `docs/BACKOFFICE-ONION-TLS.md` for HTTPS): a
`tor` container runs the onion service with client authorization and forwards its port 443 to
`kinetix-api-gateway:8444` and its port 80 to `kinetix-api-gateway:8081`. Three routes answer on the host
`KINETIX_BACKOFFICE_ONION_HOST`: `edge-backoffice-onion-route` (`/bff/` to the edge, `Host` kept),
`backoffice-tiles-onion-route` (`/tiles/`, the map's archive, to the app) and `backoffice-app-onion-route`
(everything else to the app). Each starts with a guard: HTTPS that arrived on 8444 is
served, with the onion's own certificate (a Kong `certificates` entity whose `snis` is the onion address, issued by
our own CA, so the public listener's certificate is untouched); plaintext that arrived on 8081 gets
`308 Location: https://<onion address><path and query>` and is not forwarded; anything else gets
`421 Misdirected Request`. Each carries a per-address limit, 100 a minute on `/bff/` and the app and 1200 on
`/tiles/`, and every onion visitor shares it; there is no staff gate, because Kong only ever sees the `tor`
container's address. On 8081 every other host gets Kong's `426` or a twin's `421`; on 8444 another host is
served exactly as on 8443. HTTPS adds no secrecy to Tor; it makes the onion a secure origin, so passkeys and the
`Secure` session cookie work in Chrome and KeePassXC. Why, and what each listener exposes: `CLAUDE.md`, "The onion
listeners".

---

## 🔑 Backoffice over WireGuard, by name

The backoffice's other face is `KINETIX_BACKOFFICE_HOST`, reached over the WireGuard tunnel when Tor is down (infra
`docs/BACKOFFICE-TUNNEL-NAME.md`). It used to be the server's tunnel address, and WebAuthn refuses an IP address as a
relying party, so passkeys never worked there. It is now a name: `backoffice.kinetix.internal` in production (`.internal`
is reserved for private use; no public DNS record, each staff device maps it to the tunnel address in `/etc/hosts`) and
`backoffice.localhost:8443` in the lab. The gateway refuses an address as the backoffice host.

Its certificate is a second Kong `certificates` entity, `snis` = the backoffice host without its port, issued by a CA of
our own name-constrained to that host (no public CA issues for `.internal`, and a public certificate would publish the
name in Certificate Transparency logs). The public listener's default certificate and the onion's are untouched. The
backoffice host's routes are unchanged: `/bff/` to the edge with `Host` kept, everything else to the app, both behind the
staff gate (and `/tiles/`, below, behind the same gate). Staff import that CA's certificate in the browser they use over
WireGuard. Why, and how it is tested: `CLAUDE.md`, "The backoffice host's own certificate".

---

## 🗺️ The backoffice's map tiles (`/tiles/`)

The fleet and dispatch screens draw a street map from one PMTiles archive that the backoffice serves itself, from a
read-only volume (infra `docs/BACKOFFICE-F5.md`): `/tiles/basemap.pmtiles` by range requests and `/tiles/basemap.json`,
its manifest. On each backoffice face `/tiles/` has a route of its own to the same `kinetix-backoffice:8080`, path
unchanged: `backoffice-tiles-route` on `KINETIX_BACKOFFICE_HOST`, behind the staff gate, and
`backoffice-tiles-onion-route` on the onion address, behind the onion guard. Both carry 1200 requests a minute per
address instead of the app route's 100: map panning comes in bursts of range requests (a zoom from the whole of
Indonesia to a street is 100 to 250 of them), and on the onion every visitor shares tor's address. `/tiles` without its
slash, other spellings and the rest of each face stay the app route's, at 100. Kong passes `Range`, `If-Range` and
`If-None-Match` through and returns the app's `206`, `304` and `ETag` as sent. Why 1200, and how it is tested:
`CLAUDE.md`, "The backoffice's map tiles".

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
  -e KINETIX_BACKOFFICE_TLS_CERT_B64="$(base64 < backoffice.crt)" \
  -e KINETIX_BACKOFFICE_TLS_KEY_B64="$(base64 < backoffice.key)" \
  -e KINETIX_SELLER_HOST=seller.localhost:8443 \
  -e KINETIX_BACKOFFICE_ONION_HOST="$(cat onion-hostname)" \
  -e KINETIX_BACKOFFICE_ONION_TLS_CERT_B64="$(base64 < onion.crt)" \
  -e KINETIX_BACKOFFICE_ONION_TLS_KEY_B64="$(base64 < onion.key)" \
  -e KINETIX_GATEWAY_TLS_CERT_B64="$(base64 < server.pem)" \
  -e KINETIX_GATEWAY_TLS_KEY_B64="$(base64 < server.key)" \
  kinetix-api-gateway

# 3. Verify the health route
curl -k https://localhost:8443/health
```
