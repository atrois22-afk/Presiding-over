-- Server/RemoteHandler.lua
-- SSOT v0.2.3.3 / Contract v1.3 Addendum
-- 역할: Remote 이벤트 연결, HandleServiceResponse 어댑터, GATE3 로깅

local RunService = game:GetService("RunService")

local ServerFlags = require(game.ReplicatedStorage.Shared.ServerFlags)
local GameData = require(game.ReplicatedStorage.Shared.GameData)
local PoolUtils = require(game.ReplicatedStorage.Shared.PoolUtils)

local RemoteHandler = {}

--------------------------------------------------------------------------------
-- Refill 전용 RNG (모듈 스코프)
--------------------------------------------------------------------------------

local RefillRNG = Random.new()

-- 의존성 주입용 참조
local Remotes = nil
local Services = nil

--------------------------------------------------------------------------------
-- Phase 3: GATE3 로깅 인프라 (Studio Only)
-- Evidence: server_recv, server_send
-- 최소 필드: uid, joinTs, name, scope, success, error, noticeCode
-- SSOT: Contract §15.3과 필드명 일치 (noticeCode)
--------------------------------------------------------------------------------

local IS_STUDIO = RunService:IsStudio()

-- SSOT: ServerFlags.GATE3_LOG_ENABLED (false = 운영 모드, true = 검증 모드)
local GATE3_LOG_ENABLED = ServerFlags.GATE3_LOG_ENABLED

--[[
    GATE3 로그 헬퍼 (중앙 집중)
    @param logType: "recv" | "send" | "bonus" | "SEALED"
    @param player: Player instance
    @param data: { name?, scope?, success?, error?, noticeCode?, ... }

    필드명 SSOT: Contract/Gate 문서와 동일하게 noticeCode 사용
]]
local function GATE3_LOG(logType, player, data)
    if not IS_STUDIO then return end
    if not GATE3_LOG_ENABLED then return end

    local uid = player.UserId
    local joinTs = Services.DataService:GetJoinTs(player) or 0

    local fields = {
        string.format("uid=%d", uid),
        string.format("joinTs=%d", joinTs),
    }

    -- 데이터 필드 추가 (순서 보장을 위해 특정 키 우선)
    -- 필드명 SSOT: noticeCode (Contract §15.3과 일치)
    local orderedKeys = { "name", "scope", "success", "error", "noticeCode" }
    local addedKeys = {}

    for _, key in ipairs(orderedKeys) do
        if data[key] ~= nil then
            table.insert(fields, string.format("%s=%s", key, tostring(data[key])))
            addedKeys[key] = true
        end
    end

    -- 나머지 키 추가
    for key, value in pairs(data) do
        if not addedKeys[key] then
            table.insert(fields, string.format("%s=%s", key, tostring(value)))
        end
    end

    print(string.format("[GATE3][%s] %s", logType, table.concat(fields, " ")))
end

--[[
    server_recv 로그 (요청 수신)
    - scope 없음 (recv는 요청 시점, scope는 응답에서 결정)
]]
local function LogServerRecv(player, actionName)
    GATE3_LOG("recv", player, { name = actionName })
end

--[[
    server_send 로그 (응답 전송 - Evidence)
    - name 포함 (디버깅 역추적용)
    - Contract §15.3: success=false인데 error=nil이면 경고
]]
local function LogServerSend(player, actionName, scope, response)
    -- §15.3 계약 위반 감지 (운영 유지 - GATE3_LOG_ENABLED 무관)
    -- success=false인데 error 없음
    if response.Success == false and response.Error == nil then
        warn(string.format(
            "[Contract] Invalid response: error missing (scope=%s uid=%d)",
            scope, player.UserId
        ))
    end

    -- noticeCode 누락 감지 (§15.3)
    if response.Success == false and response.NoticeCode == nil then
        warn(string.format(
            "[Contract] Invalid response: noticeCode missing (scope=%s uid=%d)",
            scope, player.UserId
        ))
    end

    GATE3_LOG("send", player, {
        name = actionName,  -- recv와 매칭용
        scope = scope,
        success = response.Success,
        error = response.Error or "nil",
        noticeCode = response.NoticeCode or "nil",
    })
end

--------------------------------------------------------------------------------
-- HandleServiceResponse (camelCase → PascalCase 변환)
-- 서비스는 camelCase로 반환, Contract v1.2는 PascalCase 요구
--------------------------------------------------------------------------------

