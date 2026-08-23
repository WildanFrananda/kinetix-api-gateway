ngx.header["Access-Control-Allow-Origin"] = "*"
ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
ngx.header["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-User-Id, X-User-Role, X-Merchant-Key"
ngx.header["Server"] = "Kinetix-API-Gateway/OpenResty"

if ngx.req.get_method() == "OPTIONS" then
    ngx.status = 204
    return ngx.exit(204)
end
