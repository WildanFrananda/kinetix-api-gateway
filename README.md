# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

High-performance enterprise API Gateway, central JWT authentication guard, C-level rate limiter, and modular reverse proxy built with **OpenResty (NGINX + LuaJIT)**.

---

## 🏛️ Architecture Overview

- **C-Level Network I/O**: High-concurrency reverse proxying for REST APIs, WebSockets (Phoenix Channels), and Server-Sent Events (SSE) telemetry streaming.
- **Lua Business Logic**:
  - `lua/auth_guard.lua`: Centralized JWT authentication subrequest guard (`/_validate_jwt`) querying `kinetix-identity-service`.
  - `lua/cors.lua`: Standardized cross-origin resource sharing headers.
- **Memory-Leak Free Rate Limiting**: NGINX C-level `limit_req_zone` (100 req/min per IP with burst configuration).

---

## 📂 Repository File Structure

```
kinetix-api-gateway/
├── Dockerfile                  # Official openresty/openresty:alpine image
├── docker-compose.yml          # Container compose deployment
├── README.md                   # Technical documentation
├── conf/
│   └── nginx.conf              # Declarative NGINX reverse-proxy configuration
└── lua/
    ├── auth_guard.lua          # Lua JWT subrequest validation guard
    └── cors.lua                # Lua CORS header filter
```

---

## ⚡ Build & Verification Execution Guide

```bash
# 1. Build Production Docker Image
docker build -t kinetix-api-gateway .

# 2. Run Container Smoke Test
docker run --rm -d -p 8080:8080 --name test_openresty kinetix-api-gateway

# 3. Health Check Verification (Returns 200 OK)
curl -i http://localhost:8080/health

# 4. WebSocket Handshake Verification
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://localhost:8080/ws/v1/matching/socket

# 5. SSE Telemetry Stream Verification
curl -i -N http://localhost:8080/api/v1/matching/telemetry/stream
```
