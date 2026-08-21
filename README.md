# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

High-performance public API Gateway built on **Luau** (Fast typed Lua scripting engine) and **Lute Runtime** inside Docker. Supports REST APIs, Authentication, WebSockets (Phoenix Channels), and Server-Sent Events (SSE).

---

## 🏛️ Architecture & Protocol Routing Matrix

Acts as the single public entrypoint for all web & mobile clients, reverse-proxying HTTP REST requests, WebSockets, and Server-Sent Events (SSE) streaming:

### 1. Gateway Health Check
- `GET /health` ➔ Gateway status check (`200 OK`).

### 2. Authentication & Session Routes
- `POST /api/v1/auth/login` ➔ User & Courier login authentication.
- `POST /api/v1/auth/register` ➔ New user & courier registration.

### 3. Catalog Service Routes (`kinetix-catalog-service` Port `:8000`)
- `GET /api/v1/products/` ➔ Proxy to Catalog listing & search (`/api/products/`).
- `GET /api/v1/products/{sku}/` ➔ Proxy to Catalog product detail & bin stock (`/api/products/{sku}/`).
- `POST /api/v1/cart/reserve/` ➔ Proxy to Cart inventory stock reservation (`/api/cart/reserve/`).
- `POST /api/v1/checkout/` ➔ Proxy to Order checkout & gRPC OMS dispatch (`/api/orders/checkout/`).

### 4. Warehouse Service Routes (`kinetix-warehouse-service` Port `:3000`)
- `GET /api/v1/warehouse/orders/` ➔ Proxy to Warehouse order fulfillment status.
- `GET /api/v1/warehouse/inventory/` ➔ Proxy to Warehouse bin physical inventory.
- `POST /api/v1/warehouse/returns/` ➔ Proxy to Customer return processing.

### 5. Matching Service Routes (`kinetix-matching-service` Port `:4000`)
- `GET /api/v1/matching/couriers/` ➔ Proxy to Active courier fleet query.
- `GET /api/v1/matching/dispatches/` ➔ Proxy to Delivery dispatch status & ETAs.
- `GET /api/v1/matching/telemetry/stream` ➔ **SSE (Server-Sent Events)** real-time GPS coordinate stream.
- `WS /ws/v1/matching/socket` ➔ **WebSocket Connection Upgrade (`101 Switching Protocols`)** for Phoenix Channels bidirectional courier location streaming.

---

## 📦 Package Management

Luau package management is configured using **Pesde** (`pesde.toml`) and **Wally** (`wally.toml`):

- **Pesde**: Modern Luau package manager manifest (`pesde.toml`).
- **Wally**: Community Luau package registry manifest (`wally.toml`).

---

## ⚡ Local Setup with Docker (Step-by-Step)

```bash
# 1. Navigate to Gateway directory
cd kinetix-api-gateway

# 2. Build & Run Docker Container
docker-compose up --build -d

# 3. Test Health Check Endpoint
curl http://localhost:8080/health
```
