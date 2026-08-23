local auth_header = ngx.req.get_headers()["Authorization"] or ngx.req.get_headers()["authorization"]

if not auth_header or not string.match(auth_header, "^Bearer ") then
    ngx.status = 401
    ngx.header.content_type = "application/json"
    ngx.say('{"error":"Unauthorized","message":"Missing or malformed Authorization header."}')
    return ngx.exit(401)
end

local token = string.gsub(auth_header, "^Bearer ", "")

-- Execute internal subrequest to /_validate_jwt
local res = ngx.location.capture("/_validate_jwt", {
    method = ngx.HTTP_POST,
    body = '{"token":"' .. token .. '"}'
})

if res.status == 200 then
    -- Inject verified identity headers to downstream request
    if res.header["X-User-Id"] then
        ngx.req.set_header("X-User-Id", res.header["X-User-Id"])
    end
    if res.header["X-User-Role"] then
        ngx.req.set_header("X-User-Role", res.header["X-User-Role"])
    end
else
    ngx.status = 401
    ngx.header.content_type = "application/json"
    ngx.say('{"error":"Unauthorized","message":"Invalid or expired JWT access token."}')
    return ngx.exit(401)
end
