-- Server/Services/DataService.lua
-- SSOT v0.2.3.4 / Contract v1.3 Addendum
-- 역할: 플레이어 데이터 로드/저장, RF_GetInitialData, RE_CompleteTutorial, SessionCache

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ServerFlags = require(game.ReplicatedStorage.Shared.ServerFlags)
local GameData = require(game.ReplicatedStorage.Shared.GameData)
local PoolUtils = require(game.ReplicatedStorage.Shared.PoolUtils)
local OrderService = require(game.ServerScriptService.Server.Services.OrderService)

-- Production 로깅 (Google Sheets Webhook)
local ProductionLogger = require(game.ServerScriptService.Server.Shared.ProductionLogger)

local DataService = {}
DataService.__index = DataService

--[[
    플레이어별 데이터 캐시 (영구 데이터 - DataStore)
    PlayerDataCache[UserId] = {
        data = PlayerProfile,
        lastSave = tick(),
        isDirty = bool,
        urgentSave = bool,  -- Phase 3: exitReason 등 중요 변경 시 설정
        isSaving = bool,    -- Phase 3: 중복 저장 방지
    }
]]
local PlayerDataCache = {}

-- v0.2.3.4: 온보딩 전용 RNG (모듈 로드 시 1회 생성, 서버 프로세스 생명주기 동안 공유)
local FirstJoinRNG = Random.new()

--[[
    Phase 3: 세션 상태 캐시 (메모리 전용 - 세션 종료 시 소멸)
    SessionState[UserId] = {
        joinTs = number,  -- os.time(), PlayerAdded 시 1회 생성, 불변
    }

    IMPORTANT:
    - 생성: PlayerAdded에서만
    - 삭제: PlayerRemoving에서만
    - joinTs 재할당 금지
]]
local SessionState = {}

-- DataStore 참조 (실제 환경에서 초기화)
local PlayerDataStore = nil

-- 상수
local MAX_RETRY = 2
local RETRY_DELAY = 1

-- BindToClose idempotent 가드 (모듈 레벨)
local _bindToCloseConnected = false

-- P3: per-player Day End Concurrency Guard (Contract v1.4 §4.7)
local DayEndInProgress = {}  -- [UserId] = true/false

-- S-29.2: Stale Notice 세션 캐시 (서버 런타임 per uid)
-- StaleNoticeCache[uid] = { ["dish_1_1"] = true, ["dish_1_2"] = true, ... }
-- key = dishKey .. "_" .. staleLevel
local StaleNoticeCache = {}

--------------------------------------------------------------------------------
-- 유틸리티 함수
--------------------------------------------------------------------------------

local function DeepCopy(original)
    if type(original) ~= "table" then
        return original
    end
    local copy = {}
    for key, value in pairs(original) do
        copy[DeepCopy(key)] = DeepCopy(value)
    end
    return copy
end

local function GetDataStoreKey(player)
    return "Player_" .. player.UserId
end

--------------------------------------------------------------------------------
-- [B-0 가드레일] Inventory 키 정규화 (저장 직전 self-heal)
-- 혼합 키 테이블 방지: 모든 키를 문자열로 강제 변환
--------------------------------------------------------------------------------

local function NormalizeInventoryKeys(inventory)
    if not inventory then return {}, 0, 0, 0 end

    local normalized = {}
    local strKeys = 0
    local numKeys = 0
    local dishKeys = 0

    for k, v in pairs(inventory) do
        local keyType = type(k)
        local strKey = tostring(k)

        if keyType == "string" then
            strKeys = strKeys + 1
        elseif keyType == "number" then
            numKeys = numKeys + 1
        end

        -- dish 키 카운트
        if strKey:sub(1, 5) == "dish_" then
            dishKeys = dishKeys + 1
        end

        normalized[strKey] = v
    end

    return normalized, strKeys, numKeys, dishKeys
end

--------------------------------------------------------------------------------
-- [S-29.2] staleCounts 불변식 검증 + self-heal
-- SSOT: S29_2_MVP_Definition.md §6
-- Trigger: on load + before save (2지점만)
-- Authority: inventory가 권위, staleCounts는 종속
-- Heal rule: lvl0 = inv - (lvl1 + lvl2), 음수면 clamp(0)
--------------------------------------------------------------------------------

--[[
    staleCounts 버킷 안전 접근 (기본값 0)
]]
local function GetStaleBucket(staleCounts, dishKey, level)
    if not staleCounts then return 0 end
    if not staleCounts[dishKey] then return 0 end
    return staleCounts[dishKey][level] or 0
end

--[[
    staleCounts 버킷 설정 (자동 초기화)
]]
local function SetStaleBucket(staleCounts, dishKey, level, value)
    if not staleCounts[dishKey] then
        staleCounts[dishKey] = { [0] = 0, [1] = 0, [2] = 0 }
    end
    staleCounts[dishKey][level] = value
end

--[[
    S-30: Stale II dishKey 목록 생성 (클라 동기화용)
    - staleCounts[dishKey][2] > 0 인 모든 dishKey를 배열로 반환
    - 스냅샷 방식: 매번 전체 목록 재구성

    @param staleCounts: playerData.staleCounts
    @return array: { "dish_10", "dish_22", ... }
]]
local function GetStale2Keys(staleCounts)
    local result = {}
    if not staleCounts then return result end

    for dishKey, buckets in pairs(staleCounts) do
        if type(buckets) == "table" and (buckets[2] or 0) > 0 then
            table.insert(result, dishKey)
        end
    end

    return result
end

--[[
    S-29.2: staleCounts 마이그레이션 (기존 inventory → Fresh(0))
    - 기존 유저: staleCounts가 없으면 inventory 기준으로 생성
    - 모든 dish는 Fresh(0)으로 초기화

    @param playerData: 플레이어 데이터
    @param uid: 유저 ID (로깅용)
    @return bool: 마이그레이션 발생 여부
]]
local function MigrateStaleCounts(playerData, uid)
    if not playerData then return false end

    -- 이미 staleCounts가 있으면 스킵
    if playerData.staleCounts then
        return false
    end

    -- 신규 생성
    playerData.staleCounts = {}

    -- inventory에서 dish 키만 추출하여 Fresh(0)으로 초기화
    local inventory = playerData.inventory or {}
    local dishCount = 0

    for itemKey, count in pairs(inventory) do
        local strKey = tostring(itemKey)
        if strKey:sub(1, 5) == "dish_" and count and count > 0 then
            playerData.staleCounts[strKey] = {
                [0] = count,  -- 전부 Fresh
                [1] = 0,
                [2] = 0,
            }
            dishCount = dishCount + 1
        end
    end

    if dishCount > 0 then
        print(string.format(
            "[DataService] S-29.2|STALE_MIGRATE uid=%d dishTypes=%d (all Fresh)",
            uid, dishCount
        ))
    end

    return true
end

