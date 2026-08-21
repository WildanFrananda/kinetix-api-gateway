--!strict

local net = require("@lute/net")
local types = require("../types")
local builder = require("../response_builder")

local function handleCatalogRoute(path: string, method: string, catalogUrl: string, req: types.Request): types.Response?
    if string.find(path, "^/api/v1/products") or string.find(path, "^/api/v1/cart/") or string.find(path, "^/api/v1/checkout") then
        local targetPath: string = string.gsub(path, "^/api/v1", "/api")
        local targetUrl: string = catalogUrl .. targetPath
        
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
            local errorJson: string = '{"error":"Catalog Service Unavailable","target":"' .. targetUrl .. '"}'
            return builder.buildJsonResponse(503, errorJson)
        end
    end
    return nil
end

return {
    handleCatalogRoute = handleCatalogRoute
}
