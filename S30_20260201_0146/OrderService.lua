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
-- NOTE: S-24 함수들이 GetDataService를 사용하므로 먼저 정의해야 함
--------------------------------------------------------------------------------

local function GetDataService()
    if not DataService then
        DataService = require(game.ServerScriptService.Server.Services.DataService)
    end
    return DataService
end

-- PG-2: CustomerService 지연 로드
local CustomerService = nil
local function GetCustomerService()
    if not CustomerService then
        CustomerService = require(game.ServerScriptService.Server.Services.CustomerService)
    end
    return CustomerService
end

--------------------------------------------------------------------------------
-- S-24: Dish Reservation API
-- 목적: 동일 recipeId 주문 2개 + dish 1개일 때 2슬롯 동시 SERVE 활성화 방지
-- 저장: playerData.orders[slotId].reservedDishKey (DataStore 저장)
--------------------------------------------------------------------------------

--[[
    S-24: ReserveDish - dish 생성 시 해당 슬롯에 예약 설정
    @param player: Player
    @param slotId: number
    @param dishKey: string (예: "dish_5")
    @return boolean (성공 여부)
]]
function OrderService:ReserveDish(player, slotId, dishKey)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        warn(string.format("[OrderService] S-24|RESERVE_FAILED uid=%d slot=%d reason=no_data",
            player.UserId, slotId))
        return false
    end

    local order = playerData.orders[slotId]
    if not order then
        warn(string.format("[OrderService] S-24|RESERVE_FAILED uid=%d slot=%d reason=no_order",
            player.UserId, slotId))
        return false
    end

    -- S-29.2: stale-first 선택 (level 2→1→0 우선순위)
    -- NOTE: 버킷 차감은 하지 않음. 레벨 선택만 함.
    -- 차감 시점: Deliver 성공 또는 GraceExpired (승격/폐기)
    local reservedLevel = DS:SelectStaleFirst(player, dishKey)
    if reservedLevel == nil then
        -- staleCounts가 비어있으면 기존 호환: inventory 기준 Fresh(0)로 가정
        local invQty = playerData.inventory and playerData.inventory[dishKey] or 0
        if invQty > 0 then
            reservedLevel = 0  -- Fresh로 간주
        else
            warn(string.format("[OrderService] S-29.2|RESERVE_FAILED uid=%d slot=%d dishKey=%s reason=no_stock",
                player.UserId, slotId, dishKey))
            return false
        end
    end

    -- 예약 설정
    order.reservedDishKey = dishKey
    order.reservedStaleLevel = reservedLevel  -- S-29.2: 소비할 버킷 레벨 기록

    -- S-26: SERVE 유예 시간 설정 (rotate/cancel 보호)
    local graceSeconds = ServerFlags.SERVE_GRACE_SECONDS or 15
    order.serveDeadline = os.time() + graceSeconds

    DS:MarkDirty(player)

    -- 로깅 (S-24 Exit Evidence) - S-25: DEBUG 게이팅
    if ServerFlags.DEBUG_S24 then
        local invQty = playerData.inventory and playerData.inventory[dishKey] or 0
        print(string.format("[OrderService] S-24|RESERVE_DISH uid=%d slot=%d dishKey=%s invQty=%d staleLevel=%d",
            player.UserId, slotId, dishKey, invQty, reservedLevel))
    end

    return true
end

--[[
    S-24: ClearReservation - 주문 교체/취소 시 예약 해제
    @param player: Player
    @param slotId: number
    @param reason: string (로그용)
]]
function OrderService:ClearReservation(player, slotId, reason)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        return
    end

    local order = playerData.orders[slotId]
    if order and order.reservedDishKey then
        local oldDishKey = order.reservedDishKey
        local oldStaleLevel = order.reservedStaleLevel  -- S-29.2
        order.reservedDishKey = nil
        order.reservedStaleLevel = nil  -- S-29.2: stale 레벨도 정리
        order.serveDeadline = nil  -- S-26: 유예 시간도 정리
        DS:MarkDirty(player)

        -- S-25: DEBUG 게이팅 추가
        if IS_STUDIO and ServerFlags.DEBUG_S24 then
            print(string.format("[OrderService] S-24|RESERVATION_CLEARED uid=%d slot=%d dishKey=%s staleLevel=%s reason=%s",
                player.UserId, slotId, oldDishKey, tostring(oldStaleLevel), reason or "unknown"))
        end
    end
end