--[[
    S-29.2: staleCounts 불변식 검증 + self-heal

    불변식: inventory[dishKey] == staleCounts[dishKey][0] + [1] + [2]

    @param playerData: 플레이어 데이터
    @param uid: 유저 ID (로깅용)
    @param source: "load" | "save" (로깅용)
    @return healCount: 수정된 dishKey 개수
]]
local function ValidateAndHealStaleCounts(playerData, uid, source)
    if not playerData then return 0 end

    local inventory = playerData.inventory or {}
    local staleCounts = playerData.staleCounts or {}

    local healCount = 0
    local allDishKeys = {}

    -- 1. inventory에서 dish 키 수집
    for itemKey, _ in pairs(inventory) do
        local strKey = tostring(itemKey)
        if strKey:sub(1, 5) == "dish_" then
            allDishKeys[strKey] = true
        end
    end

    -- 2. staleCounts에서 dish 키 수집 (inventory에 없는 것도 포함)
    for dishKey, _ in pairs(staleCounts) do
        if tostring(dishKey):sub(1, 5) == "dish_" then
            allDishKeys[dishKey] = true
        end
    end

    -- 3. 각 dishKey에 대해 불변식 검증
    for dishKey, _ in pairs(allDishKeys) do
        local inv = inventory[dishKey] or 0
        local b0 = GetStaleBucket(staleCounts, dishKey, 0)
        local b1 = GetStaleBucket(staleCounts, dishKey, 1)
        local b2 = GetStaleBucket(staleCounts, dishKey, 2)
        local bucketSum = b0 + b1 + b2

        -- 불변식 위반 체크
        if inv ~= bucketSum then
            -- self-heal: lvl0 = inv - (lvl1 + lvl2)
            local newB0 = inv - (b1 + b2)

            -- 음수면 clamp(0) + 추가 조정
            local reason = "mismatch"
            if newB0 < 0 then
                reason = "negative_clamp"
                -- lvl1, lvl2도 조정 필요 (inv가 권위)
                -- 간단히: 전부 Fresh로 리셋
                newB0 = inv
                b1 = 0
                b2 = 0
            end

            -- staleCounts 초기화 (없으면)
            if not staleCounts[dishKey] then
                staleCounts[dishKey] = { [0] = 0, [1] = 0, [2] = 0 }
            end

            local after0 = newB0
            local after1 = (reason == "negative_clamp") and 0 or b1
            local after2 = (reason == "negative_clamp") and 0 or b2

            staleCounts[dishKey][0] = after0
            staleCounts[dishKey][1] = after1
            staleCounts[dishKey][2] = after2

            healCount = healCount + 1

            -- STALE_HEAL_WARN 로그
            print(string.format(
                "[DataService] S-29.2|STALE_HEAL_WARN uid=%d dishKey=%s reason=%s source=%s inv=%d b0=%d b1=%d b2=%d after0=%d after1=%d after2=%d",
                uid, dishKey, reason, source, inv, b0, b1, b2, after0, after1, after2
            ))
        end

        -- inventory가 0이면 staleCounts에서 제거 (정리)
        if inv == 0 and staleCounts[dishKey] then
            staleCounts[dishKey] = nil
        end
    end

    -- playerData에 반영
    playerData.staleCounts = staleCounts

    return healCount
end

--------------------------------------------------------------------------------
-- 초기화
--------------------------------------------------------------------------------

function DataService:Init()
    -- DataStore 초기화
    -- ⚠️ 환경 분기 정책:
    --   Studio = v2 (Gate-3.x 테스트 전용, 신규 유저)
    --   운영   = v1 (기존 데이터 유지)
    local storeName = RunService:IsStudio()
        and "FoodTruck_PlayerData_v2"
        or  "FoodTruck_PlayerData_v1"

    -- 운영 안전 가드 (v2가 운영에서 열리면 즉시 경고)
    if not RunService:IsStudio() and storeName ~= "FoodTruck_PlayerData_v1" then
        warn("[CRITICAL] Production server using non-v1 DataStore!")
    end

    local success, store = pcall(function()
        return DataStoreService:GetDataStore(storeName)
    end)

    if success then
        PlayerDataStore = store
    else
        warn("[DataService] DataStore 초기화 실패:", store)
    end

    -- PlayerAdded 연결
    Players.PlayerAdded:Connect(function(player)
        self:OnPlayerAdded(player)
    end)

    -- PlayerRemoving 연결
    Players.PlayerRemoving:Connect(function(player)
        self:OnPlayerRemoving(player)
    end)

    -- 이미 접속한 플레이어 처리 (Studio 테스트용)
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(function()
            self:OnPlayerAdded(player)
        end)
    end

    -- Autosave Loop 시작
    task.spawn(function()
        self:AutosaveLoop()
    end)

    -- BindToClose: 서버 종료 시 모든 플레이어 저장 (pending counter 대기)
    if _bindToCloseConnected then
        warn("[DataService] BINDTOCLOSE_SKIPPED (already connected)")
    else
        _bindToCloseConnected = true
        game:BindToClose(function()
            local players = Players:GetPlayers()
            local playerCount = #players

            if playerCount == 0 then
                print("[DataService] BINDTOCLOSE_START players=0 (skip)")
                return
            end

            print(string.format("[DataService] BINDTOCLOSE_START players=%d", playerCount))

            local pending = playerCount
            local failedUids = {}
            local MAX_WAIT = 25  -- Roblox BindToClose 최대 30초 제한에 여유

            -- 각 플레이어 저장 (task.spawn으로 병렬 처리)
            for _, player in ipairs(players) do
                task.spawn(function()
                    local success, err = pcall(function()
                        self:SaveData(player, "bind_to_close")
                    end)
                    if not success then
                        table.insert(failedUids, player.UserId)
                        warn(string.format(
                            "[DataService] BINDTOCLOSE_SAVE_FAIL uid=%d err=%s",
                            player.UserId, tostring(err)
                        ))
                    end
                    pending = pending - 1
                end)
            end

            -- pending counter로 완료 대기
            local waited = 0
            while pending > 0 and waited < MAX_WAIT do
                task.wait(0.1)
                waited = waited + 0.1
            end

            -- 타임아웃 또는 완료 로그
            if pending > 0 then
                warn(string.format(
                    "[DataService] BINDTOCLOSE_TIMEOUT remaining=%d waited=%.1fs",
                    pending, waited
                ))
            end

            if #failedUids > 0 then
                warn(string.format(
                    "[DataService] BINDTOCLOSE_DONE failed_uids=[%s]",
                    table.concat(failedUids, ",")
                ))
            else
                print(string.format(
                    "[DataService] BINDTOCLOSE_DONE saved=%d waited=%.1fs",
                    playerCount, waited
                ))
            end
        end)
        print("[DataService] BindToClose 연결 완료")
    end

    print("[DataService] 초기화 완료")
end

