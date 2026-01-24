-- Server/Services/OrderService.lua
-- SSOT v0.2.3.3 / Contract v1.3 Addendum
-- 역할: RE_DeliverOrder 서버 처리 로직
-- Phase 3: Step 3 코인 보정 (튜토리얼 §4)
-- Phase 0: Soft-Lock 방지 - RefillOrders, rotate, ValidateBoardEscapePath

local Players = game:GetService("Players")
local ServerFlags = require(game.ReplicatedStorage.Shared.ServerFlags)
local GameData = require(game.ReplicatedStorage.Shared.GameData)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- P3 패치: W3NextLogger 상단 1회 require (함수 내 중복 require 제거)
local W3NextLogger = require(game.ServerScriptService.Server.Shared.W3NextLogger)

-- Phase 3: GATE3 로깅용
local IS_STUDIO = RunService:IsStudio()
local DataService = nil  -- 순환 참조 방지, 지연 로드

-- Phase 6: RemoteHandler 의존성 주입 (rotate 동기화용)
local _remoteHandler = nil

local OrderService = {}
OrderService.__index = OrderService

--[[
    플레이어별 런타임 상태 (DataStore 저장 X)
    - sessionNotSaved: UpdateAsync 최종 실패 시 true
    - sessionCoinEarned: sessionNotSaved 상태에서 Step3 1회 보상 지급 여부
    - tutorialState: "ACTIVE" | "RECOVERY"
]]
local PlayerSessionState = {}

--[[
    Phase 0: 주문 슬롯 lastMutatedAt 추적 (런타임, DataStore 저장 X)
    OrderStamp[userId][slotId] = os.time()

    SEALED: 모든 슬롯 변경 시 갱신 (refill/rotate/smart_swap/failsafe)
]]
local OrderStamp = {}

--[[
    Phase 0: Fail-Safe 사용 추적 (세션당 1회 제한)
    FailSafeUsedThisSession[userId] = true
]]
local FailSafeUsedThisSession = {}

--[[
    P1-ORDER-INVARIANT: 슬롯 보호(LOCK) 테이블
    LockedSlot[userId][slotId] = true/nil

    목적: Craft 승인 후 해당 슬롯의 recipeId가 rotate/reroll/refill로 변경되지 않도록 보호
    LOCK 트리거: CraftingService에서 Craft 승인(isActive=true) 시점
    LOCK 해제: Deliver 성공 / PlayerRemoving

    SEALED: DataStore 저장 안 함 (세션 메모리 only)
]]
local LockedSlot = {}

--[[
    PG-1: Cook 미니게임 점수 저장 (런타임 전용)
    OrderCookScores[userId][slotId] = { cookScore = number, sessionId = string }

    목적: SubmitCookTap에서 계산된 cookScore를 DeliverOrder에서 팁 계산에 사용
    설정: CraftingService:SubmitCookTap → OrderService:SetCookScore (Push)
    읽기: OrderService:DeliverOrder → GetCookScore (기본값 1.0)
    정리: CleanupPlayer 시 전체 삭제

    NOTE: DataStore 저장 안 함 (재접속 시 기본값 1.0 적용)
]]
local OrderCookScores = {}

--------------------------------------------------------------------------------
-- 지연 로드 헬퍼 (순환 참조 방지)
--------------------------------------------------------------------------------

local function GetDataService()
    if not DataService then
        DataService = require(game.ServerScriptService.Server.Services.DataService)
    end
    return DataService
end

--------------------------------------------------------------------------------
-- P2-FIX: W3-NEXT run lifecycle 정리 헬퍼
-- DeliverOrder의 모든 반환 경로(성공/실패)에서 호출
-- "서비스가 run lifecycle을 소유"하는 구조
--------------------------------------------------------------------------------

local function finalizeW3Next(userId, slotId)
    local run_id = W3NextLogger.GetRunId(userId, slotId)
    if run_id then
        W3NextLogger.ClearStopped(run_id)
        W3NextLogger.ClearTrackACache(run_id)
    end
    W3NextLogger.ClearRunId(userId, slotId)
end

--------------------------------------------------------------------------------
-- v6.2: 정책 위반 시 slot lock 해제 헬퍼
-- 처리 순서: 락 해제 → W3Next 정리 → 주문 폐기 → Refill
-- reason_tag: "policy_violation" (운영 로그 추적용)
--------------------------------------------------------------------------------

local function clearPolicyViolationLock(orderService, userId, slotId)
    if orderService:IsSlotLocked(userId, slotId) then
        orderService:SetSlotLock(userId, slotId, false, "policy_violation")
    end
end

--------------------------------------------------------------------------------
-- 초기화
--------------------------------------------------------------------------------

-- Init 부수효과별 idempotent 가드
-- _rotateTimerStarted: 무한 루프 타이머 (취소 불가, spawn 직전 세팅)
-- _playerAddedConn: 이벤트 커넥션 핸들 (nil 체크로 idempotent)
local _rotateTimerStarted = false
local _playerAddedConn = nil

--------------------------------------------------------------------------------
-- Phase 6: RemoteHandler 의존성 주입
--------------------------------------------------------------------------------

function OrderService:SetRemoteHandler(handler)
    _remoteHandler = handler
    print("[OrderService] RemoteHandler 주입 완료")
end

function OrderService:Init()
    -- 이미 모든 부수효과가 설치된 경우 스킵
    if _rotateTimerStarted and _playerAddedConn then
        warn(string.format(
            "[OrderService] INIT_SKIPPED timer_started=%s playerAdded_connected=%s",
            tostring(_rotateTimerStarted),
            tostring(_playerAddedConn ~= nil)
        ))
        return
    end

    -- 부분 상태 로그 (디버깅용)
    if _rotateTimerStarted or _playerAddedConn then
        print(string.format(
            "[OrderService] INIT_PARTIAL timer_started=%s playerAdded_connected=%s",
            tostring(_rotateTimerStarted),
            tostring(_playerAddedConn ~= nil)
        ))
    end

    -- ============================================================
    -- 부수효과 1: 전역 rotate 타이머 (Phase 0)
    -- 주의: 서버 수명 동안 단 1회만 실행되는 전역 루프
    -- xpcall 가드: 루프 크래시 시 재시도 가능하도록 롤백
    -- ============================================================
    if not _rotateTimerStarted then
        _rotateTimerStarted = true  -- spawn 직전 세팅 (중복 루프 방지 우선)
        task.spawn(function()
            local success, err = xpcall(function()
                self:StartGlobalRotateTimer()
            end, debug.traceback)

            if not success then
                _rotateTimerStarted = false  -- 롤백: 다음 Init에서 재시도 가능
                warn(string.format(
                    "[OrderService] ROTATE_TIMER_CRASH err=%s",
                    tostring(err)
                ))
            end
        end)
        print("[OrderService] ROTATE_TIMER_STARTED")
    end

    -- ============================================================
    -- 부수효과 2: PlayerAdded 핸들러 (Phase 0)
    -- ============================================================
    if not _playerAddedConn then
        _playerAddedConn = Players.PlayerAdded:Connect(function(player)
            task.spawn(function()
                local DS = GetDataService()
                local maxWait = 5
                local interval = 0.25
                local elapsed = 0

                while elapsed < maxWait do
                    if not player.Parent then return end

                    local playerData = DS:GetPlayerData(player)
                    if playerData and playerData.orders then
                        break
                    end

                    task.wait(interval)
                    elapsed = elapsed + interval
                end

                if not player.Parent then return end

                local playerData = DS:GetPlayerData(player)
                if not playerData then
                    warn(string.format(
                        "[OrderService] WARN|PLAYER_DATA_TIMEOUT uid=%d elapsed=%.1f",
                        player.UserId, elapsed
                    ))
                    return
                end

                self:InitOrderStamp(player)
                self:InitW3NextForExistingOrders(player)  -- Track B Fix: 기존 Hard 주문 run_id 초기화

                local escapeResult = self:ValidateBoardEscapePath(player, nil)
                if escapeResult then
                    print(string.format(
                        "[OrderService] ESCAPE_VALIDATE source=player_added uid=%d slot=%d elapsed=%.2f",
                        player.UserId, escapeResult, elapsed
                    ))
                end
            end)
        end)
    end

    print("[OrderService] 초기화 완료 (Phase 0: rotate 타이머 + PlayerAdded 핸들러)")
