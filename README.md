# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

The **Kinetix API Gateway** is the single entry point for all external client REST and WebSocket traffic into the **Kinetix Real-Time E-Commerce & Fulfillment Ecosystem**. Built on **Kong Gateway DB-less Mode** (`kong:latest`) with declarative configurations compiled from **Apple Pkl** (`config/gateway.pkl`).

---

## 🏛️ Stack & Architecture

- **Gateway Engine**: **Kong Gateway (DB-less Mode)** listening on port `:8080`.
- **Configuration Engine**: **Apple Pkl (`config/gateway.pkl`)** compiled to `/usr/local/kong/declarative/kong.yml` via Docker Multi-Stage build.
- **Security & Plugins**:
  - Global CORS policy (`cors` plugin).
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
# 1. Build Docker Image (Pkl Multi-Stage Build)
docker build -t kinetix-api-gateway .

# 2. Run Container on Port 8080
docker run -p 8080:8080 kinetix-api-gateway

# 3. Verify Health Check Endpoint
curl -i http://localhost:8080/health
```