function DataService:OnPlayerAdded(player)
    local uid = player.UserId
    local joinTs = os.time()

    ----------------------------------------------------------------------------
    -- ⚠️ 임시 리셋 코드 (테스트 후 삭제할 것!)
    ----------------------------------------------------------------------------
    local TEMP_RESET_ENABLED = false  -- ✅ 삭제 완료, 비활성화됨
    if TEMP_RESET_ENABLED and PlayerDataStore then
        local success, err = pcall(function()
            PlayerDataStore:RemoveAsync(tostring(uid))
        end)
        if success then
            print(string.format("⚠️ [TEMP_RESET] 데이터 삭제 완료: uid=%d", uid))
        else
            warn(string.format("⚠️ [TEMP_RESET] 삭제 실패: %s", tostring(err)))
        end
    end
    ----------------------------------------------------------------------------

    -- Phase 3: SessionState 생성 (PlayerAdded에서만, 1회)
    SessionState[uid] = {
        joinTs = joinTs,
    }

    -- GATE3 로그 (Studio + GATE3_LOG_ENABLED)
    if RunService:IsStudio() and ServerFlags.GATE3_LOG_ENABLED then
        print(string.format("[GATE3][session] uid=%d joinTs=%d event=created", uid, joinTs))
    end

    -- 데이터 로드
    local data = self:LoadData(player)
    PlayerDataCache[uid] = {
        data = data,
        lastSave = tick(),
        isDirty = false,
        urgentSave = false,
        isSaving = false,
        pendingDirty = false,  -- 저장 중 스킵된 요청이 있으면 후속 저장 필요
    }

    -- 로드된 데이터의 dish_count 로그 (진단용)
    local loadedDishCount = 0
    if data and data.inventory then
        for itemKey, count in pairs(data.inventory) do
            if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
                loadedDishCount = loadedDishCount + (count or 0)
            end
        end
    end
    print(string.format(
        "[DataService] PLAYER_ADDED_LOADED uid=%d dish_count=%d",
        uid, loadedDishCount
    ))

    -- P1-OBS-1: SESSION_REJOIN 로그 (nil-safe)
    local loadOk = "unknown"
    local success, orderSessionState = pcall(function()
        return OrderService:GetSessionState(player)
    end)
    if success and orderSessionState then
        loadOk = orderSessionState.sessionNotSaved and "false" or "true"
    end

    local logSuccess = pcall(function()
        print(string.format(
            "OBS|SESSION_REJOIN|ts=%d|uid=%d|sid=%s|type=%s|loadOk=%s",
            os.time(),
            uid,
            game.JobId or "local",
            "initial",
            loadOk
        ))
    end)
    if not logSuccess then
        print("OBS|SESSION_REJOIN|error=log_failed")
    end
end

function DataService:OnPlayerRemoving(player)
    local uid = player.UserId

    -- 진입 로그: cache 존재 여부 + dish 합계 (진단용)
    local cache = PlayerDataCache[uid]
    local cacheExists = cache ~= nil
    local dishCount = 0
    if cache and cache.data and cache.data.inventory then
        for itemKey, count in pairs(cache.data.inventory) do
            if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
                dishCount = dishCount + (count or 0)
            end
        end
    end
    print(string.format(
        "[DataService] PLAYER_REMOVING_ENTER uid=%d cache_exists=%s dish_count=%d",
        uid, tostring(cacheExists), dishCount
    ))

    -- 종료 저장 (PlayerRemoving) - source 명시
    self:SaveData(player, "player_removing")

    -- Phase 3: SessionState 정리 (PlayerRemoving에서만)
    local session = SessionState[uid]
    if session and RunService:IsStudio() and ServerFlags.GATE3_LOG_ENABLED then
        print(string.format("[GATE3][session] uid=%d joinTs=%d event=removed", uid, session.joinTs))
    end
    SessionState[uid] = nil

    -- S-29.2: StaleNoticeCache 정리
    StaleNoticeCache[uid] = nil

    -- 캐시 정리
    PlayerDataCache[uid] = nil
    OrderService:CleanupPlayer(player)

    print(string.format("[DataService] PLAYER_REMOVING_DONE uid=%d", uid))
end

--------------------------------------------------------------------------------
-- 1. LoadData (핵심)
--------------------------------------------------------------------------------

function DataService:LoadData(player)
    ----------------------------------------------------------------------------
    -- ⚠️ 테스트 전용 플래그 (2026-01-18 Owner 승인으로 비활성화)
    -- 주의: Studio 한정, 운영 환경 절대 금지
    -- 승인: Owner PASS (P1 Smoke Test 차단 해소)
    ----------------------------------------------------------------------------
    local FORCE_NEW_USER = false  -- 비활성화됨 (원래 의도된 DataStore Load 복귀)
    -- if FORCE_NEW_USER then
    --     print("⚠️ [FORCE_NEW_USER] 강제 신규 유저 모드")
    --     return self:CreateMinSafeState()
    -- end
    ----------------------------------------------------------------------------

    if not PlayerDataStore then
        warn("[DataService] DataStore 없음, MIN_SAFE_STATE 반환")
        OrderService:SetSessionNotSaved(player, true)
        return self:CreateMinSafeState()
    end

    local key = GetDataStoreKey(player)
    local data = nil
    local loadSuccess = false

    -- 재시도 로직 (최대 MAX_RETRY회)
    for attempt = 1, MAX_RETRY + 1 do
        local success, result = pcall(function()
            return PlayerDataStore:GetAsync(key)
        end)

        if success then
            data = result
            loadSuccess = true
            -- [감리 로그] GETASYNC_RESULT: keyType + dish_keys
            if data and data.inventory then
                local strKeys, numKeys, dishKeyCount = 0, 0, 0
                local dishSample = {}
                for k, v in pairs(data.inventory) do
                    local keyType = type(k)
                    if keyType == "string" then
                        strKeys = strKeys + 1
                        if k:sub(1, 5) == "dish_" then
                            dishKeyCount = dishKeyCount + 1
                            table.insert(dishSample, k .. "=" .. tostring(v))
                        end
                    elseif keyType == "number" then
                        numKeys = numKeys + 1
                    end
                end
                print(string.format(
                    "[DataService] GETASYNC_RESULT uid=%d keyType={str=%d,num=%d} dish_keys=%d sample={%s}",
                    player.UserId, strKeys, numKeys, dishKeyCount, table.concat(dishSample, ",")
                ))
                -- Production 로깅
                ProductionLogger.LogLoad(player.UserId, true, {str = strKeys, num = numKeys}, {
                    dish_keys = dishKeyCount,
                })
            else
                print(string.format(
                    "[DataService] GETASYNC_RESULT uid=%d has_inventory=%s data_nil=%s",
                    player.UserId, tostring(data and data.inventory ~= nil), tostring(data == nil)
                ))
                -- Production 로깅 (데이터 없음/신규 유저)
                ProductionLogger.LogLoad(player.UserId, true, {str = 0, num = 0}, {
                    dish_keys = 0,
                    is_new_user = data == nil,
                })
            end
            break
        else
            warn("[DataService] GetAsync 실패 (시도 " .. attempt .. "):", result)
            if attempt <= MAX_RETRY then
                task.wait(RETRY_DELAY)
            end
        end
    end

    -- 로드 실패 시: sessionNotSaved 설정 + MIN_SAFE_STATE 반환
    if not loadSuccess then
        warn("[DataService] 최종 로드 실패, sessionNotSaved 설정")
        OrderService:SetSessionNotSaved(player, true)
        return self:CreateMinSafeState()
    end

    -- 신규 플레이어 (데이터 없음)
    if data == nil then
        data = self:CreateNewPlayerProfile(player)
    else
        -- 기존 플레이어: FIRST_JOIN_ORDERS_POLICY 스킵 확인
        -- (이미 firstJoinOrdersApplied가 true이면 스킵)
    end

    -- S-29.2: staleCounts 마이그레이션 (기존 유저)
    MigrateStaleCounts(data, player.UserId)

    -- S-29.2: staleCounts 불변식 검증 + self-heal (load 시점)
    ValidateAndHealStaleCounts(data, player.UserId, "load")

    -- S-29.2: StaleNoticeCache 초기화 (session = server runtime per uid)
    StaleNoticeCache[player.UserId] = {}

    return data
end

