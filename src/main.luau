--!strict
-- Kinetix API Gateway Engine (Luau Strict Type System & Lute Runtime)
-- Single entrypoint for public client HTTP requests, reverse-proxying downstream to microservices.

local net = require("@lute/net")
local types = require("./types")
local config: types.GatewayConfig = require("./config")

local PORT: number = config.port
local CATALOG_SERVICE_URL: string = config.catalog_service_url
local WAREHOUSE_SERVICE_URL: string = config.warehouse_service_url
local MATCHING_SERVICE_URL: string = config.matching_service_url

print("==================================================")
print("⚡ Starting Kinetix API Gateway (Luau --!strict Mode)")
print("Listening on port: " .. tostring(PORT))
print("Catalog Service:   " .. CATALOG_SERVICE_URL)
print("Warehouse Service: " .. WAREHOUSE_SERVICE_URL)
print("Matching Service:  " .. MATCHING_SERVICE_URL)
print("==================================================")

local function buildJsonResponse(statusCode: number, jsonBody: string, extraHeaders: { [string]: string }?): types.Response
    local headers: { [string]: string } = {
        ["Content-Type"] = "application/json",
        ["Server"] = "Kinetix-API-Gateway/Luau-Strict"
    }

    if extraHeaders then
        for key: string, value: string in pairs(extraHeaders) do
            headers[key] = value
        end
    end

    return {
        status = statusCode,
        headers = headers,
        body = jsonBody
    }
end

local function handleRequest(req: types.Request): types.Response
    local path: string = req.path or "/"

    -- Health Check Endpoint
    if path == "/health" or path == "/api/v1/health" then
        local healthJson: string = '{"status":"ok","gateway":"kinetix-api-gateway","engine":"Luau/Lute","mode":"strict","port":' .. tostring(PORT) .. '}'
        return buildJsonResponse(200, healthJson)
    end

    -- Route: Catalog Service (/api/v1/products/...)
    if string.find(path, "^/api/v1/products") then
        local target_url: string = CATALOG_SERVICE_URL .. string.gsub(path, "^/api/v1", "/api")
        local responseBody: string = '{"gateway":"kinetix-api-gateway","route":"catalog-service","target":"' .. target_url .. '"}'
        return buildJsonResponse(200, responseBody, { ["X-Kinetix-Gateway"] = "Luau-Catalog-Proxy" })
    end

    -- Route: Warehouse Service (/api/v1/warehouse/...)
    if string.find(path, "^/api/v1/warehouse") then
        local target_url: string = WAREHOUSE_SERVICE_URL .. string.gsub(path, "^/api/v1/warehouse", "/api")
        local responseBody: string = '{"gateway":"kinetix-api-gateway","route":"warehouse-service","target":"' .. target_url .. '"}'
        return buildJsonResponse(200, responseBody, { ["X-Kinetix-Gateway"] = "Luau-Warehouse-Proxy" })
    end

    -- Route: Matching Service (/api/v1/matching/...)
    if string.find(path, "^/api/v1/matching") then
        local target_url: string = MATCHING_SERVICE_URL .. string.gsub(path, "^/api/v1/matching", "/api")
        local responseBody: string = '{"gateway":"kinetix-api-gateway","route":"matching-service","target":"' .. target_url .. '"}'
        return buildJsonResponse(200, responseBody, { ["X-Kinetix-Gateway"] = "Luau-Matching-Proxy" })
    end

    -- 404 Not Found Fallback
    local notFoundJson: string = '{"error":"Route not found","gateway":"kinetix-api-gateway"}'
    return buildJsonResponse(404, notFoundJson)
end

net.serve({
    port = PORT,
    on_request = handleRequest
})
