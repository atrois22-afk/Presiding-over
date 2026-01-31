-- StarterPlayerScripts/Client/ClientController.client.lua
-- SSOT v0.2.3.4 / Contract v1.3
-- 역할: 서버 통신, 데이터 동기화, EventBus 발행, 정규화 레이어
-- Phase 3: TutorialManager 연동
-- P1-CONTRACT-SLOT-BINDING: CraftItemForSlot(slotId) 추가, CraftItem(recipeId) deprecated

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- 모듈
local NoticeUI = require(script.Parent.UI.NoticeUI)
local TutorialUI = require(script.Parent.UI.TutorialUI)
local PostTutorialUI = require(script.Parent.UI.PostTutorialUI)
local ClientEvents = require(ReplicatedStorage.Shared.ClientEvents)
local ServerFlags = require(ReplicatedStorage.Shared.ServerFlags)
local Gate5Logger = require(ReplicatedStorage.Shared.Gate5Logger)
local TutorialManager = require(script.Parent.TutorialManager)
local InteractionHandler = require(script.Parent.InteractionHandler)

--------------------------------------------------------------------------------
-- Phase 4: Gate4 Logging (Dev/Studio only)
--------------------------------------------------------------------------------

local function ShouldGate4Log()
    return RunService:IsStudio() and ServerFlags.GATE4_LOG_ENABLED
end

--------------------------------------------------------------------------------
-- Phase 4: G4.1 Invariant Verification (Dev/Studio only)
--------------------------------------------------------------------------------

local UPGRADE_IDS = {"quantity", "craftSpeed", "slots"}
local KNOWN_ORDER_REASONS = { rotate = true, deliver = true }  -- Phase 7-B S-02.2

-- INV_COINS: coins >= 0
local function VerifyInvCoins(clientData)
    local coins = clientData.wallet and clientData.wallet.coins
    if coins == nil then
        return false, "PATH_MISSING path=ClientData.wallet.coins"
    end
    if coins < 0 then
        return false, string.format("NEGATIVE_VALUE coins=%d", coins)
    end
    return true, string.format("coins=%d", coins)
end

-- INV_INVENTORY: 존재하는 키의 수량 >= 0, 중복 키 감지
local function VerifyInvInventory(clientData)
    local inventory = clientData.inventory
    if inventory == nil then
        return false, "PATH_MISSING path=ClientData.inventory"
    end

    local seen = {}
    local failDetails = {}
    local keyCount = 0

    for k, v in pairs(inventory) do
        local normalizedKey = tonumber(k) or k
        keyCount = keyCount + 1

        -- 중복 키 감지 (string "1" vs number 1)
        if seen[normalizedKey] then
            table.insert(failDetails, string.format("DUP_KEY key=%s", tostring(k)))
        end
        seen[normalizedKey] = true

        -- 음수 값 감지
        if type(v) == "number" and v < 0 then
            table.insert(failDetails, string.format("NEGATIVE_VALUE key=%s value=%d", tostring(k), v))
        end
    end

    if #failDetails > 0 then
        return false, table.concat(failDetails, "; ")
    end
    return true, string.format("keys=%d", keyCount)
end

-- INV_UPGRADE_MIN: upgrades[id] >= 1 (nil → 1 fallback)
local function VerifyInvUpgradeMin(clientData)
    local upgrades = clientData.upgrades
    if upgrades == nil then
        return false, "PATH_MISSING path=ClientData.upgrades"
    end

    local details = {}
    local allPass = true

    for _, id in ipairs(UPGRADE_IDS) do
        local rawLevel = upgrades[id]
        local level = rawLevel or 1  -- nil → 1 fallback (검증식에서만)

        if level < 1 then
            allPass = false
            table.insert(details, string.format("%s=%d<1", id, level))
        else
            local displayLevel = rawLevel == nil and "nil→1" or tostring(rawLevel)
            table.insert(details, string.format("%s=%s", id, displayLevel))
        end
    end

    return allPass, table.concat(details, " ")
end

-- INV_UPGRADE_MAX: upgrades[id] <= MAX_LEVEL (nil → 1 fallback)
local function VerifyInvUpgradeMax(clientData)
    local upgrades = clientData.upgrades
    if upgrades == nil then
        return false, "PATH_MISSING path=ClientData.upgrades"
    end

    local maxLevel = ServerFlags.MAX_LEVEL or 10
    local details = {}
    local allPass = true

    for _, id in ipairs(UPGRADE_IDS) do
        local rawLevel = upgrades[id]
        local level = rawLevel or 1  -- nil → 1 fallback (검증식에서만)

        if level > maxLevel then
            allPass = false
            table.insert(details, string.format("%s=%d>%d", id, level, maxLevel))
        end
    end

    if allPass then
        return true, string.format("max=%d", maxLevel)
    end
    return false, table.concat(details, " ")
end

-- G4.1 전체 검증 (InitialData 직후 1회용)
local function RunAllInvariants(clientData)
    if not ShouldGate4Log() then return end

    local failCount = 0

    -- INV_COINS
    local pass, detail = VerifyInvCoins(clientData)
    print(string.format("[G4.1][invariant] id=INV_COINS pass=%s detail=\"%s\"", tostring(pass), detail))
    if not pass then failCount = failCount + 1 end

    -- INV_INVENTORY
    pass, detail = VerifyInvInventory(clientData)
    print(string.format("[G4.1][invariant] id=INV_INVENTORY pass=%s detail=\"%s\"", tostring(pass), detail))
    if not pass then failCount = failCount + 1 end

    -- INV_UPGRADE_MIN
    pass, detail = VerifyInvUpgradeMin(clientData)
    print(string.format("[G4.1][invariant] id=INV_UPGRADE_MIN pass=%s detail=\"%s\"", tostring(pass), detail))
    if not pass then failCount = failCount + 1 end

    -- INV_UPGRADE_MAX
    pass, detail = VerifyInvUpgradeMax(clientData)
    print(string.format("[G4.1][invariant] id=INV_UPGRADE_MAX pass=%s detail=\"%s\"", tostring(pass), detail))
    if not pass then failCount = failCount + 1 end

    -- Summary
    local allPass = failCount == 0
    print(string.format("[G4.1][summary] pass=%s fails=%d", tostring(allPass), failCount))
end

-- G4.1 도메인별 검증 (RE_SyncState용)
local function RunDomainInvariant(domain, clientData)
    if not ShouldGate4Log() then return end
    -- active=true 이후에만 검증 (불필요 경고 감소)
    if not clientData.postTutorial.active then return end

    local pass, detail

    if domain == "wallet" then
        pass, detail = VerifyInvCoins(clientData)
        print(string.format("[G4.1][invariant] id=INV_COINS pass=%s detail=\"%s\"", tostring(pass), detail))
    elseif domain == "inventory" then
        pass, detail = VerifyInvInventory(clientData)
        print(string.format("[G4.1][invariant] id=INV_INVENTORY pass=%s detail=\"%s\"", tostring(pass), detail))
    elseif domain == "upgrades" then
        pass, detail = VerifyInvUpgradeMin(clientData)
        print(string.format("[G4.1][invariant] id=INV_UPGRADE_MIN pass=%s detail=\"%s\"", tostring(pass), detail))
        pass, detail = VerifyInvUpgradeMax(clientData)
        print(string.format("[G4.1][invariant] id=INV_UPGRADE_MAX pass=%s detail=\"%s\"", tostring(pass), detail))
    end