--[[
    MIN_SAFE_STATE 생성 (Contract v1.2)
    - 로드 실패에서도 Step3 진행 보장
]]
function DataService:CreateMinSafeState()
    local minSafe = DeepCopy(ServerFlags.MIN_SAFE_STATE)

    -- orders 실제 데이터 생성 (v0.2.3.4: 중복 금지 정책 적용)
    minSafe.orders = {}

    -- P2: Day 통계 초기화 (MIN_SAFE_STATE에도 포함)
    minSafe.dayStats = {
        day = 1,
        ordersServed = 0,
        totalReward = 0,
        totalTip = 0,
    }

    -- 기준 레시피 (reward fallback 기준)
    local recipe1 = GameData.GetRecipeById(1)
    local baseReward = recipe1 and recipe1.reward or 50

    -- Slot 1: recipeId=1 보장 (Step3 진행)
    minSafe.orders[1] = {
        slotId = 1,
        recipeId = 1,
        reward = baseReward,
    }

    -- Slot 2, 3: FIRST_JOIN_EASY_POOL에서 선택 (중복 금지)
    local pool = ServerFlags.FIRST_JOIN_EASY_POOL
    local allowDuplicates = (ServerFlags.FIRST_JOIN_ALLOW_DUPLICATES == true)

    -- 연속 배열 검증 (PoolUtils SSOT 사용)
    local poolValid, poolSize = PoolUtils.isValidPool(pool)
    if not poolValid then
        -- fill_basic: pool 문제 시 기본버거
        for slotId = 2, 3 do
            minSafe.orders[slotId] = {
                slotId = slotId,
                recipeId = 1,
                reward = baseReward,
            }
        end
    elseif not allowDuplicates and poolSize >= 2 then
        -- unique: 중복 금지 (shuffle)
        local tmp = {table.unpack(pool)}
        for i = poolSize, 2, -1 do
            local j = FirstJoinRNG:NextInteger(1, i)
            tmp[i], tmp[j] = tmp[j], tmp[i]
        end
        for idx, slotId in ipairs({2, 3}) do
            local recipeId = tonumber(tmp[idx])
            local recipe = GameData.GetRecipeById(recipeId)
            if not recipe then
                recipeId = 1
                recipe = recipe1
            end
            minSafe.orders[slotId] = {
                slotId = slotId,
                recipeId = recipeId,
                reward = recipe and recipe.reward or baseReward,
            }
        end
    else
        -- dup: 중복 허용
        for slotId = 2, 3 do
            local idx = FirstJoinRNG:NextInteger(1, poolSize)
            local recipeId = tonumber(pool[idx])
            local recipe = GameData.GetRecipeById(recipeId)
            if not recipe then
                recipeId = 1
                recipe = recipe1
            end
            minSafe.orders[slotId] = {
                slotId = slotId,
                recipeId = recipeId,
                reward = recipe and recipe.reward or baseReward,
            }
        end
    end

    return minSafe
end

--[[
    신규 플레이어 프로필 생성 + FIRST_JOIN_ORDERS_POLICY 적용
]]
function DataService:CreateNewPlayerProfile(player)
    local profile = {
        -- 기본 데이터
        inventory = {},
        wallet = { coins = ServerFlags.STARTING_COINS },
        upgrades = {
            quantity = 1,
            craftSpeed = 1,
            slots = 1,
        },
        tutorial = { hasCompleted = false },

        -- 플래그
        flags = {
            firstJoinOrdersApplied = false,
            firstDeliveryUsed = false,
        },

        -- 주문 (빈 상태로 시작, FIRST_JOIN_ORDERS_POLICY에서 채움)
        orders = {},

        -- P2: Day 통계 (누적, DataStore 영속)
        dayStats = {
            day = 1,            -- MVP: 항상 1 (Day 리셋은 P3)
            ordersServed = 0,   -- 완료 주문 수
            totalReward = 0,    -- reward 누적
            totalTip = 0,       -- tip 누적
        },

        -- S-29.2: staleCounts (버킷 모델)
        -- 스키마: { [dishKey: string]: { [0]=int, [1]=int, [2]=int } }
        staleCounts = {},

        -- 메타데이터
        createdAt = os.time(),
        lastLogin = os.time(),
    }

    -- FIRST_JOIN_ORDERS_POLICY 적용 (SSOT §6.6)
    self:ApplyFirstJoinOrders(profile)

    return profile
end

--[[
    FIRST_JOIN_ORDERS_POLICY 적용 (SSOT v0.2.3.4 §6.6)
    - 첫 접속 시 주문 보드 즉시 3개 채움
    - recipeId=1 보장
    - 슬롯 2,3 중복 금지 (mode: unique/dup/fill_basic)
]]
function DataService:ApplyFirstJoinOrders(profile)
    -- 방어 코드 (nil 가능성 대비)
    profile.flags = profile.flags or {}
    profile.orders = profile.orders or {}

    if profile.flags.firstJoinOrdersApplied then
        return  -- 이미 적용됨, 스킵
    end

    -- 기준 레시피 (reward fallback 기준)
    local recipe1 = GameData.GetRecipeById(1)
    local baseReward = recipe1 and recipe1.reward or 50

    -- Slot 1: recipeId=1 고정 (튜토리얼 Step3 보장)
    profile.orders[1] = {
        slotId = 1,
        recipeId = 1,
        reward = baseReward,
    }

    -- Slot 2, 3 결정
    local pool = ServerFlags.FIRST_JOIN_EASY_POOL
    local allowDuplicates = (ServerFlags.FIRST_JOIN_ALLOW_DUPLICATES == true)

    -- mode 3상태: unique(중복금지) / dup(중복허용) / fill_basic(운영fallback)
    local mode = "unique"  -- 기본값 (보수적)

    -- 연속 배열 검증 (PoolUtils SSOT 사용)
    local poolValid, poolSize = PoolUtils.isValidPool(pool)
    if not poolValid then
        mode = "fill_basic"
    elseif allowDuplicates or poolSize < 2 then
        mode = "dup"
    else
        mode = "unique"
    end

    -- 모드별 처리
    if mode == "fill_basic" then
        -- pool 문제 → 기본버거로 채움 (중복 정책 적용 대상 아님)
        for slotId = 2, 3 do
            profile.orders[slotId] = {
                slotId = slotId,
                recipeId = 1,
                reward = baseReward,
            }
        end
    elseif mode == "unique" then
        -- 중복 금지 (Fisher-Yates shuffle)
        local tmp = {table.unpack(pool)}
        for i = poolSize, 2, -1 do
            local j = FirstJoinRNG:NextInteger(1, i)
            tmp[i], tmp[j] = tmp[j], tmp[i]
        end
        for idx, slotId in ipairs({2, 3}) do
            local recipeId = tonumber(tmp[idx])
            local recipe = GameData.GetRecipeById(recipeId)
            if not recipe then
                recipeId = 1
                recipe = recipe1
            end
            profile.orders[slotId] = {
                slotId = slotId,
                recipeId = recipeId,
                reward = recipe and recipe.reward or baseReward,
            }
        end
    else  -- mode == "dup"
        -- 중복 허용 (독립 추첨)
        for slotId = 2, 3 do
            local idx = FirstJoinRNG:NextInteger(1, poolSize)
            local recipeId = tonumber(pool[idx])
            local recipe = GameData.GetRecipeById(recipeId)
            if not recipe then
                recipeId = 1
                recipe = recipe1
            end
            profile.orders[slotId] = {
                slotId = slotId,
                recipeId = recipeId,
                reward = recipe and recipe.reward or baseReward,
            }
        end
    end

    -- 플래그 설정 (원자적 처리 보장)
    profile.flags.firstJoinOrdersApplied = true

    -- Studio 로깅 (mode 기반, QA/디버깅용)
    if RunService:IsStudio() then
        local s2 = profile.orders[2] and profile.orders[2].recipeId or "nil"
        local s3 = profile.orders[3] and profile.orders[3].recipeId or "nil"
        print(string.format(
            "[FIRST_JOIN] mode=%s pool=%d s2=%s s3=%s flag_allowDup=%s",
            mode, poolSize, s2, s3, tostring(allowDuplicates)
        ))
    end