local function HandleServiceResponse(result)
    if not result then
        return { Success = false, Error = "internal_error" }
    end

    local response = {}

    -- 필수 필드 변환
    response.Success = result.success

    -- 선택 필드 변환 (존재할 때만)
    if result.error then
        response.Error = result.error
    end

    if result.noticeCode then
        response.NoticeCode = result.noticeCode
    end

    if result.updates then
        response.Updates = {}
        if result.updates.wallet then
            response.Updates.Wallet = result.updates.wallet
        end
        if result.updates.inventory then
            -- [FIX] 혼합 키 테이블 직렬화 문제 해결: 모든 키를 문자열로 변환
            local invToSend = {}
            for k, v in pairs(result.updates.inventory) do
                invToSend[tostring(k)] = v
            end
            response.Updates.Inventory = invToSend
        end
        -- S-30: Stale2Keys 동기화 (Inventory와 함께 전송)
        if result.updates.stale2Keys then
            response.Updates.Stale2Keys = result.updates.stale2Keys
        end
        if result.updates.orders then
            response.Updates.Orders = result.updates.orders
        end
        if result.updates.upgrades then
            response.Updates.Upgrades = result.updates.upgrades
        end
        if result.updates.cooldown then
            response.Updates.Cooldown = result.updates.cooldown
        end
        if result.updates.craftingState then
            response.Updates.CraftingState = result.updates.craftingState
        end
    end

    if result.analytics then
        response.Analytics = result.analytics
    end

    -- 서비스별 특수 필드
    if result.items then
        response.Items = result.items
    end
    if result.newLevel then
        response.NewLevel = result.newLevel
    end
    if result.cost then
        response.Cost = result.cost
    end
    -- P4: upgradeId 필드 변환 (감리 추적성)
    if result.upgradeId then
        response.UpgradeId = result.upgradeId
    end
    if result.craftTime then
        response.CraftTime = result.craftTime
    end
    -- P1-CONTRACT-SLOT-BINDING: slotId 상위 필드 에코
    if result.slotId then
        response.SlotId = result.slotId
    end
    if result.recipeId then
        response.RecipeId = result.recipeId
    end
    if result.remainingTime then
        response.RemainingTime = result.remainingTime
    end
    if result.required then
        response.Required = result.required
    end
    if result.current then
        response.Current = result.current
    end
    if result.recoveryTriggered then
        response.RecoveryTriggered = result.recoveryTriggered
    end

    -- P2: Score/Tip 필드 변환 (Contract v1.4)
    if result.score then
        response.Score = result.score
    end
    if result.tip then
        response.Tip = result.tip
    end
    if result.totalRevenue then
        response.TotalRevenue = result.totalRevenue
    end
    if result.walletCoins then
        response.WalletCoins = result.walletCoins
    end
    if result.reward then
        response.Reward = result.reward
    end

    -- Phase 2: Partial Delivery 필드 변환
    if result.isPartialDelivery then
        response.IsPartialDelivery = result.isPartialDelivery
    end
    if result.cappedItems then
        response.CappedItems = result.cappedItems
    end

    -- PG-1: Mode 분기 필드 (cook_minigame / timer)
    if result.mode then
        response.Mode = result.mode
    end

    -- PG-1: CookSession 변환 (중첩 객체, camelCase → PascalCase)
    if result.cookSession then
        response.CookSession = {
            SessionId = result.cookSession.sessionId,
            Seed = result.cookSession.seed,
            GaugeSpeed = result.cookSession.gaugeSpeed,
            UiTargetZone = result.cookSession.uiTargetZone,
            IsTutorial = result.cookSession.isTutorial,
            Ttl = result.cookSession.ttl,
        }
    end

    -- PG-1: SubmitCookTap 응답 필드 (S-07)
    if result.sessionId then
        response.SessionId = result.sessionId
    end
    if result.serverGaugePos then
        response.ServerGaugePos = result.serverGaugePos
    end
    if result.judgment then
        response.Judgment = result.judgment
    end
    if result.cookScore then
        response.CookScore = result.cookScore
    end
    if result.corrected ~= nil then
        response.Corrected = result.corrected
    end

    -- S-12/S-15: CookTimePhase 응답 필드 (PG-1.1)
    if result.Phase then
        response.Phase = result.Phase
    end
    if result.CookTimeDuration then
        response.CookTimeDuration = result.CookTimeDuration
    end
    if result.FallbackReason then
        response.FallbackReason = result.FallbackReason
    end

    return response
