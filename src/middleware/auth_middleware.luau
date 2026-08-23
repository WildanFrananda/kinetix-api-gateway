--!strict

local net = require("@lute/net")
local types = require("../types")
local builder = require("../response_builder")

local PUBLIC_EXACT_ROUTES: { [string]: boolean } = {
    ["/health"] = true,
    ["/api/v1/health"] = true,
    ["/api/v1/auth/login"] = true,
    ["/api/v1/auth/register"] = true
}

local function isPublicRoute(path: string): boolean
    if string.find(path, "%.%.") then
        return false
    end

    if PUBLIC_EXACT_ROUTES[path] then
        return true
    end

    if string.find(path, "^/api/v1/products/") or path == "/api/v1/products" then
        if not string.find(path, "/cart/") and not string.find(path, "/checkout") then
            return true
        end
    end

    return false
end

local function verifyAuthentication(req: types.Request, identityUrl: string): (boolean, types.Response?, string?, string?)
    local path: string = req.path or "/"

    if isPublicRoute(path) then
        return true, nil, nil, nil
    end

    local headersMap: { [string]: string } = req.headers or {}
    local authHeader: string? = headersMap["Authorization"] or headersMap["authorization"]

    if not authHeader or not string.find(authHeader, "^Bearer ") then
        local unauthJson: string = '{"error":"Unauthorized access","message":"Missing or malformed Authorization header. Please log in via kinetix-identity-service."}'
        return false, builder.buildJsonResponse(401, unauthJson), nil, nil
    end

    local token: string = string.gsub(authHeader, "^Bearer ", "")
    if token == "" then
        local unauthJson: string = '{"error":"Unauthorized access","message":"Empty Bearer token provided."}'
        return false, builder.buildJsonResponse(401, unauthJson), nil, nil
    end

    local validateUrl: string = identityUrl .. "/api/auth/validate"
    local success, res = pcall(function()
        return net.client.request(validateUrl, {
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer " .. token
            },
            body = '{"token":"' .. token .. '"}'
        })
    end)

    if success and res and res.status == 200 then
        local userId: string = res.headers["X-User-Id"] or res.headers["x-user-id"] or "user_authenticated"
        local userRole: string = res.headers["X-User-Role"] or res.headers["x-user-role"] or "customer"
        return true, nil, userId, userRole
    elseif success and res and res.status == 401 then
        local invalidJson: string = '{"error":"Unauthorized access","message":"Invalid or expired JWT access token."}'
        return false, builder.buildJsonResponse(401, invalidJson), nil, nil
    else
        local serviceUnavailableJson: string = '{"error":"Service Unavailable","message":"Identity Service is currently unreachable for JWT validation."}'
        return false, builder.buildJsonResponse(503, serviceUnavailableJson), nil, nil
    end
end

return {
    isPublicRoute = isPublicRoute,
    verifyAuthentication = verifyAuthentication
}