end

--------------------------------------------------------------------------------
-- 2. SaveData (핵심)
--------------------------------------------------------------------------------

function DataService:SaveData(player, source)
    source = source or "unknown"
    local uid = player.UserId
    local cache = PlayerDataCache[uid]

    -- 캐시 없음 (다른 핸들러가 먼저 정리했을 가능성)
    if not cache then
        warn(string.format(
            "[DataService] SAVE_SKIPPED_NO_CACHE uid=%d source=%s",
            uid, source
        ))
        return false, "no_cache"
    end

    -- Phase 3: isSaving 가드 (중복 저장 방지)
    if cache.isSaving then
        -- 스킵되었으므로 후속 저장 필요 (pendingDirty)
        cache.pendingDirty = true
        warn(string.format(
            "[DataService] SAVE_SKIPPED_ALREADY_SAVING uid=%d source=%s pendingDirty=true",
            uid, source
        ))
        return false, "already_saving"
    end

    -- sessionNotSaved 상태면 저장 스킵 (데이터 오염 방지)
    local orderSessionState = OrderService:GetSessionState(player)
    if orderSessionState.sessionNotSaved then
        warn(string.format(
            "[DataService] SAVE_SKIPPED_SESSION_NOT_SAVED uid=%d source=%s",
            uid, source
        ))
        return false, "session_not_saved"
    end

    if not PlayerDataStore then
        warn(string.format(
            "[DataService] SAVE_SKIPPED_NO_DATASTORE uid=%d source=%s",
            uid, source
        ))
        return false, "no_datastore"
    end

    -- [B-0 가드레일] 저장 직전 inventory 키 정규화 (self-heal)
    local strKeys, numKeys, dishKeys = 0, 0, 0
    if cache.data and cache.data.inventory then
        local normalized
        normalized, strKeys, numKeys, dishKeys = NormalizeInventoryKeys(cache.data.inventory)

        -- num 키가 발견되면 경고 + 자동 변환
        if numKeys > 0 then
            warn(string.format(
                "[DataService] B0_SELFHEAL uid=%d numKeys=%d converted_to_str",
                uid, numKeys
            ))
        end

        -- 정규화된 inventory로 교체 (self-heal)
        cache.data.inventory = normalized
    end

    -- S-29.2: staleCounts 불변식 검증 + self-heal (save 시점)
    ValidateAndHealStaleCounts(cache.data, uid, "save")

    -- dish 합계 계산
    local dishTotal = 0
    if cache.data and cache.data.inventory then
        for itemKey, count in pairs(cache.data.inventory) do
            if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
                dishTotal = dishTotal + (count or 0)
            end
        end
    end

    -- [감리 로그] SAVE_START: keyType + dish_keys
    print(string.format(
        "[DataService] SAVE_START uid=%d source=%s keyType={str=%d,num=%d} dish_keys=%d dish_total=%d",
        uid, source, strKeys, numKeys, dishKeys, dishTotal
    ))
    -- Production 로깅
    ProductionLogger.LogSave("SAVE_START", uid, {str = strKeys, num = numKeys}, {
        dish_keys = dishKeys,
        dish_total = dishTotal,
        source = source,
    })

    -- isSaving 플래그 설정
    cache.isSaving = true

    local key = GetDataStoreKey(player)
    local data = cache.data

    -- lastLogin 업데이트
    data.lastLogin = os.time()

    -- 재시도 로직
    local saveSuccess = false
    local lastError = nil

    for attempt = 1, MAX_RETRY + 1 do
        local success, result = pcall(function()
            return PlayerDataStore:UpdateAsync(key, function(oldData)
                -- 새 데이터로 덮어쓰기
                return data
            end)
        end)

        if success then
            saveSuccess = true
            break
        else
            lastError = result
            warn(string.format(
                "[DataService] SAVE_UPDATEASYNC_FAIL uid=%d source=%s attempt=%d err=%s",
                uid, source, attempt, tostring(result)
            ))
            if attempt <= MAX_RETRY then
                task.wait(RETRY_DELAY)
            end
        end
    end

    -- isSaving 플래그 해제
    cache.isSaving = false

    -- 최종 실패 시: sessionNotSaved 설정 (SSOT §10.1)
    -- 실패 시에는 pendingDirty reflush 금지 (무한 루프 방지)
    if not saveSuccess then
        warn(string.format(
            "[DataService] SAVE_FINAL_FAIL uid=%d source=%s err=%s",
            uid, source, tostring(lastError)
        ))
        OrderService:SetSessionNotSaved(player, true)

        -- Notice 전송 (RE_ShowNotice)
        self:SendNotice(player, "save_fail_bootstrap", "error", "save_failed")

        return false, lastError
    end

    -- 성공
    cache.lastSave = tick()
    cache.isDirty = false
    cache.urgentSave = false  -- Phase 3: urgentSave 플래그 리셋

    print(string.format(
        "[DataService] SAVE_OK uid=%d source=%s keyType={str=%d,num=%d} dish_keys=%d dish_total=%d",
        uid, source, strKeys, numKeys, dishKeys, dishTotal
    ))
    -- Production 로깅
    ProductionLogger.LogSave("SAVE_OK", uid, {str = strKeys, num = numKeys}, {
        dish_keys = dishKeys,
        dish_total = dishTotal,
        source = source,
    })

    -- pendingDirty 후속 저장 (성공 후에만 실행, 실패 시 무한 루프 방지)
    if cache.pendingDirty then
        cache.pendingDirty = false
        print(string.format(
            "[DataService] DIRTY_REFLUSH_ENQUEUED uid=%d",
            uid
        ))
        -- task.defer로 즉시 재귀 방지 (다음 프레임에 실행)
        task.defer(function()
            -- 플레이어가 아직 존재하고 캐시가 있을 때만
            if player.Parent and PlayerDataCache[uid] then
                self:SaveData(player, "dirty_reflush")
            end
        end)
    end

    return true, nil
end

--[[
    주기적 자동 저장 (SSOT: SAVE_INTERVAL_SECONDS = 300)
    Phase 3: urgentSave 플래그가 있는 플레이어 우선 처리
]]
function DataService:AutosaveLoop()
    while true do
        task.wait(ServerFlags.SAVE_INTERVAL_SECONDS)

        -- Phase 3: urgentSave 우선 처리
        for userId, cache in pairs(PlayerDataCache) do
            local player = Players:GetPlayerByUserId(userId)
            if player and cache.urgentSave and not cache.isSaving then
                task.spawn(function()
                    self:SaveData(player, "autosave_urgent")
                end)
            end
        end

        -- 일반 dirty 처리
        for userId, cache in pairs(PlayerDataCache) do
            local player = Players:GetPlayerByUserId(userId)
            if player and cache.isDirty and not cache.isSaving then
                task.spawn(function()
                    self:SaveData(player, "autosave")
                end)
            end
        end
    end
end

--[[
    데이터 변경 시 dirty 플래그 설정
]]
function DataService:MarkDirty(player)
    local cache = PlayerDataCache[player.UserId]
    if cache then
        cache.isDirty = true
    end
end

--------------------------------------------------------------------------------
-- 3. RF_GetInitialData 핸들러 (Contract v1.2 §3.1)
--------------------------------------------------------------------------------

