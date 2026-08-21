--!strict

local types = require("../types")
local builder = require("../response_builder")

local function handleHealth(path: string, port: number): types.Response?
    if path == "/health" or path == "/api/v1/health" then
        local healthJson: string = '{"status":"ok","gateway":"kinetix-api-gateway","engine":"Luau/Lute","mode":"strict","port":' .. tostring(port) .. '}'
        return builder.buildJsonResponse(200, healthJson)
    end
    return nil
end

return {
    handleHealth = handleHealth
}
