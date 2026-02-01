-- Server/Main.server.lua
-- SSOT v0.2.3.3 / Contract v1.2
-- 역할: 서버 진입점, Remotes 생성, 서비스 초기화

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--------------------------------------------------------------------------------
-- 1. Remotes 폴더 생성
--------------------------------------------------------------------------------

local Remotes = Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = ReplicatedStorage

-- RemoteFunctions (동기 요청)
local RF_GetInitialData = Instance.new("RemoteFunction")
RF_GetInitialData.Name = "RF_GetInitialData"
RF_GetInitialData.Parent = Remotes

-- P2: RF_GetDayEnd (Contract v1.4 §4.6)
local RF_GetDayEnd = Instance.new("RemoteFunction")
RF_GetDayEnd.Name = "RF_GetDayEnd"
RF_GetDayEnd.Parent = Remotes

-- P3: RF_EndDay (Contract v1.4 §4.7) - Manual Day End 트리거
local RF_EndDay = Instance.new("RemoteFunction")
RF_EndDay.Name = "RF_EndDay"
RF_EndDay.Parent = Remotes

-- RemoteEvents (비동기 요청 - 클라이언트 → 서버)
local RE_CollectDelivery = Instance.new("RemoteEvent")
RE_CollectDelivery.Name = "RE_CollectDelivery"
RE_CollectDelivery.Parent = Remotes

local RE_CraftItem = Instance.new("RemoteEvent")
RE_CraftItem.Name = "RE_CraftItem"
RE_CraftItem.Parent = Remotes

local RE_BuyUpgrade = Instance.new("RemoteEvent")
RE_BuyUpgrade.Name = "RE_BuyUpgrade"
RE_BuyUpgrade.Parent = Remotes

local RE_DeliverOrder = Instance.new("RemoteEvent")
RE_DeliverOrder.Name = "RE_DeliverOrder"
RE_DeliverOrder.Parent = Remotes

local RE_CompleteTutorial = Instance.new("RemoteEvent")
RE_CompleteTutorial.Name = "RE_CompleteTutorial"
RE_CompleteTutorial.Parent = Remotes

-- PG-1: Cook 미니게임 탭 전송
local RE_SubmitCookTap = Instance.new("RemoteEvent")
RE_SubmitCookTap.Name = "RE_SubmitCookTap"
RE_SubmitCookTap.Parent = Remotes

-- S-30: 수동 폐기
local RE_ManualDiscard = Instance.new("RemoteEvent")
RE_ManualDiscard.Name = "RE_ManualDiscard"
RE_ManualDiscard.Parent = Remotes

-- S-35: Full Snapshot 요청 (Client Self-Heal)
local RE_RequestFullSnapshot = Instance.new("RemoteEvent")
RE_RequestFullSnapshot.Name = "RE_RequestFullSnapshot"
RE_RequestFullSnapshot.Parent = Remotes

-- RemoteEvents (서버 → 클라이언트)
local RE_SyncState = Instance.new("RemoteEvent")
RE_SyncState.Name = "RE_SyncState"
RE_SyncState.Parent = Remotes

local RE_ShowNotice = Instance.new("RemoteEvent")
RE_ShowNotice.Name = "RE_ShowNotice"
RE_ShowNotice.Parent = Remotes

local RE_PlayFX = Instance.new("RemoteEvent")
RE_PlayFX.Name = "RE_PlayFX"
RE_PlayFX.Parent = Remotes

print("[Main] Remotes 폴더 생성 완료")

--------------------------------------------------------------------------------
-- 2. 서비스 로드 (의존성 순서 중요!)
--------------------------------------------------------------------------------