end

local ClientController = {}

-- Phase 3: TutorialManager 인스턴스 (Initialize에서 생성)
local TutorialManagerInstance = nil

-- P4: MainHUD 인스턴스 참조 (DayEndResponse 직접 전달용)
local MainHUDInstance = nil

--------------------------------------------------------------------------------
-- 클라이언트 데이터 저장소 (camelCase 표준 - Contract §5.6)
--------------------------------------------------------------------------------

local ClientData = {
    inventory = {},
    orders = {},
    wallet = { coins = 0 },
    upgrades = {},
    cooldown = { remainingSeconds = 0, isReady = true, tutorialActive = false },
    craftingState = { isActive = false },
    tutorial = {
        hasCompleted = false,
        -- 표현 전용 (Presentation-only, 서버 저장 X)
        ui = {
            visible = false,
            mode = "hidden",  -- "guide" | "recovery" | "hard_block" | "completed" | "hidden"
            step = 0,
            enhanced = false,
            noticeCode = nil,
            highlightTarget = nil,
        },
    },
    -- Phase 4: Post-Tutorial 상태 (Presentation-only, 서버 저장 X)
    -- active와 tutorial.hasCompleted는 상호배타 (active=true면 tutorial UI 비활성)
    postTutorial = {
        active = false,           -- 상태: post_tutorial 상태 머신 플래그 (once true, stays true)
        entryLogged = false,      -- Dev/Studio only: G4.0 entry evidence idempotency
        ui = {
            visible = false,      -- 표현: 현재 화면에 띄우는지 (active와 독립, 일시적 숨김 가능)
            mode = "hidden",      -- "hidden" | "guide" | "completed"
        },
    },
    flags = {},
}

-- Remotes (서버가 생성할 때까지 대기)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
    warn("[Client] Critical Error: Remotes folder not found!")
    return
end

--------------------------------------------------------------------------------
-- 정규화 레이어 (Contract §5.6 - 스키마 인지형)
--------------------------------------------------------------------------------

--[[
    Response 정규화: PascalCase → camelCase
    화이트리스트 기반으로 알려진 필드만 처리

    스키마 참조: Contract §5.3 (cooldown), §5.4 (craftingState), §5.6 (Response Payload)
]]
local function normalizeResponse(response)
    if not response then return nil end

    local normalized = {}

    -- 1. Envelope 정규화 (알려진 키만)
    normalized.success = response.Success
    normalized.error = response.Error
    normalized.message = response.Message
    normalized.noticeCode = response.NoticeCode
    -- Phase 6: 2-phase CraftResponse 구분
    normalized.phase = response.Phase
    -- Phase 6: OrderResponse Meta (rotate 동기화용)
    normalized.meta = response.Meta

    -- P2: DeliverResponse Score/Tip 필드 (Contract v1.4)
    normalized.score = response.Score
    normalized.tip = response.Tip
    normalized.totalRevenue = response.TotalRevenue
    normalized.walletCoins = response.WalletCoins
    normalized.reward = response.Reward
    normalized.slotId = response.SlotId

    -- P4: DayEndResponse 필드 (Contract v1.5)
    normalized.reason = response.Reason
    normalized.dayBefore = response.DayBefore
    normalized.dayAfter = response.DayAfter
    normalized.ordersServedAtEnd = response.OrdersServedAtEnd
    normalized.target = response.Target

    -- PG-1: CraftResponse Cook 미니게임 필드
    normalized.mode = response.Mode  -- "cook_minigame" | "timer"
    -- S-15/C-10: FallbackReason (방어적 호환: PascalCase 우선, camelCase 폴백)
    normalized.fallbackReason = response.FallbackReason or response.fallbackReason
    -- CookSession: PascalCase → camelCase 변환
    if response.CookSession then
        normalized.cookSession = {
            sessionId = response.CookSession.SessionId,
            seed = response.CookSession.Seed,
            gaugeSpeed = response.CookSession.GaugeSpeed,
            uiTargetZone = response.CookSession.UiTargetZone,
            isTutorial = response.CookSession.IsTutorial,
            ttl = response.CookSession.Ttl,
        }
    end

    -- PG-1: CookTapResponse 필드 (S-07)
    normalized.sessionId = response.SessionId or normalized.sessionId  -- 기존 sessionId 덮어쓰기 방지
    normalized.serverGaugePos = response.ServerGaugePos
    normalized.judgment = response.Judgment
    normalized.cookScore = response.CookScore
    normalized.corrected = response.Corrected

    -- S-12: CookTimePhase 필드 (PG-1.1)
    normalized.cookTimeDuration = response.CookTimeDuration

    -- S-14/C-11: COOK_TIME_COMPLETE 필드 (PG-1.1)
    normalized.dishKey = response.DishKey
    normalized.recipeId = response.RecipeId or normalized.recipeId  -- 기존 recipeId 덮어쓰기 방지

    -- 2. Updates 정규화 (도메인별 처리)
    if response.Updates then
        normalized.updates = {}

        -- wallet: coins 키 정규화
        if response.Updates.Wallet then
            normalized.updates.wallet = {
                coins = response.Updates.Wallet.coins or response.Updates.Wallet.Coins
            }
        end

        -- orders: array 그대로 유지 (변환 없음!)
        if response.Updates.Orders then
            normalized.updates.orders = response.Updates.Orders
        end

        -- inventory: B-0 문자열 키 유지 (BindableEvent 혼합키 유실 방지)
        if response.Updates.Inventory then
            normalized.updates.inventory = {}
            for key, value in pairs(response.Updates.Inventory) do
                normalized.updates.inventory[tostring(key)] = value
            end
        end

        -- S-30: Stale2Keys → stale2Set 변환 (O(1) 조회용)
        if response.Updates.Stale2Keys then
            normalized.updates.stale2Set = {}
            for _, dishKey in ipairs(response.Updates.Stale2Keys) do
                normalized.updates.stale2Set[dishKey] = true
            end
        end

        -- upgrades: 직접 전달
        if response.Updates.Upgrades then
            normalized.updates.upgrades = response.Updates.Upgrades
        end

        -- cooldown: remainingSeconds + tutorialActive 보장 (Phase 3)
        if response.Updates.Cooldown then
            normalized.updates.cooldown = {
                remainingSeconds = response.Updates.Cooldown.remainingSeconds
                    or response.Updates.Cooldown.RemainingSeconds or 0,
                isReady = response.Updates.Cooldown.isReady
                    or response.Updates.Cooldown.IsReady,
                tutorialActive = response.Updates.Cooldown.tutorialActive
                    or response.Updates.Cooldown.TutorialActive or false,
            }
        end

        -- craftingState: isActive 키 사용
        -- P1-HF: slotId 추가 (CRAFT_COMPLETE 시 정확한 슬롯 식별용)
        if response.Updates.CraftingState then
            normalized.updates.craftingState = {
                isActive = response.Updates.CraftingState.isActive
                    or response.Updates.CraftingState.IsActive or false,
                recipeId = response.Updates.CraftingState.recipeId
                    or response.Updates.CraftingState.RecipeId,
                endTime = response.Updates.CraftingState.endTime
                    or response.Updates.CraftingState.EndTime,
                startTime = response.Updates.CraftingState.startTime
                    or response.Updates.CraftingState.StartTime,
                -- P1-HF: Response 레벨 SlotId를 craftingState로 전달
                slotId = response.SlotId,
            }
        end

        -- tutorial: 직접 전달
        if response.Updates.Tutorial then
            normalized.updates.tutorial = response.Updates.Tutorial
        end
    end

    return normalized
