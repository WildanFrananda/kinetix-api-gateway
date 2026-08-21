--!strict
-- Kinetix API Gateway Response Builder Helper (Luau Strict Mode)

local types = require("./types")

local function buildJsonResponse(statusCode: number, jsonBody: string, extraHeaders: { [string]: string }?): types.Response
    local headers: { [string]: string } = {
        ["Content-Type"] = "application/json",
        ["Server"] = "Kinetix-API-Gateway/Luau-Strict",
        ["Access-Control-Allow-Origin"] = "*",
        ["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-Merchant-Key, Upgrade, Connection"
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
