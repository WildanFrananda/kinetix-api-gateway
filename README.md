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
| `/api/v1/auth/*` | `kinetix-identity-service:5000/api/auth/*` | HTTP REST | `/api/v1/auth` ➔ `/api/auth` |
| `/api/v1/products` etc. | `kinetix-catalog-service:8000/api/*` | HTTP REST | `/api/v1/*` ➔ `/api/*` |
| `/api/v1/warehouse/*` | `kinetix-warehouse-service:3000/api/v1/*` | HTTP REST | `/api/v1/warehouse` ➔ `/api/v1` |
| `/api/v1/matching/*` | `kinetix-matching-service:4000/api/v1/*` | HTTP REST | `/api/v1/matching` ➔ `/api/v1` |
| `/ws/v1/matching/socket` | `kinetix-matching-service:4000/socket/websocket` | WebSockets | Forwarded `Upgrade` connection |
| `/api/v1/matching/telemetry/stream` | `kinetix-matching-service:4000/api/v1/telemetry/stream` | SSE Stream | Non-buffered EventStream |

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
