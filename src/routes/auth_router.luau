--!strict

local net = require("@lute/net")
local types = require("../types")
local builder = require("../response_builder")

local function handleAuthRoute(path: string, method: string, identityUrl: string, req: types.Request): types.Response?
    if path == "/api/v1/auth/login" or path == "/api/v1/auth/register" then
        local targetPath: string = string.gsub(path, "^/api/v1/auth", "/api/auth")
        local targetUrl: string = identityUrl .. targetPath
        
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
            local errorJson: string = '{"error":"Identity Service Unavailable","target":"' .. targetUrl .. '"}'
            return builder.buildJsonResponse(503, errorJson)
        end
    end
    return nil
end

return {
    handleAuthRoute = handleAuthRoute
}