end

--[[
    InitialData 정규화 (RF_GetInitialData 응답)
]]
local function normalizeInitialData(data)
    if not data then return nil end

    local normalized = {}

    -- inventory: B-0 문자열 키 유지 (BindableEvent 혼합키 유실 방지)
    normalized.inventory = {}
    if data.inventory then
        for key, value in pairs(data.inventory) do
            normalized.inventory[tostring(key)] = value
        end
    end

    -- orders: array 유지
    normalized.orders = data.orders or {}

    -- wallet
    normalized.wallet = {
        coins = data.wallet and (data.wallet.coins or data.wallet.Coins) or 0
    }

    -- upgrades
    normalized.upgrades = data.upgrades or {}

    -- cooldown (Phase 3: tutorialActive 포함)
    if data.cooldown then
        normalized.cooldown = {
            remainingSeconds = data.cooldown.remainingSeconds
                or data.cooldown.RemainingSeconds or 0,
            isReady = data.cooldown.isReady or data.cooldown.IsReady or true,
            tutorialActive = data.cooldown.tutorialActive
                or data.cooldown.TutorialActive or false,
        }
    else
        normalized.cooldown = { remainingSeconds = 0, isReady = true, tutorialActive = false }
    end

    -- craftingState (초기에는 없을 수 있음)
    normalized.craftingState = { isActive = false }

    -- tutorial
    normalized.tutorial = data.tutorial or { hasCompleted = false }

    -- flags
    normalized.flags = data.flags or {}

    return normalized
end

--------------------------------------------------------------------------------
-- 1. 초기 데이터 로드 (Bootstrapper)
--------------------------------------------------------------------------------

local function Initialize()
    print("[Client] Requesting Initial Data...")

    local RF_GetInitialData = Remotes:WaitForChild("RF_GetInitialData")

    -- 서버에 데이터 요청 (동기)
    local rawData = RF_GetInitialData:InvokeServer()

    if rawData then
        print("[Client] Initial Data Received!")

        -- 정규화 적용
        local normalizedData = normalizeInitialData(rawData)

        -- ClientData 갱신
        ClientData.inventory = normalizedData.inventory
        ClientData.orders = normalizedData.orders
        ClientData.wallet = normalizedData.wallet
        ClientData.upgrades = normalizedData.upgrades
        ClientData.cooldown = normalizedData.cooldown
        ClientData.craftingState = normalizedData.craftingState
        -- 병합 정책: 서버 필드만 갱신, ui는 기본값 유지
        ClientData.tutorial.hasCompleted = normalizedData.tutorial.hasCompleted or false
        if normalizedData.tutorial.bonusGranted ~= nil then
            ClientData.tutorial.bonusGranted = normalizedData.tutorial.bonusGranted
        end
        if normalizedData.tutorial.exitReason ~= nil then
            ClientData.tutorial.exitReason = normalizedData.tutorial.exitReason
        end
        ClientData.flags = normalizedData.flags

        -- MainHUD 초기화 (P0-1: 데이터 준비 후, Fire 직전)
        local MainHUD = require(script.Parent.UI.MainHUD)
        MainHUD:Init(ClientController)
        MainHUDInstance = MainHUD  -- P4: DayEndResponse 직접 전달용 참조 저장

        -- TutorialUI 초기화 (C Checklist: StateChanged 리스너 연결)
        TutorialUI:Init(ClientController)

        -- Phase 4: PostTutorialUI 초기화 (StateChanged 리스너 연결)
        PostTutorialUI:Init(ClientController)

        -- Phase 4: G4.1 전수 검사 (InitialData 직후 1회)
        RunAllInvariants(ClientData)

        -- EventBus: 전체 데이터 발행
        ClientEvents.StateChanged:Fire("All", ClientData)

        --------------------------------------------------------------------
        -- Phase 3: TutorialManager 초기화 및 Entry 판정
        -- UI 표시 직전(StateChanged 직후)에 CheckEntry 수행
        --------------------------------------------------------------------
        TutorialManagerInstance = TutorialManager.new(ClientController)
        local entryResult = TutorialManagerInstance:CheckEntry(normalizedData)

        print(string.format("[Client] Tutorial Entry: %s", entryResult))

        if entryResult == "START" then
            -- 튜토리얼 시작
            TutorialManagerInstance:Start()
            -- C Checklist: Start()가 ui 상태를 변경했으므로 StateChanged 발화
            ClientEvents.StateChanged:Fire("tutorial", ClientData.tutorial)
        elseif entryResult == "SKIP" then
            -- 튜토리얼 완료 상태 → Post-Tutorial Entry
            print("[Client] Tutorial already completed, entering post-tutorial mode...")

            --------------------------------------------------------------------
            -- Phase 4: G4.0 Entry (Post-Tutorial 진입)
            -- 조건: hasCompleted == true (SKIP은 이 조건에서만 발생 - TutorialManager:171)
            --------------------------------------------------------------------
            local previouslyActive = ClientData.postTutorial.active

            -- Phase 4: 중복 진입 체크 (Dev/Studio only)
            if ShouldGate4Log() and previouslyActive then
                warn("[G4.0][entry] duplicate entry attempt - already active")
            end

            ClientData.postTutorial.active = true

            -- Phase 5: G5.2 로그 플래그 리셋 (Must-Fix A)
            PostTutorialUI:ResetG5_2Log()

            -- Phase 4: 상호배타 강제 (1회 HideAll, nil 가드 포함)
            if TutorialUI and TutorialUI.HideAll then
                TutorialUI:HideAll()
            end

            -- Phase 4: StateChanged 발화 (G4.2 전제 조건)
            ClientEvents.StateChanged:Fire("post_tutorial", ClientData.postTutorial)

            -- Phase 4: G4.0 Evidence (Dev/Studio only, 세션당 1회)
            if ShouldGate4Log() and not ClientData.postTutorial.entryLogged then
                ClientData.postTutorial.entryLogged = true
                local uid = Players.LocalPlayer.UserId
                local exitReason = ClientData.tutorial.exitReason or "nil"
                print(string.format("[G4.0][entry] uid=%d hasCompleted=%s active=%s exitReason=%s",
                    uid, tostring(ClientData.tutorial.hasCompleted), tostring(ClientData.postTutorial.active), exitReason))

                -- Phase 4: G4.2 Evidence (Entry 시점, 최소 필드만)
                print("[G4.2][render] scope=post_tutorial via=StateChanged batch=post_tutorial active=true")
                -- NOTE: G5.2 via_StateChanged는 PostTutorialUI 핸들러에서 출력 (Must-Fix B)
            end
        elseif entryResult == "RECOVERY" then
            -- RECOVERY 상태 - Modal 표시, 튜토리얼 차단
            TutorialManagerInstance:ShowRecoveryModal()
            -- C Checklist: RECOVERY도 ui 상태 변경이므로 StateChanged 발화
            ClientEvents.StateChanged:Fire("tutorial", ClientData.tutorial)
        end

        print("[Client] Data Ready:", ClientData)
    else
        warn("[Client] Failed to load initial data.")
    end
