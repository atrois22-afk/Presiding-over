-- Server/Shared/ProductionLogger.lua
-- Production 로깅 모듈: Google Sheets Webhook 전송
-- Design Freeze: 2026-01-19
-- Security: Auth v1 (API_KEY header + timestamp + nonce)

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- FNV-1a 32-bit hash (URL fingerprint without exposing sensitive data)
local function fnv1a32(str)
    local hash = 2166136261
    for i = 1, #str do
        hash = bit32.bxor(hash, string.byte(str, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

-- Secrets 로드 (존재하지 않으면 nil)
local Secrets
local secretsSuccess, secretsResult = pcall(function()
    return require(script.Parent.Parent.Config.Secrets)
end)
if secretsSuccess then
    Secrets = secretsResult
end

local ProductionLogger = {}

--------------------------------------------------------------------------------
-- 1. Configuration
--------------------------------------------------------------------------------

local CONFIG = {
    -- Queue settings (Design: 200 items, 120s TTL, 3 retries)
    QUEUE_MAX_SIZE = 200,
    QUEUE_TTL_SECONDS = 120,
    MAX_RETRIES = 3,
    RETRY_DELAY_SECONDS = 5,

    -- Batch processing
    BATCH_SIZE = 10,
    FLUSH_INTERVAL_SECONDS = 10,

    -- Environment detection
    IS_STUDIO = RunService:IsStudio(),

    -- Webhook URL (from Secrets or placeholder)
    WEBHOOK_URL = Secrets and Secrets.WEBHOOK_URL or nil,
    API_KEY = Secrets and Secrets.API_KEY or nil,
}

-- Runtime state
local queue = {}
local isProcessing = false
local isProcessingStartTime = 0  -- Watchdog: 락 시작 시간
local lastFlushTime = 0
local chainId = nil  -- Session-unique chain identifier

-- N8: PARSE_ERROR 카운터 (5분 윈도우, 3회 임계)
local parseErrorCount = 0
local parseErrorWindowStart = 0
local PARSE_ERROR_WINDOW_SECONDS = 300  -- 5분
local PARSE_ERROR_THRESHOLD = 3

-- STOP 상태 플래그 (API_KEY_INVALID 또는 PARSE_ERROR 임계 초과 시)
local isStopped = false
local stopReason = nil
local lastStopLogTime = 0  -- STOP 로그 레이트리밋용

-- Build fingerprint for deployment verification
local LOGGER_REV = "AUTHV1_BODYPARSE_004"

--------------------------------------------------------------------------------
-- 2. Environment Info
--------------------------------------------------------------------------------

local function getEnvironmentInfo()
    local placeId = game.PlaceId
    local universeId = game.GameId
    local env = CONFIG.IS_STUDIO and "studio" or "production"

    -- Build commit (placeholder - can be set via attribute or config)
    local buildCommit = game:GetAttribute("BuildCommit") or "UNKNOWN"

    return {
        place_id = tostring(placeId),
        universe_id = tostring(universeId),
        env = env,
        build_commit = buildCommit,
    }
end

--------------------------------------------------------------------------------
-- 3. Timestamp & Nonce Generation
--------------------------------------------------------------------------------

local function getTimestampKST()
    local dt = DateTime.now()
    local unixMs = dt.UnixTimestampMillis
    local sec = math.floor(unixMs / 1000)
    local ms = unixMs % 1000

    -- KST = UTC + 9 hours
    local kst = os.date("!%Y-%m-%dT%H:%M:%S", sec + 32400) .. string.format(".%03d+09:00", ms)
    return kst
end

local function generateNonce()
    -- Combine GUID + timestamp for uniqueness
    local guid = HttpService:GenerateGUID(false)
    local ts = DateTime.now().UnixTimestampMillis
    return guid .. "-" .. tostring(ts)
end

local function generateChainId()
    if not chainId then
        -- Session-unique chain ID: server_start_time + random
        local serverStart = DateTime.now().UnixTimestampMillis
        local random = math.random(100000, 999999)
        chainId = string.format("chain_%d_%d", serverStart, random)
    end
    return chainId
end

--------------------------------------------------------------------------------
-- 4. Queue Management
--------------------------------------------------------------------------------

local function pruneExpiredItems()
    local now = os.time()
    local newQueue = {}

    for _, item in ipairs(queue) do
        local age = now - item.queued_at
        if age < CONFIG.QUEUE_TTL_SECONDS then
            table.insert(newQueue, item)
        else
            warn(string.format("[ProductionLogger] Queue item expired: log_point=%s age=%ds",
                item.payload.log_point or "UNKNOWN", age))
        end
    end

    queue = newQueue
end

local function addToQueue(payload)
    -- Prune expired items first
    pruneExpiredItems()

    -- Check queue size limit
    if #queue >= CONFIG.QUEUE_MAX_SIZE then
        -- Remove oldest item
        local removed = table.remove(queue, 1)
        warn(string.format("[ProductionLogger] Queue full, dropped: log_point=%s",
            removed.payload.log_point or "UNKNOWN"))
    end

    -- Add new item
    table.insert(queue, {
        payload = payload,
        queued_at = os.time(),
        retries = 0,
    })

    -- [DBG] Log queue addition
    print(string.format("[ProductionLogger:DBG] ENQUEUE log_point=%s queue_len=%d",
        payload.log_point or "?", #queue))
end

--------------------------------------------------------------------------------
-- 5. HTTP Request (Auth v1: API_KEY header + timestamp + nonce)
--------------------------------------------------------------------------------

local function sendToWebhook(item)
    if not CONFIG.WEBHOOK_URL then
        warn("[ProductionLogger] WEBHOOK_URL not configured")
        return false, "NO_WEBHOOK_URL"
    end

    if not CONFIG.API_KEY then
        warn("[ProductionLogger] API_KEY not configured")
        return false, "NO_API_KEY"
    end

    -- Auth v1: timestamp와 nonce는 요청 시점에 생성
    local timestamp = getTimestampKST()
    local nonce = generateNonce()

    -- 요청 본문: 모든 필드 병합 (Apps Script가 payload 또는 top-level에서 읽음)
    local requestBody = {
        timestamp_kst = timestamp,
        nonce = nonce,
        chain_id = item.payload.chain_id,
        env = item.payload.env,
        place_id = item.payload.place_id,
        universe_id = item.payload.universe_id,
        log_point = item.payload.log_point,
        build_commit = item.payload.build_commit,
        datastore_name = item.payload.datastore_name,
        payload = item.payload,  -- 전체 payload도 포함 (Apps Script에서 추가 필드 참조)
    }

    -- Auth v1: API_KEY를 URL 쿼리 파라미터로 전송 (Apps Script 헤더 접근 제한)
    local urlWithKey = CONFIG.WEBHOOK_URL .. "?api_key=" .. CONFIG.API_KEY

    -- [DBG] Log before HTTP request
    print(string.format("[ProductionLogger:DBG] HTTP_SEND log_point=%s nonce=%s",
        item.payload.log_point or "?", string.sub(nonce, 1, 16) .. "..."))

    local success, result = pcall(function()
        return HttpService:RequestAsync({
            Url = urlWithKey,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = HttpService:JSONEncode(requestBody),
        })
    end)

    if not success then
        -- [DBG] Log HTTP error
        warn(string.format("[ProductionLogger:DBG] HTTP_PCALL_FAIL error=%s", tostring(result)))
        return false, "HTTP_ERROR: " .. tostring(result)
    end

    -- [DBG] HTTP 응답 관측
    print(string.format("[ProductionLogger:DBG] HTTP_RESP status=%d body=%s",
        result.StatusCode, string.sub(result.Body or "", 1, 120)))

    -- N1: 본문 JSON 파싱 (Apps Script는 항상 HTTP 200 반환)
    local ok, body = pcall(function()
        return HttpService:JSONDecode(result.Body or "{}")
    end)
    if not ok then
        warn(string.format("[ProductionLogger] PARSE_ERROR body=%s",
            string.sub(result.Body or "", 1, 120)))

        -- N8: PARSE_ERROR 카운터 증가 (5분 윈도우, 3회 임계)
        local now = os.time()
        if now - parseErrorWindowStart > PARSE_ERROR_WINDOW_SECONDS then
            -- 새 윈도우 시작
            parseErrorCount = 1
            parseErrorWindowStart = now
        else
            parseErrorCount = parseErrorCount + 1
        end

        print(string.format("[ProductionLogger:DBG] PARSE_ERROR_COUNT count=%d window=%ds",
            parseErrorCount, now - parseErrorWindowStart))

        -- N8: 임계 초과 시 STOP 승격
        if parseErrorCount >= PARSE_ERROR_THRESHOLD then
            warn(string.format("[ProductionLogger] STOP_CONDITION: PARSE_ERROR_THRESHOLD (%d in %ds)",
                parseErrorCount, now - parseErrorWindowStart))
            isStopped = true
            stopReason = "PARSE_ERROR_THRESHOLD"
        end

        return false, "PARSE_ERROR"
    end

    -- N7: 관측성 — code, error 로그
    if body.code then
        print(string.format("[ProductionLogger:DBG] RESPONSE_CODE code=%s error=%s",
            tostring(body.code), string.sub(body.error or "", 1, 80)))
    end

    -- N2: 성공 판정
    if body.success == true then
        return true, nil
    end

    -- N3: 실패 판정
    local code = body.code or "UNKNOWN_ERROR"

    -- N4: 영구 실패 — 키 오류 → STOP (flush loop 중지)
    if code == "API_KEY_INVALID" then
        warn("[ProductionLogger] STOP_CONDITION: API_KEY_INVALID - flush loop will halt")
        isStopped = true
        stopReason = "API_KEY_INVALID"
        return false, "API_KEY_INVALID"
    end

    -- N5: 영구 실패 — nonce 중복 → Drop
    if code == "NONCE_DUPLICATE" then
        return false, "NONCE_DUPLICATE"
    end

    -- N6: 재시도 가능 — 레이트 제한 → 백오프(현행 정책 적용)
    if code == "RATE_LIMIT" then
        return false, "RATE_LIMIT"
    end

    -- 그 외 영구 실패
    return false, code
end

--------------------------------------------------------------------------------
-- 6. Queue Processing
--------------------------------------------------------------------------------

local function processQueue()
    -- [DBG] Watchdog: 락이 30초 이상 지속되면 강제 리셋
    if isProcessing and isProcessingStartTime > 0 then
        local lockDuration = os.time() - isProcessingStartTime
        if lockDuration > 30 then
            warn(string.format("[ProductionLogger:DBG] WATCHDOG_RESET lock_duration=%ds", lockDuration))
            isProcessing = false
        end
    end

    if isProcessing then
        -- [DBG] Early return: already processing
        print("[ProductionLogger:DBG] PROCESS_SKIP reason=isProcessing")
        return
    end

    if #queue == 0 then
        -- [DBG] Early return: queue empty (don't log every time to reduce noise)
        return
    end

    -- STOP 상태 체크: API_KEY_INVALID 또는 PARSE_ERROR 임계 초과 시 처리 중단
    if isStopped then
        -- 60초에 1회만 로그 출력 (노이즈 방지)
        local now = os.time()
        if now - lastStopLogTime >= 60 then
            warn(string.format("[ProductionLogger] STOPPED: reason=%s queue_len=%d - manual intervention required (restart server to resume)",
                stopReason or "UNKNOWN", #queue))
            lastStopLogTime = now
        end
        return
    end

    -- [DBG] Log process start
    print(string.format("[ProductionLogger:DBG] PROCESS_START queue_len=%d", #queue))

    isProcessing = true
    isProcessingStartTime = os.time()

    -- Process up to BATCH_SIZE items
    local processed = 0
    local newQueue = {}

    for i, item in ipairs(queue) do
        if processed >= CONFIG.BATCH_SIZE then
            -- Move remaining items to new queue
            table.insert(newQueue, item)
        else
            local success, errCode = sendToWebhook(item)

            if success then
                processed = processed + 1
                -- Item successfully sent, don't re-add to queue
            elseif errCode == "NONCE_DUPLICATE" or errCode == "API_KEY_INVALID" or errCode == "PARSE_ERROR" or string.find(errCode or "", "BAD_REQUEST") then
                -- Don't retry these errors (permanent failures)
                warn(string.format("[ProductionLogger] Permanent failure: %s, log_point=%s",
                    errCode, item.payload.log_point or "UNKNOWN"))
            elseif item.retries < CONFIG.MAX_RETRIES then
                -- Retry later (RATE_LIMIT, HTTP_ERROR, etc.)
                item.retries = item.retries + 1
                table.insert(newQueue, item)
            else
                warn(string.format("[ProductionLogger] Max retries reached: log_point=%s",
                    item.payload.log_point or "UNKNOWN"))
            end
        end
    end

    queue = newQueue
    isProcessing = false
    isProcessingStartTime = 0

    -- [DBG] Log process end
    print(string.format("[ProductionLogger:DBG] PROCESS_END processed=%d remaining=%d", processed, #queue))
end

--------------------------------------------------------------------------------
-- 7. Periodic Flush
--------------------------------------------------------------------------------

local function startPeriodicFlush()
    task.spawn(function()
        print("[ProductionLogger:DBG] FLUSH_LOOP_STARTED")
        local flushCount = 0
        while true do
            task.wait(CONFIG.FLUSH_INTERVAL_SECONDS)
            flushCount = flushCount + 1
            -- Log every 6th tick (1분 간격) to reduce noise
            if flushCount % 6 == 1 then
                print(string.format("[ProductionLogger:DBG] FLUSH_TICK count=%d queue_len=%d", flushCount, #queue))
            end
            processQueue()
        end
    end)
end

--------------------------------------------------------------------------------
-- 8. Main Logging Functions
--------------------------------------------------------------------------------

--[[
    Log an event to Google Sheets
    @param logPoint: string - Log point identifier (e.g., "SAVE_START", "GETASYNC_RESULT")
    @param userId: number - User ID
    @param data: table - Additional log data
    @param datastoreName: string|nil - DataStore name (optional)
]]
function ProductionLogger.Log(logPoint, userId, data, datastoreName)
    -- Skip in Studio (use local logging instead)
    if CONFIG.IS_STUDIO then
        -- Optional: print locally for debugging
        -- print(string.format("[ProductionLogger] STUDIO: %s uid=%s", logPoint, tostring(userId)))
        return
    end

    -- Build payload
    local envInfo = getEnvironmentInfo()

    local payload = {
        timestamp_kst = getTimestampKST(),
        log_point = logPoint,
        user_id = userId and tostring(userId) or nil,
        datastore_name = datastoreName or "FoodTruck_PlayerData_v1",
        env = envInfo.env,
        place_id = envInfo.place_id,
        universe_id = envInfo.universe_id,
        build_commit = envInfo.build_commit,
        chain_id = generateChainId(),
    }

    -- Merge additional data
    if data then
        for k, v in pairs(data) do
            payload[k] = v
        end
    end

    -- Add to queue
    addToQueue(payload)

    -- Immediate flush attempt if queue is getting large
    if #queue >= CONFIG.BATCH_SIZE then
        task.defer(processQueue)
    end
end

--[[
    Log DataService SAVE events
    @param phase: string - "SAVE_START" | "SAVE_OK" | "SAVE_FAIL"
    @param userId: number
    @param keyType: table - { str=N, num=N }
    @param extraData: table|nil
]]
function ProductionLogger.LogSave(phase, userId, keyType, extraData)
    local data = {
        keyType_str = keyType and keyType.str or 0,
        keyType_num = keyType and keyType.num or 0,
    }

    if extraData then
        for k, v in pairs(extraData) do
            data[k] = v
        end
    end

    ProductionLogger.Log(phase, userId, data, "FoodTruck_PlayerData_v1")
end

--[[
    Log DataService LOAD events
    @param userId: number
    @param loadOk: boolean
    @param keyType: table - { str=N, num=N }
    @param extraData: table|nil
]]
function ProductionLogger.LogLoad(userId, loadOk, keyType, extraData)
    local data = {
        loadOk = loadOk,
        keyType_str = keyType and keyType.str or 0,
        keyType_num = keyType and keyType.num or 0,
    }

    if extraData then
        for k, v in pairs(extraData) do
            data[k] = v
        end
    end

    ProductionLogger.Log("GETASYNC_RESULT", userId, data, "FoodTruck_PlayerData_v1")
end

--[[
    Log W3-NEXT events
    @param logPoint: string - "ORDER_CREATED" | "INGREDIENTS_FINALIZED" | "PRE_COMPLETION" | "DELIVER_SETTLE"
    @param userId: number
    @param data: table - W3-NEXT specific data
]]
function ProductionLogger.LogW3Next(logPoint, userId, data)
    ProductionLogger.Log(logPoint, userId, data, nil)
end

--[[
    Log Order events
    @param logPoint: string - "REFILL" | "VARIETY_REROLL" | "DELIVER_SETTLE"
    @param userId: number
    @param data: table
]]
function ProductionLogger.LogOrder(logPoint, userId, data)
    ProductionLogger.Log(logPoint, userId, data, nil)
end

--[[
    PG-1: Log Cook Judgment events (S-09)
    @param userId: number
    @param data: table - {
        recipeId: number,
        serverJudgment: string,
        clientJudgment: string|nil,
        finalJudgment: string,
        corrected: boolean,
        correctionType: string|nil - "up" | "down" | nil
        isTutorial: boolean,
        cookScore: number,
        slotId: number,
    }
]]
function ProductionLogger.LogCookJudgment(userId, data)
    -- 보정 타입 결정 (Up/Down 분리 추적 - 감리자 권장)
    local correctionType = nil
    if data.corrected then
        local judgmentOrder = { Bad = 1, OK = 2, Good = 3, Great = 4, Perfect = 5 }
        local serverRank = judgmentOrder[data.serverJudgment] or 0
        local finalRank = judgmentOrder[data.finalJudgment] or 0
        if finalRank > serverRank then
            correctionType = "up"
        elseif finalRank < serverRank then
            correctionType = "down"
        end
    end

    local logData = {
        recipeId = data.recipeId,
        slotId = data.slotId,
        serverJudgment = data.serverJudgment,
        clientJudgment = data.clientJudgment or "nil",
        finalJudgment = data.finalJudgment,
        corrected = data.corrected,
        correctionType = correctionType or "none",
        isTutorial = data.isTutorial,
        cookScore = data.cookScore,
    }

    ProductionLogger.Log("COOK_JUDGMENT", userId, logData, nil)
end

--------------------------------------------------------------------------------
-- 9. Initialization
--------------------------------------------------------------------------------

function ProductionLogger.Init()
    -- Validate configuration (Auth v1: API_KEY required)
    if not CONFIG.IS_STUDIO then
        if not CONFIG.WEBHOOK_URL then
            warn("[ProductionLogger] WARNING: WEBHOOK_URL not configured (Production mode)")
        end
        if not CONFIG.API_KEY then
            warn("[ProductionLogger] WARNING: API_KEY not configured (Production mode)")
        end
    end

    -- Start periodic flush
    startPeriodicFlush()

    print(string.format("[ProductionLogger] Initialized (env=%s, rev=%s, queue_max=%d, ttl=%ds)",
        CONFIG.IS_STUDIO and "studio" or "production",
        LOGGER_REV,
        CONFIG.QUEUE_MAX_SIZE,
        CONFIG.QUEUE_TTL_SECONDS))

    -- [DBG] URL verification logging (ChatGPT auditor recommendation)
    local url = CONFIG.WEBHOOK_URL or ""
    local apiKey = CONFIG.API_KEY or ""
    local urlTail = string.sub(url, -24)
    local hasQuery = (string.find(url, "?", 1, true) ~= nil)
    local urlHash = fnv1a32(url)
    local apiKeyLen = #apiKey
    print(string.format(
        "[ProductionLogger:DBG] URL_TAIL=%s HAS_QUERY=%s URL_FNV32=%s URL_LEN=%d API_KEY_LEN=%d",
        urlTail, tostring(hasQuery), urlHash, #url, apiKeyLen
    ))
end

--[[
    Flush all pending items (call before server shutdown)
]]
function ProductionLogger.FlushAll()
    if CONFIG.IS_STUDIO then
        return
    end

    -- Process all remaining items with extended retry
    local maxAttempts = 3
    for attempt = 1, maxAttempts do
        if #queue == 0 then
            break
        end

        print(string.format("[ProductionLogger] FlushAll attempt %d/%d, items=%d",
            attempt, maxAttempts, #queue))

        -- Process entire queue
        local batchBackup = CONFIG.BATCH_SIZE
        CONFIG.BATCH_SIZE = #queue + 1
        processQueue()
        CONFIG.BATCH_SIZE = batchBackup

        if #queue > 0 then
            task.wait(CONFIG.RETRY_DELAY_SECONDS)
        end
    end

    if #queue > 0 then
        warn(string.format("[ProductionLogger] FlushAll incomplete, %d items remaining", #queue))
    end
end

--[[
    Get current queue status (debugging)
]]
function ProductionLogger.GetStatus()
    return {
        queue_size = #queue,
        is_processing = isProcessing,
        is_studio = CONFIG.IS_STUDIO,
        has_webhook = CONFIG.WEBHOOK_URL ~= nil,
        has_api_key = CONFIG.API_KEY ~= nil,
        chain_id = chainId,
        auth_version = "v1",
        -- STOP 상태 정보
        is_stopped = isStopped,
        stop_reason = stopReason,
        last_stop_log_time = lastStopLogTime,
        -- N8 카운터 정보
        parse_error_count = parseErrorCount,
        parse_error_window_start = parseErrorWindowStart,
    }
end

return ProductionLogger