--[[
    S-24: ReconcileReservations - 기존 유저 데이터 마이그레이션
    패치 전 데이터에 reservedDishKey가 없으면 자동 부여 (softlock 방지)

    @param player: Player
    실행 시점: PlayerAdded 후, orders/inventory 로드 직후 1회
]]
function OrderService:ReconcileReservations(player)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders or not playerData.inventory then
        return
    end

    local userId = player.UserId
    local reconciledCount = 0
    local patchedSlots = {}

    -- S-24 Exit Evidence: 시작 로그 (dishKeys 수 포함)
    local dishKeyCount = 0
    for itemKey, _ in pairs(playerData.inventory) do
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
            dishKeyCount = dishKeyCount + 1
        end
    end
    print(string.format("[OrderService] S-24|RECONCILE_START uid=%d dishKeys=%d",
        userId, dishKeyCount))

    -- 각 dish의 사용 가능 수량 추적 (수량만큼만 예약)
    local availableDishes = {}
    for itemKey, count in pairs(playerData.inventory) do
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
            availableDishes[itemKey] = count
        end
    end

    -- slotId 오름차순으로 예약 배분
    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local order = playerData.orders[slotId]
        if order and order.recipeId then
            -- 이미 예약이 있으면 스킵
            if not order.reservedDishKey then
                local dishKey = "dish_" .. order.recipeId
                local available = availableDishes[dishKey] or 0

                if available >= 1 then
                    -- 예약 부여
                    order.reservedDishKey = dishKey
                    availableDishes[dishKey] = available - 1
                    reconciledCount = reconciledCount + 1
                    table.insert(patchedSlots, slotId)

                    -- S-25: DEBUG 게이팅
                    if ServerFlags.DEBUG_S24 then
                        print(string.format("[OrderService] S-24|RESERVE_DISH uid=%d slot=%d dishKey=%s invQty=%d (reconcile)",
                            userId, slotId, dishKey, available))
                    end
                end
            else
                -- 기존 예약이 있으면 availableDishes에서 차감
                local reservedKey = order.reservedDishKey
                if availableDishes[reservedKey] then
                    availableDishes[reservedKey] = availableDishes[reservedKey] - 1
                end
            end
        end
    end

    if reconciledCount > 0 then
        DS:MarkDirty(player)
    end

    -- S-24 Exit Evidence: 완료 로그 (항상 출력, patchedSlots 포함)
    local patchedStr = #patchedSlots > 0 and table.concat(patchedSlots, ",") or "none"
    print(string.format("[OrderService] S-24|RECONCILE_DONE uid=%d patchedSlots=%s",
        userId, patchedStr))
end

--[[
    S-24: IsSlotDeliverable - 슬롯에 배달 가능한 dish가 있는지 확인
    ESCAPE_HELD_DISH 다중 처리에서 이미 배달 가능한 슬롯 스킵용

    S-28: reservation 기반으로 변경
    - deliverable = "예약(reservedDishKey)이 있고" + "그 dish 수량이 1 이상"

    @param playerData: table (orders, inventory 포함)
    @param slotId: number
    @return boolean
]]
function OrderService:IsSlotDeliverable(playerData, slotId)
    local order = playerData.orders and playerData.orders[slotId]
    if not order or not order.recipeId then
        return false
    end
    -- S-28: reservation 없으면 deliverable 아님
    if not order.reservedDishKey then
        return false
    end
    local inv = playerData.inventory or {}
    local qty = inv[order.reservedDishKey] or 0
    return (tonumber(qty) or 0) >= 1
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
                self:ReconcileReservations(player)  -- S-24: 기존 유저 예약 마이그레이션

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
        return false, "INVALID_PARAMS"
    end

    if not OrderCookScores[userId] then
        OrderCookScores[userId] = {}
    end

    -- S-10: STALE_COOK_SESSION 방어 (감리자 승인 2026-01-25)
    -- 정책: 실패 시 기본값 1.0 적용 (게임 진행 보장)
    local existing = OrderCookScores[userId][slotId]
    if existing and existing.sessionId ~= sessionId then
        warn(string.format(
            "[OrderService] STALE_COOK_SESSION userId=%d slot=%d incoming=%s existing=%s",
            userId, slotId, sessionId or "nil", existing.sessionId or "nil"
        ))
        return false, "STALE_COOK_SESSION"
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

    -- PG-2: 새로 채운 슬롯에 Customer 스폰
    local CS = GetCustomerService()
    if CS and CS.SpawnCustomer then
        for _, slotId in ipairs(filledSlots) do
            CS:SpawnCustomer(player, slotId)
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
                    -- S-26: serveDeadline 유효한 슬롯 제외 (SERVE 대기 중)
                    local order = playerData.orders[slotId]
                    local deadline = order and order.serveDeadline
                    if deadline and deadline > now then
                        -- SERVE 유예 시간 내: rotate 대상 제외
                    else
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
    end

    return oldestSlot
end

--------------------------------------------------------------------------------
-- S-26: RotateSlot (슬롯 강제 교체 - 공용 함수)
--------------------------------------------------------------------------------

