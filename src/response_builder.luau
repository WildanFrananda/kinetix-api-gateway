--!strict

local types = require("./types")

local function buildJsonResponse(statusCode: number, jsonBody: string, extraHeaders: { [string]: string }?): types.Response
    local headers: { [string]: string } = {
        ["Content-Type"] = "application/json",
        ["Server"] = "Kinetix-API-Gateway/Lute-Engine",
        ["Access-Control-Allow-Origin"] = "*",
        ["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-User-Id, X-User-Role, X-Merchant-Key, Upgrade, Connection",
        ["Access-Control-Expose-Headers"] = "X-User-Id, X-User-Role, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset"
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

return {
    buildJsonResponse = buildJsonResponse
}
