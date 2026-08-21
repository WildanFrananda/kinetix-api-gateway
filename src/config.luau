--!strict
-- Kinetix API Gateway Environment Configuration (Luau Strict Mode)

local process = require("@lute/process")
local types = require("./types")

local port_str: string? = process.env.PORT
local port_num: number = if port_str then (tonumber(port_str) or 8080) else 8080

local config: types.GatewayConfig = {
    port = port_num,
    identity_service_url = process.env.IDENTITY_SERVICE_URL or "http://localhost:5000",
    catalog_service_url = process.env.CATALOG_SERVICE_URL or "http://localhost:8000",
    warehouse_service_url = process.env.WAREHOUSE_SERVICE_URL or "http://localhost:3000",
    matching_service_url = process.env.MATCHING_SERVICE_URL or "http://localhost:4000"
}

return config