end

--[[
    Phase 0: 전역 rotate 타이머 (서버 전역 1개)
    SEALED: 플레이어별 타이머 금지 (메모리/스케줄러 부하 방지)
]]
function OrderService:StartGlobalRotateTimer()
    while true do
        task.wait(ServerFlags.ORDER_REFRESH_SECONDS)

        for _, player in ipairs(Players:GetPlayers()) do
            task.spawn(function()
                self:rotate_one_slot(player)
            end)
        end
    end
end

function OrderService:GetSessionState(player)
    local userId = player.UserId
    if not PlayerSessionState[userId] then
        PlayerSessionState[userId] = {
            sessionNotSaved = false,
            sessionCoinEarned = false,
            tutorialState = "ACTIVE",
        }
    end
    return PlayerSessionState[userId]
end

function OrderService:SetSessionNotSaved(player, value)
    local state = self:GetSessionState(player)
    state.sessionNotSaved = value
end

function OrderService:CleanupPlayer(player)
    local userId = player.UserId
    PlayerSessionState[userId] = nil
    OrderStamp[userId] = nil
    FailSafeUsedThisSession[userId] = nil

    -- P1-ORDER-INVARIANT: LOCK 정리 (PlayerRemoving)
    if LockedSlot[userId] then
        print(string.format(
            "[OrderService] LOCK_CLEAR userId=%d slot=ALL reason=player_leave",
            userId
        ))
        LockedSlot[userId] = nil
    end

    -- PG-1: cookScore 정리 (PlayerRemoving)
    if OrderCookScores[userId] then
        OrderCookScores[userId] = nil
    end
end

--------------------------------------------------------------------------------
-- P1-ORDER-INVARIANT: 슬롯 LOCK API
--------------------------------------------------------------------------------

--[[
    슬롯 LOCK 설정/해제
    @param userId: number
    @param slotId: number
    @param locked: boolean
    @param reason: string (로그용: "craft_accept", "deliver_success", "craft_failed")
]]
function OrderService:SetSlotLock(userId, slotId, locked, reason)
    if not LockedSlot[userId] then
        LockedSlot[userId] = {}
    end

    if locked then
        LockedSlot[userId][slotId] = true
        -- recipeId 가져오기 (로그용)
        local DS = GetDataService()
        local players = game:GetService("Players")
        local player = players:GetPlayerByUserId(userId)
        local playerData = player and DS:GetPlayerData(player)
        local recipeId = playerData and playerData.orders and playerData.orders[slotId] and playerData.orders[slotId].recipeId or 0

        print(string.format(
            "[OrderService] LOCK_SET userId=%d slot=%d recipeId=%d reason=%s",
            userId, slotId, recipeId, reason or "unknown"
        ))
    else
        LockedSlot[userId][slotId] = nil
        print(string.format(
            "[OrderService] LOCK_CLEAR userId=%d slot=%d reason=%s",
            userId, slotId, reason or "unknown"
        ))
    end
end

--[[
    슬롯 LOCK 상태 확인
    @param userId: number
    @param slotId: number
    @return boolean
]]
function OrderService:IsSlotLocked(userId, slotId)
    return LockedSlot[userId] and LockedSlot[userId][slotId] == true
end

--------------------------------------------------------------------------------
-- PG-1: CookScore API (런타임 전용)
--------------------------------------------------------------------------------

--[[
    Cook 미니게임 점수 설정 (CraftingService에서 Push)
    @param userId: number
    @param slotId: number
    @param cookScore: number (0.0 ~ 1.0)
    @param sessionId: string (세션 검증용)
    @return boolean (성공 여부)
]]
function OrderService:SetCookScore(userId, slotId, cookScore, sessionId)
    if not userId or not slotId or not cookScore then
        warn("[OrderService] SetCookScore: missing required params")
        return false
    end

    if not OrderCookScores[userId] then
        OrderCookScores[userId] = {}
    end

    OrderCookScores[userId][slotId] = {
        cookScore = cookScore,
        sessionId = sessionId,
    }

    print(string.format(
        "[OrderService] COOKSCORE_SET userId=%d slot=%d score=%.2f sessionId=%s",
        userId, slotId, cookScore, sessionId or "nil"
    ))

    return true
end

--[[
    Cook 미니게임 점수 조회 (DeliverOrder에서 사용)
    @param userId: number
    @param slotId: number
    @return number (기본값 1.0 - 미니게임 미사용 or 재접속)
]]
function OrderService:GetCookScore(userId, slotId)
    if OrderCookScores[userId] and OrderCookScores[userId][slotId] then
        local entry = OrderCookScores[userId][slotId]
        -- Deliver 후 정리 (1회성)
        OrderCookScores[userId][slotId] = nil
        return entry.cookScore
    end
    return 1.0  -- 기본값: timer 모드 / 재접속 / Feature Flag OFF
end

--[[
    recipeId로 해당 슬롯 찾기 (LOCK 설정용)
    @param player: Player
    @param recipeId: number
    @return slotId: number? (없으면 nil)
]]
function OrderService:GetSlotByRecipeId(player, recipeId)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        return nil
    end

    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local order = playerData.orders[slotId]
        if order and order.recipeId == recipeId then
            return slotId
        end
    end

    return nil
end

--[[
    모든 슬롯이 LOCK 상태인지 확인 (All Locked Skip Safety)
    @param userId: number
    @return boolean
]]
function OrderService:AreAllSlotsLocked(userId)
    if not LockedSlot[userId] then
        return false
    end

    local lockedCount = 0
    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        if LockedSlot[userId][slotId] then
            lockedCount = lockedCount + 1
        end
    end

    return lockedCount >= ServerFlags.ORDER_SLOT_COUNT
end

--------------------------------------------------------------------------------
-- Phase 0: OrderStamp 관리 (lastMutatedAt)
--------------------------------------------------------------------------------

--[[
    OrderStamp 초기화 (플레이어 조인 시 또는 최초 접근 시)
    SEALED: 기존 주문은 현재 시간으로 초기화 (서버 리스타트 허용)
]]
function OrderService:InitOrderStamp(player)
    local userId = player.UserId
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        OrderStamp[userId] = {}
        return
    end

    local now = os.time()
    OrderStamp[userId] = {}

    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        if playerData.orders[slotId] then
            OrderStamp[userId][slotId] = now
        end
    end
end