end

--------------------------------------------------------------------------------
-- 2. 데이터 동기화 (Sync Listener)
--------------------------------------------------------------------------------

local function SetupSyncListener()
    local RE_SyncState = Remotes:WaitForChild("RE_SyncState")

    RE_SyncState.OnClientEvent:Connect(function(scope, data)
        -- Phase 7-A S-07A-03: 표준 수신 로그
        -- hasUpdates: Updates가 존재하고 비어있지 않을 때만 true (지적 A 반영)
        local hasUpdates = type(data) == "table"
            and data.Updates ~= nil
            and type(data.Updates) == "table"
            and next(data.Updates) ~= nil
        local phase = type(data) == "table" and data.Phase or nil
        local reason = type(data) == "table" and data.Meta and data.Meta.reason or nil
        print(string.format("[Client][RECV] scope=%s phase=%s reason=%s hasUpdates=%s",
            tostring(scope),
            tostring(phase),
            tostring(reason),
            tostring(hasUpdates)
        ))

        ------------------------------------------------------------------------
        -- Case 0: PG-1 CookTapResponse 처리 (C-05~C-06, C-09)
        -- 서버 판정 수신 → CookGaugeUI에 확정 표시 → CookTimePhase 전환
        ------------------------------------------------------------------------
        if scope == "CookTapResponse" then
            local normalized = normalizeResponse(data)
            local phase = normalized.phase or "nil"
            local cookTimeDuration = normalized.cookTimeDuration

            -- S-12: CookTimePhase 로그 (Exit Evidence)
            print(string.format(
                "[Client] CookTapResponse RECV success=%s judgment=%s phase=%s duration=%s",
                tostring(normalized.success),
                tostring(normalized.judgment),
                phase,
                tostring(cookTimeDuration)
            ))

            if normalized.success and normalized.judgment then
                local CookGaugeUI = require(script.Parent.UI.CookGaugeUI)
                if CookGaugeUI:IsActive() then
                    -- C-05~C-06: 서버 확정 판정 표시
                    local wasCorrected = normalized.corrected == true
                    CookGaugeUI:ShowJudgment(normalized.judgment, wasCorrected)

                    ----------------------------------------------------------------
                    -- C-09: CookTimePhase 전환 (판정 표시 후)
                    ----------------------------------------------------------------
                    if phase == "COOK_TIME_START" and cookTimeDuration then
                        print(string.format(
                            "[Client] [C-09] CookTimePhase START slotId=%s duration=%.2f",
                            tostring(normalized.slotId), cookTimeDuration
                        ))

                        -- 판정 표시 후 CookGaugeUI Hide, CookTimePhase UI로 전환
                        -- 최소 0.6초 판정 표시 보장 후 전환
                        local capturedSlotId = normalized.slotId
                        local capturedDuration = cookTimeDuration
                        local capturedRecipeId = normalized.recipeId

                        task.delay(0.6, function()
                            -- S-20: 슬롯 비교 후 조건부 Hide (다른 슬롯 미니게임 보호)
                            if CookGaugeUI:IsActive() then
                                local activeSlot = CookGaugeUI:GetActiveSlotId()
                                if activeSlot == capturedSlotId then
                                    CookGaugeUI:Hide()
                                    print(string.format(
                                        "[CookGaugeUI] Hide reason=COOK_TIME_PHASE_ENTER slotId=%s",
                                        tostring(capturedSlotId)
                                    ))
                                else
                                    print(string.format(
                                        "[CookGaugeUI] Hide SKIPPED reason=COOK_TIME_PHASE_ENTER activeSlot=%s capturedSlot=%s",
                                        tostring(activeSlot), tostring(capturedSlotId)
                                    ))
                                end
                            end

                            -- C-09: MainHUD 타이머 UI 시작 (CookTimePhase)
                            if MainHUDInstance and MainHUDInstance.StartCookTimePhase then
                                -- 0.6초 지연 후 남은 시간 계산
                                local remainingDuration = capturedDuration - 0.6
                                if remainingDuration > 0 then
                                    MainHUDInstance:StartCookTimePhase(
                                        capturedSlotId,
                                        remainingDuration,
                                        capturedRecipeId
                                    )
                                end
                            else
                                warn("[Client] [C-09] MainHUDInstance.StartCookTimePhase not available")
                            end

                            print(string.format(
                                "[Client] [C-09] CookTimePhase UI transition slotId=%s remaining=%.2f",
                                tostring(capturedSlotId), capturedDuration - 0.6
                            ))
                        end)
                    end
                else
                    warn("[Client] CookTapResponse but CookGaugeUI not active")
                end
            elseif normalized.success == false then
                -- S-21: 실패 시 슬롯/세션 가드 적용 (멀티태스킹 정합성)
                local CookGaugeUI = require(script.Parent.UI.CookGaugeUI)
                if CookGaugeUI:IsActive() then
                    local activeSlot = CookGaugeUI:GetActiveSlotId()
                    local activeSession = CookGaugeUI:GetActiveSessionId()
                    local slotMatch = (activeSlot == normalized.slotId)
                    local sessionMatch = (normalized.sessionId == nil)
                        or (activeSession == nil)
                        or (activeSession == normalized.sessionId)
                    if slotMatch and sessionMatch then
                        CookGaugeUI:Hide()
                        print(string.format("[CookGaugeUI] Hide reason=FAIL error=%s",
                            tostring(normalized.error)))
                    else
                        print(string.format(
                            "[CookGaugeUI] Hide SKIPPED (fail) activeSlot=%s eventSlot=%s activeSession=%s eventSession=%s",
                            tostring(activeSlot), tostring(normalized.slotId),
                            tostring(activeSession), tostring(normalized.sessionId)
                        ))
                    end
                end
                print(string.format("[Client] CookTapResponse FAILED error=%s",
                    tostring(normalized.error)))
            end

            -- EventBus 발행 (다른 시스템이 필요 시 사용)
            ClientEvents.StateChanged:Fire("CookTapResponse", normalized)

            -- [TEST] S-11 증거: AFTER_TAP dishCount 덤프 (Studio only)
            if RunService:IsStudio() then
                local dishCount = 0
                for key, value in pairs(ClientData.inventory or {}) do
                    if type(key) == "string" and key:sub(1, 5) == "dish_" then
                        dishCount = dishCount + (value or 0)
                    end
                end
                print(string.format("[TEST] AFTER_TAP dishCount=%d (from ClientData.inventory)", dishCount))
            end
        end

        ------------------------------------------------------------------------
        -- Case 1: Response 객체 처리 (~Response 형태)
        ------------------------------------------------------------------------
        if scope == "DeliveryResponse" or scope == "CraftResponse" or
           scope == "UpgradeResponse" or scope == "OrderResponse" or
           scope == "TutorialResponse" then

            -- 정규화 적용
            local normalized = normalizeResponse(data)

            -- Phase 6: CraftResponse phase 로그 (2-phase 구분)
            if scope == "CraftResponse" then
                local phase = normalized.phase or "nil"
                local isActive = normalized.updates and normalized.updates.craftingState
                    and normalized.updates.craftingState.isActive
                local slotId = normalized.slotId or "nil"
                local mode = normalized.mode or "timer"
                local recipeId = normalized.updates and normalized.updates.craftingState
                    and normalized.updates.craftingState.recipeId or "nil"

                -- 기존 Phase 6 로그 유지
                print(string.format("[Client] CraftResponse RECV slot=%s phase=%s isActive=%s",
                    tostring(slotId), phase, tostring(isActive)))

                -- S-15/C-10: 감리 증거 로그 (Exit Evidence 포맷)
                local fallbackReasonLog = normalized.fallbackReason or "nil"
                print(string.format("[Client] [C-10] CraftResponse mode=%s phase=%s fallbackReason=%s slotId=%s",
                    mode, phase, fallbackReasonLog, tostring(slotId)))

                ----------------------------------------------------------------
                -- Bug 4 수정 3: 실패 응답 시 craftingState.failed 플래그 주입
                -- 조건 D: CraftResponse 스코프에만, 내부 정규화 레벨에서만 수행
                -- (다른 시스템이 craftingState를 "진행 상태"로 가정할 수 있으므로 오염 범위 통제)
                ----------------------------------------------------------------
                if normalized.success == false then
                    -- Updates가 없으면 강제 생성
                    if not normalized.updates then
                        normalized.updates = {}
                    end
                    -- craftingState.failed 플래그 주입 (MainHUD가 복구 트리거로 사용)
                    normalized.updates.craftingState = {
                        isActive = false,
                        failed = true,
                        error = normalized.error,
                        noticeCode = normalized.noticeCode,
                    }
                    print(string.format("[Client] CraftResponse FAILED error=%s noticeCode=%s",
                        tostring(normalized.error), tostring(normalized.noticeCode)))
                end

                ----------------------------------------------------------------
                -- C-10: CraftResponse 3단 분기 (PG-1.1 Gate)
                -- 1) mode="timer" + fallbackReason → MODE_TIMER_FALLBACK
                -- 2) mode="timer" (no reason) → Legacy timer
                -- 3) mode="cook_minigame" → PG-1/PG-1.1 처리
                ----------------------------------------------------------------
                local mode = normalized.mode or "timer"
                local fallbackReason = normalized.fallbackReason

                if mode == "timer" and fallbackReason then
                    ----------------------------------------------------------------
                    -- C-10: MODE_TIMER_FALLBACK (FallbackReason 존재 시에만)
                    ----------------------------------------------------------------
                    print(string.format(
                        "[Client] [C-10] TimerFallback mode=timer fallbackReason=%s slotId=%s",
                        tostring(fallbackReason), tostring(normalized.slotId)
                    ))
                    -- S-20: 슬롯 비교 후 조건부 Hide (다른 슬롯 미니게임 보호)
                    local CookGaugeUI = require(script.Parent.UI.CookGaugeUI)
                    if CookGaugeUI:IsActive() then
                        local activeSlot = CookGaugeUI:GetActiveSlotId()
                        if activeSlot == normalized.slotId then
                            print(string.format(
                                "[CookGaugeUI] Hide reason=MODE_TIMER_FALLBACK slotId=%s",
                                tostring(normalized.slotId)
                            ))
                            CookGaugeUI:Hide()
                        else
                            print(string.format(
                                "[CookGaugeUI] Hide SKIPPED reason=MODE_TIMER_FALLBACK activeSlot=%s slotId=%s",
                                tostring(activeSlot), tostring(normalized.slotId)
                            ))
                        end
                    end
                    -- timer fallback: MainHUD 타이머 흐름으로 진행
                elseif mode == "timer" then
                    ----------------------------------------------------------------
                    -- C-10: Legacy timer (fallbackReason 없음, 향후 제거 가능)
                    ----------------------------------------------------------------
                    print(string.format(
                        "[Client] [C-10] LegacyTimer mode=timer slotId=%s (no fallbackReason)",
                        tostring(normalized.slotId)
                    ))
                    -- Legacy timer 경로: 기존 MainHUD 처리
                end
                -- mode="cook_minigame"은 아래 별도 블록에서 처리

                if normalized.success and mode == "cook_minigame" then
                    ----------------------------------------------------------------
                    -- C-11: Phase 기반 cook_minigame 분기 (PG-1.1)
                    -- MINIGAME_START (또는 nil): CookGaugeUI 표시
                    -- COOK_TIME_COMPLETE: CookTimePhase 완료 처리
                    ----------------------------------------------------------------
                    local phase = normalized.phase

                    if phase == "COOK_TIME_COMPLETE" then
                        ----------------------------------------------------------------
                        -- C-11: COOK_TIME_COMPLETE 처리 (S-14 완료 응답)
                        -- dish 생성 완료 → CookTimePhase UI 숨김 → Serve 전환
                        ----------------------------------------------------------------
                        print(string.format(
                            "[Client] [C-11] CookTimePhase COMPLETE slotId=%s dishKey=%s recipeId=%s",
                            tostring(normalized.slotId),
                            tostring(normalized.dishKey),
                            tostring(normalized.recipeId)
                        ))

                        -- S-20: CookGaugeUI 조건부 Hide (슬롯+세션 정합성 가드)
                        -- 완료된 슬롯과 활성 슬롯이 일치할 때만 Hide (다른 슬롯 미니게임 보호)
                        local CookGaugeUI = require(script.Parent.UI.CookGaugeUI)
                        if CookGaugeUI:IsActive() then
                            local activeSlot = CookGaugeUI:GetActiveSlotId()
                            local activeSession = CookGaugeUI:GetActiveSessionId()

                            local slotMatch = (activeSlot == normalized.slotId)
                            local sessionMatch = (normalized.sessionId == nil)
                                or (activeSession == nil)
                                or (activeSession == normalized.sessionId)

                            if slotMatch and sessionMatch then
                                CookGaugeUI:Hide()
                                print("[CookGaugeUI] Hide reason=COOK_TIME_COMPLETE")
                            else
                                print(string.format(
                                    "[CookGaugeUI] Hide SKIPPED activeSlot=%s completedSlot=%s activeSession=%s completedSession=%s",
                                    tostring(activeSlot), tostring(normalized.slotId),
                                    tostring(activeSession), tostring(normalized.sessionId)
                                ))
                            end
                        end

                        -- C-11: MainHUD 타이머 UI 완료 (CookTimePhase → SERVE 전환)
                        if MainHUDInstance and MainHUDInstance.CompleteCookTimePhase then
                            MainHUDInstance:CompleteCookTimePhase(normalized.slotId)
                        else
                            warn("[Client] [C-11] MainHUDInstance.CompleteCookTimePhase not available")
                        end

                        -- Inventory 업데이트는 Updates 통해 MainHUD에서 처리됨
                        -- (ClientEvents.StateChanged → MainHUD 리스너)
                    else
                        ----------------------------------------------------------------
                        -- MINIGAME_START (또는 nil): 기존 CookGaugeUI 표시 로직
                        ----------------------------------------------------------------
                        local cookSession = normalized.cookSession
                        if cookSession then
                            -- slotId 주입 (콜백에서 필요)
                            cookSession.slotId = normalized.slotId

                            local CookGaugeUI = require(script.Parent.UI.CookGaugeUI)
                            CookGaugeUI:Show(cookSession, function(tapData)
                                -- RE_SubmitCookTap 전송 (최소 페이로드: sessionId, slotId만)
                                local RE_SubmitCookTap = Remotes:FindFirstChild("RE_SubmitCookTap")
                                if RE_SubmitCookTap then
                                    print(string.format(
                                        "[Client] SubmitCookTap session=%s slot=%d clientPos=%.2f",
                                        tapData.sessionId or "nil",
                                        tapData.slotId or 0,
                                        tapData.clientPos or 0
                                    ))
                                    -- 파라미터 순서: slotId, sessionId (서버 OnServerEvent와 일치)
                                    RE_SubmitCookTap:FireServer(tapData.slotId, tapData.sessionId)
                                else
                                    warn("[Client] RE_SubmitCookTap not found")
                                end
                            end)

                            print(string.format(
                                "[Client] CookGaugeUI shown for session=%s slot=%d",
                                cookSession.sessionId or "nil",
                                normalized.slotId or 0
                            ))
                        else
                            warn("[Client] cook_minigame mode but no cookSession (phase=%s)", phase or "nil")
                        end
                    end
                end
            end

            -- Phase 6: OrderResponse reason 로그 (rotate 동기화 추적)
            if scope == "OrderResponse" and normalized.meta then
                local reason = normalized.meta.reason or "nil"
                local slot = normalized.meta.slot or "nil"
                print(string.format("[Client] OrderResponse RECV reason=%s slot=%s",
                    reason, tostring(slot)))
            end

            -- Phase 7-B S-02.2: Unknown reason 가드
            -- Unknown scope 가드(Phase 7-A)와 동일 철학: warn + 관측, 크래시 방지
            if scope == "OrderResponse" then
                local meta = normalized.meta
                local reason = meta and meta.reason
                if reason and not KNOWN_ORDER_REASONS[reason] then
                    warn(string.format("[Client][WARN][UNKNOWN_ORDER_REASON] reason=%s slot=%s stamp=%s",
                        tostring(reason), tostring(meta.slot), tostring(meta.stamp)))
                end
            end

            ----------------------------------------------------------------
            -- P4: UpgradeResponse 증거 로그 (EC-P4-03)
            ----------------------------------------------------------------
            if scope == "UpgradeResponse" then
                if normalized.success then
                    -- 성공: newLevel, newCoins 추출
                    local newLevel = normalized.updates and normalized.updates.upgrades
                    local newCoins = normalized.updates and normalized.updates.wallet and normalized.updates.wallet.coins
                    print(string.format("[Client][RECV] scope=UpgradeResponse Success=true"))
                    print(string.format("UPGRADE_PURCHASE_SUCCESS upgradeId=%s newLevel=%s newCoins=%s",
                        tostring(data.UpgradeId or "unknown"),
                        tostring(data.NewLevel or "unknown"),
                        tostring(newCoins or "unknown")))
                else
                    -- 실패: NoticeCode 기반 로그
                    local noticeCode = normalized.noticeCode or normalized.error or "unknown"
                    print(string.format("[Client][RECV] scope=UpgradeResponse Success=false NoticeCode=%s",
                        tostring(noticeCode)))
                    print(string.format("UPGRADE_PURCHASE_FAIL upgradeId=%s reason=%s",
                        tostring(data.UpgradeId or "unknown"),
                        tostring(noticeCode)))
                    -- 실패 알림 표시
                    if noticeCode then
                        NoticeUI.Show(noticeCode, "error", noticeCode)
                    end
                end
            end

            ----------------------------------------------------------------
            -- P2: OrderResponse (Deliver) 성공 시 deliverResult scope 발화 준비
            -- Score/Tip/TotalRevenue를 UI에 전달하기 위한 별도 payload
            -- NOTE: 납품 응답은 "OrderResponse" scope로 전송됨 (DeliveryResponse는 배달 수령)
            ----------------------------------------------------------------
            local deliverResultPayload = nil
            if scope == "OrderResponse" and normalized.success and normalized.score then
                deliverResultPayload = {
                    score = normalized.score,
                    tip = normalized.tip,
                    reward = normalized.reward,
                    totalRevenue = normalized.totalRevenue,
                    walletCoins = normalized.walletCoins,
                    slotId = normalized.slotId,
                }
                print(string.format("[Client] P2|DELIVER_RESULT score=%s tip=%d reward=%d total=%d wallet=%d",
                    tostring(normalized.score), normalized.tip or 0, normalized.reward or 0,
                    normalized.totalRevenue or 0, normalized.walletCoins or 0))
            end

            ----------------------------------------------------------------
            -- 1. ClientData 업데이트 (StateChanged 발화 없이 데이터만 먼저 적용)
            -- 실패 응답에도 updates가 올 수 있으므로 success 무관하게 적용
            -- updatedScopes는 집합(set)으로 관리 (중복 방지, 순서 무관)
            ----------------------------------------------------------------
            local updatedScopes = {}  -- set: updatedScopes[scope] = true

            if normalized.updates then
                if normalized.updates.inventory then
                    ClientData.inventory = normalized.updates.inventory
                    updatedScopes["inventory"] = true
                end
                if normalized.updates.wallet then
                    ClientData.wallet = normalized.updates.wallet
                    updatedScopes["wallet"] = true
                end
                if normalized.updates.orders then
                    ClientData.orders = normalized.updates.orders
                    updatedScopes["orders"] = true
                end
                if normalized.updates.upgrades then
                    ClientData.upgrades = normalized.updates.upgrades
                    updatedScopes["upgrades"] = true
                end
                if normalized.updates.craftingState then
                    ClientData.craftingState = normalized.updates.craftingState
                    updatedScopes["craftingState"] = true
                end
                if normalized.updates.cooldown then
                    ClientData.cooldown = normalized.updates.cooldown
                    updatedScopes["cooldown"] = true
                end
                -- S-30: stale2Set 적용 (스냅샷 - 전체 재구성)
                if normalized.updates.stale2Set then
                    ClientData.stale2Set = normalized.updates.stale2Set
                    updatedScopes["stale2Set"] = true
                end
                if normalized.updates.tutorial then
                    -- 병합 정책: hasCompleted만 갱신, ui는 보존 (Presentation-only)
                    ClientData.tutorial.hasCompleted = normalized.updates.tutorial.hasCompleted
                    -- bonusGranted 등 서버 필드도 병합
                    if normalized.updates.tutorial.bonusGranted ~= nil then
                        ClientData.tutorial.bonusGranted = normalized.updates.tutorial.bonusGranted
                    end
                    if normalized.updates.tutorial.exitReason ~= nil then
                        ClientData.tutorial.exitReason = normalized.updates.tutorial.exitReason
                    end
                    -- ui는 건드리지 않음 (클라 전용)
                    updatedScopes["tutorial"] = true
                end
            end

            -- 실패 로그 (success=false인 경우)
            if not normalized.success and normalized.noticeCode then
                warn("[Client] Action Failed:", normalized.error, "NoticeCode:", normalized.noticeCode)
            end

            ----------------------------------------------------------------
            -- 2. Phase 3: TutorialManager로 응답 전달 (옵션 A: StateChanged 전)
            -- Step 전진이 UI 갱신보다 먼저 처리됨
            -- tutorialDirty가 true면 "tutorial" scope 강제 추가 (UI 갱신 보장)
            ----------------------------------------------------------------
            if TutorialManagerInstance then
                local tutorialDirty = TutorialManagerInstance:OnServerSend(scope, normalized)
                if tutorialDirty then
                    updatedScopes["tutorial"] = true
                end
            end

            ----------------------------------------------------------------
            -- 3. StateChanged 발화 (TutorialManager 처리 후)
            -- UI는 Tutorial Step이 반영된 최종 상태로 한 번에 갱신
            -- Phase 4: SCOPE_ORDER v4.0 (post_tutorial 추가, tutorial 스킵 지원)
            ----------------------------------------------------------------
            local SCOPE_ORDER = {"post_tutorial", "tutorial", "wallet", "inventory", "orders", "upgrades", "cooldown", "craftingState"}

            -- Phase 4: scope → ClientData 키 매핑 (snake_case scope → camelCase key)
            local SCOPE_DATA_KEY = {
                post_tutorial = "postTutorial",
            }

            -- Phase 4: batch 기록 + tutorial 스킵 증빙
            local batch = {}
            local tutorialUpdated = updatedScopes["tutorial"] == true
            local skippedTutorial = false

            for _, scopeName in ipairs(SCOPE_ORDER) do
                if updatedScopes[scopeName] then
                    -- Phase 4: tutorial scope 스킵 (상호배타 강제)
                    if scopeName == "tutorial" and ClientData.postTutorial.active then
                        skippedTutorial = true  -- 스킵 증빙
                        -- Phase 5: G5.2 Evidence (3.1.1 - tutorial 발화 스킵)
                        Gate5Logger.Log({ gate = "G5.2", player = Players.LocalPlayer, pass = true, reason = "tutorial_skipped" })
                        -- active=true면 tutorial scope 발화 스킵 (batch에도 미포함)
                    else
                        local dataKey = SCOPE_DATA_KEY[scopeName] or scopeName
                        -- Phase 4: nil payload 방어 (Dev/Studio only)
                        if ShouldGate4Log() and ClientData[dataKey] == nil then
                            warn(string.format("[G4.2][warning] nil payload for scope=%s dataKey=%s", scopeName, dataKey))
                        end
                        ClientEvents.StateChanged:Fire(scopeName, ClientData[dataKey])
                        table.insert(batch, scopeName)
                    end
                end
            end

            -- Phase 4: G4.2 Evidence (batch에 post_tutorial 포함 시 - RE_SyncState에서는 발생 안 함)
            -- NOTE: post_tutorial은 Client-only이므로 이 루프에서는 batch에 안 들어감
            -- 실제 G4.2 Evidence는 G4.0 Entry(순서 4)에서 출력됨
            if ShouldGate4Log() and table.find(batch, "post_tutorial") then
                local batchStr = table.concat(batch, ",")
                print(string.format("[G4.2][render] scope=post_tutorial via=StateChanged batch=%s tutorial_updated=%s skipped_tutorial=%s active=%s",
                    batchStr, tostring(tutorialUpdated), tostring(skippedTutorial), tostring(ClientData.postTutorial.active)))
            end

            -- Phase 4: G4.1 도메인별 검증 (updatedScopes 기준, active=true 이후에만)
            if updatedScopes["wallet"] then
                RunDomainInvariant("wallet", ClientData)
            end
            if updatedScopes["inventory"] then
                RunDomainInvariant("inventory", ClientData)
            end
            if updatedScopes["upgrades"] then
                RunDomainInvariant("upgrades", ClientData)
            end

            ----------------------------------------------------------------
            -- P2: deliverResult scope 발화 (UI에 Score/Tip 전달)
            -- SCOPE_ORDER 루프 외부에서 발화 (별도 scope, batch 미포함)
            ----------------------------------------------------------------
            if deliverResultPayload then
                ClientEvents.StateChanged:Fire("deliverResult", deliverResultPayload)
                print("[Client] P2|DELIVER_RESULT_FIRED")
            end

        ------------------------------------------------------------------------
        -- Case 2: 직접 데이터 업데이트 (명사형 scope)
        -- Note: Inventory/CraftingState legacy scope 삭제됨 (Phase 6 S-03.2 완료)
        ------------------------------------------------------------------------
        elseif scope == "Wallet" then
            ClientData.wallet = {
                coins = data.coins or data.Coins or 0
            }
            ClientEvents.StateChanged:Fire("wallet", ClientData.wallet)

        elseif scope == "Orders" then
            ClientData.orders = data
            ClientEvents.StateChanged:Fire("orders", ClientData.orders)

        ------------------------------------------------------------------------
        -- P4: DayEndResponse (threshold Day End 신호)
        -- F-01 준수: StateChanged 사용 X, MainHUD 직접 호출
        -- Contract v1.5 §4.6.1: Signal(신호) vs Data(스냅샷) 분리
        ------------------------------------------------------------------------
        elseif scope == "DayEndResponse" then
            local normalized = normalizeResponse(data)
            print(string.format("[Client][RECV] DayEndResponse success=%s reason=%s dayAfter=%s",
                tostring(normalized.success),
                tostring(normalized.reason),
                tostring(normalized.dayAfter)
            ))

            -- F-01: MainHUD에 직접 전달 (StateChanged 오염 방지)
            if MainHUDInstance and normalized.success then
                MainHUDInstance:OnDayEndSignal({
                    reason = normalized.reason or "threshold",
                    dayBefore = normalized.dayBefore,
                    dayAfter = normalized.dayAfter,
                    ordersServedAtEnd = normalized.ordersServedAtEnd,
                    target = normalized.target,
                })
            end

        ------------------------------------------------------------------------
        -- Case 3: Unknown scope 가드 (Phase 7-A S-07A-02)
        -- silent fail 방지: warn + 관측 로그, 데이터 적용 없음 (no-op)
        ------------------------------------------------------------------------
        else
            -- Unknown scope 요약 정보 수집
            local dataType = type(data)
            local hasUpdates = dataType == "table"
                and data.Updates ~= nil
                and type(data.Updates) == "table"
                and next(data.Updates) ~= nil
            local phase = dataType == "table" and (data.Phase or "nil") or "nil"
            local reason = dataType == "table" and data.Meta and data.Meta.reason or "nil"
            local keysTotal = 0
            local sample = {}

            -- 지적 B 반영: non-table payload 처리
            if dataType == "table" then
                for k, v in pairs(data) do
                    keysTotal = keysTotal + 1
                    if #sample < 4 then
                        local valStr = type(v) == "table" and "{...}" or tostring(v)
                        if #valStr > 20 then valStr = valStr:sub(1, 20) .. "..." end
                        table.insert(sample, tostring(k) .. "=" .. valStr)
                    end
                end
            else
                -- non-table: 값 자체를 sample에 기록
                local valStr = tostring(data)
                if #valStr > 50 then valStr = valStr:sub(1, 50) .. "..." end
                table.insert(sample, "value=" .. valStr)
            end

            warn(string.format(
                "[Client][WARN][UNKNOWN_SCOPE] scope=%s scopeType=%s dataType=%s phase=%s reason=%s hasUpdates=%s keys=%d sample={%s}",
                tostring(scope),
                type(scope),
                dataType,
                tostring(phase),
                tostring(reason),
                tostring(hasUpdates),
                keysTotal,
                table.concat(sample, ", ")
            ))
            -- no-op: 데이터 적용 없음
        end
    end)