end

--------------------------------------------------------------------------------
-- 초기화 (의존성 주입)
--------------------------------------------------------------------------------

function RemoteHandler:Init(config)
    Remotes = config.Remotes
    Services = config.Services

    self:ConnectRemotes()
    print("[RemoteHandler] 초기화 완료")
end

--------------------------------------------------------------------------------
-- Remote 연결
--------------------------------------------------------------------------------

function RemoteHandler:ConnectRemotes()
    local RF_GetInitialData = Remotes:FindFirstChild("RF_GetInitialData")
    local RE_CollectDelivery = Remotes:FindFirstChild("RE_CollectDelivery")
    local RE_CraftItem = Remotes:FindFirstChild("RE_CraftItem")
    local RE_BuyUpgrade = Remotes:FindFirstChild("RE_BuyUpgrade")
    local RE_DeliverOrder = Remotes:FindFirstChild("RE_DeliverOrder")
    local RE_CompleteTutorial = Remotes:FindFirstChild("RE_CompleteTutorial")
    local RE_SubmitCookTap = Remotes:FindFirstChild("RE_SubmitCookTap")  -- PG-1: S-07
    local RE_SyncState = Remotes:WaitForChild("RE_SyncState")
    local RE_ShowNotice = Remotes:WaitForChild("RE_ShowNotice")

    ---------------------------------------------------------------------------
    -- Notice 발송 헬퍼 (Phase 2: Partial Delivery 지원)
    -- P0-Server-2: 실패 시 OR 성공 + 특수 NoticeCode 시
    ---------------------------------------------------------------------------
    local function FireNoticeIfNeeded(player, response)
        if type(response) ~= "table" then
            warn("[RemoteHandler] FireNoticeIfNeeded: invalid response type")
            return
        end

        local failed = (response.Success == false) or (response.Error ~= nil)

        -- Case 1: 실패 시 Notice 발송
        if failed and response.NoticeCode then
            local severity = "error"
            RE_ShowNotice:FireClient(player, response.NoticeCode, severity, response.NoticeCode)
            return
        end

        -- Case 2: Phase 2 - Partial Delivery (성공이지만 알림 필요)
        if response.Success and response.IsPartialDelivery and response.NoticeCode then
            local severity = "warning"  -- 경고 (오렌지) - 실패 아니지만 주의 필요
            RE_ShowNotice:FireClient(player, response.NoticeCode, severity, response.NoticeCode)
            return
        end
    end

    ---------------------------------------------------------------------------
    -- RF_GetInitialData (RemoteFunction - 동기)
    ---------------------------------------------------------------------------
    RF_GetInitialData.OnServerInvoke = function(player)
        local result = Services.DataService:GetInitialData(player)
        -- GetInitialData는 이미 PascalCase로 반환하므로 변환 불필요
        return result
    end

    ---------------------------------------------------------------------------
    -- P2: RF_GetDayEnd (RemoteFunction - 동기) — Contract v1.4 §4.6
    -- Day End 스냅샷 조회 (RF 단일 경로)
    ---------------------------------------------------------------------------
    local RF_GetDayEnd = Remotes:FindFirstChild("RF_GetDayEnd")
    if RF_GetDayEnd then
        RF_GetDayEnd.OnServerInvoke = function(player)
            -- data_error 가드 (§4.6 에러 응답 정책)
            local dayStats = Services.DataService:GetDayStats(player)
            if not dayStats then
                return {
                    Success = false,
                    Error = "data_error",
                    NoticeCode = "data_error",
                }
            end

            -- P4: WalletCoins SSOT를 위해 playerData도 로드
            local playerData = Services.DataService:GetPlayerData(player)
            if not playerData or not playerData.wallet then
                return {
                    Success = false,
                    Error = "data_error",
                    NoticeCode = "data_error",
                }
            end

            -- I-P2-DA-01: Snapshot은 복사본 (새 테이블) 생성
            -- 라이브 참조 반환 금지 (이후 Deliver 시 값 변경됨)
            -- P4: WalletCoins 추가 (Day Summary SSOT)
            local snapshot = {
                Day = dayStats.day,
                SnapshotAt = os.time(),
                OrdersServed = dayStats.ordersServed,
                TotalReward = dayStats.totalReward,
                TotalTip = dayStats.totalTip,
                TotalRevenue = dayStats.totalReward + dayStats.totalTip,
                WalletCoins = playerData.wallet.coins or 0,
            }

            -- P2/P4 로그: DAYEND_SNAPSHOT (감리 검증용)
            -- source=dayStats_copy+wallet: 혼합 소스 (dayStats + playerData.wallet)
            print(string.format(
                "DAYEND_SNAPSHOT uid=%d day=%d ordersServed=%d totalReward=%d totalTip=%d totalRevenue=%d walletCoins=%d source=dayStats_copy+wallet",
                player.UserId,
                snapshot.Day,
                snapshot.OrdersServed,
                snapshot.TotalReward,
                snapshot.TotalTip,
                snapshot.TotalRevenue,
                snapshot.WalletCoins
            ))

            return {
                Success = true,
                Snapshot = snapshot,
            }
        end
        print("[RemoteHandler] RF_GetDayEnd 연결 완료 (P2/P4)")
    else
        warn("[RemoteHandler] RF_GetDayEnd RemoteFunction not found - P2 Day End disabled")
    end

    ---------------------------------------------------------------------------
    -- P3: RF_EndDay (RemoteFunction - 동기) — Contract v1.4 §4.7
    -- Manual Day End 트리거 (클라이언트 버튼 → 서버 처리)
    -- threshold 자동 트리거는 OrderService에서 직접 호출
    ---------------------------------------------------------------------------
    local RF_EndDay = Remotes:FindFirstChild("RF_EndDay")
    if RF_EndDay then
        RF_EndDay.OnServerInvoke = function(player)
            -- P3 로그: DAYEND_MANUAL_RECV (감리 검증용)
            print(string.format("DAYEND_MANUAL_RECV uid=%d", player.UserId))

            -- DataService:ProcessDayEnd 호출 (reason = "manual")
            -- ProcessDayEnd는 이미 PascalCase 응답 반환 (HandleServiceResponse 불필요)
            local response = Services.DataService:ProcessDayEnd(player, "manual")

            -- P3 로그: DAYEND_MANUAL_SEND
            print(string.format(
                "DAYEND_MANUAL_SEND uid=%d success=%s error=%s",
                player.UserId,
                tostring(response.Success),
                tostring(response.Error or "nil")
            ))

            return response
        end
        print("[RemoteHandler] RF_EndDay 연결 완료 (P3)")
    else
        warn("[RemoteHandler] RF_EndDay RemoteFunction not found - P3 Manual Day End disabled")
    end

    ---------------------------------------------------------------------------
    -- RE_CollectDelivery (RemoteEvent - 비동기)
    ---------------------------------------------------------------------------
    RE_CollectDelivery.OnServerEvent:Connect(function(player)
        LogServerRecv(player, "CollectDelivery")

        local result = Services.DeliveryService:CollectDelivery(player)
        local response = HandleServiceResponse(result)

        LogServerSend(player, "CollectDelivery", "DeliveryResponse", response)
        RE_SyncState:FireClient(player, "DeliveryResponse", response)
        FireNoticeIfNeeded(player, response)
    end)

    ---------------------------------------------------------------------------
    -- RE_CraftItem (RemoteEvent - 비동기)
    -- P1-CONTRACT-SLOT-BINDING: v1.3에서 recipeId → slotId로 변경
    ---------------------------------------------------------------------------
    RE_CraftItem.OnServerEvent:Connect(function(player, slotId)
        LogServerRecv(player, "CraftItem")

        -- P1-CONTRACT-SLOT-BINDING: slotId 타입/범위 검증 (1~3 정수)
        if type(slotId) ~= "number" or slotId % 1 ~= 0 or slotId < 1 or slotId > 3 then
            warn(string.format(
                "[RemoteHandler] CraftItem bad_param uid=%d slotId=%s type=%s",
                player.UserId, tostring(slotId), type(slotId)
            ))
            local errorResponse = HandleServiceResponse({
                success = false,
                error = "bad_param",
                noticeCode = "bad_param",
            })
            RE_SyncState:FireClient(player, "CraftResponse", errorResponse)
            FireNoticeIfNeeded(player, errorResponse)
            return
        end

        local result = Services.CraftingService:CraftItem(player, slotId)
        local response = HandleServiceResponse(result)

        -- Phase 6: 2-phase CraftResponse 구분 (start/complete)
        response.Phase = "start"

        LogServerSend(player, "CraftItem", "CraftResponse", response)
        RE_SyncState:FireClient(player, "CraftResponse", response)
        FireNoticeIfNeeded(player, response)
    end)

    ---------------------------------------------------------------------------
    -- RE_SubmitCookTap (RemoteEvent - 비동기) — PG-1 S-07
    -- Cook 미니게임 탭 제출 처리
    ---------------------------------------------------------------------------
    if RE_SubmitCookTap then
        RE_SubmitCookTap.OnServerEvent:Connect(function(player, slotId, sessionId, clientJudgment)
            LogServerRecv(player, "SubmitCookTap")

            -- slotId 타입/범위 검증 (1~3 정수)
            if type(slotId) ~= "number" or slotId % 1 ~= 0 or slotId < 1 or slotId > 3 then
                warn(string.format(
                    "[RemoteHandler] SubmitCookTap bad_param uid=%d slotId=%s",
                    player.UserId, tostring(slotId)
                ))
                local errorResponse = HandleServiceResponse({
                    success = false,
                    error = "bad_param",
                    noticeCode = "bad_param",
                })
                RE_SyncState:FireClient(player, "CookTapResponse", errorResponse)
                FireNoticeIfNeeded(player, errorResponse)
                return
            end

            -- sessionId 타입 검증 (문자열)
            if type(sessionId) ~= "string" or sessionId == "" then
                warn(string.format(
                    "[RemoteHandler] SubmitCookTap bad_session uid=%d sessionId=%s",
                    player.UserId, tostring(sessionId)
                ))
                local errorResponse = HandleServiceResponse({
                    success = false,
                    error = "bad_param",
                    noticeCode = "cook_session_error",
                })
                RE_SyncState:FireClient(player, "CookTapResponse", errorResponse)
                FireNoticeIfNeeded(player, errorResponse)
                return
            end

            -- clientJudgment 검증 (nil 허용, 문자열이면 유효 판정만)
            local validJudgments = { Perfect = true, Great = true, Good = true, OK = true, Bad = true }
            if clientJudgment ~= nil and (type(clientJudgment) ~= "string" or not validJudgments[clientJudgment]) then
                clientJudgment = nil  -- 무효한 값은 nil로 처리 (보호 미적용)
            end

            local result = Services.CraftingService:SubmitCookTap(player, slotId, sessionId, clientJudgment)
            local response = HandleServiceResponse(result)

            LogServerSend(player, "SubmitCookTap", "CookTapResponse", response)
            RE_SyncState:FireClient(player, "CookTapResponse", response)
            FireNoticeIfNeeded(player, response)
        end)
        print("[RemoteHandler] RE_SubmitCookTap 연결 완료 (PG-1)")
    else
        warn("[RemoteHandler] RE_SubmitCookTap RemoteEvent not found - PG-1 disabled")
    end

    ---------------------------------------------------------------------------
    -- S-30: RE_ManualDiscard (RemoteEvent - 비동기)
    ---------------------------------------------------------------------------
    local RE_ManualDiscard = Remotes:FindFirstChild("RE_ManualDiscard")
    if RE_ManualDiscard then
        RE_ManualDiscard.OnServerEvent:Connect(function(player, dishKey)
            LogServerRecv(player, "ManualDiscard")

            local result = Services.OrderService:ManualDiscard(player, dishKey)
            local response = HandleServiceResponse(result)

            LogServerSend(player, "ManualDiscard", "DiscardResponse", response)
            RE_SyncState:FireClient(player, "DiscardResponse", response)
            FireNoticeIfNeeded(player, response)
        end)
        print("[RemoteHandler] RE_ManualDiscard 연결 완료 (S-30)")
    else
        warn("[RemoteHandler] RE_ManualDiscard RemoteEvent not found - S-30 disabled")
    end

    ---------------------------------------------------------------------------
    -- RE_BuyUpgrade (RemoteEvent - 비동기)
    ---------------------------------------------------------------------------
    RE_BuyUpgrade.OnServerEvent:Connect(function(player, upgradeId)
        LogServerRecv(player, "BuyUpgrade")

        local result = Services.UpgradeService:BuyUpgrade(player, upgradeId)
        local response = HandleServiceResponse(result)

        LogServerSend(player, "BuyUpgrade", "UpgradeResponse", response)
        RE_SyncState:FireClient(player, "UpgradeResponse", response)
        FireNoticeIfNeeded(player, response)
    end)

    ---------------------------------------------------------------------------
    -- RE_DeliverOrder (RemoteEvent - 비동기)
    ---------------------------------------------------------------------------
    RE_DeliverOrder.OnServerEvent:Connect(function(player, slotId)
        LogServerRecv(player, "DeliverOrder")

        -- OrderService는 playerData를 외부에서 주입받음
        local playerData = Services.DataService:GetPlayerData(player)
        if not playerData then
            local errorResponse = HandleServiceResponse({
                success = false,
                error = "no_player_data",
                noticeCode = "data_error",
            })
            -- Phase 7-B S-02.1b: Deliver 실패에도 Meta 추가
            errorResponse.Meta = {
                reason = "deliver",
                slot = slotId,
            }
            LogServerSend(player, "DeliverOrder", "OrderResponse", errorResponse)
            RE_SyncState:FireClient(player, "OrderResponse", errorResponse)
            FireNoticeIfNeeded(player, errorResponse)
            return
        end

        local result = Services.OrderService:DeliverOrder(player, slotId, playerData)
        local response = HandleServiceResponse(result)

        -- Phase 7-B S-02.1b: Deliver에 Meta 추가 (성공/실패 모두)
        if result.success then
            -- 성공: reason + slot + stamp
            local stamp = Services.OrderService:GetOrderStamp(player, slotId)
            response.Meta = {
                reason = "deliver",
                slot = slotId,
                stamp = stamp,
            }

            -- deliver_order는 빈도가 높으므로 즉시 저장 제거
            -- dirty 마킹 후 autosave/PlayerRemoving/BindToClose로 저장
            Services.DataService:MarkDirty(player)

            -- 주문 리필 (빈 슬롯에 새 주문 생성)
            self:RefillOrderSlot(player, slotId)
        else
            -- 실패: reason + slot만 (stamp는 변경되지 않았으므로 미포함)
            response.Meta = {
                reason = "deliver",
                slot = slotId,
            }
        end

        LogServerSend(player, "DeliverOrder", "OrderResponse", response)
        RE_SyncState:FireClient(player, "OrderResponse", response)
        FireNoticeIfNeeded(player, response)
    end)

    ---------------------------------------------------------------------------
    -- RE_CompleteTutorial (RemoteEvent - 비동기)
    ---------------------------------------------------------------------------
    RE_CompleteTutorial.OnServerEvent:Connect(function(player)
        LogServerRecv(player, "CompleteTutorial")

        local result = Services.DataService:CompleteTutorial(player)
        local response = HandleServiceResponse(result)

        LogServerSend(player, "CompleteTutorial", "TutorialResponse", response)
        RE_SyncState:FireClient(player, "TutorialResponse", response)
        FireNoticeIfNeeded(player, response)
    end)

    print("[RemoteHandler] 모든 Remote 연결 완료")
