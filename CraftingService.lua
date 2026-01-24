-- Server/Services/CraftingService.lua
-- SSOT v0.2.3.4 / Contract v1.3
-- 역할: RE_CraftItem 처리, 제작 시스템, 타이머 관리
-- P1-CONTRACT-SLOT-BINDING: v1.3에서 recipeId → slotId 기반으로 변경

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local ServerFlags = require(game.ReplicatedStorage.Shared.ServerFlags)
local GameData = require(game.ReplicatedStorage.Shared.GameData)
local DataService = require(game.ServerScriptService.Server.Services.DataService)
local OrderService = require(game.ServerScriptService.Server.Services.OrderService)

-- P3 패치: W3NextLogger 상단 1회 require (함수 내 중복 require 제거)
local W3NextLogger = require(game.ServerScriptService.Server.Shared.W3NextLogger)

-- PG-1: Cook 미니게임 설정
local FeatureFlags = require(game.ServerScriptService.Server.Config.FeatureFlags)
local PGConfig = require(game.ServerScriptService.Server.Shared.PGConfig)
local ProductionLogger = require(game.ServerScriptService.Server.Shared.ProductionLogger)

local CraftingService = {}
CraftingService.__index = CraftingService

--------------------------------------------------------------------------------
-- Phase 6: RemoteHandler 참조 (의존성 주입)
-- 목적: RE_SyncState 직접 호출 제거, RemoteHandler 단일 경로 통일
--------------------------------------------------------------------------------
local _remoteHandler = nil

--[[
    제작 상태 메모리 캐시 (런타임 전용)
    CraftingStates[UserId] = {
        recipeId = number,
        startTime = tick(),
        endTime = tick(),
    }
]]
local CraftingStates = {}

--[[
    PG-1: Cook 미니게임 세션 캐시
    CookSessions[UserId][SlotId] = {
        sessionId = string (GUID),
        seed = number,
        serverStartTime = number (os.clock),
        gaugeSpeed = number,
        uiTargetZone = {number, number},
        isTutorial = bool,
        expiresAt = number (os.clock + TTL),
        consumed = bool,
    }
]]
local CookSessions = {}

-- PG-1: 세션용 RNG (deterministic seed 생성)
local SessionRNG = Random.new()

-- PG-1: 서버 시간 함수 (일관성 유지)
local function GetServerTime()
    return os.clock()
end

--[[
    Phase 0 패치: EscapePath Validate 디바운스 (uid 단위)
    LastEscapeValidateAt[UserId] = os.clock()
    목적: 중복/연쇄 호출 방지 (0.5초 쿨다운)
]]
local LastEscapeValidateAt = {}
local ESCAPE_VALIDATE_DEBOUNCE = 0.5  -- 초

--------------------------------------------------------------------------------
-- 초기화
--------------------------------------------------------------------------------

-- Init 중복 호출 방지 (idempotent 가드)
local _craftingServiceInited = false

function CraftingService:Init()
    if _craftingServiceInited then
        warn("[CraftingService] Init already called, skipping")
        return
    end

    -- (현재 추가 초기화 로직 없음)

    -- 초기화 완료 후 가드 플래그 세팅
    _craftingServiceInited = true
    print("[CraftingService] 초기화 완료")
end

--------------------------------------------------------------------------------
-- Phase 6: SetRemoteHandler (의존성 주입)
-- 호출 시점: Main.server.lua에서 RemoteHandler.Init() 이후
--------------------------------------------------------------------------------
function CraftingService:SetRemoteHandler(handler)
    _remoteHandler = handler
    print("[CraftingService] RemoteHandler 주입 완료")
end

function CraftingService:CleanupPlayer(player)
    local userId = player.UserId
    CraftingStates[userId] = nil
    CookSessions[userId] = nil  -- PG-1: Cook 세션 정리
    LastEscapeValidateAt[userId] = nil  -- Phase 0 패치: 메모리 정리
end

--------------------------------------------------------------------------------
-- 1. CraftItem (핵심)
-- P1-CONTRACT-SLOT-BINDING: v1.3에서 recipeId → slotId로 변경
--------------------------------------------------------------------------------