-- OrderService가 먼저 (다른 서비스들이 sessionNotSaved 체크에 사용)
local OrderService = require(ServerScriptService.Server.Services.OrderService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local DeliveryService = require(ServerScriptService.Server.Services.DeliveryService)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local UpgradeService = require(ServerScriptService.Server.Services.UpgradeService)
local CustomerService = require(ServerScriptService.Server.Services.CustomerService)  -- PG-2
local WorldSetup = require(ServerScriptService.Server.WorldSetup)

-- (C) 패치: W3NextLogger 모듈 (PlayerRemoving에서 CleanupPlayer 호출용)
local W3NextLogger = require(ServerScriptService.Server.Shared.W3NextLogger)

-- Production 로깅 모듈 (Google Sheets Webhook)
local ProductionLogger = require(ServerScriptService.Server.Shared.ProductionLogger)

--------------------------------------------------------------------------------
-- 2.5. P7-2: Gate5 Emitter 연결 (서비스 Init 이전에 연결 필수!)
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

-- Studio가 아닐 때만 P7-2 활성화
if not RunService:IsStudio() then
    local Gate5Logger = require(ReplicatedStorage.Shared.Gate5Logger)
    local GateLogBuffer = require(ServerScriptService.Server.Shared.GateLogBuffer)

    -- Emitter 연결: 모든 Gate5 로그가 GateLogBuffer로 흘러감
    -- 서비스 Init 중 발생하는 로그도 캡처하기 위해 여기서 연결
    Gate5Logger.SetEmitter(function(args, uid, pass)
        if uid then
            GateLogBuffer.Append(uid, args)
        end
    end)

    -- DataStore 준비
    local Gate5SummaryStore = DataStoreService:GetDataStore("Gate5Summary")

    -- P7-2: 키 생성 (충돌 방지: uid + timestamp + jobId 일부)
    -- 포맷: gate5_<uid>_<timestamp>_<jobId8> (SSOT v1.1 봉인)
    local function makeKey(uid, timestamp)
        local jobShort = string.sub(game.JobId or "local", 1, 8)
        return string.format("gate5_%d_%d_%s", uid, timestamp, jobShort)
    end

    -- P7-2: 재시도 로직 포함 저장
    local function saveSummaryWithRetry(key, summary, maxRetries)
        maxRetries = maxRetries or 3
        for attempt = 1, maxRetries do
            local success, err = pcall(function()
                Gate5SummaryStore:SetAsync(key, summary)
            end)

            if success then
                print(string.format("[P7-2] Saved: %s (events=%d)", key, summary.counts.total_events))
                return true
            else
                warn(string.format("[P7-2] Attempt %d/%d failed: %s - %s", attempt, maxRetries, key, tostring(err)))
                if attempt < maxRetries then
                    task.wait(0.5 * attempt)  -- 백오프
                end
            end
        end
        return false
    end

    -- PlayerRemoving: 세션 요약 저장
    Players.PlayerRemoving:Connect(function(player)
        local uid = player.UserId
        local summary = GateLogBuffer.Flush(uid)

        if summary and summary.counts.total_events > 0 then
            local key = makeKey(uid, summary.session_start)
            saveSummaryWithRetry(key, summary, 3)
        end
    end)

    -- BindToClose: 서버 종료 시 모든 플레이어 Flush (재시도 1회, 빠른 종료)
    game:BindToClose(function()
        for _, player in ipairs(Players:GetPlayers()) do
            local uid = player.UserId
            local summary = GateLogBuffer.Flush(uid)

            if summary and summary.counts.total_events > 0 then
                local key = makeKey(uid, summary.session_start)
                saveSummaryWithRetry(key, summary, 1)  -- 서버 종료 시 빠른 처리
            end
        end
    end)

    print("[Main] P7-2 Gate5 Emitter + DataStore 연결 완료 (운영 모드)")
else
    print("[Main] P7-2 스킵 (Studio 모드)")
end

--------------------------------------------------------------------------------
-- 2.6. ProductionLogger 초기화 (서비스 Init 이전)
--------------------------------------------------------------------------------

ProductionLogger.Init()

-- BindToClose: ProductionLogger 큐 플러시
game:BindToClose(function()
    ProductionLogger.FlushAll()
end)

--------------------------------------------------------------------------------
-- 3. 서비스 초기화
--------------------------------------------------------------------------------

OrderService:Init()
DataService:Init()
DeliveryService:Init()
CraftingService:Init()
UpgradeService:Init()
CustomerService:Init()  -- PG-2

print("[Main] 모든 서비스 초기화 완료")

--------------------------------------------------------------------------------
-- 3.5. PlayerRemoving: 서비스 메모리 정리
-- 목적: 런타임 캐시(쿨다운, 상태, 스탬프 등) 메모리 누수 방지
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
    -- 각 서비스의 플레이어별 런타임 데이터 정리
    OrderService:CleanupPlayer(player)
    DeliveryService:CleanupPlayer(player)
    CraftingService:CleanupPlayer(player)
    CustomerService:CleanupPlayer(player)  -- PG-2
    -- UpgradeService는 런타임 캐시 없음

    -- (C) 패치: W3NextLogger 런타임 캐시 정리 (RunIdCache, TrackACache, RunStopCache)
    W3NextLogger.CleanupPlayer(player.UserId)

    print(string.format("[Main] CLEANUP uid=%d", player.UserId))
end)

print("[Main] PlayerRemoving 핸들러 연결 완료")

--------------------------------------------------------------------------------
-- 3.6. PG-2: PlayerAdded에서 기존 주문에 대한 Customer 동기화
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
    -- DataService 로드 대기 (playerData 준비될 때까지)
    task.spawn(function()
        local maxWait = 5
        local interval = 0.25
        local elapsed = 0

        while elapsed < maxWait do
            if not player.Parent then return end

            local playerData = DataService:GetPlayerData(player)
            if playerData and playerData.orders then
                break
            end

            task.wait(interval)
            elapsed = elapsed + interval
        end

        if not player.Parent then return end

        -- S-24: 기존 유저 데이터에 reservedDishKey 없으면 자동 부여 (마이그레이션)
        -- RF_GetInitialData 호출 전에 실행되어야 클라이언트가 올바른 orders 수신
        OrderService:ReconcileReservations(player)

        -- 기존 주문에 대해 Customer 스폰
        CustomerService:SyncFromOrders(player)
    end)
end)

print("[Main] PG-2 PlayerAdded 핸들러 연결 완료")

--------------------------------------------------------------------------------
-- 4. RemoteHandler 연결
--------------------------------------------------------------------------------

local RemoteHandler = require(ServerScriptService.Server.RemoteHandler)
RemoteHandler:Init({
    Remotes = Remotes,
    Services = {
        OrderService = OrderService,
        DataService = DataService,
        DeliveryService = DeliveryService,
        CraftingService = CraftingService,
        UpgradeService = UpgradeService,
    },
})

print("[Main] RemoteHandler 연결 완료")

--------------------------------------------------------------------------------
-- 4.5. Phase 6: CraftingService/OrderService → RemoteHandler 주입
-- 목적: RE_SyncState 직접 호출 제거, RemoteHandler 단일 경로 통일
--------------------------------------------------------------------------------
CraftingService:SetRemoteHandler(RemoteHandler)
OrderService:SetRemoteHandler(RemoteHandler)

print("[Main] Phase 6 의존성 주입 완료")

--------------------------------------------------------------------------------
-- 5. 월드 셋업 (물리 인터랙션 MVP)
--------------------------------------------------------------------------------
WorldSetup.Init()

print("[Main] ========== 서버 부트스트랩 완료 ==========")
