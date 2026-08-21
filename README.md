# 🛡️ Kinetix API Gateway (`kinetix-api-gateway`)

High-performance public API Gateway built on **Luau** (Fast typed Lua scripting engine) and **Lute Runtime** inside Docker.

---

## 🏛️ Architecture & Routing

Acts as the single public entrypoint for all web & mobile clients, reverse-proxying requests to internal downstream microservices:

- `GET /health` ➔ Gateway status check (`200 OK`).
- `/api/v1/products/...` ➔ Proxy to `kinetix-catalog-service` (`:8000`).
- `/api/v1/warehouse/...` ➔ Proxy to `kinetix-warehouse-service` (`:3000`).
- `/api/v1/matching/...` ➔ Proxy to `kinetix-matching-service` (`:4000`).

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