end

--------------------------------------------------------------------------------
-- Phase 6: BroadcastCraftComplete (CraftingService 통합)
-- 목적: RE_SyncState 직접 호출을 RemoteHandler 단일 경로로 통일
-- scope: CraftResponse (기존 scope 재사용 - ClientController 분기 최소화)
--------------------------------------------------------------------------------

function RemoteHandler:BroadcastCraftComplete(player, updates, overrides)
    -- 가드 1: player 유효성 (task.delay 콜백에서 호출되므로 이중 안전)
    if not player or not player.Parent then
        warn("[RemoteHandler] BroadcastCraftComplete: player invalid")
        return
    end

    local RE_SyncState = Remotes:FindFirstChild("RE_SyncState")
    if not RE_SyncState then
        warn("[RemoteHandler] BroadcastCraftComplete: RE_SyncState not found")
        return
    end

    -- S-18 Fix: overrides 파라미터로 mode/phase 오버라이드 지원
    -- overrides = { mode = "cook_minigame", phase = "COOK_TIME_COMPLETE", ... }
    overrides = overrides or {}

    -- Contract Response 포맷 구성 (G-01 준수)
    -- Phase 6: 2-phase CraftResponse 구분 (start/complete)
    -- S-18: Mode/Phase 오버라이드 지원 (PG-1.1 CookTimePhase용)
    -- S-18 감리 요구: Mode는 반드시 non-nil (레거시 호환)
    local response = {
        Success = true,
        Mode = overrides.mode or "timer",               -- S-18: 레거시 기본값 "timer" 보장
        Phase = overrides.phase or "complete",          -- S-18: phase 오버라이드
        SlotId = updates.slotId,  -- P1-CRIT: 완료된 슬롯 ID (클라이언트 SERVE 전환용)
        RecipeId = updates.recipeId,                    -- S-18: recipeId 추가
        DishKey = updates.dishKey,                      -- S-18: dishKey 추가
        Updates = {},
    }

    -- Updates 필드 변환 (camelCase → PascalCase, 키 문자열화)
    if updates.inventory then
        local invToSend = {}
        for k, v in pairs(updates.inventory) do
            invToSend[tostring(k)] = v
        end
        response.Updates.Inventory = invToSend

        -- S-30: Stale2Keys 동기화 (Inventory와 함께)
        response.Updates.Stale2Keys = Services.DataService:GetStale2Keys(player)
    end

    -- S-24 FIX: Orders 자동 동기화 (reservedDishKey 포함)
    -- 중앙집중형(Option B): 호출부 누락 방지를 위해 BroadcastCraftComplete에서 항상 동기화
    local playerData = Services.DataService:GetPlayerData(player)
    if playerData and playerData.orders then
        response.Updates.Orders = playerData.orders

        -- S-24 Exit Evidence: CraftComplete 시점 reservation 상태 로깅
        local slotId = updates.slotId
        local reservedKey = slotId and playerData.orders[slotId] and playerData.orders[slotId].reservedDishKey
        print(string.format(
            "[RemoteHandler] S-24|CRAFTCOMPLETE_SYNC uid=%d slot=%d reserved=%s",
            player.UserId,
            slotId or -1,
            tostring(reservedKey)
        ))
    end

    if updates.craftingState then
        response.Updates.CraftingState = updates.craftingState
    end

    -- CraftResponse scope로 송신 (기존 scope 재사용)
    LogServerSend(player, "CraftComplete", "CraftResponse", response)
    RE_SyncState:FireClient(player, "CraftResponse", response)

    -- FX 재생 (기존 SendCraftComplete 로직 유지)
    local RE_PlayFX = Remotes:FindFirstChild("RE_PlayFX")
    if RE_PlayFX then
        RE_PlayFX:FireClient(player, "craft_complete", nil)
    end
