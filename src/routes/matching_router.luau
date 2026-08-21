--!strict

local net = require("@lute/net")
local types = require("../types")
local builder = require("../response_builder")

local function handleMatchingRoute(path: string, method: string, matchingUrl: string, req: types.Request): types.Response?
    if string.find(path, "^/api/v1/matching/") then
        local targetPath: string = string.gsub(path, "^/api/v1/matching", "/api/v1")
        local targetUrl: string = matchingUrl .. targetPath
        
        local success, res = pcall(function()
            return net.request({
                url = targetUrl,
                method = method,
                headers = req.headers or {},
                body = req.body or ""
            })
        end)

        if success and res then
            return {
                status = res.status or 200,
                headers = res.headers or { ["Content-Type"] = "application/json" },
                body = res.body or ""
            }
        else
            local errorJson: string = '{"error":"Matching Service Unavailable","target":"' .. targetUrl .. '"}'
            return builder.buildJsonResponse(503, errorJson)
        end
    end
    return nil
end

return {
    handleMatchingRoute = handleMatchingRoute
}