function CraftingService:CraftItem(player, slotId)
    --[[
        반환값:
        { success = bool, error = string?, craftTime = number?, noticeCode = string? }

        P1-CONTRACT-SLOT-BINDING: slotId 기반 Craft (v1.3)
        - slotId: 1-based 정수 (1|2|3)
        - 서버는 orders[slotId].recipeId를 직접 조회
    ]]

    local userId = player.UserId

    ----------------------------------------------------------------------------
    -- 1-1. CraftingEnabled 체크 (Kill Switch)
    ----------------------------------------------------------------------------
    if not ServerFlags.CraftingEnabled then
        return {
            success = false,
            error = "feature_disabled",
            noticeCode = "crafting_disabled",
        }
    end

    ----------------------------------------------------------------------------
    -- 1-2. 플레이어 데이터 가져오기 (orders 조회 필요)
    ----------------------------------------------------------------------------
    local playerData = DataService:GetPlayerData(player)
    if not playerData then
        return {
            success = false,
            error = "no_player_data",
            noticeCode = "data_error",
        }
    end

    ----------------------------------------------------------------------------
    -- 1-3. orders[slotId] 존재 확인 (Contract v1.3 검증 순서 #2)
    ----------------------------------------------------------------------------
    local orders = playerData.orders or {}
    local order = orders[slotId]
    if not order or not order.recipeId then
        return {
            success = false,
            error = "no_order",
            noticeCode = "no_order",
            slotId = slotId,  -- Q-CRIT: 실패 응답에도 slotId 에코
        }
    end

    -- slotId에서 recipeId 추출
    local recipeId = order.recipeId

    ----------------------------------------------------------------------------
    -- 1-4. 중복 요청 방어 (Contract v1.3 검증 순서 #3)
    ----------------------------------------------------------------------------
    if CraftingStates[userId] then
        return {
            success = false,
            error = "already_crafting",
            noticeCode = "already_crafting",
            slotId = slotId,  -- Q-CRIT: 실패 응답에도 slotId 에코
        }
    end

    ----------------------------------------------------------------------------
    -- 1-5. 해당 슬롯 LOCK 상태 체크 (Contract v1.3 검증 순서 #4)
    ----------------------------------------------------------------------------
    if OrderService:IsSlotLocked(userId, slotId) then
        return {
            success = false,
            error = "slot_locked",
            noticeCode = "slot_locked",
            slotId = slotId,  -- Q-CRIT: 실패 응답에도 slotId 에코
        }
    end

    ----------------------------------------------------------------------------
    -- 1-6. 레시피 유효성 검사 (Contract v1.3 검증 순서 #5)
    ----------------------------------------------------------------------------
    local recipe = GameData.GetRecipeById(recipeId)
    if not recipe then
        return {
            success = false,
            error = "invalid_recipe",
            noticeCode = "invalid_recipe",
            slotId = slotId,  -- Q-CRIT: 실패 응답에도 slotId 에코
        }
    end

    ----------------------------------------------------------------------------
    -- 1-7. 재료 보유량 검사 (Contract v1.3 검증 순서 #6)
    ----------------------------------------------------------------------------
    local inventory = playerData.inventory or {}
    for materialId, requiredCount in pairs(recipe.ingredients) do
        -- [B-0] 문자열 키 통일 (DataStore 직렬화 안전)
        local currentCount = inventory[tostring(materialId)] or 0
        if currentCount < requiredCount then
            return {
                success = false,
                error = "insufficient_materials",
                noticeCode = "insufficient_materials",
                missingMaterial = materialId,
                slotId = slotId,  -- Q-CRIT: 실패 응답에도 slotId 에코
            }
        end
    end

    ----------------------------------------------------------------------------
    -- 1-8. Dish Cap 체크 (Contract v1.3 검증 순서 #7)
    ----------------------------------------------------------------------------
    local currentDishCount = self:CountDishes(playerData.inventory)
    if currentDishCount >= ServerFlags.DISH_CAP_TOTAL then
        return {
            success = false,
            error = "dish_cap_full",
            noticeCode = "dish_cap_full",
            slotId = slotId,  -- Q-CRIT: 실패 응답에도 slotId 에코
        }
    end

    ----------------------------------------------------------------------------
    -- 1-8.5: PG-1 Feature Flag 분기 (Cook 미니게임)
    -- Flag ON → StartCookSession 호출, 재료 차감, cook_minigame 응답
    -- Flag OFF → 기존 타이머 흐름 계속 (1-9 이후)
    ----------------------------------------------------------------------------
    if FeatureFlags.COOK_MINIGAME_ENABLED then
        -- Cook 미니게임 세션 시작
        local sessionResult = self:StartCookSession(player, slotId, recipeId, playerData)
        if not sessionResult.success then
            -- 세션 생성 실패 (session_already_active 등)
            local noticeCode = sessionResult.error
            if sessionResult.error == "session_already_active" then
                noticeCode = "cook_already_active"
            end
            return {
                success = false,
                error = sessionResult.error,
                noticeCode = noticeCode,
                slotId = slotId,
            }
        end

        -- W3-NEXT: Inventory Before 스냅샷 (차감 직전)
        local inventoryBeforeMG = W3NextLogger.ExtractRelevantInventory(inventory, recipe)

        -- 재료 차감 (기존 1-10 로직과 동일)
        DataService:UpdatePlayerData(player, function(data)
            for materialId, requiredCount in pairs(recipe.ingredients) do
                local key = tostring(materialId)
                data.inventory[key] = (data.inventory[key] or 0) - requiredCount
                if data.inventory[key] <= 0 then
                    data.inventory[key] = nil
                end
            end
        end)

        -- W3-NEXT: Inventory After 스냅샷 (차감 직후)
        local updatedDataMG = DataService:GetPlayerData(player)
        local inventoryAfterMG = W3NextLogger.ExtractRelevantInventory(
            updatedDataMG and updatedDataMG.inventory or {},
            recipe
        )

        -- W3-NEXT: INGREDIENTS_FINALIZED 로그 (Hard 레시피만)
        W3NextLogger.LogIngredientsFinalized({
            recipeId = recipeId,
            userId = userId,
            slotId = slotId,
            inventory_before = inventoryBeforeMG,
            inventory_after = inventoryAfterMG,
        })

        -- Cook 미니게임 응답 (Mode = "cook_minigame")
        return {
            success = true,
            mode = "cook_minigame",
            slotId = slotId,
            recipeId = recipeId,
            cookSession = sessionResult.cookSession,
            updates = {
                inventory = DataService:GetPlayerData(player).inventory,
            },
        }
    end

    ----------------------------------------------------------------------------
    -- 1-9. 제작 상태 잠금 + LOCK 설정 (ACCEPT 시점)
    -- P1-CONTRACT-SLOT-BINDING: slotId가 직접 전달되므로 GetSlotByRecipeId 불필요
    ----------------------------------------------------------------------------
    local craftTime = self:GetCraftTime(player, recipeId)
    local currentTime = tick()

    CraftingStates[userId] = {
        recipeId = recipeId,
        startTime = currentTime,
        endTime = currentTime + craftTime,
        slotId = slotId,  -- P1-CONTRACT-SLOT-BINDING: slotId 직접 저장
    }

    -- P1-ORDER-INVARIANT: 슬롯 LOCK 설정 (ACCEPT = CraftingStates 생성 직후)
    OrderService:SetSlotLock(userId, slotId, true, "craft_accept")

    ----------------------------------------------------------------------------
    -- 1-10. 재료 차감 (잠금 후 차감)
    ----------------------------------------------------------------------------

    -- W3-NEXT: Inventory Before 스냅샷 (차감 직전)
    local inventoryBefore = W3NextLogger.ExtractRelevantInventory(inventory, recipe)

    DataService:UpdatePlayerData(player, function(data)
        for materialId, requiredCount in pairs(recipe.ingredients) do
            -- [B-0] 문자열 키 통일 (DataStore 직렬화 안전)
            local key = tostring(materialId)
            data.inventory[key] = (data.inventory[key] or 0) - requiredCount
            if data.inventory[key] <= 0 then
                data.inventory[key] = nil
            end
        end
    end)

    -- W3-NEXT: Inventory After 스냅샷 (차감 직후)
    local updatedPlayerData = DataService:GetPlayerData(player)
    local inventoryAfter = W3NextLogger.ExtractRelevantInventory(
        updatedPlayerData and updatedPlayerData.inventory or {},
        recipe
    )

    -- W3-NEXT: INGREDIENTS_FINALIZED 로그 (Hard 레시피만)
    W3NextLogger.LogIngredientsFinalized({
        recipeId = recipeId,
        userId = userId,
        slotId = slotId,
        inventory_before = inventoryBefore,
        inventory_after = inventoryAfter,
    })

    ----------------------------------------------------------------------------
    -- 1-11. 비동기 타이머 (제작 완료 처리)
    ----------------------------------------------------------------------------
    task.delay(craftTime, function()
        self:OnCraftComplete(player, recipeId)
    end)

    ----------------------------------------------------------------------------
    -- 1-12. 성공 응답 (제작 시작됨)
    -- P1-CONTRACT-SLOT-BINDING: SlotId 에코 추가
    -- PG-1: Mode="timer" 추가 (Feature Flag OFF 시)
    ----------------------------------------------------------------------------
    return {
        success = true,
        mode = "timer",       -- PG-1: Mode 분기 (timer fallback)
        craftTime = craftTime,
        slotId = slotId,      -- v1.3: 요청한 slotId 에코
        recipeId = recipeId,  -- 해당 슬롯의 recipeId
        updates = {
            inventory = DataService:GetPlayerData(player).inventory,
            craftingState = {
                isActive = true,
                recipeId = recipeId,
                slotId = slotId,  -- v1.3: slotId 포함
                endTime = currentTime + craftTime,
            },
        },
        analytics = {
            event = "craft_start",
            slotId = slotId,
            recipeId = recipeId,
            craftTime = craftTime,
        },
    }
end

--------------------------------------------------------------------------------
-- 2. OnCraftComplete (타이머 완료 콜백)
--------------------------------------------------------------------------------

function CraftingService:OnCraftComplete(player, recipeId)
    local userId = player.UserId

    -- 제작 상태 확인
    local craftState = CraftingStates[userId]
    if not craftState or craftState.recipeId ~= recipeId then
        return  -- 이미 취소되었거나 다른 제작
    end

    -- 유저 이탈 체크 (중요!)
    if not player.Parent then
        CraftingStates[userId] = nil
        return  -- 유저가 나갔으면 지급 스킵
    end

    -- 레시피 정보
    local recipe = GameData.GetRecipeById(recipeId)
    if not recipe then
        -- P1-ORDER-INVARIANT: 비정상 종료 시 LOCK 해제
        local slotId = craftState.slotId
        if slotId then
            OrderService:SetSlotLock(userId, slotId, false, "craft_failed")
        end
        CraftingStates[userId] = nil
        return
    end

    -- 완성품 키 (dish_1, dish_2, ...)
    local dishKey = "dish_" .. recipeId

    -- [DEBUG] before 값 캡처
    local playerDataBefore = DataService:GetPlayerData(player)
    local beforeDish = playerDataBefore and playerDataBefore.inventory and playerDataBefore.inventory[dishKey] or 0

    -- 완성품 지급 (Dish Cap은 이미 진입 시점에 체크됨)
    local giveSuccess = DataService:UpdatePlayerData(player, function(data)
        if not data.inventory then
            data.inventory = {}
        end
        data.inventory[dishKey] = (data.inventory[dishKey] or 0) + 1
    end)

    -- [DEBUG] after 값 확인 (같은 cache.data 참조)
    local afterDish = playerDataBefore and playerDataBefore.inventory and playerDataBefore.inventory[dishKey] or 0
    print(string.format("[DEBUG] CRAFT_DISH uid=%d key=%s before=%d after=%d giveSuccess=%s",
        userId, dishKey, beforeDish, afterDish, tostring(giveSuccess)))

    ----------------------------------------------------------------------------
    -- P1-ORDER-INVARIANT: give 실패 시 방어적 LOCK 해제 + early return (OI-03 v3)
    -- 정상 흐름에서는 도달 안 함 (PlayerRemoving이 선행 처리)
    -- 예외/타임아웃 등 예상치 못한 상황 대비 안전장치
    -- v3: 실패 시 성공 흐름(ValidateBoardEscapePath, SendCraftComplete) 스킵
    ----------------------------------------------------------------------------
    if not giveSuccess then
        local slotId = craftState.slotId
        if slotId then
            OrderService:SetSlotLock(userId, slotId, false, "give_failed")
        end
        warn(string.format(
            "[CraftingService] WARN|GIVE_FAILED uid=%d slotId=%s recipeId=%d",
            userId, tostring(slotId), recipeId
        ))
        -- 제작 상태 해제 후 early return (성공 흐름 스킵)
        CraftingStates[userId] = nil
        return
    end

    -- P1-CRIT: slotId 보존 (CraftingStates 클리어 전)
    local completedSlotId = craftState.slotId

    -- 제작 상태 해제 (성공 경로)
    CraftingStates[userId] = nil

    ----------------------------------------------------------------------------
    -- Phase 0 패치: Hard Soft-Lock "즉시" 보장 (디바운스 적용)
    -- 요리 완성 시점에 ValidateBoardEscapePath 1회 호출
    -- 목적: dish_full 진입 순간 최대 60초 지연 제거
    ----------------------------------------------------------------------------
    local now = os.clock()
    local lastValidate = LastEscapeValidateAt[userId] or 0

    if (now - lastValidate) >= ESCAPE_VALIDATE_DEBOUNCE then
        LastEscapeValidateAt[userId] = now
        local escapeResult = OrderService:ValidateBoardEscapePath(player, nil)
        if escapeResult then
            print(string.format(
                "[CraftingService] ESCAPE_VALIDATE source=craft_complete uid=%d slot=%d",
                userId, escapeResult
            ))
        end
    else
        -- 디바운스로 스킵됨 (DEBUG 로그)
        print(string.format(
            "[CraftingService] DEBUG|ESCAPE_VALIDATE_SKIPPED_RATE_LIMIT uid=%d elapsed=%.2f",
            userId, now - lastValidate
        ))
    end

    -- 클라이언트에 완료 알림 (성공 경로만)
    -- P1-CRIT: completedSlotId 전달 (클라이언트가 어느 슬롯이 완료됐는지 알 수 있도록)
    self:SendCraftComplete(player, recipeId, dishKey, completedSlotId)

    -- Analytics
    -- (DataService에서 저장 시 기록)
end

--------------------------------------------------------------------------------
-- 3. GetCraftTime (CraftSpeed 업그레이드 적용)
--------------------------------------------------------------------------------

function CraftingService:GetCraftTime(player, recipeId)
    local recipe = GameData.GetRecipeById(recipeId)
    if not recipe then
        return ServerFlags.MIN_CRAFT_TIME
    end

    local baseTime = recipe.craftTime or 3

    -- CraftSpeed 업그레이드 레벨 가져오기
    local playerData = DataService:GetPlayerData(player)
    local craftSpeedLevel = 1
    if playerData and playerData.upgrades then
        craftSpeedLevel = playerData.upgrades.craftSpeed or 1
    end

    -- 공식: max(MIN_CRAFT_TIME, BaseTime * (0.9 ^ (Level - 1)))
    local reducedTime = baseTime * math.pow(0.9, craftSpeedLevel - 1)
    local finalTime = math.max(ServerFlags.MIN_CRAFT_TIME, reducedTime)

    return finalTime
end

--------------------------------------------------------------------------------
-- 3.5 PG-1: Cook 미니게임 세션 시작
--------------------------------------------------------------------------------

--[[
    StartCookSession: Cook 미니게임 세션 생성
    - CraftItem 검증 통과 후 호출됨
    - 서버 독립 재현을 위한 seed/startTime 저장
    - 클라이언트에 serverStartTime 미노출 (보안)

    @param player: Player
    @param slotId: number (1-3)
    @param recipeId: number
    @param playerData: table (DataService에서 가져온 데이터)
    @return { success, error?, cookSession? }
]]
function CraftingService:StartCookSession(player, slotId, recipeId, playerData)
    local userId = player.UserId
    local now = GetServerTime()

    -- 0. Feature Flag 체크
    if not FeatureFlags.COOK_MINIGAME_ENABLED then
        return { success = false, error = "feature_disabled" }
    end

    -- 1. 레시피 정보 가져오기
    local recipe = GameData.GetRecipeById(recipeId)
    if not recipe then
        return { success = false, error = "invalid_recipe" }
    end

    -- 2. 난이도별 게이지 설정
    local difficulty = recipe.difficulty or PGConfig.DEFAULT_DIFFICULTY
    local gaugeConfig = PGConfig.GetGaugeConfig(difficulty)

    -- 3. CraftSpeed 업그레이드 적용 (게이지 속도 감소)
    local craftSpeedLevel = 1
    if playerData and playerData.upgrades then
        craftSpeedLevel = playerData.upgrades.craftSpeed or 1
    end
    local speedMultiplier = PGConfig.GetSpeedMultiplier(craftSpeedLevel)
    local effectiveGaugeSpeed = gaugeConfig.speed * speedMultiplier

    -- 4. 튜토리얼 여부 판단 (기존 tutorialComplete 플래그 사용)
    local isTutorial = not (playerData and playerData.tutorialComplete)

    -- 5. 세션 TTL 결정
    local ttl = PGConfig.GetSessionTTL(isTutorial)

    -- 6. 세션 ID 및 시드 생성
    local sessionId = HttpService:GenerateGUID(false)
    local seed = SessionRNG:NextInteger(1, 2147483647)  -- 2^31-1

    -- 7. 유저별 CookSessions 테이블 초기화
    if not CookSessions[userId] then
        CookSessions[userId] = {}
    end

    -- 8. 기존 세션 중복 체크
    local existingSession = CookSessions[userId][slotId]
    if existingSession then
        -- 아직 소비되지 않고 만료 전인 세션이 있으면 거부
        if not existingSession.consumed and now < existingSession.expiresAt then
            return { success = false, error = "session_already_active" }
        end
        -- 만료되었거나 소비된 세션은 덮어씀
    end

    -- 9. 슬롯 LOCK 설정 (OrderService에 위임)
    if OrderService.SetSlotLock and type(OrderService.SetSlotLock) == "function" then
        OrderService:SetSlotLock(userId, slotId, true, "cook_session_start")
    else
        warn("[CraftingService] StartCookSession: SetSlotLock not available")
    end

    -- 10. 세션 저장 (내부 전용 데이터 포함)
    CookSessions[userId][slotId] = {
        sessionId = sessionId,
        recipeId = recipeId,
        seed = seed,
        serverStartTime = now,  -- 내부 전용 (클라 미노출)
        gaugeSpeed = effectiveGaugeSpeed,
        uiTargetZone = gaugeConfig.targetZone,  -- UI 표시용
        initialDirection = (seed % 2 == 0) and 1 or -1,
        isTutorial = isTutorial,
        expiresAt = now + ttl,
        consumed = false,
    }

    -- 11. 로그
    print(string.format(
        "[CraftingService] COOK_SESSION_START uid=%d slot=%d recipe=%d difficulty=%s speed=%.2f tutorial=%s ttl=%d",
        userId, slotId, recipeId, difficulty, effectiveGaugeSpeed, tostring(isTutorial), ttl
    ))

    -- 12. 클라이언트용 payload (화이트리스트 - serverStartTime 제외)
    local cookSessionPayload = {
        sessionId = sessionId,
        seed = seed,
        gaugeSpeed = effectiveGaugeSpeed,
        uiTargetZone = gaugeConfig.targetZone,
        isTutorial = isTutorial,
        ttl = ttl,
    }

    return {
        success = true,
        cookSession = cookSessionPayload,
    }
end

--------------------------------------------------------------------------------
-- 3.6 PG-1: 게이지 위치 계산 (서버 독립 재현)
--------------------------------------------------------------------------------

--[[
    CalculateGaugePosition: elapsed 시간으로 게이지 위치 계산
    - 서버에서 독립적으로 재현 (클라 데이터 불신뢰)

    @param elapsed: number (초)
    @param speed: number (position/초)
    @param initialDir: number (1 또는 -1)
    @return number (0~100)
]]
function CraftingService:CalculateGaugePosition(elapsed, speed, initialDir)
    -- 게이지는 0~100 사이를 왕복
    local totalDistance = elapsed * speed
    local cycles = math.floor(totalDistance / 100)
    local remainder = totalDistance % 100

    -- 방향 결정 (짝수 사이클 = 초기 방향, 홀수 = 반대)
    local currentDir = (cycles % 2 == 0) and initialDir or -initialDir

    if currentDir == 1 then
        return remainder  -- 0 → 100 방향
    else
        return 100 - remainder  -- 100 → 0 방향
    end
end

--------------------------------------------------------------------------------
-- 3.7 PG-1: 판정 계산 (S-03)
--------------------------------------------------------------------------------

--[[
    CalculateJudgment: 게이지 위치로 판정 계산
    - JUDGMENT_ZONES 적용 (튜토리얼 ±8, 일반 ±5)
    - 허용 윈도우 기반 보정 적용

    @param gaugePos: number (0~100)
    @param uiTargetZone: {number, number} (UI 표시용 목표 영역, 판정 중앙 계산에만 사용)
    @param gaugeSpeed: number (position/초)
    @param toleranceWindowMs: number (허용 윈도우, 밀리초) - 실제 RTT가 아닌 고정 윈도우
    @param isTutorial: bool
    @return string ("Perfect"|"Great"|"Good"|"Bad")

    Note: 판정은 JUDGMENT_ZONES 기준(중심 거리)으로 결정됨.
          uiTargetZone은 시각적 목표 영역으로, 중앙값 계산에만 활용.
]]
function CraftingService:CalculateJudgment(gaugePos, uiTargetZone, gaugeSpeed, toleranceWindowMs, isTutorial)
    -- 중앙 계산 (uiTargetZone에서 중앙값 추출)
    local targetCenter = (uiTargetZone[1] + uiTargetZone[2]) / 2
    local distance = math.abs(gaugePos - targetCenter)

    -- 허용 윈도우 보정: 거리에서 보정값 차감
    -- 보정량 = (윈도우시간 * 속도 * 0.5) - 양방향이므로 절반 적용
    local toleranceCompensation = (toleranceWindowMs / 1000) * gaugeSpeed * 0.5
    local adjustedDistance = math.max(0, distance - toleranceCompensation)

    -- 판정 구간 선택 (튜토리얼에서 확대)
    local zones = PGConfig.GetJudgmentZones(isTutorial)

    -- 판정
    if adjustedDistance <= zones.Perfect then
        return "Perfect"
    elseif adjustedDistance <= zones.Great then
        return "Great"
    elseif adjustedDistance <= zones.Good then
        return "Good"
    elseif adjustedDistance <= zones.OK then
        return "OK"
    else
        return "Bad"
    end
end

--------------------------------------------------------------------------------
-- 3.8 PG-1: Perfect 보호 구간 적용 (S-04)
--------------------------------------------------------------------------------

--[[
    ApplyProtection: 서버 판정이 클라보다 낮을 때 보호 적용
    - Perfect → Great 다운그레이드 시, 중심 ±ε 이내면 Perfect 유지

    @param serverJudgment: string
    @param clientJudgment: string
    @param serverGaugePos: number
    @return string (최종 판정)
]]
function CraftingService:ApplyProtection(serverJudgment, clientJudgment, serverGaugePos)
    -- 클라가 Perfect인데 서버가 Great로 내려갈 때만 적용
    if clientJudgment == "Perfect" and serverJudgment == "Great" then
        local distFromCenter = math.abs(serverGaugePos - PGConfig.PERFECT_CENTER)
        if distFromCenter <= PGConfig.PROTECTION_EPSILON then
            return "Perfect"  -- 보호
        end
    end
    return serverJudgment  -- 원래 판정 유지
end

--------------------------------------------------------------------------------
-- 3.9 PG-1: Cook Tap 제출 처리 (S-05)
--------------------------------------------------------------------------------

--[[
    SubmitCookTap: 클라이언트 탭 제출 처리
    - 서버 독립 게이지 재현
    - 판정 계산 및 보호 적용
    - cookScore 반환

    @param player: Player
    @param slotId: number
    @param sessionId: string (클라이언트가 보유한 세션 ID, 검증용)
    @param clientJudgment: string? (클라 임시 판정, 보호 적용용)
    @return { success, error?, judgment?, cookScore?, corrected? }
]]
function CraftingService:SubmitCookTap(player, slotId, sessionId, clientJudgment)
    local userId = player.UserId
    local now = GetServerTime()

    -- 1. 세션 존재 확인
    if not CookSessions[userId] then
        return { success = false, error = "no_user_sessions", noticeCode = "cook_session_error" }
    end

    local session = CookSessions[userId][slotId]
    if not session then
        return { success = false, error = "session_not_found", noticeCode = "cook_session_error" }
    end

    -- 1.5. sessionId 검증 (보안: 클라이언트가 다른 세션 ID로 요청 방지)
    if sessionId and session.sessionId ~= sessionId then
        return { success = false, error = "session_mismatch", noticeCode = "cook_session_error" }
    end

    -- 2. 세션 유효성 검사
    if session.consumed then
        return { success = false, error = "session_consumed", noticeCode = "cook_already_submitted" }
    end

    if now > session.expiresAt then
        -- 만료된 세션 정리
        CookSessions[userId][slotId] = nil
        return { success = false, error = "session_expired", noticeCode = "cook_session_expired" }
    end

    -- 3. 경과 시간 계산
    local elapsed = now - session.serverStartTime

    -- 4. 시간 범위 검증
    if elapsed < PGConfig.MIN_COOK_TIME then
        return { success = false, error = "too_early" }
    end

    if elapsed > PGConfig.MAX_COOK_TIME then
        return { success = false, error = "too_late" }
    end

    -- 5. 서버 독립 게이지 위치 계산
    local serverGaugePos = self:CalculateGaugePosition(
        elapsed,
        session.gaugeSpeed,
        session.initialDirection
    )

    -- 6. 판정 계산 (TOLERANCE_WINDOW_MS = 고정 허용 윈도우, 실제 RTT 아님)
    local serverJudgment = self:CalculateJudgment(
        serverGaugePos,
        session.uiTargetZone,
        session.gaugeSpeed,
        PGConfig.TOLERANCE_WINDOW_MS,
        session.isTutorial
    )

    -- 7. 보호 적용 (클라 판정이 제공된 경우)
    local finalJudgment = serverJudgment
    local corrected = false
    if clientJudgment then
        finalJudgment = self:ApplyProtection(serverJudgment, clientJudgment, serverGaugePos)
        corrected = (finalJudgment ~= serverJudgment)
    end

    -- 8. 점수 계산
    local cookScore = PGConfig.JUDGMENT_SCORES[finalJudgment] or 0

    -- 9. 세션 소비 처리
    session.consumed = true

    -- 10. 슬롯 LOCK 해제
    if OrderService.SetSlotLock and type(OrderService.SetSlotLock) == "function" then
        OrderService:SetSlotLock(userId, slotId, false, "cook_tap_submitted")
    end

    -- 11. 로컬 로그
    print(string.format(
        "[CraftingService] COOK_TAP_SUBMIT uid=%d slot=%d elapsed=%.3f pos=%.2f server=%s final=%s score=%.2f corrected=%s",
        userId, slotId, elapsed, serverGaugePos, serverJudgment, finalJudgment, cookScore, tostring(corrected)
    ))

    -- 12. PG-1 텔레메트리 (S-09: Production 로깅)
    ProductionLogger.LogCookJudgment(userId, {
        recipeId = session.recipeId,
        slotId = slotId,
        serverJudgment = serverJudgment,
        clientJudgment = clientJudgment,
        finalJudgment = finalJudgment,
        corrected = corrected,
        isTutorial = session.isTutorial,
        cookScore = cookScore,
    })

    -- 13. cookScore를 OrderService에 Push (DeliverOrder에서 사용)
    if OrderService.SetCookScore and type(OrderService.SetCookScore) == "function" then
        OrderService:SetCookScore(userId, slotId, cookScore, session.sessionId)
    end

    return {
        success = true,
        slotId = slotId,
        sessionId = session.sessionId,
        serverGaugePos = serverGaugePos,
        judgment = finalJudgment,
        cookScore = cookScore,
        corrected = corrected,
        recipeId = session.recipeId,
        updates = {
            craftingState = { isActive = false },
        },
    }
end

--------------------------------------------------------------------------------
-- 4. 상태 조회 함수
--------------------------------------------------------------------------------

function CraftingService:IsCrafting(player)
    return CraftingStates[player.UserId] ~= nil
end

function CraftingService:GetCraftingState(player)
    local state = CraftingStates[player.UserId]
    if not state then
        return {
            isActive = false,
        }
    end

    local currentTime = tick()
    local remainingTime = math.max(0, state.endTime - currentTime)

    return {
        isActive = true,
        recipeId = state.recipeId,
        startTime = state.startTime,
        endTime = state.endTime,
        remainingTime = remainingTime,
    }
end

--------------------------------------------------------------------------------
-- 5. 헬퍼 함수
--------------------------------------------------------------------------------

--[[
    요리(Dish) 개수 카운트 (ChatGPT 아이디어 반영)
    - 인벤토리에서 "dish_" 접두사를 가진 아이템만 카운트
    - DISH_CAP_TOTAL (5) 체크에 사용
]]
function CraftingService:CountDishes(inventory)
    if not inventory then
        return 0
    end

    local total = 0
    for itemKey, count in pairs(inventory) do
        -- dish_1, dish_2, ... 형태 체크
        if type(itemKey) == "string" and itemKey:sub(1, 5) == "dish_" then
            total = total + count
        end
    end

    return total
end

--------------------------------------------------------------------------------
-- 6. 클라이언트 통신 (Phase 6: RemoteHandler 경유)
--------------------------------------------------------------------------------

function CraftingService:SendCraftComplete(player, recipeId, dishKey, slotId)
    -- Phase 6 가드: RemoteHandler 미주입 시 경고 + early return
    if not _remoteHandler then
        warn("[CraftingService] SendCraftComplete: RemoteHandler not injected")
        return
    end

    local playerData = DataService:GetPlayerData(player)
    local inv = playerData and playerData.inventory or {}

    -- [DEBUG] 전송 직전 inventory 상태 확인
    local dishCount = 0
    local dishSample = {}
    for k, v in pairs(inv) do
        if type(k) == "string" and k:sub(1, 5) == "dish_" then
            dishCount = dishCount + 1
            table.insert(dishSample, k .. "=" .. tostring(v))
        end
    end
    print(string.format("[DEBUG] SendCraftComplete uid=%d dishCount=%d sample={%s}",
        player.UserId, dishCount, table.concat(dishSample, ", ")))

    -- Phase 6: RemoteHandler.BroadcastCraftComplete 경유 (G-02 준수)
    -- camelCase로 전달 → RemoteHandler에서 PascalCase 변환
    -- P1-CRIT: slotId 포함 (클라이언트가 어느 슬롯이 완료됐는지 식별)
    _remoteHandler:BroadcastCraftComplete(player, {
        inventory = inv,
        craftingState = { isActive = false },
        slotId = slotId,  -- P1-CRIT: 완료된 슬롯 ID
    })
end

return CraftingService