--[[
    특정 슬롯을 새 주문으로 교체 (rotate_one_slot, grace_expired에서 공용)

    @param player: Player
    @param slotId: number
    @param reason: string (timer_rotate, grace_expired_rotate 등)
    @return boolean (성공 여부)
]]
function OrderService:RotateSlot(player, slotId, reason)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        return false
    end

    -- nil 슬롯은 rotate 불가 (INVARIANT)
    if not playerData.orders[slotId] then
        return false
    end

    local userId = player.UserId

    -- S-24: 기존 주문의 예약 정리 (교체 전)
    self:ClearReservation(player, slotId, reason)

    -- 새 주문 생성 및 교체
    local newOrder = self:GenerateOrder(slotId)
    playerData.orders[slotId] = newOrder
    self:UpdateOrderStamp(player, slotId)
    DS:MarkDirty(player)

    -- Track B-C: ROTATE path Hard 주문 run_id 초기화
    W3NextLogger.LogOrderCreated({
        recipeId = newOrder.recipeId,
        userId = userId,
        slotId = slotId,
    })

    -- S-26.1: nil 방어 (로그 출력 전에 정의)
    local reasonStr = reason or ""

    -- S-26: 운영 로그 (reason 포함)
    print(string.format(
        "[OrderService] S-26|ROTATE uid=%d slot=%d newRecipe=%d reason=%s",
        userId, slotId, newOrder.recipeId, reasonStr
    ))

    -- S-26.1: grace_expired 사유일 때는 ESCAPE 스킵 (15초 페널티 유지)
    -- 이유: dish가 제때 납품되지 않은 것에 대한 페널티로 dish는 고아 상태로 유지
    local isGraceExpired = (reasonStr == "grace_expired_rotate" or reasonStr == "grace_expired_timeout")
    if isGraceExpired then
        -- Studio에서만 로그 출력 (운영 스팸 방지)
        if IS_STUDIO then
            print(string.format(
                "[OrderService] S-26.1|ESCAPE_SKIPPED uid=%d slot=%d reason=%s",
                userId, slotId, reasonStr
            ))
        end
    else
        -- ValidateBoardEscapePath 실행 (timer_rotate 등 일반 사유)
        self:ValidateBoardEscapePath(player, slotId)
    end

    -- 클라이언트에 orders 동기화
    -- S-29.2: inventory 포함 (STALE_DISCARD 후 인벤 변경 반영)
    if _remoteHandler then
        local stamp = self:GetOrderStamp(player, slotId)
        _remoteHandler:BroadcastOrders(player, playerData.orders, {
            reason = reason,
            slot = slotId,
            stamp = stamp,
        }, playerData.inventory)
    end

    return true
end

--------------------------------------------------------------------------------
-- S-26: HandleServeGraceExpired (유예 만료 즉시 후속 처리)
--------------------------------------------------------------------------------