end

--------------------------------------------------------------------------------
-- 3. 알림 수신 (Notice Listener)
--------------------------------------------------------------------------------

local function SetupNoticeListener()
    local RE_ShowNotice = Remotes:WaitForChild("RE_ShowNotice")

    RE_ShowNotice.OnClientEvent:Connect(function(code, severity, messageKey, extra)
        -- PG-1 Bug #1 Fix: session_consumed는 예상 동작(더블탭)이므로 silent fail
        -- 감리 승인: ChatGPT 2026-01-25 (Notice UI 팝업 없이 debug 로그만)
        if code == "session_consumed" or code == "cook_already_submitted" then
            print(string.format("[Notice] SUPPRESSED code=%s (expected double-tap)", code))
            return
        end

        -- A: extra에 dishKey가 있으면 로그에 포함
        local extraInfo = extra and extra.dishKey or "nil"
        print(string.format("[Notice] [%s] %s (Code: %s, dishKey: %s)", severity, messageKey, code, extraInfo))
        NoticeUI.Show(code, severity, messageKey, extra)
    end)
end

--------------------------------------------------------------------------------
-- 4. 액션 메서드 (UI에서 호출)
--------------------------------------------------------------------------------

function ClientController:CollectDelivery()
    local RE = Remotes:FindFirstChild("RE_CollectDelivery")
    if RE then
        RE:FireServer()
    end