function DataService:GetInitialData(player)
    local cache = PlayerDataCache[player.UserId]
    if not cache then
        -- 캐시 없으면 로드 시도
        local data = self:LoadData(player)
        PlayerDataCache[player.UserId] = {
            data = data,
            lastSave = tick(),
            isDirty = false,
        }
        cache = PlayerDataCache[player.UserId]
    end

    local data = cache.data

    --------------------------------------------------------------------------
    -- DEBUG: Tutorial Reset (Studio-only, C-DoD 테스트용)
    -- 조건: IsStudio AND DEBUG_TUTORIAL_RESET=true
    -- 리셋 대상: tutorial 필드만 (경제/진행 데이터 유지)
    -- ⚠️ 테스트 후 ServerFlags.DEBUG_TUTORIAL_RESET = false로 원복!
    --------------------------------------------------------------------------
    if RunService:IsStudio() and ServerFlags.DEBUG_TUTORIAL_RESET then
        -- 튜토리얼 필드 리셋
        if data.tutorial then
            data.tutorial.hasCompleted = false
            data.tutorial.exitReason = nil
            data.tutorial.bonusGranted = nil
        end
        -- C-DoD 테스트용: 코인/인벤/주문 리셋
        data.wallet = { coins = ServerFlags.STARTING_COINS }
        data.inventory = {}
        data.upgrades = {}
        data.orders = {}  -- 주문도 초기화 (QA 혼선 방지)

        -- FIRST_JOIN 테스트용: firstJoinOrdersApplied 리셋
        data.flags = data.flags or {}
        data.flags.firstJoinOrdersApplied = false

        -- 저장 정책에 태움
        cache.isDirty = true

        -- DEBUG_RESET 로그 (리셋 완료 상태 증빙, ApplyFirstJoinOrders 호출 전)
        print(string.format(
            "[DEBUG_RESET] uid=%d coins=%d orders=cleared firstJoinOrdersApplied=false (Studio-only)",
            player.UserId, ServerFlags.STARTING_COINS
        ))

        -- ApplyFirstJoinOrders 재호출 (DEBUG 리셋 후 온보딩 주문 재생성)
        self:ApplyFirstJoinOrders(data)
    end

    --------------------------------------------------------------------------
    -- Phase 3: SKIP 분기 exitReason 백필 (G3.3 Evidence)
    -- 조건: hasCompleted=true AND exitReason=nil (레거시 완료 유저)
    -- 이번 세션의 Entry에서 "튜토리얼 미진입" = skipped
    --------------------------------------------------------------------------
    if data.tutorial
       and data.tutorial.hasCompleted
       and not data.tutorial.exitReason then

        self:SetTutorialExitReason(player, "skipped")
    end

    -- lazy require: 순환 의존 방지 (TD-001)
    local DeliveryService = require(script.Parent.DeliveryService)

    -- [FIX] 혼합 키 테이블 직렬화 문제 해결: 모든 키를 문자열로 변환
    local invToSend = {}
    for k, v in pairs(data.inventory or {}) do
        invToSend[tostring(k)] = v
    end

    -- Contract v1.2 형식으로 변환
    local response = {
        inventory = invToSend,
        orders = self:ConvertOrdersToArray(data.orders),
        upgrades = data.upgrades or {},
        wallet = data.wallet or { coins = ServerFlags.STARTING_COINS },
        flags = {
            EconomyEnabled = ServerFlags.EconomyEnabled,
            DeliveryEnabled = ServerFlags.DeliveryEnabled,
            OrdersEnabled = ServerFlags.OrdersEnabled,
            CraftingEnabled = ServerFlags.CraftingEnabled,
            SOFT_LAUNCH_MODE = ServerFlags.SOFT_LAUNCH_MODE,
        },
        tutorial = data.tutorial or { hasCompleted = false },
        cooldown = DeliveryService:GetCooldown(player),  -- Contract v1.2 §3.2
    }

    return response
end

--[[
    orders 딕셔너리를 배열로 변환 (Contract 형식)
]]
function DataService:ConvertOrdersToArray(ordersDict)
    local ordersArray = {}
    if ordersDict then
        for slotId, order in pairs(ordersDict) do
            table.insert(ordersArray, order)
            -- S-24 DEBUG: reservedDishKey 전송 확인 - S-25: DEBUG 게이팅
            if ServerFlags.DEBUG_S24 then
                print(string.format("[S-24|INIT_PAYLOAD] slot=%d reserved=%s recipeId=%s",
                    order.slotId or slotId,
                    tostring(order.reservedDishKey),
                    tostring(order.recipeId)))
            end
        end
        -- slotId 순으로 정렬
        table.sort(ordersArray, function(a, b)
            return a.slotId < b.slotId
        end)
    end
    return ordersArray
end

--------------------------------------------------------------------------------
-- 4. RE_CompleteTutorial 핸들러 (Contract v1.2 §4.5)
--------------------------------------------------------------------------------

function DataService:CompleteTutorial(player)
    local sessionState = OrderService:GetSessionState(player)

    -- sessionNotSaved 상태면 저장 거부 (RECOVERY 유도)
    if sessionState.sessionNotSaved then
        -- Step3 완료 후라면 RECOVERY 상태
        if sessionState.tutorialState == "RECOVERY" then
            return {
                success = false,
                error = "recovery_mode",
                noticeCode = "save_fail_reconnect",
            }
        end

        -- Step3 이전이면 진행은 허용하되 저장 안 함
        return {
            success = true,
            saved = false,
            noticeCode = "save_fail_economy_locked",
        }
    end

    -- 정상 상태: 튜토리얼 완료 저장
    local cache = PlayerDataCache[player.UserId]
    if not cache then
        return {
            success = false,
            error = "no_data",
        }
    end

    -- 1. hasCompleted=true 설정
    cache.data.tutorial.hasCompleted = true

    -- 2. Phase 3: exitReason 기록 (SSOT 단일 경로 - G3.3 Evidence)
    -- SetTutorialExitReason()은 멱등성 보장 (이미 값 있으면 무시)
    local reasonOk, reasonErr = self:SetTutorialExitReason(player, "completed")
    -- reasonErr="already_set"는 정상 케이스 (재호출 허용)

    -- 3. 저장 플래그 (SetTutorialExitReason 내부에서 urgentSave 설정됨)
    self:MarkDirty(player)

    -- 4. 즉시 저장 (중요 이벤트)
    local saveSuccess, saveError = self:SaveData(player, "tutorial_complete")

    return {
        success = true,
        saved = saveSuccess,
        analytics = {
            event = "tutorial_complete",
            exitReasonSet = reasonOk,  -- 디버깅용
        },
    }
end

--------------------------------------------------------------------------------
-- 플레이어 데이터 접근자
--------------------------------------------------------------------------------

function DataService:GetPlayerData(player)
    local cache = PlayerDataCache[player.UserId]
    return cache and cache.data or nil
end

--[[
    S-30: Stale II dishKey 목록 조회 (클라 동기화용)
    - staleCounts[dishKey][2] > 0 인 모든 dishKey를 배열로 반환
    - 스냅샷 방식: 매번 전체 목록 재구성

    @param player: Player 객체
    @return array: { "dish_10", "dish_22", ... } or {}
]]
function DataService:GetStale2Keys(player)
    local playerData = self:GetPlayerData(player)
    if not playerData or not playerData.staleCounts then
        return {}
    end
    return GetStale2Keys(playerData.staleCounts)
end