--[[
    serveDeadline 만료 시 즉시 후속 처리 (CustomerService에서 호출)

    @param player: Player
    @param slotId: number
    @param patienceNow: number (현재 인내심)
]]
function OrderService:HandleServeGraceExpired(player, slotId, patienceNow)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData or not playerData.orders then
        return
    end

    local order = playerData.orders[slotId]
    if not order then
        return
    end

    -- 만료 확인 (이중 체크)
    if not order.serveDeadline then
        return
    end

    local now = os.time()
    if order.serveDeadline > now then
        return  -- 아직 만료 안 됨
    end

    -- serveDeadline 제거 (만료 처리 완료 마킹)
    order.serveDeadline = nil

    local uid = player.UserId

    ----------------------------------------------------------------------------
    -- S-29.2: Stale 승격/폐기 처리 (serveDeadline 만료 = 납품 실패)
    ----------------------------------------------------------------------------
    local dishKey = order.reservedDishKey
    local reservedLevel = order.reservedStaleLevel

    if dishKey and reservedLevel ~= nil then
        local inv = playerData.inventory and playerData.inventory[dishKey] or 0
        local b0 = DS:GetStaleBucketValue(player, dishKey, 0)
        local b1 = DS:GetStaleBucketValue(player, dishKey, 1)
        local b2 = DS:GetStaleBucketValue(player, dishKey, 2)

        -- 소스 버킷 확인
        local sourceCount = DS:GetStaleBucketValue(player, dishKey, reservedLevel)

        if sourceCount <= 0 then
            -- 가드: no-op + warn (음수 방지)
            print(string.format(
                "[OrderService] S-29.2|STALE_HEAL_WARN uid=%d dishKey=%s reason=negative_source level=%d current=%d",
                uid, dishKey, reservedLevel, sourceCount
            ))
        else
            local nextLevel = reservedLevel + 1

            if nextLevel >= 3 then
                -- Rotten(3): 자동 폐기
                -- 버킷에서 제거
                DS:DecrementStaleBucket(player, dishKey, reservedLevel, 1)

                -- inventory에서 제거
                if playerData.inventory and playerData.inventory[dishKey] then
                    playerData.inventory[dishKey] = playerData.inventory[dishKey] - 1
                    if playerData.inventory[dishKey] <= 0 then
                        playerData.inventory[dishKey] = nil
                    end
                end

                -- 로그
                print(string.format(
                    "[OrderService] S-29.2|STALE_DISCARD uid=%d dishKey=%s fromLevel=%d reason=stale_rotten inv=%d b0=%d b1=%d b2=%d",
                    uid, dishKey, reservedLevel, inv, b0, b1, b2
                ))

                -- 팝업 전송 (세션 1회) - A: dishKey 포함
                if not DS:HasSentStaleNotice(player, dishKey, 3) then
                    DS:MarkStaleNoticeSent(player, dishKey, 3)
                    DS:SendNotice(player, "stale_discard", "warning", "stale_discard", { dishKey = dishKey })
                    print(string.format(
                        "[OrderService] S-29.2|NOTICE_SENT uid=%d key=%s level=3",
                        uid, dishKey
                    ))
                end
            else
                -- 승격: level → level+1
                DS:DecrementStaleBucket(player, dishKey, reservedLevel, 1)
                DS:IncrementStaleBucket(player, dishKey, nextLevel, 1)

                -- 로그
                print(string.format(
                    "[OrderService] S-29.2|STALE_UPGRADE uid=%d dishKey=%s from=%d to=%d inv=%d b0=%d b1=%d b2=%d",
                    uid, dishKey, reservedLevel, nextLevel, inv, b0, b1, b2
                ))

                -- 팝업 전송 (세션 1회) - A: dishKey 포함
                if not DS:HasSentStaleNotice(player, dishKey, nextLevel) then
                    DS:MarkStaleNoticeSent(player, dishKey, nextLevel)
                    DS:SendNotice(player, "stale_upgrade", "warning", "stale_upgrade_" .. tostring(nextLevel), { dishKey = dishKey })
                    print(string.format(
                        "[OrderService] S-29.2|NOTICE_SENT uid=%d key=%s level=%d",
                        uid, dishKey, nextLevel
                    ))
                end
            end
        end
    end
    ----------------------------------------------------------------------------

    DS:MarkDirty(player)

    -- S-26: 운영 로그
    local action = (patienceNow <= 0) and "cancel" or "rotate"
    print(string.format(
        "[OrderService] S-26|GRACE_EXPIRED uid=%d slot=%d action=%s patience=%.1f",
        uid, slotId, action, patienceNow
    ))

    -- S-26/PG2 핫픽스: Customer 세션 정리 보장
    local CS = GetCustomerService()

    -- 분기: patience에 따라 cancel 또는 rotate
    if patienceNow <= 0 then
        -- 즉시 cancel (손님 이미 떠날 상태)
        local cancelled = self:CancelOrder(player, slotId, "grace_expired_timeout")
        if cancelled and CS then
            CS:RemoveCustomer(player, slotId, "grace_expired_timeout")
        end
    else
        -- 즉시 rotate (주문 교체)
        local rotated = self:RotateSlot(player, slotId, "grace_expired_rotate")
        if rotated and CS then
            CS:RespawnCustomer(player, slotId, "grace_expired_rotate")
        end
    end
end

--------------------------------------------------------------------------------
-- Phase 0: rotate_one_slot (주기적 교체)
--------------------------------------------------------------------------------

