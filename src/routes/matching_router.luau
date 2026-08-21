--!strict

local types = require("../types")
local builder = require("../response_builder")

local function handleMatchingRoute(path: string, method: string, matchingUrl: string): types.Response?
    if string.find(path, "^/api/v1/matching") then
        local targetUrl: string = matchingUrl .. string.gsub(path, "^/api/v1/matching", "/api")
        local body: string = '{"gateway":"kinetix-api-gateway","service":"matching-service","route":"matching-api","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end
    return nil
end

return {
    handleMatchingRoute = handleMatchingRoute
}
