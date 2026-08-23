--!strict
-- Kinetix API Gateway Rate Limiting Middleware (Luau Strict Mode & Lute Engine)
-- High-traffic memory-leak free rate limiter with 60-second TTL eviction and anti-spoofing IP extraction.

local types = require("../types")
local builder = require("../response_builder")

type RateBucket = {
    count: number,
    windowStart: number
}

local clientBuckets: { [string]: RateBucket } = {}
local lastCleanupTime: number = os.time()
local CLEANUP_INTERVAL_SEC: number = 60 -- Evict expired IP buckets every 60 seconds to prevent high-traffic memory bloat

local AUTH_ROUTE_LIMIT: number = 10     -- Max 10 auth requests per window (login/register)
local GENERAL_ROUTE_LIMIT: number = 100   -- Max 100 general API requests per window
local WINDOW_DURATION_SEC: number = 60    -- 60 seconds fixed sliding window

-- Memory Cleanup Routine to prevent IP table memory leaks on high traffic
local function evictExpiredBuckets(now: number)
    if (now - lastCleanupTime) < CLEANUP_INTERVAL_SEC then
        return
    end

    for key: string, bucket: RateBucket in pairs(clientBuckets) do
        if (now - bucket.windowStart) > WINDOW_DURATION_SEC then
            clientBuckets[key] = nil
        end
    end
    lastCleanupTime = now
end

local function getClientKey(req: types.Request): string
    local headersMap: { [string]: string } = req.headers or {}
    -- Anti-spoofing IP extraction
    local clientIp: string = headersMap["x-real-ip"] or headersMap["remote-addr"] or "127.0.0.1"
    local rawForwarded: string? = headersMap["x-forwarded-for"] or headersMap["X-Forwarded-For"]
    if rawForwarded and rawForwarded ~= "" then
        -- Take last IP entry from trusted reverse proxy chain
        local parts = string.split(rawForwarded, ",")
        if #parts > 0 then
            clientIp = string.gsub(parts[#parts], "%s+", "")
        end
    end

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
        local headersMap: { [string]: string } = res.headers or {}
        headersMap["X-RateLimit-Limit"] = tostring(maxLimit)
        headersMap["X-RateLimit-Remaining"] = "0"
        headersMap["X-RateLimit-Reset"] = tostring(resetSec)
        headersMap["Retry-After"] = tostring(resetSec)
        res.headers = headersMap

        return false, res, maxLimit, 0
    end

    bucket.count = bucket.count + 1
    local remaining: number = maxLimit - bucket.count
    return true, nil, maxLimit, remaining
end

return {
    checkRateLimit = checkRateLimit
}