end

--------------------------------------------------------------------------------
-- Phase 6: BroadcastOrders (rotate 동기화용)
--------------------------------------------------------------------------------

function RemoteHandler:BroadcastOrders(player, orders, meta, inventory)
    if not player or not player.Parent then
        warn("[RemoteHandler] BroadcastOrders: player invalid")
        return
    end

    local RE_SyncState = Remotes:FindFirstChild("RE_SyncState")
    if not RE_SyncState then
        warn("[RemoteHandler] BroadcastOrders: RE_SyncState not found")
        return
    end

    -- 방어적 얕은 복사 (리스크 A 대응)
    local ordersCopy = {}
    for k, v in pairs(orders) do
        ordersCopy[k] = v
    end

    local response = {
        Success = true,
        Updates = {
            Orders = ordersCopy,
        },
        Meta = meta,  -- { reason="rotate", slot=N, stamp=N }
    }

    -- S-29.2: optional inventory 동기화 (STALE_DISCARD 등 인벤 변경 시)
    if inventory then
        local invToSend = {}
        for k, v in pairs(inventory) do
            invToSend[tostring(k)] = v  -- 0도 포함 (클라에서 제거 처리)
        end
        response.Updates.Inventory = invToSend

        -- S-30: Stale2Keys 동기화 (Inventory와 함께)
        response.Updates.Stale2Keys = Services.DataService:GetStale2Keys(player)
    end

    LogServerSend(player, "OrderRotate", "OrderResponse", response)
    RE_SyncState:FireClient(player, "OrderResponse", response)
