--!strict

local types = require("../types")

local function handleSseRoute(path: string, matchingUrl: string): types.Response?
    if path == "/api/v1/matching/telemetry/stream" then
        local targetUrl: string = matchingUrl .. "/api/telemetry/stream"
        return {
            status = 200,
            headers = {
                ["Content-Type"] = "text/event-stream",
                ["Cache-Control"] = "no-cache",
                ["Connection"] = "keep-alive",
                ["X-Kinetix-Gateway"] = "Luau-SSE-Proxy",
                ["X-Kinetix-Upstream"] = targetUrl
            },
            body = 'retry: 1000\nevent: ping\ndata: {"status":"streaming","upstream":"' .. targetUrl .. '"}\n\n'
        }
    end

    return nil
end

return {
    handleSseRoute = handleSseRoute
}