end

function ClientController:DeliverOrder(slotId)
    local RE = Remotes:FindFirstChild("RE_DeliverOrder")
    if RE then
        RE:FireServer(slotId)
    end
end

-- P1-CONTRACT-SLOT-BINDING: Deprecated 경고 플래그 (세션당 1회 제한)
local _craftItemLegacyWarned = false

-- DEPRECATED (v1.3): CraftItemForSlot(slotId)로 대체됨
-- Single Path Policy: 서버 전송 금지, no-op
function ClientController:CraftItem(recipeId)
    -- 스팸 방지: 세션당 최초 1회만 경고
    if not _craftItemLegacyWarned then
        _craftItemLegacyWarned = true
        warn(string.format(
            "[ClientController] DEPRECATED|CRAFT_ITEM_LEGACY called recipeId=%s\n%s",
            tostring(recipeId),
            debug.traceback()
        ))
    end
    -- no-op: 서버 전송하지 않음 (v1.3 Single Path Policy)
end

-- P1-CONTRACT-SLOT-BINDING: slotId 기반 Craft 요청 (v1.3 표준)
function ClientController:CraftItemForSlot(slotId)
    -- 클라이언트 가드: 명백한 잘못된 입력 차단
    if type(slotId) ~= "number" or slotId % 1 ~= 0 or slotId < 1 or slotId > 3 then
        warn(string.format(
            "[Client] CRAFT_REQ_REJECT bad_param slotId=%s type=%s",
            tostring(slotId), type(slotId)
        ))
        return
    end

    local RE = Remotes:FindFirstChild("RE_CraftItem")
    if not RE then
        warn("[Client] CRAFT_REQ_FAILED reason=no_remote")
        return
    end

    print(string.format("[Client] CRAFT_REQ slotId=%d", slotId))
    RE:FireServer(slotId)