--[[
    W3-NEXT 캐시 초기화 (기존 주문 로드 시)
    Track B Fix: 세션 시작 시 로드된 Hard 주문에 대해 run_id 초기화

    문제: DataStore에서 로드된 주문은 ORDER_CREATED 로그 없이 존재
          → Craft 시작 시 MISSING_RUN_ID 발생 (run_id 캐시가 비어있음)
    해결: 세션 시작 시 기존 Hard 주문에 대해 LogOrderCreated 호출하여 run_id 초기화
]]
function OrderService:InitW3NextForExistingOrders(player)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        return
    end

    local initializedCount = 0
    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local order = playerData.orders[slotId]
        if order and order.recipeId then
            -- LogOrderCreated는 내부에서 Hard 여부 체크 (non-Hard는 무시됨)
            local run_id = W3NextLogger.LogOrderCreated({
                recipeId = order.recipeId,
                userId = player.UserId,
                slotId = slotId,
            })
            if run_id then
                initializedCount = initializedCount + 1
            end
        end
    end

    if IS_STUDIO and initializedCount > 0 then
        print(string.format(
            "[OrderService] W3NEXT_INIT uid=%d hardOrdersInitialized=%d",
            player.UserId, initializedCount
        ))
    end
end

--[[
    OrderStamp 갱신 (슬롯 변경 시)
]]
function OrderService:UpdateOrderStamp(player, slotId)
    local userId = player.UserId
    if not OrderStamp[userId] then
        self:InitOrderStamp(player)
    end
    OrderStamp[userId][slotId] = os.time()
end

--[[
    OrderStamp 조회
]]
function OrderService:GetOrderStamp(player, slotId)
    local userId = player.UserId
    if not OrderStamp[userId] then
        self:InitOrderStamp(player)
    end
    return OrderStamp[userId][slotId] or 0
end

--------------------------------------------------------------------------------
-- Phase 0: 주문 생성 (2단계 샘플링)
--------------------------------------------------------------------------------

--[[
    난이도별 레시피 ID 목록 반환
]]
local function getRecipesByDifficulty(difficulty)
    local result = {}
    for _, recipeId in ipairs(GameData.GetAllRecipeIds()) do
        local recipe = GameData.GetRecipeById(recipeId)
        if recipe and recipe.difficulty == difficulty then
            table.insert(result, recipeId)
        end
    end
    return result
end

--[[
    난이도별 레시피 (fallback 체인 포함)
    SEALED: Hard → Medium → Easy → 기본버거(1)
]]
local function getRecipesByDifficultyWithFallback(difficulty)
    local chain = {"Hard", "Medium", "Easy"}
    local startIdx = 1

    for i, d in ipairs(chain) do
        if d == difficulty then
            startIdx = i
            break
        end
    end

    for i = startIdx, #chain do
        local recipes = getRecipesByDifficulty(chain[i])
        if #recipes > 0 then
            return recipes, chain[i]
        end
    end

    -- 최종 fallback: 기본버거
    warn("ERROR|RECIPE_POOL_EMPTY|fallback=recipe_1")
    return {1}, "Fallback"
end

--[[
    가중치 기반 난이도 선택
    SEALED: Easy=50, Medium=35, Hard=15
]]
local function selectDifficultyWeighted()
    local weights = {
        {difficulty = "Easy", weight = 50},
        {difficulty = "Medium", weight = 35},
        {difficulty = "Hard", weight = 15},
    }

    local totalWeight = 0
    for _, w in ipairs(weights) do
        totalWeight = totalWeight + w.weight
    end

    local roll = math.random(1, totalWeight)
    local cumulative = 0

    for _, w in ipairs(weights) do
        cumulative = cumulative + w.weight
        if roll <= cumulative then
            return w.difficulty
        end
    end

    return "Easy"  -- fallback
end