--[[
    P2: Day 통계 조회 (RF_GetDayEnd용)
    Returns: dayStats 테이블 or nil

    NOTE: 반환값은 playerData.dayStats의 참조입니다.
    Snapshot 생성 시 반드시 새 테이블로 복사해야 합니다 (I-P2-DA-01).
]]
function DataService:GetDayStats(player)
    local playerData = self:GetPlayerData(player)
    if not playerData then
        return nil
    end

    -- dayStats가 없으면 초기화 (기존 유저 마이그레이션)
    if not playerData.dayStats then
        playerData.dayStats = {
            day = 1,
            ordersServed = 0,
            totalReward = 0,
            totalTip = 0,
        }
        self:MarkDirty(player)
    end

    return playerData.dayStats
end

--[[
    P3: ProcessDayEnd (Contract v1.4 §4.7 / §5.9)
    수동(manual)/자동(threshold) Day End 공통 처리 함수

    @param player: Player 인스턴스
    @param reason: "manual" | "threshold"
    @return Contract §4.7 RF_EndDay 응답 형식
]]
function DataService:ProcessDayEnd(player, reason)
    local uid = player.UserId
    local target = ServerFlags.SOFT_DAY_ORDER_TARGET  -- 10

    -- 1. 입력 검증
    if not player or not player:IsA("Player") then
        return {
            Success = false,
            Error = "bad_param",
            NoticeCode = "bad_param",
        }
    end

    -- Reason enum 검증 (SSOT)
    if reason ~= "manual" and reason ~= "threshold" then
        return {
            Success = false,
            Error = "bad_param",
            NoticeCode = "bad_param",
        }
    end

    -- 2. per-player Concurrency Guard
    if DayEndInProgress[uid] then
        return {
            Success = false,
            Error = "dayend_in_progress",
            NoticeCode = "dayend_in_progress",
        }
    end

    -- 3. 가드 세팅
    DayEndInProgress[uid] = true

    -- 4. 보호 실행 (pcall + finally)
    local ok, result = pcall(function()
        -- 4.1 데이터 로드
        local playerData = self:GetPlayerData(player)
        if not playerData then
            return {
                Success = false,
                Error = "data_error",
                NoticeCode = "data_error",
            }
        end

        -- dayStats 초기화 (기존 유저 마이그레이션)
        if not playerData.dayStats then
            playerData.dayStats = {
                day = 1,
                ordersServed = 0,
                totalReward = 0,
                totalTip = 0,
            }
        end

        local stats = playerData.dayStats

        -- 4.2 스냅샷 고정 (커밋 직전 값, SSOT)
        local dayBefore = stats.day
        local ordersServed = stats.ordersServed
        local thresholdAt = dayBefore * target  -- dayBefore 기준 (SSOT)

        -- 4.3 사전 조건 체크 (reason별)
        if reason == "manual" then
            -- manual 허용 조건: ordersServed > (day-1) * target
            local manualThreshold = (dayBefore - 1) * target
            if ordersServed <= manualThreshold then
                return {
                    Success = false,
                    Error = "not_ready",
                    NoticeCode = "not_ready",
                }
            end
        elseif reason == "threshold" then
            -- threshold 조건: ordersServed >= day * target
            if ordersServed < thresholdAt then
                -- 동시성에 의한 오탐 방지
                return {
                    Success = false,
                    Error = "not_ready",
                    NoticeCode = "not_ready",
                }
            end
        end

        -- 4.4 TRIGGER 로그 (커밋 전, dayBefore 기준)
        print(string.format(
            "DAY_END_TRIGGER uid=%d reason=%s dayBefore=%d ordersServed=%d target=%d thresholdAt=%d",
            uid, reason, dayBefore, ordersServed, target, thresholdAt
        ))

        -- 4.5 Day 커밋 (리셋 없음 정책, P3 MVP)
        stats.day = dayBefore + 1
        local dayAfter = stats.day
        -- ordersServed, totalReward, totalTip 리셋 없음 (SSOT)

        -- 4.6 COMMIT 로그
        print(string.format("DAY_END_COMMIT uid=%d dayAfter=%d", uid, dayAfter))

        -- 4.7 저장 플래그 설정
        self:MarkDirty(player)

        -- 4.8 RF_EndDay 응답 payload 구성 (Contract §4.7)
        return {
            Success = true,
            Reason = reason,
            DayBefore = dayBefore,
            DayAfter = dayAfter,
            OrdersServedAtEnd = ordersServed,
            Target = target,
        }
    end)

    -- 5. finally: 가드 해제 (무조건)
    DayEndInProgress[uid] = false

    -- 6. pcall 실패 처리
    if not ok then
        warn(string.format(
            "[DataService] DAYEND_PCALL_ERROR uid=%d err=%s",
            uid, tostring(result)
        ))
        return {
            Success = false,
            Error = "data_error",
            NoticeCode = "data_error",
        }
    end

    return result
end

--[[
    P3: threshold 체크 헬퍼 (OrderService에서 호출)
    Deliver 성공 후 ordersServed 증가 이후에 호출

    @param player: Player 인스턴스
    @return bool: threshold 도달 여부
]]
function DataService:CheckDayEndThreshold(player)
    local stats = self:GetDayStats(player)
    if not stats then
        return false
    end

    local target = ServerFlags.SOFT_DAY_ORDER_TARGET
    local thresholdAt = stats.day * target

    return stats.ordersServed >= thresholdAt
end

function DataService:UpdatePlayerData(player, updateFunc)
    local cache = PlayerDataCache[player.UserId]
    if not cache then
        return false
    end

    updateFunc(cache.data)
    self:MarkDirty(player)
    return true
end

--------------------------------------------------------------------------------
-- Phase 3: SessionState 접근자
--------------------------------------------------------------------------------

--[[
    joinTs 조회 (생성 권한 없음 - 조회만)
    Returns: number or nil
]]
function DataService:GetJoinTs(player)
    local session = SessionState[player.UserId]
    return session and session.joinTs or nil
end

--[[
    SessionState 전체 조회 (디버깅용)
]]
function DataService:GetSessionState(player)
    return SessionState[player.UserId]
end

--------------------------------------------------------------------------------
-- Phase 3: urgentSave 정책
--------------------------------------------------------------------------------

--[[
    urgentSave 플래그 설정 (다음 저장 tick에서 우선 처리)
]]
function DataService:SetUrgentSave(player)
    local cache = PlayerDataCache[player.UserId]
    if cache then
        cache.urgentSave = true
        cache.isDirty = true
    end
end

--[[
    urgentSave 상태 확인
]]
function DataService:IsUrgentSave(player)
    local cache = PlayerDataCache[player.UserId]
    return cache and cache.urgentSave or false
end

--------------------------------------------------------------------------------
-- Phase 3: SetTutorialExitReason (§2 - G3.3 Evidence)
--------------------------------------------------------------------------------

--[[
    유효한 exitReason 값 (Contract v1.3 Addendum §15.3)

    | 값                    | 트리거 조건                                    |
    |-----------------------|-----------------------------------------------|
    | completed             | Step 4 성공 (BuyUpgrade success)               |
    | skipped               | hasCompleted=true AND exitReason nil 상태에서 Join |
    | auto_exit_error       | 시스템 오류로 튜토리얼 강제 종료                 |
    | forced_exit_recovery  | RECOVERY 상태에서 Modal 표시 후 종료            |
]]
local VALID_EXIT_REASONS = {
    completed = true,
    skipped = true,
    auto_exit_error = true,
    forced_exit_recovery = true,
}

