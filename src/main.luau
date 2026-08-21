--!strict
-- Kinetix API Gateway Engine (Luau Strict Type System & Lute Runtime)
-- Modular Dispatcher & Orchestrator for REST, WebSockets, SSE Streaming, and Auth routes.

local net = require("@lute/net")
local types = require("./types")
local config: types.GatewayConfig = require("./config")
local builder = require("./response_builder")

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
print("⚡ Kinetix API Gateway (Complete Modular Engine)")
print("Public Port:         " .. tostring(PORT))
print("Identity Service:    " .. IDENTITY_URL)
print("Catalog Service:     " .. CATALOG_URL)
print("Warehouse Service:   " .. WAREHOUSE_URL)
print("Matching Service:    " .. MATCHING_URL)
print("==================================================")

local function handleRequest(req: types.Request): types.Response
    local path: string = req.path or "/"
    local method: string = req.method or "GET"
    local headersMap: { [string]: string } = req.headers or {}

    -- CORS OPTIONS Preflight
    if method == "OPTIONS" then
        return builder.buildJsonResponse(204, "")
    end

    -- 1. Health Router
    local healthRes: types.Response? = healthRouter.handleHealth(path, PORT)
    if healthRes then return healthRes end

    -- 2. Auth & Identity Router (Login / Register / Profile / Seller Onboarding)
    local authRes: types.Response? = authRouter.handleAuthRoute(path, method, IDENTITY_URL)
    if authRes then return authRes end

    -- 3. WebSocket Upgrade Router
    local wsRes: types.Response? = websocketRouter.handleWebSocketRoute(path, headersMap, MATCHING_URL)
    if wsRes then return wsRes end

    -- 4. SSE Stream Router
    local sseRes: types.Response? = sseRouter.handleSseRoute(path, MATCHING_URL)
    if sseRes then return sseRes end

    -- 5. Catalog Service Router
    local catalogRes: types.Response? = catalogRouter.handleCatalogRoute(path, method, CATALOG_URL)
    if catalogRes then return catalogRes end

    -- 6. Warehouse Service Router
    local warehouseRes: types.Response? = warehouseRouter.handleWarehouseRoute(path, method, WAREHOUSE_URL)
    if warehouseRes then return warehouseRes end

    -- 7. Matching Service Router
    local matchingRes: types.Response? = matchingRouter.handleMatchingRoute(path, method, MATCHING_URL)
    if matchingRes then return matchingRes end

    -- 8. 404 Fallback
    local notFoundJson: string = '{"error":"Public route not found on Kinetix API Gateway","path":"' .. path .. '"}'
    return builder.buildJsonResponse(404, notFoundJson)
end

net.serve({
    port = PORT,
    on_request = handleRequest
})