end

function ClientController:BuyUpgrade(upgradeId)
    local RE = Remotes:FindFirstChild("RE_BuyUpgrade")
    if RE then
        RE:FireServer(upgradeId)
    end
end

function ClientController:CompleteTutorial()
    local RE = Remotes:FindFirstChild("RE_CompleteTutorial")
    if RE then
        RE:FireServer()
    end
end

--------------------------------------------------------------------------------
-- P3: Manual Day End (Contract v1.4 §4.7)
--------------------------------------------------------------------------------

function ClientController:EndDay()
    local RF = Remotes:FindFirstChild("RF_EndDay")
    if not RF then
        warn("[Client] DAYEND_REQ_FAILED reason=no_remote")
        return { Success = false, Error = "no_remote", NoticeCode = "no_remote" }
    end

    print("[Client] DAYEND_REQ_SEND")

    -- CRIT-C-01: pcall로 InvokeServer 감싸기 (네트워크/런타임 에러 방어)
    local ok, response = pcall(function()
        return RF:InvokeServer()
    end)

    -- pcall 실패 시 (네트워크 에러, 타임아웃 등)
    if not ok then
        local errMsg = tostring(response)  -- pcall 실패 시 response는 에러 메시지
        warn(string.format("[Client] DAYEND_REQ_RECV success=false error=invoke_failed detail=%s", errMsg))
        return { Success = false, Error = "data_error", NoticeCode = "data_error" }
    end

    -- 응답 로그
    if response then
        if response.Success then
            print(string.format(
                "[Client] DAYEND_REQ_RECV success=true reason=%s dayBefore=%d dayAfter=%d",
                tostring(response.Reason),
                response.DayBefore or 0,
                response.DayAfter or 0
            ))
        else
            print(string.format(
                "[Client] DAYEND_REQ_RECV success=false error=%s noticeCode=%s",
                tostring(response.Error),
                tostring(response.NoticeCode)
            ))
        end
    else
        warn("[Client] DAYEND_REQ_RECV success=false error=nil_response")
        return { Success = false, Error = "data_error", NoticeCode = "data_error" }
    end

    return response