--[[
    FIFO로 1개 슬롯 교체 (타이머 기반)
    SEALED INVARIANT: nil 개수는 변하지 않음 (nil 슬롯 미접촉)

    S-26: 내부적으로 RotateSlot 호출

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
    -- S-26: GetFIFOSlot 내부에서 serveDeadline 슬롯도 제외됨
    local targetSlot = self:GetFIFOSlot(player, true, nil)

    if not targetSlot then
        -- 모든 슬롯이 MIN_LIFETIME 이내 또는 일부 LOCK 또는 serveDeadline 보호
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

    -- S-26: RotateSlot 공용 함수 호출 (코드 중복 제거)
    local success = self:RotateSlot(player, targetSlot, "timer_rotate")
    if not success then
        return nil
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
    if not playerData or not playerData.orders then
        return 0
    end

    -- S-28: IsSlotDeliverable() 호출로 통일 (reservation 기반)
    local count = 0
    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        if self:IsSlotDeliverable(playerData, slotId) then
            count = count + 1
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

    -- S-28: orphanCount 기반 트리거/스킵 판단 (기존 boardRecipes 방식 대체)
    -- SSOT: orphanCount = max(0, inventoryCount - reservedCount)

    -- 1) reservedCount 계산 (dishKey 기준)
    local reservedCount = {}
    for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
        local o = playerData.orders[slotId]
        if o and o.reservedDishKey then
            reservedCount[o.reservedDishKey] = (reservedCount[o.reservedDishKey] or 0) + 1
        end
    end

    -- 2) orphanCount 기반으로 "배정 가능한 orphan dish 존재" 판단
    local inv = playerData.inventory or {}
    local hasAssignableOrphan = false

    for _, rid in ipairs(heldDishRecipeIds) do
        local dishKey = "dish_" .. rid
        local invCount = tonumber(inv[dishKey] or 0) or 0
        local resCount = tonumber(reservedCount[dishKey] or 0) or 0
        local orphan = math.max(invCount - resCount, 0)

        if orphan > 0 then
            -- S-28 FIX: "배정 가능 슬롯" 존재 검사 (IsSlotDeliverable 기반)
            -- ESCAPE_MULTI_ASSIGN의 실제 배정 조건과 일치시킴
            for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
                if slotId ~= excludeSlotId then
                    local o = playerData.orders[slotId]
                    if o and not self:IsSlotDeliverable(playerData, slotId) then
                        hasAssignableOrphan = true
                        break
                    end
                end
            end
        end

        if hasAssignableOrphan then break end
    end

    if not hasAssignableOrphan then
        -- S-28: 배정 가능한 orphan 없음 → ESCAPE 스킵
        if ServerFlags.DEBUG_S24 then
            print(string.format("[OrderService] S-24|ESCAPE_SKIPPED uid=%d reason=no_assignable_orphan held=%d deliverable=%d",
                player.UserId, #heldDishRecipeIds, deliverableCount))
        end
    else
            -- 매칭 안 된 dish 있음 → ESCAPE 실행
            --------------------------------------------------------------------
            -- S-24 다중 처리: 보유 dish를 최대 3슬롯에 배치
            -- 규칙: 3동일 방지 (ORDER_VARIETY)
            --------------------------------------------------------------------

            -- 1. 보유 dish를 { dishKey, recipeId, qty } 형태로 수집
            local heldDishes = {}
            for itemKey, count in pairs(playerData.inventory) do
                if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" and count >= 1 then
                    local recipeId = tonumber(itemKey:sub(6))
                    if recipeId then
                        table.insert(heldDishes, {
                            dishKey = itemKey,
                            recipeId = recipeId,
                            qty = count,
                        })
                    end
                end
            end

            local dishKinds = #heldDishes
            local dishTotal = 0
            for _, d in ipairs(heldDishes) do
                dishTotal = dishTotal + d.qty
            end

            print(string.format(
                "[OrderService] S-24|ESCAPE_MULTI_START uid=%d dishKinds=%d dishTotal=%d",
                player.UserId, dishKinds, dishTotal
            ))

            -- 2. 슬롯별로 강제 주문 생성
            local assignedCount = 0
            local assignedRecipes = {}  -- 3동일 방지용
            local _escapeCS = GetCustomerService()  -- S-29.1: 루프 전 1회 캐시

            for slotId = 1, ServerFlags.ORDER_SLOT_COUNT do
                if slotId == excludeSlotId then
                    -- 방금 변경된 슬롯은 스킵
                elseif self:IsSlotDeliverable(playerData, slotId) then
                    -- 이미 납품 가능한 슬롯은 건드리지 않음
                else
                    -- 사용 가능한 dish 찾기
                    local selectedDish = nil
                    local selectedStaleLevel = nil
                    local fallbackStale2 = nil  -- S-29.2 버그픽스: Stale II only fallback
                    local DS = GetDataService()
                    for _, dish in ipairs(heldDishes) do
                        if dish.qty >= 1 then
                            -- 3동일 방지: 이미 2슬롯에 같은 recipeId가 있으면 스킵
                            local sameRecipeCount = assignedRecipes[dish.recipeId] or 0
                            if sameRecipeCount < 2 then
                                -- S-29.2: stale-first 선택 (2→1→0)
                                local staleLevel = DS:SelectStaleFirst(player, dish.dishKey)
                                if staleLevel == nil then
                                    staleLevel = 0  -- 호환: staleCounts 없으면 Fresh
                                end

                                -- S-29.2: stale >= 2면 ESCAPE 후보에서 후순위 (완전 배제 아님)
                                if staleLevel >= 2 then
                                    print(string.format(
                                        "[OrderService] S-29.2|ESCAPE_SKIP_STALE uid=%d dishKey=%s level=%d",
                                        player.UserId, dish.dishKey, staleLevel
                                    ))
                                    -- S-29.2 버그픽스: fallback 후보 기록 (첫 번째만)
                                    if not fallbackStale2 then
                                        fallbackStale2 = { dish = dish, level = staleLevel }
                                    end
                                else
                                    selectedDish = dish
                                    selectedStaleLevel = staleLevel
                                    break
                                end
                            end
                        end
                    end

                    -- S-29.2 버그픽스: Fresh/Stale-I 없고 Stale II만 있으면 fallback 사용
                    if not selectedDish and fallbackStale2 then
                        selectedDish = fallbackStale2.dish
                        selectedStaleLevel = fallbackStale2.level
                        print(string.format(
                            "[OrderService] S-29.2|ESCAPE_FALLBACK_STALE2 uid=%d dishKey=%s level=%d reason=no_alternative",
                            player.UserId, fallbackStale2.dish.dishKey, fallbackStale2.level
                        ))
                    end

                    if selectedDish then
                        -- S-24: 기존 주문의 예약 정리
                        self:ClearReservation(player, slotId, "escape_multi")

                        local recipe = GameData.GetRecipeById(selectedDish.recipeId)
                        local graceSeconds = ServerFlags.SERVE_GRACE_SECONDS or 15
                        playerData.orders[slotId] = {
                            slotId = slotId,
                            recipeId = selectedDish.recipeId,
                            reward = recipe and recipe.reward or 50,
                            reservedDishKey = selectedDish.dishKey,
                            reservedStaleLevel = selectedStaleLevel,  -- S-29.2: 소비할 버킷 레벨
                            serveDeadline = os.time() + graceSeconds,  -- S-26 호환: SERVE 유예 시간
                        }
                        self:UpdateOrderStamp(player, slotId)

                        -- qty 감소 및 카운트
                        selectedDish.qty = selectedDish.qty - 1
                        assignedRecipes[selectedDish.recipeId] = (assignedRecipes[selectedDish.recipeId] or 0) + 1
                        assignedCount = assignedCount + 1

                        -- W3-NEXT: Hard 레시피면 ORDER_CREATED 로그
                        W3NextLogger.LogOrderCreated({
                            recipeId = selectedDish.recipeId,
                            userId = player.UserId,
                            slotId = slotId,
                        })

                        -- S-25: DEBUG 게이팅
                        if ServerFlags.DEBUG_S24 then
                            print(string.format(
                                "[OrderService] S-24|ESCAPE_ASSIGN uid=%d slot=%d dishKey=%s recipeId=%d qtyLeft=%d",
                                player.UserId, slotId, selectedDish.dishKey, selectedDish.recipeId, selectedDish.qty
                            ))
                        end

                        -- S-29: CustomerService 동기화 (고객 리스폰)
                        -- S-29.1: _escapeCS는 루프 전 캐시됨
                        if _escapeCS and _escapeCS.RespawnCustomer then
                            _escapeCS:RespawnCustomer(player, slotId, "escape_multi")
                        end
                    end
                end
            end

            if assignedCount > 0 then
                DS:MarkDirty(player)

                -- S-24: 즉시 클라이언트 동기화
                if _remoteHandler then
                    _remoteHandler:BroadcastOrders(player, playerData.orders, {
                        reason = "escape_held_dish",
                    })
                    -- S-25: DEBUG 게이팅
                    if ServerFlags.DEBUG_S24 then
                        print(string.format(
                            "[OrderService] S-24|ESCAPE_BROADCAST_ORDERS uid=%d",
                            player.UserId
                        ))
                    end
                end

                -- S-25: 운영 유지 (저빈도 요약)
                print(string.format(
                    "[OrderService] S-24|ESCAPE_MULTI_DONE uid=%d assigned=%d",
                    player.UserId, assignedCount
                ))

                return 1  -- 첫 슬롯 반환 (호환성)
            end
        end
    -- S-28: 기존 외부 if 블록 end 제거됨 (orphanCount 기반으로 대체)

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

    -- S-24: 기존 주문의 예약 정리 (강제 교체 전)
    self:ClearReservation(player, targetSlot, "escape_forced")

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

    -- S-24: 기존 주문의 예약 정리 (failsafe 교체 전)
    self:ClearReservation(player, targetSlot, "failsafe_reroll")

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
    -- 1-5. S-24: 예약(Reservation) 검증 (SERVE 정합성 강제)
    ----------------------------------------------------------------------------
    local reservedDishKey = order.reservedDishKey
    local expectedDishKey = dishId  -- "dish_" .. order.recipeId

    -- S-24 로깅: SERVE_ELIGIBLE (진입점 1회) - S-25: DEBUG 게이팅
    if ServerFlags.DEBUG_S24 then
        print(string.format("[OrderService] S-24|SERVE_ELIGIBLE uid=%d slot=%d reserved=%s invQty=%d",
            player.UserId, slotId, reservedDishKey or "nil", dishCount))
    end

    -- 1-5a. 예약 존재 확인
    if not reservedDishKey then
        if hadRunIdAtEntry then
            finalizeW3Next(player.UserId, slotId)
        end
        print(string.format("[OrderService] S-24|SERVE_BLOCKED uid=%d slot=%d reason=no_reserved_dish",
            player.UserId, slotId))
        return {
            success = false,
            error = "no_reserved_dish",
            noticeCode = "serve_not_reserved",
        }
    end

    -- 1-5b. 예약-recipeId 일관성 검증 (reservation_mismatch 가드)
    if reservedDishKey ~= expectedDishKey then
        warn(string.format("[OrderService] S-24|RESERVATION_MISMATCH uid=%d slot=%d reserved=%s expected=%s",
            player.UserId, slotId, reservedDishKey, expectedDishKey))
        -- 예약 자동 정리
        order.reservedDishKey = nil
        if hadRunIdAtEntry then
            finalizeW3Next(player.UserId, slotId)
        end
        print(string.format("[OrderService] S-24|SERVE_BLOCKED uid=%d slot=%d reason=reservation_mismatch",
            player.UserId, slotId))
        return {
            success = false,
            error = "reservation_mismatch",
            noticeCode = "serve_reservation_error",
        }
    end

    -- 1-5c. 예약된 dish의 인벤토리 수량 확인 (이중 검증)
    local reservedQty = playerData.inventory[reservedDishKey] or 0
    if reservedQty < 1 then
        if hadRunIdAtEntry then
            finalizeW3Next(player.UserId, slotId)
        end
        print(string.format("[OrderService] S-24|SERVE_BLOCKED uid=%d slot=%d reason=insufficient_inventory",
            player.UserId, slotId))
        return {
            success = false,
            error = "insufficient_inventory",
            noticeCode = "serve_no_dish",
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

    -- S-29.2: 예약된 stale 레벨 캡처 (슬롯 비우기 전)
    local reservedStaleLevel = order.reservedStaleLevel

    -- 3-1. 주문 슬롯 비움
    playerData.orders[slotId] = nil

    -- 3-2. 완성품 인벤토리 차감
    playerData.inventory[dishId] = dishCount - 1
    if playerData.inventory[dishId] <= 0 then
        playerData.inventory[dishId] = nil
    end

    -- S-29.2: staleCounts 버킷 차감 (Deliver 성공 시)
    local DS = GetDataService()
    if reservedStaleLevel ~= nil then
        local decremented = DS:DecrementStaleBucket(player, dishId, reservedStaleLevel, 1)
        if not decremented then
            -- 이론상 발생 안 함 (Reserve에서 검증됨)
            warn(string.format(
                "[OrderService] S-29.2|DELIVER_DECREMENT_WARN uid=%d dishKey=%s level=%d",
                userId, dishId, reservedStaleLevel
            ))
        end
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
    -- PG-2: Customer Serve 처리 (Serve Path Exit Evidence)
    --------------------------------------------------------------------------
    local CS = GetCustomerService()
    if CS and CS.OnServed then
        CS:OnServed(player, slotId, tip)
    end

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
            stale2Keys = GetDataService():GetStale2Keys(player),  -- S-30: Stale II 목록 동기화
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

--------------------------------------------------------------------------------
-- S-30: 수동 폐기 (Stale II만 허용)
--------------------------------------------------------------------------------

-- S-30: 쿨다운 상태 (uid → lastDiscardTime)
local ManualDiscardCooldowns = {}
local MANUAL_DISCARD_COOLDOWN = 0.5  -- 0.5초

--[[
    S-30: 수동 폐기
    @param player: Player
    @param dishKey: string (예: "dish_10")
    @return { success, error?, noticeCode?, updates? }
]]
function OrderService:ManualDiscard(player, dishKey)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)
    local uid = player.UserId

    -- 1. 기본 검증
    if not playerData then
        print(string.format("[OrderService] S-30|DISCARD_DENIED uid=%d dishKey=%s reason=no_data", uid, tostring(dishKey)))
        return { success = false, error = "no_player_data", noticeCode = "data_error" }
    end

    if type(dishKey) ~= "string" or not string.match(dishKey, "^dish_%d+$") then
        print(string.format("[OrderService] S-30|DISCARD_DENIED uid=%d dishKey=%s reason=invalid_key", uid, tostring(dishKey)))
        return { success = false, error = "invalid_key", noticeCode = "discard_failed" }
    end

    -- 2. 쿨다운 체크 (uid 전역 0.5s)
    local now = tick()
    local lastTime = ManualDiscardCooldowns[uid] or 0
    if (now - lastTime) < MANUAL_DISCARD_COOLDOWN then
        print(string.format("[OrderService] S-30|DISCARD_DENIED uid=%d dishKey=%s reason=cooldown dt=%.2f", uid, dishKey, now - lastTime))
        return { success = false, error = "cooldown", noticeCode = "discard_failed" }
    end

    -- 3. 수량 체크
    local inventory = playerData.inventory or {}
    local qty = inventory[dishKey] or 0
    if qty <= 0 then
        print(string.format("[OrderService] S-30|DISCARD_DENIED uid=%d dishKey=%s reason=no_qty", uid, dishKey))
        return { success = false, error = "no_qty", noticeCode = "discard_failed" }
    end

    -- 4. Stale II 체크
    local staleCounts = playerData.staleCounts or {}
    local stale2Qty = (staleCounts[dishKey] and staleCounts[dishKey][2]) or 0
    if stale2Qty <= 0 then
        print(string.format("[OrderService] S-30|DISCARD_DENIED uid=%d dishKey=%s reason=not_stale2 stale2=%d", uid, dishKey, stale2Qty))
        return { success = false, error = "not_stale2", noticeCode = "discard_failed" }
    end

    -- 5. 폐기 처리 (원자적)
    -- inventory 감소
    playerData.inventory[dishKey] = qty - 1
    if playerData.inventory[dishKey] <= 0 then
        playerData.inventory[dishKey] = nil  -- 0이면 제거
    end

    -- staleCounts[2] 감소 (defensive nil check)
    if not staleCounts[dishKey] then
        -- 이론상 도달 불가 (4번 체크 통과 시 반드시 존재해야 함)
        -- 하지만 데이터 레이스/손상 방어
        warn(string.format("[OrderService] S-30|WARN uid=%d dishKey=%s staleCounts entry unexpectedly nil", uid, dishKey))
        staleCounts[dishKey] = { [0] = 0, [1] = 0, [2] = stale2Qty }
    end
    staleCounts[dishKey][2] = stale2Qty - 1
    if staleCounts[dishKey][2] < 0 then
        staleCounts[dishKey][2] = 0  -- 음수 방지 (clamp)
        warn(string.format("[OrderService] S-30|WARN uid=%d dishKey=%s stale2 went negative, clamped", uid, dishKey))
    end

    -- 6. 쿨다운 기록
    ManualDiscardCooldowns[uid] = now

    -- 7. 저장 플래그
    DS:MarkDirty(player)

    -- 8. 로그
    local remaining = playerData.inventory[dishKey] or 0
    print(string.format("[OrderService] S-30|MANUAL_DISCARD uid=%d dishKey=%s level=2 remaining=%d", uid, dishKey, remaining))

    -- 9. 응답 (동기화 포함)
    return {
        success = true,
        noticeCode = "discard_success",
        updates = {
            inventory = playerData.inventory,
            orders = playerData.orders,
            stale2Keys = DS:GetStale2Keys(player),
        },
    }
end

--------------------------------------------------------------------------------
-- PG-2: 주문 취소 (손님 patience timeout 등)
--------------------------------------------------------------------------------

--[[
    주문 취소 (CustomerService에서 호출)
    @param player: Player
    @param slotId: number
    @param reason: string (patience_timeout, customer_cancel 등)
    @return boolean (성공 여부)
]]
function OrderService:CancelOrder(player, slotId, reason)
    local DS = GetDataService()
    local playerData = DS:GetPlayerData(player)

    if not playerData then
        warn("[OrderService] CancelOrder: no playerData")
        return false
    end

    playerData.orders = playerData.orders or {}

    -- idempotent: 이미 비어있으면 성공 처리
    if not playerData.orders[slotId] then
        return true
    end

    -- S-26: patience_timeout 시 serveDeadline 보호
    -- SERVE 유예 시간 내에는 인내심 타임아웃으로 인한 취소 거부
    if reason == "patience_timeout" then
        local order = playerData.orders[slotId]
        local deadline = order and order.serveDeadline
        if deadline and deadline > os.time() then
            -- SERVE 대기 중: 취소 거부 (유예 시간 남음)
            if IS_STUDIO then
                print(string.format(
                    "[OrderService] S-26|CANCEL_BLOCKED uid=%d slot=%d reason=%s remaining=%ds",
                    player.UserId, slotId, reason, deadline - os.time()
                ))
            end
            return false
        end
    end

    local userId = player.UserId

    -- 취소 시 슬롯 락 해제(있으면)
    if self.IsSlotLocked and self.SetSlotLock and self:IsSlotLocked(userId, slotId) then
        self:SetSlotLock(userId, slotId, false, "order_canceled:" .. tostring(reason or "unknown"))
    end

    -- W3-NEXT 정리: 존재할 때만 호출
    if finalizeW3Next then
        finalizeW3Next(userId, slotId)
    end

    -- S-24: 예약 정리 (주문 삭제 전)
    self:ClearReservation(player, slotId, "order_canceled:" .. tostring(reason or "unknown"))

    -- 주문 삭제
    playerData.orders[slotId] = nil

    -- DataService dirty 마킹
    if DS.MarkDirty then
        DS:MarkDirty(player)
    end

    -- Exit Evidence (형식 고정)
    print(string.format(
        "[OrderService] ORDER_CANCELED uid=%d slot=%d reason=%s",
        userId, slotId, tostring(reason)
    ))

    -- SEALED INVARIANT: nil 슬롯 제거(즉시 리필)
    local filledSlots = {}
    if self.RefillOrders then
        filledSlots = self:RefillOrders(player)
    end

    -- S-29.2 버그픽스: CancelOrder 후에도 ESCAPE 체크
    -- 이유: patience_timeout 후 orphan 요리가 ESCAPE 매칭되어야 Stale 진행 가능
    local excludeSlotId = filledSlots[1] or slotId
    self:ValidateBoardEscapePath(player, excludeSlotId)

    -- 클라이언트 동기화
    -- S-29.2: inventory 포함 (STALE_DISCARD 후 인벤 변경 반영)
    if _remoteHandler and _remoteHandler.BroadcastOrders then
        _remoteHandler:BroadcastOrders(player, playerData.orders, {
            reason = "order_canceled",
            slot = slotId,
            cancelReason = reason,
        }, playerData.inventory)
    end

    return true
end

return OrderService
