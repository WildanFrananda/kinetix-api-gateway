--!strict

local types = require("../types")
local builder = require("../response_builder")

local function handleCatalogRoute(path: string, method: string, catalogUrl: string): types.Response?
    -- Product Catalog Listing (GET /api/v1/products/)
    if path == "/api/v1/products" or path == "/api/v1/products/" or string.find(path, "^/api/v1/products%?") then
        local targetUrl: string = catalogUrl .. string.gsub(path, "^/api/v1", "/api")
        local body: string = '{"gateway":"kinetix-api-gateway","service":"catalog-service","route":"catalog-list","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    -- Product Detail & Stock (GET /api/v1/products/{sku}/)
    if string.find(path, "^/api/v1/products/") then
        local targetUrl: string = catalogUrl .. string.gsub(path, "^/api/v1", "/api")
        local body: string = '{"gateway":"kinetix-api-gateway","service":"catalog-service","route":"catalog-detail","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    -- Cart Stock Reservation (POST /api/v1/cart/reserve/)
    if path == "/api/v1/cart/reserve" or path == "/api/v1/cart/reserve/" then
        local targetUrl: string = catalogUrl .. "/api/cart/reserve/"
        local body: string = '{"gateway":"kinetix-api-gateway","service":"catalog-service","route":"cart-reserve","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(200, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    -- Order Checkout (POST /api/v1/checkout/)
    if path == "/api/v1/checkout" or path == "/api/v1/checkout/" then
        local targetUrl: string = catalogUrl .. "/api/orders/checkout/"
        local body: string = '{"gateway":"kinetix-api-gateway","service":"catalog-service","route":"order-checkout","method":"' .. method .. '","upstream":"' .. targetUrl .. '"}'
        return builder.buildJsonResponse(201, body, { ["X-Kinetix-Upstream"] = targetUrl })
    end

    return nil
end

return {
    handleCatalogRoute = handleCatalogRoute
}
