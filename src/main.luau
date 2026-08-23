--!strict
-- Kinetix API Gateway Engine (Luau Strict Type System & Lute Engine Runtime)
-- Modular Reverse-Proxy Dispatcher & Orchestrator for REST, WebSockets, SSE Streaming, Rate Limiting & JWT Auth Verification.

local net = require("@lute/net")
local types = require("./types")
local config: types.GatewayConfig = require("./config")
local builder = require("./response_builder")

local rateLimitMiddleware = require("./middleware/rate_limit_middleware")
local authMiddleware = require("./middleware/auth_middleware")
local healthRouter = require("./routes/health_router")
local authRouter = require("./routes/auth_router")
local catalogRouter = require("./routes/catalog_router")
local warehouseRouter = require("./routes/warehouse_router")
local matchingRouter = require("./routes/matching_router")
local websocketRouter = require("./routes/websocket_router")
local sseRouter = require("./routes/sse_router")

local PORT: number = config.port
local IDENTITY_URL: string = config.identity_service_url
local CATALOG_URL: string = config.catalog_service_url
local WAREHOUSE_URL: string = config.warehouse_service_url
local MATCHING_URL: string = config.matching_service_url

print("==================================================")
print("⚡ Kinetix API Gateway (Lute Engine Reverse-Proxy)")
print("Public Port:         " .. tostring(PORT))
print("Identity Service:    " .. IDENTITY_URL)
print("Catalog Service:     " .. CATALOG_URL)
print("Warehouse Service:   " .. WAREHOUSE_URL)
print("Matching Service:    " .. MATCHING_URL)
print("==================================================")

local function handleRequest(req: any): types.Response
    local path: string = req.path or "/"
    local method: string = req.method or "GET"
    local headersMap: { [string]: string } = req.headers or {}

    -- CORS OPTIONS Preflight
    if method == "OPTIONS" then
        return builder.buildJsonResponse(204, "")
    end

    -- 1. Memory-Leak Free Rate Limiting Guard
    local isAllowed: boolean, rateLimitResponse: types.Response?, _limit: number, _remaining: number = rateLimitMiddleware.checkRateLimit(req)
    if not isAllowed and rateLimitResponse then
        return rateLimitResponse
    end

    -- 2. Health Router (Public)
    local healthRes: types.Response? = healthRouter.handleHealth(path, PORT)
    if healthRes then return healthRes end

    -- 3. Auth & Identity Router (Login & Register Reverse Proxy)
    local authRes: types.Response? = authRouter.handleAuthRoute(path, method, IDENTITY_URL, req)
    if authRes then return authRes end

    -- 4. Centralized JWT Token Authentication Guard (Validates with Identity Service)
    local isAuthenticated: boolean, authErrorResponse: types.Response?, userId: string?, userRole: string? = authMiddleware.verifyAuthentication(req, IDENTITY_URL)
    if not isAuthenticated and authErrorResponse then
        return authErrorResponse
    end

    -- Inject verified User Identity headers into request before forwarding to downstream microservices
    if userId then
        req.headers = req.headers or {}
        req.headers["X-User-Id"] = userId
        if userRole then
            req.headers["X-User-Role"] = userRole
        end
    end

    -- 5. WebSocket Upgrade Router
    local wsRes: types.Response? = websocketRouter.handleWebSocketRoute(path, headersMap, MATCHING_URL)
    if wsRes then return wsRes end

    -- 6. SSE Stream Router
    local sseRes: types.Response? = sseRouter.handleSseRoute(path, MATCHING_URL, req)
    if sseRes then return sseRes end

    -- 7. Catalog Service Router (Reverse Proxy with Query String & Identity Headers)
    local catalogRes: types.Response? = catalogRouter.handleCatalogRoute(path, method, CATALOG_URL, req)
    if catalogRes then return catalogRes end

    -- 8. Warehouse Service Router (Reverse Proxy with Query String & Identity Headers)
    local warehouseRes: types.Response? = warehouseRouter.handleWarehouseRoute(path, method, WAREHOUSE_URL, req)
    if warehouseRes then return warehouseRes end

    -- 9. Matching Service Router (Reverse Proxy with Query String & Identity Headers)
    local matchingRes: types.Response? = matchingRouter.handleMatchingRoute(path, method, MATCHING_URL, req)
    if matchingRes then return matchingRes end

    -- 10. 404 Fallback
    local notFoundJson: string = '{"error":"Public route not found on Kinetix API Gateway","path":"' .. path .. '"}'
    return builder.buildJsonResponse(404, notFoundJson)
end

net.server.serve({
    address = "0.0.0.0",
    host = "0.0.0.0",
    port = PORT,
    handler = handleRequest
})
