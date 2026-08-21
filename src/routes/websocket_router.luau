--!strict

local types = require("../types")
local builder = require("../response_builder")

local function handleWebSocketRoute(path: string, headers: { [string]: string }, matchingUrl: string): types.Response?
    if string.find(path, "^/ws/v1/matching/socket") or string.find(path, "^/socket/websocket") then
        local upgradeHeader: string? = headers["Upgrade"] or headers["upgrade"]
        local connectionHeader: string? = headers["Connection"] or headers["connection"]

        if upgradeHeader and string.lower(upgradeHeader) == "websocket" then
            local wsHeaders: { [string]: string } = {
                ["Upgrade"] = "websocket",
                ["Connection"] = "Upgrade",
                ["Sec-WebSocket-Accept"] = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                ["X-Upstream-Target"] = matchingUrl .. "/socket/websocket"
            }
            return {
                status = 101,
                headers = wsHeaders,
                body = ""
            }
        end
    end
    return nil
end

return {
    handleWebSocketRoute = handleWebSocketRoute
}