end

--------------------------------------------------------------------------------
-- P4: BroadcastDayEnd (threshold 자동 Day End 클라 알림)
-- manual은 RF_EndDay 응답으로 직접 전달, threshold만 이 함수로 브로드캐스트
--------------------------------------------------------------------------------

function RemoteHandler:BroadcastDayEnd(player, response)
    -- 가드: player 유효성
    if not player or not player.Parent then
        warn("[RemoteHandler] BroadcastDayEnd: player invalid")
        return
    end

    -- 가드: Success=true만 전송 (실패는 서버 로그로만)
    if not response or not response.Success then
        return
    end

    local RE_SyncState = Remotes:FindFirstChild("RE_SyncState")
    if not RE_SyncState then
        warn("[RemoteHandler] BroadcastDayEnd: RE_SyncState not found")
        return
    end

    -- P4 로그: DAY_END_BROADCAST (SSOT 포맷)
    print(string.format(
        "DAY_END_BROADCAST uid=%d reason=%s dayAfter=%d",
        player.UserId,
        tostring(response.Reason or "unknown"),
        response.DayAfter or 0
    ))

    LogServerSend(player, "DayEndBroadcast", "DayEndResponse", response)
    RE_SyncState:FireClient(player, "DayEndResponse", response)
end

--------------------------------------------------------------------------------
-- 주문 리필 (DeliverOrder 성공 후) - 중복 방지 적용
--------------------------------------------------------------------------------