end

--------------------------------------------------------------------------------
-- 5. 데이터 접근자 (다른 클라이언트 스크립트용)
--------------------------------------------------------------------------------

function ClientController:GetData()
    return ClientData
end

function ClientController:GetInventory()
    return ClientData.inventory
end

function ClientController:GetWallet()
    return ClientData.wallet
end

function ClientController:GetOrders()
    return ClientData.orders
end

function ClientController:GetUpgrades()
    return ClientData.upgrades
end

function ClientController:GetCooldown()
    return ClientData.cooldown
end

function ClientController:GetCraftingState()
    return ClientData.craftingState
end

function ClientController:GetTutorial()
    return ClientData.tutorial
end

--------------------------------------------------------------------------------
-- Phase 3: TutorialManager 접근자
--------------------------------------------------------------------------------

function ClientController:GetTutorialManager()
    return TutorialManagerInstance
end

function ClientController:IsTutorialActive()
    return TutorialManagerInstance and TutorialManagerInstance:IsActive() or false
end

--------------------------------------------------------------------------------
-- 실행 (Execution)
--------------------------------------------------------------------------------

task.wait(1) -- 서버 로딩 안전 마진

-- UI 초기화
NoticeUI:Init()

-- 리스너 설정
SetupSyncListener()
SetupNoticeListener()

-- 초기 데이터 로드
Initialize()

-- 물리 인터랙션 연결 (MVP)
InteractionHandler.Init(ClientController)

print("[Client] ========== 클라이언트 부트스트랩 완료 ==========")

return ClientController