--[[
    exitReason 설정 (1회성, 직접 할당 금지)

    @param player: Player 인스턴스
    @param reason: string - VALID_EXIT_REASONS 중 하나
    @return success: bool, error: string?

    IMPORTANT:
    - 이 함수를 통해서만 exitReason 설정 (직접 할당 금지)
    - 1회만 기록 (이미 값 있으면 무시)
    - urgentSave 플래그로 다음 저장 시점에 반영
]]
function DataService:SetTutorialExitReason(player, reason)
    local playerData = self:GetPlayerData(player)
    if not playerData then
        return false, "no_data"
    end

    -- 튜토리얼 필드 초기화 (방어적)
    if not playerData.tutorial then
        playerData.tutorial = { hasCompleted = false }
    end

    -- 1. 이미 값 있으면 무시 (1회성)
    if playerData.tutorial.exitReason then
        if RunService:IsStudio() and ServerFlags.GATE3_LOG_ENABLED then
            print(string.format(
                "[GATE3][exitReason] SKIP uid=%d reason=%s existing=%s",
                player.UserId, reason, playerData.tutorial.exitReason
            ))
        end
        return false, "already_set"
    end

    -- 2. 유효값 검증
    if not VALID_EXIT_REASONS[reason] then
        warn(string.format(
            "[DataService] Invalid exitReason: %s (uid=%d)",
            tostring(reason), player.UserId
        ))
        return false, "invalid_reason"
    end

    -- 3. 메모리 즉시 반영
    playerData.tutorial.exitReason = reason

    -- 4. urgentSave 플래그 설정 (즉시 저장 아님)
    self:SetUrgentSave(player)

    -- GATE3 로그 (Evidence)
    if RunService:IsStudio() and ServerFlags.GATE3_LOG_ENABLED then
        local joinTs = self:GetJoinTs(player) or 0
        print(string.format(
            "[GATE3][exitReason] SET uid=%d joinTs=%d reason=%s",
            player.UserId, joinTs, reason
        ))
    end

    return true
end

--[[
    exitReason 조회 (디버깅/검증용)
]]
function DataService:GetTutorialExitReason(player)
    local playerData = self:GetPlayerData(player)
    if not playerData or not playerData.tutorial then
        return nil
    end
    return playerData.tutorial.exitReason
end

--------------------------------------------------------------------------------
-- Notice 전송 (RE_ShowNotice)
--------------------------------------------------------------------------------

function DataService:SendNotice(player, code, severity, messageKey, extra)
    -- RemoteEvent가 있으면 전송
    -- extra: optional table { dishKey = "dish_X" } for S-29.2 stale notices
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if remotes then
        local showNotice = remotes:FindFirstChild("RE_ShowNotice")
        if showNotice then
            showNotice:FireClient(player, code, severity, messageKey, extra)
        end
    end
end

--------------------------------------------------------------------------------
-- S-29.2: staleCounts API (OrderService에서 사용)
--------------------------------------------------------------------------------

--[[
    S-29.2: staleCounts 조회 (안전 접근)
    @param player: Player 인스턴스
    @param dishKey: string (e.g., "dish_1")
    @return { [0]=int, [1]=int, [2]=int } or nil
]]
function DataService:GetStaleCounts(player, dishKey)
    local playerData = self:GetPlayerData(player)
    if not playerData or not playerData.staleCounts then
        return nil
    end
    return playerData.staleCounts[dishKey]
end

--[[
    S-29.2: staleCounts 버킷 값 조회 (안전 접근, 기본값 0)
    @param player: Player 인스턴스
    @param dishKey: string
    @param level: 0|1|2
    @return int
]]
function DataService:GetStaleBucketValue(player, dishKey, level)
    local playerData = self:GetPlayerData(player)
    return GetStaleBucket(playerData and playerData.staleCounts, dishKey, level)
end

--[[
    S-29.2: staleCounts 버킷 값 설정
    @param player: Player 인스턴스
    @param dishKey: string
    @param level: 0|1|2
    @param value: int
]]
function DataService:SetStaleBucketValue(player, dishKey, level, value)
    local playerData = self:GetPlayerData(player)
    if not playerData then return end

    if not playerData.staleCounts then
        playerData.staleCounts = {}
    end

    SetStaleBucket(playerData.staleCounts, dishKey, level, value)
    self:MarkDirty(player)
end

--[[
    S-29.2: staleCounts 버킷 증가
    @param player: Player 인스턴스
    @param dishKey: string
    @param level: 0|1|2
    @param delta: int (기본값 1)
]]
function DataService:IncrementStaleBucket(player, dishKey, level, delta)
    delta = delta or 1
    local current = self:GetStaleBucketValue(player, dishKey, level)
    self:SetStaleBucketValue(player, dishKey, level, current + delta)
end

--[[
    S-29.2: staleCounts 버킷 감소 (음수 방지)
    @param player: Player 인스턴스
    @param dishKey: string
    @param level: 0|1|2
    @param delta: int (기본값 1)
    @return bool: 성공 여부 (음수면 false)
]]
function DataService:DecrementStaleBucket(player, dishKey, level, delta)
    delta = delta or 1
    local current = self:GetStaleBucketValue(player, dishKey, level)

    if current < delta then
        -- 음수 방지: STALE_HEAL_WARN
        local uid = player.UserId
        print(string.format(
            "[DataService] S-29.2|STALE_HEAL_WARN uid=%d dishKey=%s reason=negative_source level=%d current=%d delta=%d",
            uid, dishKey, level, current, delta
        ))
        return false
    end

    self:SetStaleBucketValue(player, dishKey, level, current - delta)
    return true
end

--[[
    S-29.2: stale-first 선택 (level 2→1→0 우선순위)
    예약 시 가장 높은 stale 레벨에서 1개 소비

    @param player: Player 인스턴스
    @param dishKey: string
    @return level: 0|1|2|nil (nil = 재고 없음)
]]
function DataService:SelectStaleFirst(player, dishKey)
    -- stale-first: 2 → 1 → 0 순서로 확인
    for level = 2, 0, -1 do
        local count = self:GetStaleBucketValue(player, dishKey, level)
        if count > 0 then
            return level
        end
    end
    return nil  -- 재고 없음
end

--[[
    S-29.2: 새 dish 추가 시 Fresh(0) 버킷에 추가
    CraftingService에서 호출

    @param player: Player 인스턴스
    @param dishKey: string
    @param count: int (기본값 1)
]]
function DataService:AddFreshDish(player, dishKey, count)
    count = count or 1
    self:IncrementStaleBucket(player, dishKey, 0, count)
end

--[[
    S-29.2: StaleNoticeCache 확인 (세션 1회 정책)
    @param player: Player 인스턴스
    @param dishKey: string
    @param level: 0|1|2|3
    @return bool: 이미 보냈으면 true
]]
function DataService:HasSentStaleNotice(player, dishKey, level)
    local uid = player.UserId
    local cache = StaleNoticeCache[uid]
    if not cache then return false end

    local key = dishKey .. "_" .. tostring(level)
    return cache[key] == true
end

--[[
    S-29.2: StaleNoticeCache 기록 (세션 1회 정책)
    @param player: Player 인스턴스
    @param dishKey: string
    @param level: 0|1|2|3
]]
function DataService:MarkStaleNoticeSent(player, dishKey, level)
    local uid = player.UserId
    if not StaleNoticeCache[uid] then
        StaleNoticeCache[uid] = {}
    end

    local key = dishKey .. "_" .. tostring(level)
    StaleNoticeCache[uid][key] = true
end

return DataService
