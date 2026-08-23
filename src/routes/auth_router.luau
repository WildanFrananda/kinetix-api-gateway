--!strict

local net = require("@lute/net")
local types = require("../types")
local builder = require("../response_builder")

local function handleAuthRoute(path: string, method: string, identityUrl: string, req: types.Request): types.Response?
    if path == "/api/v1/auth/login" or path == "/api/v1/auth/register" then
        local targetPath: string = string.gsub(path, "^/api/v1/auth", "/api/auth")
        local queryString: string = ""
        if req.query and type(req.query) == "string" then
            queryString = req.query
        end
        local fullTargetPath: string = targetPath .. (queryString ~= "" and ("?" .. queryString) or "")
        local targetUrl: string = identityUrl .. fullTargetPath

        local forwardHeaders: { [string]: string } = {}
        if req.headers then
            for k: string, v: string in pairs(req.headers) do
                if string.lower(k) ~= "host" then
                    forwardHeaders[k] = v
                end
            end
        end
        forwardHeaders["Host"] = string.gsub(identityUrl, "^https?://", "")

        local success, res = pcall(function()
            return net.client.request(targetUrl, {
                method = method,
                headers = forwardHeaders,
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
