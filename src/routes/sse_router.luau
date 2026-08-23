--!strict

local net = require("@lute/net")
local types = require("../types")

local function handleSseRoute(path: string, matchingUrl: string, req: types.Request): types.Response?
    if path == "/api/v1/matching/telemetry/stream" or path == "/api/v1/matching/events" then
        local targetUrl: string = matchingUrl .. "/api/v1/telemetry/stream"

        local success, res = pcall(function()
            return net.client.request(targetUrl, {
                method = "GET",
                headers = req.headers or {}
            })
        end)

        if success and res then
            local sseHeaders: { [string]: string } = res.headers or {}
            sseHeaders["Content-Type"] = "text/event-stream"
            sseHeaders["Cache-Control"] = "no-cache"
            sseHeaders["Connection"] = "keep-alive"
            return {
                status = res.status or 200,
                headers = sseHeaders,
                body = res.body or "event: ping\ndata: {}\n\n"
            }
        else
            return {
                status = 200,
                headers = {
                    ["Content-Type"] = "text/event-stream",
                    ["Cache-Control"] = "no-cache",
                    ["Connection"] = "keep-alive"
                },
                body = "retry: 5000\nevent: ping\ndata: {\"status\":\"matching_service_connecting\"}\n\n"
            }
        end
    end
    return nil
end

return {
    handleSseRoute = handleSseRoute
}
