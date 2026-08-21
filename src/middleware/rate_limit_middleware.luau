--!strict
-- Kinetix API Gateway Rate Limiting Middleware (Luau Strict Mode & Lute Engine)
-- Memory-leak free sliding window with automatic TTL bucket eviction.

local types = require("../types")
local builder = require("../response_builder")

type RateBucket = {
    count: number,
    windowStart: number
}

local clientBuckets: { [string]: RateBucket } = {}
local lastCleanupTime: number = os.time()
local CLEANUP_INTERVAL_SEC: number = 300 -- Periodic eviction every 5 minutes

local AUTH_ROUTE_LIMIT: number = 10     -- Max 10 auth requests per window (login/register)
local GENERAL_ROUTE_LIMIT: number = 100   -- Max 100 general API requests per window
local WINDOW_DURATION_SEC: number = 60    -- 60 seconds fixed sliding window

-- Memory Cleanup Routine to prevent IP table memory leaks
local function evictExpiredBuckets(now: number)
    if (now - lastCleanupTime) < CLEANUP_INTERVAL_SEC then
        return
    end

    for key: string, bucket: RateBucket in pairs(clientBuckets) do
        if (now - bucket.windowStart) > (WINDOW_DURATION_SEC * 2) then
            clientBuckets[key] = nil
        end
    end
    lastCleanupTime = now
end

local function getClientKey(req: types.Request): string
    local headersMap: { [string]: string } = req.headers or {}
    local clientIp: string = headersMap["x-forwarded-for"] or headersMap["X-Forwarded-For"] or headersMap["x-real-ip"] or "127.0.0.1"
    local path: string = req.path or "/"
    
    if string.find(path, "^/api/v1/auth/") then
        return clientIp .. ":auth"
    end
    return clientIp .. ":general"
end

local function checkRateLimit(req: types.Request): (boolean, types.Response?, number, number)
    local path: string = req.path or "/"
    local now: number = os.time()

    evictExpiredBuckets(now)

    -- Health check bypasses rate limiting
    if path == "/health" or path == "/api/v1/health" then
        return true, nil, GENERAL_ROUTE_LIMIT, GENERAL_ROUTE_LIMIT
    end

    local key: string = getClientKey(req)
    local maxLimit: number = string.find(path, "^/api/v1/auth/") and AUTH_ROUTE_LIMIT or GENERAL_ROUTE_LIMIT
    local bucket: RateBucket? = clientBuckets[key]

    if not bucket or (now - bucket.windowStart) >= WINDOW_DURATION_SEC then
        clientBuckets[key] = {
            count = 1,
            windowStart = now
        }
        return true, nil, maxLimit, maxLimit - 1
    end

    if bucket.count >= maxLimit then
        local resetSec: number = WINDOW_DURATION_SEC - (now - bucket.windowStart)
        local tooManyJson: string = '{"error":"Too Many Requests","message":"API rate limit exceeded. Please wait ' .. tostring(resetSec) .. ' seconds before retrying.","retry_after":' .. tostring(resetSec) .. '}'
        
        local res: types.Response = builder.buildJsonResponse(429, tooManyJson)
        res.headers["X-RateLimit-Limit"] = tostring(maxLimit)
        res.headers["X-RateLimit-Remaining"] = "0"
        res.headers["X-RateLimit-Reset"] = tostring(resetSec)
        res.headers["Retry-After"] = tostring(resetSec)

        return false, res, maxLimit, 0
    end

    bucket.count = bucket.count + 1
    local remaining: number = maxLimit - bucket.count
    return true, nil, maxLimit, remaining
end

return {
    checkRateLimit = checkRateLimit
}