--[[
    새 주문 생성 (2단계 샘플링)
    SEALED: craftable-only 전면 적용 금지

    @param slotId: number
    @param excludeRecipeId: number? (3개 동일 방지용)
]]
function OrderService:GenerateOrder(slotId, excludeRecipeId)
    -- 1단계: 난이도 가중치로 선택
    local difficulty = selectDifficultyWeighted()

    -- 2단계: 해당 난이도 레시피 중 균등 랜덤 (fallback 포함)
    local recipes, actualDifficulty = getRecipesByDifficultyWithFallback(difficulty)

    -- 3개 동일 방지: excludeRecipeId 제외
    local filteredRecipes = recipes
    if excludeRecipeId then
        filteredRecipes = {}
        for _, rid in ipairs(recipes) do
            if rid ~= excludeRecipeId then
                table.insert(filteredRecipes, rid)
            end
        end

        -- 폴백: 필터 후 후보 0개면 원본 사용 + 관측 로그
        if #filteredRecipes == 0 then
            filteredRecipes = recipes
            if IS_STUDIO then
                warn(string.format(
                    "[OrderService] VARIETY_FALLBACK slot=%d exclude=%d difficulty=%s actualDiff=%s filteredCount=0 totalCount=%d",
                    slotId, excludeRecipeId, difficulty, actualDifficulty, #recipes
                ))
            end
        end
    end

    local recipeId = filteredRecipes[math.random(1, #filteredRecipes)]
    local recipe = GameData.GetRecipeById(recipeId)

    return {
        slotId = slotId,
        recipeId = recipeId,
        reward = recipe and recipe.reward or 50,
    }
end

--------------------------------------------------------------------------------
-- Phase 0: RefillOrders (빈 슬롯 채우기)
--------------------------------------------------------------------------------

--[[
    빈 슬롯(nil) 채우기
    SEALED INVARIANT: 실행 후 orders[1..3] 중 nil = 0

    P-01: "3슬롯 레시피 모두 동일" 상태 회피 (가능한 경우)
    P-02: 후보 부족 시 중복 허용 + 관측 로그

    @param player: Player
    @return filledSlots: table (채워진 슬롯 ID 목록)
]]
function OrderService:RefillOrders(player)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData then
        warn("[OrderService] RefillOrders: no playerData")
        return {}
    end

    if not playerData.orders then
        playerData.orders = {}
    end

    local filledSlots = {}

    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        if not playerData.orders[slotId] then
            local newOrder = self:GenerateOrder(slotId)
            playerData.orders[slotId] = newOrder
            self:UpdateOrderStamp(player, slotId)
            table.insert(filledSlots, slotId)
        end
    end

    -- P-01: 3개 동일 방지 (Refill 후 3슬롯 모두 존재할 때)
    -- 조건: 3슬롯 모두 존재 + 모두 동일 + 이번에 새로 채운 슬롯이 있음
    local r1 = playerData.orders[1] and playerData.orders[1].recipeId
    local r2 = playerData.orders[2] and playerData.orders[2].recipeId
    local r3 = playerData.orders[3] and playerData.orders[3].recipeId

    if r1 and r2 and r3 and r1 == r2 and r2 == r3 and #filledSlots > 0 then
        -- reroll 대상: 이번에 새로 채운 슬롯 중 마지막 (기존 슬롯 보호)
        local targetSlot = filledSlots[#filledSlots]
        local rerolledOrder = self:GenerateOrder(targetSlot, r1)

        if rerolledOrder.recipeId ~= r1 then
            -- 재추첨 성공
            playerData.orders[targetSlot] = rerolledOrder
            self:UpdateOrderStamp(player, targetSlot)

            if IS_STUDIO then
                print(string.format(
                    "[OrderService] VARIETY_REROLL uid=%d slot=%d before=%d after=%d filledCount=%d",
                    player.UserId, targetSlot, r1, rerolledOrder.recipeId, #filledSlots
                ))
            end
        else
            -- 재추첨 실패 (후보 부족으로 같은 레시피 나옴) - P-02 폴백
            if IS_STUDIO then
                warn(string.format(
                    "[OrderService] VARIETY_REROLL_FAILED uid=%d slot=%d allSame=%d reason=no_alternative filledCount=%d",
                    player.UserId, targetSlot, r1, #filledSlots
                ))
            end
        end
    end

    -- W3-NEXT: ORDER_CREATED 로그 (리롤 완료 후 최종 recipeId 기준)
    -- P1 패치: 리롤 이후에 로그를 찍어야 최종 상태가 보장됨
    for _, slotId in ipairs(filledSlots) do
        local finalOrder = playerData.orders[slotId]
        if finalOrder then
            W3NextLogger.LogOrderCreated({
                recipeId = finalOrder.recipeId,
                userId = player.UserId,
                slotId = slotId,
            })
        end
    end

    if #filledSlots > 0 then
        DS:MarkDirty(player)

        if IS_STUDIO then
            local recipeIds = {}
            for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
                local order = playerData.orders[slotId]
                recipeIds[slotId] = order and order.recipeId or 0
            end
            print(string.format(
                "[OrderService] REFILL uid=%d slots=%s recipes=[%d,%d,%d]",
                player.UserId,
                table.concat(filledSlots, ","),
                recipeIds[1], recipeIds[2], recipeIds[3]
            ))
        end
    end

    return filledSlots
end

--------------------------------------------------------------------------------
-- Phase 0: GetFIFOSlot (가장 오래된 슬롯)
--------------------------------------------------------------------------------

--[[
    FIFO 슬롯 반환 (가장 오래된 슬롯)

    @param player: Player
    @param respectMinLifetime: bool (true면 MIN_LIFETIME 이내 슬롯 제외)
    @param excludeSlotId: number? (제외할 슬롯 ID)
    @return slotId: number? (nil이면 교체 가능한 슬롯 없음)
]]
function OrderService:GetFIFOSlot(player, respectMinLifetime, excludeSlotId)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        return nil
    end

    local now = os.time()
    local minLifetime = ServerFlags.ORDER_MIN_LIFETIME or 30
    local oldestSlot = nil
    local oldestTime = math.huge

    local userId = player.UserId

    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        -- nil 슬롯은 rotate 대상 아님 (INVARIANT)
        if playerData.orders[slotId] then
            -- excludeSlotId 체크
            if slotId ~= excludeSlotId then
                -- P1-ORDER-INVARIANT: LOCK 슬롯 제외 (I-07)
                if not self:IsSlotLocked(userId, slotId) then
                    local stamp = self:GetOrderStamp(player, slotId)
                    local age = now - stamp

                    -- MIN_LIFETIME 체크
                    local passesMinLifetime = (not respectMinLifetime) or (age >= minLifetime)

                    if passesMinLifetime and stamp < oldestTime then
                        oldestTime = stamp
                        oldestSlot = slotId
                    end
                end
            end
        end
    end

    return oldestSlot
end

--------------------------------------------------------------------------------
-- Phase 0: rotate_one_slot (주기적 교체)
--------------------------------------------------------------------------------

--[[
    FIFO로 1개 슬롯 교체
    SEALED INVARIANT: nil 개수는 변하지 않음 (nil 슬롯 미접촉)

    @param player: Player
    @return rotatedSlotId: number? (nil이면 교체 안 됨)
]]
function OrderService:rotate_one_slot(player)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    -- 가드 1: playerData 없으면 return
    if not playerData then return nil end

    -- 가드 2: orders 없으면 return
    if not playerData.orders then return nil end

    -- 가드 3: OrderStamp 초기화
    local userId = player.UserId
    if not OrderStamp[userId] then
        self:InitOrderStamp(player)
    end

    -- P1-ORDER-INVARIANT: All Locked Skip Safety (OI-04)
    if self:AreAllSlotsLocked(userId) then
        print(string.format(
            "[OrderService] ROTATE_SKIP userId=%d reason=all_slots_locked",
            userId
        ))
        return nil
    end

    -- FIFO 슬롯 선택 (MIN_LIFETIME 준수, excludeSlotId 없음)
    -- P1-ORDER-INVARIANT: GetFIFOSlot 내부에서 LOCK 슬롯 제외됨
    local targetSlot = self:GetFIFOSlot(player, true, nil)

    if not targetSlot then
        -- 모든 슬롯이 MIN_LIFETIME 이내 또는 일부 LOCK
        if IS_STUDIO then
            local stamps = {}
            local locks = {}
            for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
                stamps[slotId] = self:GetOrderStamp(player, slotId)
                locks[slotId] = self:IsSlotLocked(userId, slotId)
            end
            warn(string.format(
                "WARN|ROTATE_SKIPPED|uid=%d|minLifetime=%d|stamps=%s|locks=%s",
                player.UserId,
                ServerFlags.ORDER_MIN_LIFETIME,
                game:GetService("HttpService"):JSONEncode(stamps),
                game:GetService("HttpService"):JSONEncode(locks)
            ))
        end
        return nil
    end

    -- 새 주문 생성 및 교체
    local newOrder = self:GenerateOrder(targetSlot)
    playerData.orders[targetSlot] = newOrder
    self:UpdateOrderStamp(player, targetSlot)
    DS:MarkDirty(player)

    -- Track B-C: ROTATE path Hard 주문 run_id 초기화 (2026-01-18)
    -- LogOrderCreated는 내부에서 Hard 여부 체크 (non-Hard는 무시됨)
    W3NextLogger.LogOrderCreated({
        recipeId = newOrder.recipeId,
        userId = player.UserId,
        slotId = targetSlot,
    })

    if IS_STUDIO then
        print(string.format(
            "[OrderService] ROTATE uid=%d slot=%d newRecipe=%d",
            player.UserId, targetSlot, newOrder.recipeId
        ))
    end

    -- ValidateBoardEscapePath 실행 (1 tick 1 change: excludeSlotId 적용)
    self:ValidateBoardEscapePath(player, targetSlot)

    -- Phase 6: 클라이언트에 orders 동기화 (rotate 버그 수정)
    if _remoteHandler then
        local stamp = self:GetOrderStamp(player, targetSlot)
        _remoteHandler:BroadcastOrders(player, playerData.orders, {
            reason = "rotate",
            slot = targetSlot,
            stamp = stamp,
        })
    end

    return targetSlot
end

--------------------------------------------------------------------------------
-- Phase 0: 탈출 경로 검증 헬퍼
--------------------------------------------------------------------------------

--[[
    요리(Dish) 개수 카운트
]]
function OrderService:CountDishes(inventory)
    if not inventory then return 0 end

    local total = 0
    for itemKey, count in pairs(inventory) do
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
            total = total + count
        end
    end
    return total
end

--[[
    납품 가능한 주문 개수
]]
function OrderService:GetDeliverableOrderCount(playerData)
    if not playerData or not playerData.orders or not playerData.inventory then
        return 0
    end

    local count = 0
    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local order = playerData.orders[slotId]
        if order then
            local dishKey = "dish_" .. order.recipeId
            if playerData.inventory[dishKey] and playerData.inventory[dishKey] >= 1 then
                count = count + 1
            end
        end
    end
    return count
end

--[[
    레시피 제작 가능 여부
]]
function OrderService:CanCraftRecipe(inventory, recipe)
    if not inventory or not recipe or not recipe.ingredients then
        return false
    end

    for materialId, requiredCount in pairs(recipe.ingredients) do
        -- [B-0] 문자열 키 통일 (DataStore 직렬화 안전)
        local currentCount = inventory[tostring(materialId)] or 0
        if currentCount < requiredCount then
            return false
        end
    end
    return true
end

--[[
    제작 가능한 주문 존재 여부
]]
function OrderService:HasCraftableOrder(playerData)
    if not playerData or not playerData.orders or not playerData.inventory then
        return false
    end

    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local order = playerData.orders[slotId]
        if order then
            local recipe = GameData.GetRecipeById(order.recipeId)
            if recipe and self:CanCraftRecipe(playerData.inventory, recipe) then
                return true
            end
        end
    end
    return false
end

--[[
    탈출 경로 존재 여부 (dish_full 분기 포함)
    SEALED:
    - dish_full이면 held-dish 매칭만 escape
    - 아니면 held-dish 매칭 OR craftable이면 escape
]]
function OrderService:HasEscapePath(playerData)
    if not playerData then return false end

    local dishCount = self:CountDishes(playerData.inventory)
    local dishFull = dishCount >= ServerFlags.DISH_CAP_TOTAL
    local deliverableCount = self:GetDeliverableOrderCount(playerData)

    if dishFull then
        -- held-dish 매칭만 escape
        return deliverableCount > 0
    else
        -- held-dish 매칭 OR craftable이면 escape
        return deliverableCount > 0 or self:HasCraftableOrder(playerData)
    end
end

--[[
    보드에 있는 레시피 ID 목록
]]
function OrderService:GetBoardRecipeIds(playerData)
    local recipeIds = {}
    if not playerData or not playerData.orders then
        return recipeIds
    end

    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local order = playerData.orders[slotId]
        if order and order.recipeId then
            recipeIds[order.recipeId] = true
        end
    end
    return recipeIds
end

--[[
    보유한 모든 dish의 recipeId 목록 반환 (배열)
    Softlock 방지: Held Dish Guarantee용
]]
function OrderService:GetHeldDishRecipeIds(inventory)
    local recipeIds = {}
    if not inventory then return recipeIds end

    for itemKey, count in pairs(inventory) do
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" and count >= 1 then
            local recipeId = tonumber(itemKey:sub(6))
            if recipeId then
                table.insert(recipeIds, recipeId)
            end
        end
    end
    return recipeIds
end

--[[
    held dish 중 보드에 없는 recipeId 반환
]]
function OrderService:GetFirstHeldDishRecipeId(inventory, excludeRecipes)
    if not inventory then return nil end

    for itemKey, count in pairs(inventory) do
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" and count >= 1 then
            local recipeId = tonumber(itemKey:sub(6))
            if recipeId and (not excludeRecipes or not excludeRecipes[recipeId]) then
                return recipeId
            end
        end
    end

    -- fallback: 보드 중복 허용
    for itemKey, count in pairs(inventory) do
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" and count >= 1 then
            local recipeId = tonumber(itemKey:sub(6))
            if recipeId then
                return recipeId
            end
        end
    end

    return nil
end

--[[
    craftable 레시피 중 보드에 없는 recipeId 반환
]]
function OrderService:GetFirstCraftableRecipeId(inventory, excludeRecipes)
    if not inventory then return nil end

    -- 먼저 보드에 없는 것 찾기
    for _, recipeId in ipairs(GameData.GetAllRecipeIds()) do
        if not excludeRecipes or not excludeRecipes[recipeId] then
            local recipe = GameData.GetRecipeById(recipeId)
            if recipe and self:CanCraftRecipe(inventory, recipe) then
                return recipeId
            end
        end
    end

    -- fallback: 보드 중복 허용
    for _, recipeId in ipairs(GameData.GetAllRecipeIds()) do
        local recipe = GameData.GetRecipeById(recipeId)
        if recipe and self:CanCraftRecipe(inventory, recipe) then
            return recipeId
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Phase 0: ValidateBoardEscapePath (탈출구 1개 보장)
--------------------------------------------------------------------------------

--[[
    보드에 탈출 가능 주문 1개 보장
    SEALED: refill/rotate 후 1회 실행

    @param player: Player
    @param excludeSlotId: number? (방금 변경된 슬롯 - 1 tick 1 change)
    @return swappedSlotId: number? (nil이면 교체 안 됨)
]]
function OrderService:ValidateBoardEscapePath(player, excludeSlotId)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData then return nil end

    ----------------------------------------------------------------------------
    -- Held Dish Guarantee (Softlock 방지)
    -- 조건: 보유 dish가 있는데 납품 가능한 주문이 없으면 강제 교체
    -- 규칙: "제작 가능 여부"와 무관하게 보유 dish 납품 경로 보장
    ----------------------------------------------------------------------------
    local heldDishRecipeIds = self:GetHeldDishRecipeIds(playerData.inventory)
    local deliverableCount = self:GetDeliverableOrderCount(playerData)

    if #heldDishRecipeIds > 0 and deliverableCount == 0 then
        -- 보유 dish 중 하나라도 보드에 매칭되는 주문이 있는지 확인
        local boardRecipes = self:GetBoardRecipeIds(playerData)
        local hasMatchingOrder = false
        for _, dishRecipeId in ipairs(heldDishRecipeIds) do
            if boardRecipes[dishRecipeId] then
                hasMatchingOrder = true
                break
            end
        end

        if not hasMatchingOrder then
            -- 강제로 보유 dish에 맞는 주문 생성
            local targetSlot = self:GetFIFOSlot(player, false, excludeSlotId)  -- MIN_LIFETIME 무시
            if targetSlot then
                local forcedRecipeId = heldDishRecipeIds[1]  -- 첫 번째 보유 dish
                local recipe = GameData.GetRecipeById(forcedRecipeId)
                playerData.orders[targetSlot] = {
                    slotId = targetSlot,
                    recipeId = forcedRecipeId,
                    reward = recipe and recipe.reward or 50,
                }
                self:UpdateOrderStamp(player, targetSlot)
                DS:MarkDirty(player)

                -- W3-NEXT: Hard 레시피면 ORDER_CREATED 로그
                W3NextLogger.LogOrderCreated({
                    recipeId = forcedRecipeId,
                    userId = player.UserId,
                    slotId = targetSlot,
                })

                print(string.format(
                    "[OrderService] ESCAPE_HELD_DISH uid=%d slot=%d forcedRecipeId=%d reason=deliverable_zero",
                    player.UserId, targetSlot, forcedRecipeId
                ))
                return targetSlot
            end
        end
    end

    -- 이미 탈출 경로가 있으면 OK
    if self:HasEscapePath(playerData) then
        return nil
    end

    -- 탈출 경로 없음 → 강제 보장 필요
    local dishCount = self:CountDishes(playerData.inventory)
    local dishFull = dishCount >= ServerFlags.DISH_CAP_TOTAL
    local deliverableCount = self:GetDeliverableOrderCount(playerData)

    -- ESCAPE_PATH_BLOCKED + 교착 조건 → 즉시 Fail-Safe
    local isHardSoftLock = dishFull and deliverableCount == 0

    -- 교체 대상 슬롯 선택
    local respectMinLifetime = not isHardSoftLock  -- 교착이면 MIN_LIFETIME 무시
    local targetSlot = self:GetFIFOSlot(player, respectMinLifetime, excludeSlotId)

    if not targetSlot then
        -- 교체 가능한 슬롯 없음
        if isHardSoftLock then
            -- Hard Soft-Lock인데 교체도 못함 → Fail-Safe 실행
            warn(string.format(
                "WARN|ESCAPE_PATH_BLOCKED_HARD_SOFTLOCK|uid=%d|excludeSlot=%s|triggering_failsafe",
                player.UserId, tostring(excludeSlotId)
            ))
            return self:ExecuteFailSafeReroll(player, true)
        else
            warn(string.format(
                "WARN|ESCAPE_PATH_BLOCKED|uid=%d|excludeSlot=%s|reason=no_eligible_slot",
                player.UserId, tostring(excludeSlotId)
            ))
            return nil
        end
    end

    -- 보장 주문 생성
    local boardRecipes = self:GetBoardRecipeIds(playerData)
    local newRecipeId = nil
    local duplicateAllowed = false

    -- 1순위: held dish 중 보드에 없는 것
    newRecipeId = self:GetFirstHeldDishRecipeId(playerData.inventory, boardRecipes)

    if not newRecipeId then
        -- 2순위: craftable 중 보드에 없는 것 (dish_full이 아닐 때만)
        if not dishFull then
            newRecipeId = self:GetFirstCraftableRecipeId(playerData.inventory, boardRecipes)
        end
    end

    if not newRecipeId then
        -- 3순위: held dish 중복 허용
        newRecipeId = self:GetFirstHeldDishRecipeId(playerData.inventory, nil)
        if newRecipeId then
            duplicateAllowed = true
        end
    end

    if not newRecipeId then
        -- 4순위: craftable 중복 허용 (dish_full이 아닐 때만)
        if not dishFull then
            newRecipeId = self:GetFirstCraftableRecipeId(playerData.inventory, nil)
            if newRecipeId then
                duplicateAllowed = true
            end
        end
    end

    if not newRecipeId then
        -- 보장 주문 생성 불가 (held dish도 없고 craftable도 없음)
        warn(string.format(
            "WARN|ESCAPE_FORCED_FAILED|uid=%d|reason=no_valid_recipe",
            player.UserId
        ))
        return nil
    end

    -- 주문 교체
    local recipe = GameData.GetRecipeById(newRecipeId)
    playerData.orders[targetSlot] = {
        slotId = targetSlot,
        recipeId = newRecipeId,
        reward = recipe and recipe.reward or 50,
    }
    self:UpdateOrderStamp(player, targetSlot)
    DS:MarkDirty(player)

    local logType = duplicateAllowed and "ESCAPE_DUPLICATE_ALLOWED" or "ESCAPE_FORCED"
    if IS_STUDIO then
        print(string.format(
            "[OrderService] %s uid=%d slot=%d recipe=%d",
            logType, player.UserId, targetSlot, newRecipeId
        ))
    end

    return targetSlot
end

--------------------------------------------------------------------------------
-- Phase 0: Fail-Safe 리롤
--------------------------------------------------------------------------------

--[[
    Fail-Safe 리롤 실행 (세션당 1회 제한)

    @param player: Player
    @param ignoreRestrictions: bool (MIN_LIFETIME/exclude 무시)
    @return success: bool
]]
function OrderService:ExecuteFailSafeReroll(player, ignoreRestrictions)
    local userId = player.UserId

    -- 세션당 1회 제한 체크
    if FailSafeUsedThisSession[userId] then
        warn(string.format(
            "WARN|FAILSAFE_ALREADY_USED|uid=%d",
            userId
        ))
        return false
    end

    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData then return false end

    -- 강제 리롤: 모든 제한 무시하고 FIFO 슬롯에 탈출 가능 주문 넣기
    local targetSlot = self:GetFIFOSlot(player, false, nil)  -- 모든 제한 무시

    if not targetSlot then
        -- 주문 슬롯이 전부 nil인 경우 (비정상)
        targetSlot = 1
    end

    local boardRecipes = self:GetBoardRecipeIds(playerData)
    local newRecipeId = self:GetFirstHeldDishRecipeId(playerData.inventory, boardRecipes)

    if not newRecipeId then
        newRecipeId = self:GetFirstHeldDishRecipeId(playerData.inventory, nil)
    end

    if not newRecipeId then
        -- held dish가 없으면 craftable로
        local dishFull = self:CountDishes(playerData.inventory) >= ServerFlags.DISH_CAP_TOTAL
        if not dishFull then
            newRecipeId = self:GetFirstCraftableRecipeId(playerData.inventory, nil)
        end
    end

    if not newRecipeId then
        warn(string.format(
            "WARN|FAILSAFE_REROLL_FAILED|uid=%d|reason=no_valid_recipe",
            userId
        ))
        return false
    end

    -- 주문 교체
    local recipe = GameData.GetRecipeById(newRecipeId)
    playerData.orders[targetSlot] = {
        slotId = targetSlot,
        recipeId = newRecipeId,
        reward = recipe and recipe.reward or 50,
    }
    self:UpdateOrderStamp(player, targetSlot)
    DS:MarkDirty(player)

    -- 세션당 1회 플래그 설정
    FailSafeUsedThisSession[userId] = true

    print(string.format(
        "[OrderService] FAILSAFE_REROLL uid=%d slot=%d recipe=%d",
        userId, targetSlot, newRecipeId
    ))

    return true
end

--------------------------------------------------------------------------------
-- RE_DeliverOrder 처리 로직
--------------------------------------------------------------------------------

function OrderService:DeliverOrder(player, slotId, playerData)
    --[[
        playerData 구조 (외부에서 주입):
        {
            orders = { [slotId] = { recipeId, reward }, ... },
            inventory = { [itemId] = count, ... },
            wallet = { coins = number },
        }

        반환값:
        { success = bool, error = string?, updates = table? }
    ]]

    local sessionState = self:GetSessionState(player)

    ----------------------------------------------------------------------------
    -- 1. 기본 검증 (가장 먼저)
    ----------------------------------------------------------------------------

    -- 1-1. OrdersEnabled 체크
    if not ServerFlags.OrdersEnabled then
        return {
            success = false,
            error = "feature_disabled",
            noticeCode = "orders_disabled",
        }
    end

    -- 1-2. slotId 유효성 (1~3)
    if type(slotId) ~= "number" or slotId < 1 or slotId > ServerFlags.ORDER_SLOT_COUNT then
        return {
            success = false,
            error = "invalid_slot",
            noticeCode = "invalid_order_slot",
        }
    end

    -- 1-3. 해당 주문 슬롯 존재
    local order = playerData.orders[slotId]
    if not order then
        return {
            success = false,
            error = "no_order",
            noticeCode = "order_not_found",
        }
    end

    -- v6-B: Hard 주문 캐시 누수 방지를 위한 진입 상태 캡처
    local isHard = W3NextLogger.IsHardRecipe(order.recipeId)
    local hadRunIdAtEntry = isHard and (W3NextLogger.GetRunId(player.UserId, slotId) ~= nil) or false

    -- 1-4. 완성품 보유 확인 (recipeId를 dishId로 사용)
    local dishId = "dish_" .. order.recipeId
    local dishCount = playerData.inventory[dishId] or 0
    if dishCount < 1 then
        -- v6-B: Hard 주문 캐시 누수 방지
        if hadRunIdAtEntry then
            finalizeW3Next(player.UserId, slotId)
        end
        return {
            success = false,
            error = "no_dish",
            noticeCode = "dish_not_found",
        }
    end

    ----------------------------------------------------------------------------
    -- 2. sessionNotSaved 상태 분기
    ----------------------------------------------------------------------------

    if sessionState.sessionNotSaved then
        -- 2-1. sessionCoinEarned == true → 즉시 거절
        if sessionState.sessionCoinEarned then
            -- v6-B: Hard 주문 캐시 누수 방지
            if hadRunIdAtEntry then
                finalizeW3Next(player.UserId, slotId)
            end
            return {
                success = false,
                error = "recovery_locked",
                noticeCode = "save_fail_economy_locked",
            }
        end
        -- 2-2. sessionCoinEarned == false → Step3 1회 허용, 다음 단계 진행
    end

    ----------------------------------------------------------------------------
    -- 3. 주문 처리 (서버 커밋 구간)
    -- 이 단계가 "Step3 완료 처리 커밋"
    -- 아래는 하나의 원자적 처리 흐름
    ----------------------------------------------------------------------------

    -- (B) 패치: Hard 레시피인데 run_id 없으면 차단 (W3-NEXT 무결성 보장)
    -- 정상 케이스: ORDER_CREATED에서 run_id 생성됨
    -- 비정상 케이스: W3-NEXT 적용 전 생성된 주문, 또는 ORDER_CREATED 누락
    if W3NextLogger.IsHardRecipe(order.recipeId) then
        local run_id = W3NextLogger.GetRunId(player.UserId, slotId)
        if not run_id then
            warn(string.format("[W3-NEXT] DELIVER_BLOCKED_NO_RUN_ID uid=%d slot=%d recipeId=%d",
                player.UserId, slotId, order.recipeId))
            -- v6.2: 정책 위반 처리 순서 표준화 (락 해제 → W3Next 정리 → 주문 폐기 → Refill)
            clearPolicyViolationLock(self, player.UserId, slotId)
            finalizeW3Next(player.UserId, slotId)

            -- v6-A: Softlock 방지 - 주문 폐기 + Refill
            local oldRecipeId = order.recipeId
            playerData.orders[slotId] = nil
            -- v6.1-A: 명시적 Dirty 보장 (방어적 프로그래밍)
            GetDataService():MarkDirty(player)
            self:RefillOrders(player)
            local newOrder = playerData.orders[slotId]
            local newRecipeId = newOrder and newOrder.recipeId or 0

            -- v6.1-B: ORDER_REPLACED warn + 포맷 표준화
            warn(string.format("[W3-NEXT] ORDER_REPLACED slot=%d new_recipeId=%d uid=%d reason=%s old_recipeId=%d",
                slotId, newRecipeId, player.UserId, "NO_RUN_ID", oldRecipeId))

            return {
                success = false,
                error = "w3next_policy_violation",
                noticeCode = "order_policy_violation",
                updates = {
                    orders = playerData.orders,
                },
            }
        end
    end

    -- W3-NEXT: PRE_COMPLETION 로그 (Hard 레시피만, 보상 지급 직전)
    local logSuccess = W3NextLogger.LogPreCompletion({
        recipeId = order.recipeId,
        userId = player.UserId,
        slotId = slotId,
    })

    -- v5: Hard는 PRE_COMPLETION 로그 실패 시 즉시 차단 (3포인트 체인 강제)
    if W3NextLogger.IsHardRecipe(order.recipeId) and not logSuccess then
        warn(string.format("[W3-NEXT] DELIVER_BLOCKED_LOG_FAIL uid=%d slot=%d recipeId=%d",
            player.UserId, slotId, order.recipeId))
        -- v6.2: 정책 위반 처리 순서 표준화 (락 해제 → W3Next 정리 → 주문 폐기 → Refill)
        clearPolicyViolationLock(self, player.UserId, slotId)
        finalizeW3Next(player.UserId, slotId)

        -- v6-A: Softlock 방지 - 주문 폐기 + Refill
        local oldRecipeId = order.recipeId
        playerData.orders[slotId] = nil
        -- v6.1-A: 명시적 Dirty 보장 (방어적 프로그래밍)
        GetDataService():MarkDirty(player)
        self:RefillOrders(player)
        local newOrder = playerData.orders[slotId]
        local newRecipeId = newOrder and newOrder.recipeId or 0

        -- v6.1-B: ORDER_REPLACED warn + 포맷 표준화
        warn(string.format("[W3-NEXT] ORDER_REPLACED slot=%d new_recipeId=%d uid=%d reason=%s old_recipeId=%d",
            slotId, newRecipeId, player.UserId, "LOG_FAIL", oldRecipeId))

        return {
            success = false,
            error = "w3next_policy_violation",
            noticeCode = "order_policy_violation",
            updates = {
                orders = playerData.orders,
            },
        }
    end

    -- P2-FIX: W3-NEXT STOP 상태 확인 (mismatch 발생 시 보상 지급 차단)
    local isStopped, stopReason = W3NextLogger.IsStopped(player.UserId, slotId)
    if isStopped then
        warn(string.format("[W3-NEXT] DELIVER_BLOCKED uid=%d slot=%d reason=%s",
            player.UserId, slotId, stopReason or "UNKNOWN"))
        -- v6.2: 정책 위반 처리 순서 표준화 (락 해제 → W3Next 정리 → 주문 폐기 → Refill)
        clearPolicyViolationLock(self, player.UserId, slotId)
        finalizeW3Next(player.UserId, slotId)

        -- v6-A: Softlock 방지 - 주문 폐기 + Refill
        local oldRecipeId = order.recipeId
        playerData.orders[slotId] = nil
        -- v6.1-A: 명시적 Dirty 보장 (방어적 프로그래밍)
        GetDataService():MarkDirty(player)
        self:RefillOrders(player)
        local newOrder = playerData.orders[slotId]
        local newRecipeId = newOrder and newOrder.recipeId or 0

        -- v6.1-B: ORDER_REPLACED warn + 포맷 표준화
        warn(string.format("[W3-NEXT] ORDER_REPLACED slot=%d new_recipeId=%d uid=%d reason=%s old_recipeId=%d",
            slotId, newRecipeId, player.UserId, stopReason or "STOPPED", oldRecipeId))

        return {
            success = false,
            error = "w3next_policy_violation",
            noticeCode = "order_policy_violation",
            updates = {
                orders = playerData.orders,
            },
        }
    end

    local reward = order.reward  -- SSOT: OrderReward = RecipeReward (기본버거 = 50)

    --------------------------------------------------------------------------
    -- P2: Score/Tip 계산 (서버 권한 - I-P2-01, I-P2-02)
    -- PG-1: cookScore 적용 (I-02 구현 시 팁 계산에 반영)
    --------------------------------------------------------------------------
    local userId = player.UserId
    local cookScore = self:GetCookScore(userId, slotId)  -- 기본값 1.0 (timer/재접속)

    local score = "Good"  -- MVP: 항상 Good (채점 로직 확장은 P2.1+)
    local tip = math.floor(reward * 0.25)  -- MVP: 25% 고정 (I-P2-04)
    -- TODO(I-02): cookScore 기반 팁 계산: tip = floor(reward * 0.25 * cookScore)
    local totalRevenue = reward + tip  -- I-P2-04: TotalRevenue = Reward + Tip

    -- PG-1 로그: cookScore 추적 (I-02 구현 전 검증용)
    if cookScore ~= 1.0 then
        print(string.format(
            "[OrderService] DELIVER_COOKSCORE uid=%d slot=%d cookScore=%.2f",
            userId, slotId, cookScore
        ))
    end

    -- P1-ORDER-INVARIANT: LOCK 해제 (Deliver 성공 - 커밋 직전)
    if self:IsSlotLocked(userId, slotId) then
        self:SetSlotLock(userId, slotId, false, "deliver_success")
    end

    -- 3-1. 주문 슬롯 비움
    playerData.orders[slotId] = nil

    -- 3-2. 완성품 인벤토리 차감
    playerData.inventory[dishId] = dishCount - 1
    if playerData.inventory[dishId] <= 0 then
        playerData.inventory[dishId] = nil
    end

    -- 3-3. wallet.coins += totalRevenue (P2: reward + tip)
    playerData.wallet.coins = playerData.wallet.coins + totalRevenue

    --------------------------------------------------------------------------
    -- P2: Day 통계 누적 (성공 경로만, I-P2-03 준수)
    -- NOTE: 실패 경로는 절대 dayStats 건드리지 않음
    --------------------------------------------------------------------------
    if not playerData.dayStats then
        playerData.dayStats = {
            day = 1,
            ordersServed = 0,
            totalReward = 0,
            totalTip = 0,
        }
    end
    playerData.dayStats.ordersServed = playerData.dayStats.ordersServed + 1
    playerData.dayStats.totalReward = playerData.dayStats.totalReward + reward
    playerData.dayStats.totalTip = playerData.dayStats.totalTip + tip

    -- P2 로그: DELIVER_SETTLE (감리 검증용)
    print(string.format(
        "DELIVER_SETTLE uid=%d slot=%d reward=%d tip=%d total=%d wallet=%d score=%s",
        player.UserId, slotId, reward, tip, totalRevenue, playerData.wallet.coins, score
    ))

    --------------------------------------------------------------------------
    -- P3: threshold 자동 Day End 체크 (Contract v1.4 §5.9)
    -- P4: threshold 성공 시 클라이언트 알림 (Day Summary 트리거)
    -- NOTE: ordersServed 증가 직후 평가 (SSOT), dayBefore 기준 thresholdAt
    --------------------------------------------------------------------------
    local DS = GetDataService()
    if DS:CheckDayEndThreshold(player) then
        local result = DS:ProcessDayEnd(player, "threshold")
        -- P4: Success=true일 때만 클라이언트에 DayEndResponse 브로드캐스트
        if result and result.Success then
            if _remoteHandler then
                _remoteHandler:BroadcastDayEnd(player, result)
            else
                warn("[OrderService] BroadcastDayEnd skipped: _remoteHandler not set")
            end
        end
    end

    --------------------------------------------------------------------------
    -- 3-3b. Phase 3: Step 3 코인 보정 (튜토리얼 Step 4 진행 보장)
    -- 트리거: Order 성공 직후 (server_send 전)
    -- 조건: hasCompleted=false AND bonusGranted=false
    -- 공식: coins = max(coins, UpgradeCost), 보정량 상한 200
    --------------------------------------------------------------------------
    if playerData.tutorial and not playerData.tutorial.hasCompleted then
        if not playerData.tutorial.bonusGranted then
            local UpgradeCost = ServerFlags.UPGRADE_BASE_QUANTITY or 100
            local beforeCoins = playerData.wallet.coins

            -- 보정 적용: 최소 UpgradeCost 보장
            if beforeCoins < UpgradeCost then
                local bonus = math.min(UpgradeCost - beforeCoins, 200)
                playerData.wallet.coins = beforeCoins + bonus
            end

            -- 플래그 설정 (보정 여부와 관계없이 1회 체크 후 설정)
            playerData.tutorial.bonusGranted = true

            -- GATE3 보정 로그 (Evidence)
            if IS_STUDIO and ServerFlags.GATE3_LOG_ENABLED then
                local DS = GetDataService()
                local joinTs = DS:GetJoinTs(player) or 0

                print(string.format(
                    "[GATE3][bonus] uid=%d joinTs=%d before=%d after=%d cost=%d granted=true",
                    player.UserId,
                    joinTs,
                    beforeCoins,
                    playerData.wallet.coins,
                    UpgradeCost
                ))
            end
        end
    end

    -- 3-4. sessionCoinEarned = true (sessionNotSaved인 경우만)
    if sessionState.sessionNotSaved then
        sessionState.sessionCoinEarned = true
    end

    ----------------------------------------------------------------------------
    -- Track B FIX: W3-NEXT run lifecycle 정리 (RefillOrders 이전)
    -- 이유: RefillOrders가 같은 slotId에 새 Hard 주문을 생성하면 새 run_id가 캐시됨
    --       이후 finalizeW3Next가 호출되면 새 run_id까지 삭제됨 (STOP|MISSING_RUN_ID)
    -- 수정: finalizeW3Next를 RefillOrders 이전으로 이동하여 새 run_id 보호
    ----------------------------------------------------------------------------
    finalizeW3Next(player.UserId, slotId)

    ----------------------------------------------------------------------------
    -- 3-5. Phase 0: 빈 슬롯 즉시 Refill + ValidateBoardEscapePath
    ----------------------------------------------------------------------------
    local filledSlots = self:RefillOrders(player)

    -- excludeSlotId = 방금 refill된 슬롯 (있으면)
    local excludeSlotId = filledSlots[1]
    self:ValidateBoardEscapePath(player, excludeSlotId)

    ----------------------------------------------------------------------------
    -- 4. 성공 응답 반환
    -- 오직 3단계가 전부 성공한 경우에만 도달
    -- 이 응답이 "Step3 완료 처리 성공 응답"의 정의
    ----------------------------------------------------------------------------

    local result = {
        success = true,
        -- P2: Score/Tip 필드 추가 (Contract v1.4)
        slotId = slotId,  -- SlotId Echo Policy
        recipeId = order.recipeId,
        reward = reward,
        score = score,
        tip = tip,
        totalRevenue = totalRevenue,
        walletCoins = playerData.wallet.coins,  -- I-P2-05: WalletCoins Echo Policy
        updates = {
            wallet = { coins = playerData.wallet.coins },
            orders = playerData.orders,
            inventory = playerData.inventory,
        },
        analytics = {
            event = "order_deliver",
            slotId = slotId,
            recipeId = order.recipeId,
            reward = reward,
            tip = tip,
            totalRevenue = totalRevenue,
        },
    }

    ----------------------------------------------------------------------------
    -- 5. RECOVERY 전환 트리거 (sessionNotSaved인 경우만)
    -- 성공 응답 반환 직후
    -- 다음 server-authoritative action 요청부터 모든 행동 서버 거절
    ----------------------------------------------------------------------------

    if sessionState.sessionNotSaved then
        sessionState.tutorialState = "RECOVERY"
        -- RECOVERY 상태 알림 추가
        result.recoveryTriggered = true
        result.noticeCode = "save_fail_reconnect"
    end

    -- Track B FIX: finalizeW3Next는 RefillOrders 이전으로 이동됨 (L1453)

    return result
end

--------------------------------------------------------------------------------
-- RECOVERY 상태 체크 (다른 서비스에서 호출)
--------------------------------------------------------------------------------

function OrderService:IsInRecovery(player)
    local state = self:GetSessionState(player)
    return state.tutorialState == "RECOVERY"
end

function OrderService:ShouldRejectAction(player)
    -- RECOVERY 상태면 모든 server-authoritative action 거절
    return self:IsInRecovery(player)
end

return OrderService
