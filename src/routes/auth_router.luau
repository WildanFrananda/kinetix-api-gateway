--!strict
-- Kinetix Authentication & Session Router (Luau Strict Mode)

local types = require("../types")
local builder = require("../response_builder")

local function handleAuthRoute(path: string, method: string, identityUrl: string): types.Response?
    -- User / Courier Login (POST /api/v1/auth/login)
    if path == "/api/v1/auth/login" or path == "/api/v1/auth/login/" then
        local targetUrl: string = identityUrl .. "/api/auth/login"
        local body: string = '{"gateway":"kinetix-api-gateway","service":"identity-service","route":"auth-login","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    -- User / Courier Registration (POST /api/v1/auth/register)
    if path == "/api/v1/auth/register" or path == "/api/v1/auth/register/" then
        local targetUrl: string = identityUrl .. "/api/auth/register"
        local body: string = '{"gateway":"kinetix-api-gateway","service":"identity-service","route":"auth-register","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(201, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    -- User Profile Management (/api/v1/users/...)
    if string.find(path, "^/api/v1/users/") then
        local targetUrl: string = identityUrl .. string.gsub(path, "^/api/v1", "/api")
        local body: string = '{"gateway":"kinetix-api-gateway","service":"identity-service","route":"user-profile","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    -- Seller Onboarding (/api/v1/sellers/...)
    if string.find(path, "^/api/v1/sellers/") then
        local targetUrl: string = identityUrl .. string.gsub(path, "^/api/v1", "/api")
        local body: string = '{"gateway":"kinetix-api-gateway","service":"identity-service","route":"seller-onboarding","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    return nil
end

return {
    handleAuthRoute = handleAuthRoute
}
