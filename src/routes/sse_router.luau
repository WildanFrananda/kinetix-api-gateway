--!strict

local net = require("@lute/net")
local types = require("../types")
local builder = require("../response_builder")

local function handleSseRoute(path: string, matchingUrl: string, req: types.Request): types.Response?
    if path == "/api/v1/matching/telemetry/stream" then
        local targetUrl: string = matchingUrl .. "/api/v1/telemetry/stream"
        
        local success, res = pcall(function()
            return net.request({
                url = targetUrl,
                method = "GET",
                headers = {
                    ["Accept"] = "text/event-stream",
                    ["Cache-Control"] = "no-cache",
                    ["Connection"] = "keep-alive"
                }
            })
        end)

        if success and res then
            return {
                status = res.status or 200,
                headers = res.headers or {
                    ["Content-Type"] = "text/event-stream",
                    ["Cache-Control"] = "no-cache",
                    ["Connection"] = "keep-alive"
                },
                body = res.body or ""
            }
        else
            local sseHeaders = {
                ["Content-Type"] = "text/event-stream",
                ["Cache-Control"] = "no-cache",
                ["Connection"] = "keep-alive",
                ["X-Accel-Buffering"] = "no"
            }
            return {
                status = 200,
                headers = sseHeaders,
                body = "retry: 5000\nevent: ping\ndata: {\"status\":\"gateway_stream_active\",\"timestamp\":" .. tostring(os.time()) .. "}\n\n"
            }
        end
    end
    return nil
end

return {
    handleSseRoute = handleSseRoute
}