function RemoteHandler:RefillOrderSlot(player, slotId)
    local IS_STUDIO = RunService:IsStudio()

    Services.DataService:UpdatePlayerData(player, function(data)
        if not data.orders then
            data.orders = {}
        end

        -- 해당 슬롯이 비어있으면 새 주문 생성
        if not data.orders[slotId] then
            -- baseReward 정책 정합 (recipeId=1 기준)
            local recipe1 = GameData.GetRecipeById(1)
            local baseReward = recipe1 and recipe1.reward or 50

            -- 튜토리얼 완료 여부에 따라 풀 선택
            local pool
            local poolType = "easy"
            if data.tutorial and data.tutorial.hasCompleted then
                pool = GameData.GetAllRecipeIds()
                poolType = "full"
            else
                pool = ServerFlags.FIRST_JOIN_EASY_POOL
            end

            local poolValid, poolSize = PoolUtils.isValidPool(pool)

            -- pool 무효 시 fallback (기본버거)
            if not poolValid then
                data.orders[slotId] = {
                    slotId = slotId,
                    recipeId = 1,
                    reward = baseReward,
                }
                if IS_STUDIO then
                    warn(string.format("[REFILL] pool_invalid slotId=%d fallback=recipeId_1", slotId))
                end
                return
            end

            -- 기존 주문의 recipeId 수집 (타입 정규화)
            local existingRecipeIds = {}
            local existingCount = 0
            for sId, order in pairs(data.orders) do
                if sId ~= slotId and order and order.recipeId then
                    local normalizedId = tonumber(order.recipeId)
                    if normalizedId and not existingRecipeIds[normalizedId] then
                        existingRecipeIds[normalizedId] = true
                        existingCount = existingCount + 1
                    end
                end
            end

            -- 중복 제외한 후보 풀 생성
            local candidates = {}
            for i = 1, poolSize do
                local rid = tonumber(pool[i])
                if rid and not existingRecipeIds[rid] then
                    table.insert(candidates, rid)
                end
            end

            -- 후보가 있으면 그 중에서 선택, 없으면 fallback (중복 허용)
            local randomRecipeId
            local usedFallback = false
            if #candidates > 0 then
                randomRecipeId = candidates[RefillRNG:NextInteger(1, #candidates)]
            else
                randomRecipeId = tonumber(pool[RefillRNG:NextInteger(1, poolSize)])
                usedFallback = true
            end

            local recipe = GameData.GetRecipeById(randomRecipeId)
            data.orders[slotId] = {
                slotId = slotId,
                recipeId = randomRecipeId,
                reward = recipe and recipe.reward or baseReward,
            }

            -- Studio 로그 (검증/회귀 방지)
            if IS_STUDIO then
                print(string.format(
                    "[REFILL] slotId=%d pool=%s poolSize=%d existing=%d candidates=%d selected=%d fallback=%s",
                    slotId,
                    poolType,
                    poolSize,
                    existingCount,
                    #candidates,
                    randomRecipeId,
                    tostring(usedFallback)
                ))
            end
        end
    end)
end

return RemoteHandler
