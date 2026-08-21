--!strict

local types = require("../types")

local function handleWebSocketRoute(path: string, headersMap: { [string]: string }, matchingUrl: string): types.Response?
    local upgradeHeader: string? = headersMap["Upgrade"] or headersMap["upgrade"]

    if upgradeHeader == "websocket" or string.find(path, "^/socket") or string.find(path, "^/ws/v1") then
        local targetUrl: string = string.gsub(matchingUrl, "^http", "ws") .. string.gsub(path, "^/ws/v1/matching", "")
        return {
            status = 101,
            headers = {
                ["Upgrade"] = "websocket",
                ["Connection"] = "Upgrade",
                ["X-Kinetix-Gateway"] = "Luau-WebSocket-Proxy",
                ["X-Kinetix-Upstream"] = targetUrl
            },
            body = ""
        }
    end

    return nil
end

return {
    handleWebSocketRoute = handleWebSocketRoute
}
