# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

High-performance public API Gateway built on **Luau** (Fast typed Lua scripting engine in `--!strict` static mode) and **Lute Runtime** inside Docker. Serves as the single public entrypoint for REST APIs, WebSockets (Phoenix Channels), Server-Sent Events (SSE), **Memory-Leak-Free Rate Limiting Guard**, **Real HTTP Reverse-Proxy Forwarding**, and **Centralized JWT Authentication Verification**.

---

## 🏛️ Architecture & Resolved Audit Fixes

1. **Real HTTP Reverse Proxy Forwarding**:
   - `auth_router.luau`, `catalog_router.luau`, `warehouse_router.luau`, and `matching_router.luau` perform **real HTTP request proxying** via `@lute/net` to downstream microservices (`:5000`, `:8000`, `:3000`, `:4000`).
2. **Real JWT Token Signature Validation (`auth_middleware.luau`)**:
   - Dynamically validates `Authorization: Bearer <token>` against **`kinetix-identity-service`** (`/api/auth/validate`) and injects authenticated user headers (`X-User-Id`, `X-User-Role`) to downstream services.
3. **Real SSE & WebSocket Connection Upgrades**:
   - `sse_router.luau` forwards real HTTP Event-Stream connections.
   - `websocket_router.luau` performs standard HTTP `101 Switching Protocols` connection upgrade handshake (`WS /ws/v1/matching/socket`) to `kinetix-matching-service`.
4. **Memory-Leak-Free Rate Limiter (`rate_limit_middleware.luau`)**:
   - Implements sliding window rate limiting with **automatic TTL garbage collection routine** to evict stale IP buckets every 5 minutes.
5. **Strict Static Type Safety**: 100% `--!strict` static type annotations in Luau.

---

## 📡 Protocol Routing & Security Matrix

### 1. Gateway Health Check & Auth Routes (Public)

| Method | Public Gateway Path | Downstream Target Service | Auth Required | Rate Limit Window | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `GET` | `/health` | Gateway Engine | No | Bypass | Gateway status check (`200 OK`) |
| `POST` | `/api/v1/auth/login` | `kinetix-identity-service` (`:5000`) | No | 10 req / 60s | Authenticate user & issue signed JWT |
| `POST` | `/api/v1/auth/register` | `kinetix-identity-service` (`:5000`) | No | 10 req / 60s | Register new user or courier |

### 2. User & Merchant Profile Routes (Protected)

| Method | Public Gateway Path | Downstream Target Service | Auth Required | Rate Limit Window | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `GET` | `/api/v1/users/{id}/profile` | `kinetix-identity-service` (`:5000`) | **Yes (JWT)** | 100 req / 60s | Fetch user profile and address |
| `PUT` | `/api/v1/users/{id}/profile` | `kinetix-identity-service` (`:5000`) | **Yes (JWT)** | 100 req / 60s | Update user profile and address |
| `POST` | `/api/v1/sellers/{id}/onboard` | `kinetix-identity-service` (`:5000`) | **Yes (JWT)** | 100 req / 60s | Onboard new merchant store |

### 3. Product Catalog Routes (`kinetix-catalog-service` :8000)

| Method | Public Gateway Path | Downstream Target Service | Auth Required | Rate Limit Window | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `GET` | `/api/v1/products/` | `kinetix-catalog-service` (`:8000`) | No | 100 req / 60s | Browse product catalog & search |
| `GET` | `/api/v1/products/{sku}/` | `kinetix-catalog-service` (`:8000`) | No | 100 req / 60s | Product detail & bin stock check |
| `POST` | `/api/v1/cart/reserve/` | `kinetix-catalog-service` (`:8000`) | **Yes (JWT)** | 100 req / 60s | Reserve inventory stock for cart |
| `POST` | `/api/v1/checkout/` | `kinetix-catalog-service` (`:8000`) | **Yes (JWT)** | 100 req / 60s | Process order checkout |

---

## 📂 Modular File Directory Structure (Luau `--!strict`)

```
kinetix-api-gateway/
├── src/
│   ├── main.luau                       # Main Gateway Reverse-Proxy Dispatcher
│   ├── types.luau                      # Strict Luau Type Declarations
│   ├── config.luau                     # Dynamic Environment Configuration
│   ├── response_builder.luau           # HTTP JSON & Status Response Builder
│   ├── middleware/
│   │   ├── rate_limit_middleware.luau  # TTL Memory-Leak Free Rate Limiter
│   │   └── auth_middleware.luau        # Centralized JWT Validation Guard
│   └── routes/                         # Isolated Reverse-Proxy Route Modules
│       ├── health_router.luau
│       ├── auth_router.luau
│       ├── catalog_router.luau
│       ├── warehouse_router.luau
│       ├── matching_router.luau
│       ├── websocket_router.luau
│       └── sse_router.luau
├── pesde.toml                          # Pesde Package Manifest
├── wally.toml                          # Wally Package Manifest
├── Dockerfile                          # Luau / Lute Docker Multi-Stage Build
└── docker-compose.yml                  # Gateway Service Manifest (Port 8080)
```

---

## ⚡ Local Setup & Docker Execution

```bash
# 1. Navigate to Gateway directory
cd kinetix-api-gateway

# 2. Build & Run Docker Container
docker-compose up --build -d

# 3. Test Gateway Health Check Endpoint
curl http://localhost:8080/health
```
