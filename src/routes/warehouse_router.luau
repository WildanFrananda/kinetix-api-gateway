--!strict

local types = require("../types")
local builder = require("../response_builder")

local function handleWarehouseRoute(path: string, method: string, warehouseUrl: string): types.Response?
    if string.find(path, "^/api/v1/warehouse") then
        local targetUrl: string = warehouseUrl .. string.gsub(path, "^/api/v1/warehouse", "/api")
        local body: string = '{"gateway":"kinetix-api-gateway","service":"warehouse-service","route":"warehouse-api","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end
    return nil
end

return {
    handleWarehouseRoute = handleWarehouseRoute
}
