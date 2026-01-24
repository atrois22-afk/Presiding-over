-- Client/UI/MainHUD.lua
-- SSOT v0.2.3.3 / Contract v1.3 Addendum
-- 역할: 메인 HUD (인벤토리, 주문, 제작, 업그레이드, 배달)
-- Phase 3: Tutorial Active 쿨다운 예외 (§12.1 [CLR])

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Shared Modules
local ServerFlags = require(ReplicatedStorage.Shared.ServerFlags)
local GameData = require(ReplicatedStorage.Shared.GameData)
local ClientEvents = require(ReplicatedStorage.Shared.ClientEvents)
local UIConstants = require(ReplicatedStorage.Shared.UIConstants)

-- P3: NoticeUI (End Day 실패 알림용)
local NoticeUI = require(script.Parent.NoticeUI)

local MainHUD = {}

--------------------------------------------------------------------------------
-- P1: 티켓 상태 관리 (Client-only)
-- ticketStates[slotIndex] = "ORDER" | "BUILD" | "SERVE" (I2)
--------------------------------------------------------------------------------
local ticketStates = {}  -- 슬롯별 Phase 상태
local focusedSlot = 1    -- 현재 선택된 슬롯 (초기 포커스: 슬롯 1)
local currentTab = "BUILD"  -- 현재 활성 탭

-- UI 참조
local ScreenGui = nil
local TopBar = nil
local OrderFrame = nil
local CraftFrame = nil
local InventoryFrame = nil
local UpgradeFrame = nil

-- Controller 참조 (Init에서 주입)
local Controller = nil

-- 상태 캐시
local CooldownEndTime = 0
local HeartbeatConnection = nil
local StateChangedConnection = nil  -- P0-1: EventBus 구독 핸들 (정리 책임은 SetupEventSubscription 단일)

-- Heartbeat throttle (Contract 준수 - 0.5초 간격)
local TIMER_UPDATE_INTERVAL = 0.5
local lastTimerUpdate = 0

-- 버튼 debounce
local DeliveryButtonDebounce = false
local EndDayButtonDebounce = false  -- P3: End Day 버튼 debounce

--------------------------------------------------------------------------------
-- P4: Day Summary UI 상태 (I-01: UI 내부 상태로만 관리)
--------------------------------------------------------------------------------
local DaySummaryUIState = "HIDDEN"  -- HIDDEN | SUMMARY | SHOP
local DaySummaryFrame = nil
local LastShownDayAfter = 0  -- F-02: 중복 오픈 방지 (uid, dayAfter)
local CachedSnapshot = nil   -- I-03: Summary 열릴 때 1회만 호출, 캐시 유지

-- P4: Shop UI 상태
local ShopFrame = nil
local ShopUpgradeButtons = {}  -- { [upgradeId] = buttonInstance }
local ShopSource = nil  -- "day_summary" | "manual" - Shop 닫을 때 복귀 대상

-- P4: DayEnd 큐잉 (감리자 권고: Shop 열린 상태 DayEndResponse 수신 시)
local pendingDayEnd = nil  -- { reason, dayBefore, dayAfter, ordersServedAtEnd, target }

-- P4: 업그레이드 설정 (ServerFlags와 동기화)
local UPGRADE_CONFIG = {
    { id = "quantity",   name = "배달 수량 증가",  base = 100,  desc = "배달 시 재료 +1개" },
    { id = "slots",      name = "배달 슬롯 증가",  base = 150,  desc = "재료 보관 +5칸" },
    { id = "craftSpeed", name = "제작 속도 증가",  base = 120,  desc = "요리 시간 10% 감소" },
}
local UPGRADE_GROWTH = 1.30
local MAX_LEVEL = 10

-- P4: Remotes 참조 (RF_GetDayEnd, RE_BuyUpgrade용)
local Remotes = nil

--------------------------------------------------------------------------------
-- P4: 숫자 포맷 헬퍼 (I-04: 코인 표기 통일)
--------------------------------------------------------------------------------
local function FormatCoins(n)
    if n == nil then return "0" end
    if n >= 1000 then
        return string.format("%d,%03d", math.floor(n / 1000), n % 1000)
    end
    return tostring(n)
end

--------------------------------------------------------------------------------
-- P4: 업그레이드 비용 계산 (클라이언트 표시용)
-- 공식: floor(Base * 1.3^(Level-1)) - ServerFlags와 동기화 필수
--------------------------------------------------------------------------------
local function CalculateUpgradeCost(base, currentLevel)
    if currentLevel >= MAX_LEVEL then return 0 end
    return math.floor(base * math.pow(UPGRADE_GROWTH, currentLevel - 1))
end

--------------------------------------------------------------------------------
-- 초기화
--------------------------------------------------------------------------------

function MainHUD:Init(clientController)
    Controller = clientController

    -- 1. HeartbeatConnection 정리 (재초기화 방지)
    if HeartbeatConnection then
        HeartbeatConnection:Disconnect()
        HeartbeatConnection = nil
    end

    -- 2. ScreenGui 단일 보장 (P0-1)
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    ScreenGui = playerGui:FindFirstChild("MainHUD")
    if not ScreenGui then
        ScreenGui = Instance.new("ScreenGui")
        ScreenGui.Name = "MainHUD"
        ScreenGui.Parent = playerGui
    end
    -- Parent 방어적 재설정
    if ScreenGui.Parent ~= playerGui then
        ScreenGui.Parent = playerGui
    end
    -- 속성 방어적 재설정
    ScreenGui.DisplayOrder = 1  -- NoticeUI(100)보다 아래
    ScreenGui.ResetOnSpawn = false

    -- P4: Remotes 참조 초기화 (RF_GetDayEnd용)
    Remotes = ReplicatedStorage:WaitForChild("Remotes")

    print("[MainHUD] Reuse ScreenGui:", ScreenGui ~= nil, "UIBuilt:", ScreenGui:GetAttribute("UIBuilt"))

    -- P1-UI-1/A BEGIN ─────────────────────────────────────────────────────────
    -- 3. UI 1회 빌드 (Attribute 기반, P0-1)
    local needsBuild = not ScreenGui:GetAttribute("UIBuilt")
    if not needsBuild then
        -- P1-UI-1/A: 루트 5개 존재 체크 (최소 범위)
        local rootNames = {"TopBar", "OrderFrame", "CraftFrame", "InventoryFrame", "UpgradeFrame"}
        local missing = {}

        for _, name in ipairs(rootNames) do
            if not ScreenGui:FindFirstChild(name) then
                table.insert(missing, name)
            end
        end

        if #missing > 0 then
            needsBuild = true
            warn(string.format(
                "[MainHUD] UIBuilt=true but UI damaged (missing: %s), rebuilding...",
                table.concat(missing, ", ")
            ))

            -- B1 전략: 손상 감지 시 루트 5개 전부 Destroy 후 재빌드
            for _, name in ipairs(rootNames) do
                local existing = ScreenGui:FindFirstChild(name)
                if existing then
                    existing:Destroy()
                end
            end

            -- 모듈 변수 초기화 (파괴된 인스턴스 참조 방지)
            TopBar = nil
            OrderFrame = nil
            CraftFrame = nil
            InventoryFrame = nil
            UpgradeFrame = nil

            ScreenGui:SetAttribute("UIBuilt", false)
        end
    end

    if needsBuild then
        self:CreateTopBar()
        self:CreateOrderBoard()
        self:CreateCraftPanel()
        self:CreateInventoryPanel()
        self:CreateUpgradePopup()
        ScreenGui:SetAttribute("UIBuilt", true)
    end
    -- P1-UI-1/A END ───────────────────────────────────────────────────────────

    -- 4. EventBus 구독 (단일 경로: SetupEventSubscription)
    self:SetupEventSubscription()

    -- 5. 쿨다운 타이머 루프 (Throttled) + P1-UX-01 Progress Fill
    HeartbeatConnection = RunService.Heartbeat:Connect(function()
        local now = tick()
        if now - lastTimerUpdate >= TIMER_UPDATE_INTERVAL then
            lastTimerUpdate = now
            self:UpdateDeliveryTimer()
        end
        -- P1-UX-01: Craft Progress Fill 업데이트 (매 프레임)
        self:UpdateCraftProgressFill()
    end)

    print("[MainHUD] 초기화 완료")
end

--------------------------------------------------------------------------------
-- EventBus 구독 (Contract §5.6 - 느슨한 결합)
--------------------------------------------------------------------------------

function MainHUD:SetupEventSubscription()
    -- P0-1: 기존 연결 정리 (중복 구독 방지)
    -- 정리 책임은 이 함수 단일 (Init에서 중복 정리 금지)
    if StateChangedConnection then
        StateChangedConnection:Disconnect()
        StateChangedConnection = nil
    end

    -- 새 연결 (핸들 저장)
    StateChangedConnection = ClientEvents.StateChanged.Event:Connect(function(scope, data)
        self:HandleStateChange(scope, data)
    end)

    print("[MainHUD] StateChanged subscribed")
end

function MainHUD:HandleStateChange(scope, data)
    if scope == "All" then
        -- 전체 데이터 갱신
        self:UpdateAll(data)
    elseif scope == "inventory" then
        self:UpdateInventory(data)
    elseif scope == "wallet" then
        self:UpdateWallet(data)
        -- P4: Shop UI가 열려있으면 갱신 (코인 변경 시)
        if ShopFrame and ShopFrame.Visible then
            self:UpdateShopUI()
        end
        -- P4 감리 지적 (B): CachedSnapshot ↔ WalletCoins 정합성
        -- Summary 캐시가 있으면 WalletCoins 갱신 (Shop 구매 후 Summary 복귀 시 최신값 표시)
        if CachedSnapshot and data then
            -- 방어적 nil 체크: coins 필드가 있을 때만 갱신 (감리 권고)
            local coins = data.Coins
            if coins == nil then coins = data.coins end

            if coins ~= nil then
                CachedSnapshot.WalletCoins = coins
                print(string.format("P4|LIVE_WALLET_SYNC newCoins=%d", coins))
                -- Summary UI가 열려있으면 라벨 갱신
                if DaySummaryFrame and DaySummaryFrame.Visible then
                    local walletLabel = DaySummaryFrame:FindFirstChild("WalletLabel")
                    if walletLabel then
                        walletLabel.Text = string.format("보유 코인: %s", FormatCoins(coins))
                    end
                end
            else
                -- coins 필드 없음: 캐시 유지 + 디버그 로그
                print("P4|LIVE_WALLET_SYNC_SKIP reason=no_coins_field")
            end
        end
    elseif scope == "orders" then
        self:UpdateOrders(data)
    elseif scope == "upgrades" then
        self:UpdateUpgrades(data)
        -- P4: Shop UI가 열려있으면 갱신
        if ShopFrame and ShopFrame.Visible then
            self:UpdateShopUI()
        end
    elseif scope == "cooldown" then
        self:UpdateCooldown(data)
        -- 쿨다운 응답 시 debounce 해제
        DeliveryButtonDebounce = false
    elseif scope == "craftingState" then
        self:UpdateCraftingState(data)
    elseif scope == "deliverResult" then
        -- P2: 납품 결과 표시 (Score/Tip/TotalRevenue)
        self:ShowDeliverResult(data)
    end
end

--------------------------------------------------------------------------------
-- Cleanup (리소스 정리)
--------------------------------------------------------------------------------

function MainHUD:Cleanup()
    if HeartbeatConnection then
        HeartbeatConnection:Disconnect()
        HeartbeatConnection = nil
    end
end

--------------------------------------------------------------------------------
-- 1. 상단 바 (TopBar): 배달, 지갑, 업그레이드 버튼
--------------------------------------------------------------------------------

function MainHUD:CreateTopBar()
    local frame = Instance.new("Frame")
    frame.Name = "TopBar"
    frame.Size = UDim2.new(1, 0, 0, 60)
    frame.BackgroundTransparency = 1
    frame.Parent = ScreenGui
    TopBar = frame

    -- [배달 받기] 버튼
    local deliveryBtn = Instance.new("TextButton")
    deliveryBtn.Name = "DeliveryButton"
    deliveryBtn.Size = UDim2.new(0, 160, 0, 40)
    deliveryBtn.Position = UDim2.new(0, 20, 0, 10)
    deliveryBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
    deliveryBtn.Text = "🚚 배달 받기"
    deliveryBtn.TextColor3 = Color3.new(1, 1, 1)
    deliveryBtn.TextSize = 18
    deliveryBtn.Font = Enum.Font.GothamBold
    deliveryBtn.Parent = frame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = deliveryBtn

    -- 배달 버튼 클릭 (debounce + 쿨다운 체크)
    deliveryBtn.MouseButton1Click:Connect(function()
        -- debounce 체크
        if DeliveryButtonDebounce then return end

        -- 쿨다운 체크
        if CooldownEndTime and tick() < CooldownEndTime then return end

        -- debounce 설정
        DeliveryButtonDebounce = true

        -- 서버 요청
        if Controller and Controller.CollectDelivery then
            Controller:CollectDelivery()
        end

        -- 타임아웃 안전장치 (서버 응답 없을 경우)
        task.delay(3, function()
            DeliveryButtonDebounce = false
        end)
    end)

    -- [지갑] 표시
    local walletLabel = Instance.new("TextLabel")
    walletLabel.Name = "WalletLabel"
    walletLabel.Size = UDim2.new(0, 200, 0, 40)
    walletLabel.Position = UDim2.new(0.5, -100, 0, 10)
    walletLabel.BackgroundTransparency = 1
    walletLabel.Text = "💰 0"
    walletLabel.TextSize = 24
    walletLabel.Font = Enum.Font.GothamBlack
    walletLabel.TextColor3 = Color3.fromRGB(255, 220, 0)
    walletLabel.Parent = frame

    -- [P3: End Day] 버튼 (Contract v1.4 §4.7)
    local endDayBtn = Instance.new("TextButton")
    endDayBtn.Name = "EndDayButton"
    endDayBtn.Size = UDim2.new(0, 120, 0, 40)
    endDayBtn.AnchorPoint = Vector2.new(1, 0)
    endDayBtn.Position = UDim2.new(1, -170, 0, 10)  -- Upgrade 버튼 왼쪽
    endDayBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)  -- 초록색
    endDayBtn.Text = "🌙 End Day"
    endDayBtn.TextColor3 = Color3.new(1, 1, 1)
    endDayBtn.TextSize = 16
    endDayBtn.Font = Enum.Font.GothamBold
    endDayBtn.Parent = frame

    local cornerEndDay = Instance.new("UICorner")
    cornerEndDay.CornerRadius = UDim.new(0, 8)
    cornerEndDay.Parent = endDayBtn

    -- End Day 버튼 클릭 (debounce + 동기 호출)
    -- CRIT-C-01/C-02: pcall + finally 패턴으로 debounce 해제 보장
    endDayBtn.MouseButton1Click:Connect(function()
        -- debounce 체크
        if EndDayButtonDebounce then return end

        -- debounce 설정
        EndDayButtonDebounce = true

        -- 버튼 비활성화 시각적 피드백
        endDayBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
        endDayBtn.Text = "⏳ 처리중..."

        -- 서버 요청 (비동기 래핑 - UI 블로킹 방지)
        task.spawn(function()
            -- pcall로 모든 예외 캡처 (finally 패턴 보장)
            local ok, response = pcall(function()
                if Controller and Controller.EndDay then
                    return Controller:EndDay()
                end
                return nil
            end)

            -- FINALLY: 항상 debounce 해제 + 버튼 복원 (예외 발생 여부 무관)
            EndDayButtonDebounce = false
            endDayBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
            endDayBtn.Text = "🌙 End Day"

            -- 결과 표시 (P4: manual도 OnDayEndSignal 파이프라인 합류)
            if ok and response then
                if response.Success then
                    -- P4: manual 성공 → OnDayEndSignal 파이프라인으로 통일 (threshold와 동일 경로)
                    -- 이렇게 하면 ShowEndDayResult(토스트) + OpenDaySummary() 모두 처리됨
                    self:OnDayEndSignal({
                        reason = "manual",
                        dayBefore = response.DayBefore,
                        dayAfter = response.DayAfter,
                        ordersServedAtEnd = response.OrdersServedAtEnd,
                        target = response.Target,
                    })
                else
                    -- 실패 시 기존 토스트만 표시
                    self:ShowEndDayResult(response)
                end
            elseif not ok then
                -- pcall 실패 시 (예기치 않은 런타임 에러)
                warn(string.format("[MainHUD] P3|ENDDAY_PCALL_FAILED detail=%s", tostring(response)))
                self:ShowEndDayResult({ Success = false, Error = "data_error", NoticeCode = "data_error" })
            end
        end)
    end)

    -- [업그레이드] 버튼
    local upgradeBtn = Instance.new("TextButton")
    upgradeBtn.Name = "UpgradeButton"
    upgradeBtn.Size = UDim2.new(0, 140, 0, 40)
    upgradeBtn.AnchorPoint = Vector2.new(1, 0)
    upgradeBtn.Position = UDim2.new(1, -20, 0, 10)
    upgradeBtn.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
    upgradeBtn.Text = "🔧 업그레이드"
    upgradeBtn.TextColor3 = Color3.new(1, 1, 1)
    upgradeBtn.TextSize = 18
    upgradeBtn.Font = Enum.Font.GothamBold
    upgradeBtn.Parent = frame

    local corner2 = Instance.new("UICorner")
    corner2.CornerRadius = UDim.new(0, 8)
    corner2.Parent = upgradeBtn

    upgradeBtn.MouseButton1Click:Connect(function()
        self:ToggleUpgradePopup()
    end)
end

--------------------------------------------------------------------------------
-- 2. 주문 보드 (OrderBoard) - 좌측 (P1: 티켓 카드 UI)
--------------------------------------------------------------------------------

function MainHUD:CreateOrderBoard()
    local frame = Instance.new("Frame")
    frame.Name = "OrderFrame"
    frame.Size = UDim2.new(0, 240, 0, 320)
    frame.Position = UDim2.new(0, 20, 0, 80)
    frame.BackgroundColor3 = UIConstants.COLORS.BACKGROUND
    frame.BackgroundTransparency = 0.3
    frame.Parent = ScreenGui
    OrderFrame = frame

    local corner = Instance.new("UICorner")
    corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Text = "📋 ORDER BOARD"
    title.Size = UDim2.new(1, 0, 0, 30)
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.Parent = frame

    -- P1: 3개 티켓 카드 슬롯 생성
    for i = 1, ServerFlags.ORDER_SLOT_COUNT do
        -- 티켓 상태 초기화
        ticketStates[i] = "ORDER"

        local slot = Instance.new("Frame")
        slot.Name = "Slot" .. i
        slot.Size = UDim2.new(1, -20, 0, 88)
        slot.Position = UDim2.new(0, 10, 0, 35 + (i - 1) * 93)
        slot.BackgroundColor3 = UIConstants.COLORS.SLOT_BACKGROUND
        slot.Parent = frame

        local sCorner = Instance.new("UICorner")
        sCorner.CornerRadius = UDim.new(0, 8)
        sCorner.Parent = slot

        -- 티켓 번호 (좌상단)
        local ticketNum = Instance.new("TextLabel")
        ticketNum.Name = "TicketNum"
        ticketNum.Size = UDim2.new(0, 50, 0, 20)
        ticketNum.Position = UDim2.new(0, 8, 0, 5)
        ticketNum.BackgroundTransparency = 1
        ticketNum.Text = string.format("🎫 #%d", i)
        ticketNum.TextColor3 = Color3.fromRGB(200, 200, 200)
        ticketNum.Font = Enum.Font.GothamBold
        ticketNum.TextSize = 12
        ticketNum.TextXAlignment = Enum.TextXAlignment.Left
        ticketNum.Parent = slot

        -- 레시피 이름 + 난이도 뱃지
        local recipeName = Instance.new("TextLabel")
        recipeName.Name = "RecipeName"
        recipeName.Size = UDim2.new(1, -16, 0, 22)
        recipeName.Position = UDim2.new(0, 8, 0, 25)
        recipeName.BackgroundTransparency = 1
        recipeName.Text = "주문 대기 중..."
        recipeName.TextColor3 = Color3.new(1, 1, 1)
        recipeName.Font = Enum.Font.GothamBold
        recipeName.TextSize = 14
        recipeName.TextXAlignment = Enum.TextXAlignment.Left
        recipeName.Parent = slot

        -- 보상 표시
        local rewardLabel = Instance.new("TextLabel")
        rewardLabel.Name = "RewardLabel"
        rewardLabel.Size = UDim2.new(0, 80, 0, 18)
        rewardLabel.Position = UDim2.new(0, 8, 0, 47)
        rewardLabel.BackgroundTransparency = 1
        rewardLabel.Text = ""
        rewardLabel.TextColor3 = UIConstants.COLORS.REWARD
        rewardLabel.Font = Enum.Font.Gotham
        rewardLabel.TextSize = 12
        rewardLabel.TextXAlignment = Enum.TextXAlignment.Left
        rewardLabel.Parent = slot

        -- P1: Phase 배지 (우하단)
        local phaseBadge = Instance.new("TextLabel")
        phaseBadge.Name = "PhaseBadge"
        phaseBadge.Size = UDim2.new(0, 80, 0, 22)
        phaseBadge.AnchorPoint = Vector2.new(1, 1)
        phaseBadge.Position = UDim2.new(1, -8, 1, -8)
        phaseBadge.BackgroundColor3 = UIConstants.PHASE.ORDER.color
        phaseBadge.Text = UIConstants.GetPhaseBadgeText("ORDER")
        phaseBadge.TextColor3 = Color3.new(1, 1, 1)
        phaseBadge.Font = Enum.Font.GothamBold
        phaseBadge.TextSize = 11
        phaseBadge.Parent = slot

        local badgeCorner = Instance.new("UICorner")
        badgeCorner.CornerRadius = UDim.new(0, 4)
        badgeCorner.Parent = phaseBadge

        -- P1: 선택 표시 (좌측 바)
        local selectBar = Instance.new("Frame")
        selectBar.Name = "SelectBar"
        selectBar.Size = UDim2.new(0, 4, 1, -10)
        selectBar.Position = UDim2.new(0, 0, 0, 5)
        selectBar.BackgroundColor3 = UIConstants.PHASE.BUILD.color
        selectBar.Visible = (i == focusedSlot)
        selectBar.Parent = slot

        -- 티켓 클릭 (선택)
        local clickBtn = Instance.new("TextButton")
        clickBtn.Name = "ClickArea"
        clickBtn.Size = UDim2.new(1, 0, 1, 0)
        clickBtn.BackgroundTransparency = 1
        clickBtn.Text = ""
        clickBtn.Parent = slot

        local slotId = i  -- 클로저용 캡처
        clickBtn.MouseButton1Click:Connect(function()
            self:SelectTicket(slotId)
        end)
    end
end

--------------------------------------------------------------------------------
-- P1: 티켓 선택 (포커스 변경)
--------------------------------------------------------------------------------

function MainHUD:SelectTicket(slotIndex)
    if not OrderFrame then return end

    -- 이전 선택 해제
    for i = 1, ServerFlags.ORDER_SLOT_COUNT do
        local slot = OrderFrame:FindFirstChild("Slot" .. i)
        if slot then
            local selectBar = slot:FindFirstChild("SelectBar")
            if selectBar then
                selectBar.Visible = (i == slotIndex)
            end
            -- 배경색 변경
            slot.BackgroundColor3 = (i == slotIndex)
                and UIConstants.COLORS.SLOT_SELECTED
                or UIConstants.COLORS.SLOT_BACKGROUND
        end
    end

    focusedSlot = slotIndex
    print(string.format("[MainHUD] P1|TICKET_SELECTED slot=%d", slotIndex))

    -- CraftPanel 갱신 (선택된 티켓 기준)
    self:UpdateCraftPanelForTicket(slotIndex)
end

--------------------------------------------------------------------------------
-- P1: 티켓 Phase 상태 변경
--------------------------------------------------------------------------------

function MainHUD:SetTicketPhase(slotIndex, phase)
    if not OrderFrame then return end
    if not UIConstants.PHASE[phase] then
        warn(string.format("[MainHUD] Invalid phase: %s", tostring(phase)))
        return
    end

    ticketStates[slotIndex] = phase

    local slot = OrderFrame:FindFirstChild("Slot" .. slotIndex)
    if slot then
        local phaseBadge = slot:FindFirstChild("PhaseBadge")
        if phaseBadge then
            local phaseData = UIConstants.PHASE[phase]
            phaseBadge.Text = UIConstants.GetPhaseBadgeText(phase)
            phaseBadge.BackgroundColor3 = phaseData.color
        end
    end

    print(string.format("[MainHUD] P1|PHASE_CHANGED slot=%d phase=%s", slotIndex, phase))

    -- 현재 선택된 슬롯이면 CraftPanel 탭 상태 갱신
    if slotIndex == focusedSlot then
        self:UpdateCraftPanelTabs()
    end
end

function MainHUD:GetTicketPhase(slotIndex)
    return ticketStates[slotIndex] or "ORDER"
end

--------------------------------------------------------------------------------
-- 3. 제작 패널 (CraftPanel) - 우측 (P1: BUILD/SERVE 탭)
--------------------------------------------------------------------------------

function MainHUD:CreateCraftPanel()
    local frame = Instance.new("Frame")
    frame.Name = "CraftFrame"
    frame.Size = UDim2.new(0, 260, 0, 320)
    frame.AnchorPoint = Vector2.new(1, 0)
    frame.Position = UDim2.new(1, -20, 0, 80)
    frame.BackgroundColor3 = UIConstants.COLORS.BACKGROUND
    frame.BackgroundTransparency = 0.3
    frame.Parent = ScreenGui
    CraftFrame = frame

    local corner = Instance.new("UICorner")
    corner.Parent = frame

    -- 타이틀 (선택된 티켓 정보)
    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Text = "🍔 CRAFT STATION"
    title.Size = UDim2.new(1, 0, 0, 25)
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Parent = frame

    -- 선택된 티켓 표시
    local selectedTicket = Instance.new("TextLabel")
    selectedTicket.Name = "SelectedTicket"
    selectedTicket.Size = UDim2.new(1, -10, 0, 18)
    selectedTicket.Position = UDim2.new(0, 5, 0, 23)
    selectedTicket.BackgroundTransparency = 1
    selectedTicket.Text = "선택: #1"
    selectedTicket.TextColor3 = Color3.fromRGB(180, 180, 180)
    selectedTicket.Font = Enum.Font.Gotham
    selectedTicket.TextSize = 11
    selectedTicket.TextXAlignment = Enum.TextXAlignment.Right
    selectedTicket.Parent = frame

    -- P1: 탭 컨테이너
    local tabContainer = Instance.new("Frame")
    tabContainer.Name = "TabContainer"
    tabContainer.Size = UDim2.new(1, -10, 0, 35)
    tabContainer.Position = UDim2.new(0, 5, 0, 45)
    tabContainer.BackgroundTransparency = 1
    tabContainer.Parent = frame

    -- BUILD 탭
    local buildTab = Instance.new("TextButton")
    buildTab.Name = "BuildTab"
    buildTab.Size = UDim2.new(0.5, -3, 1, 0)
    buildTab.Position = UDim2.new(0, 0, 0, 0)
    buildTab.BackgroundColor3 = UIConstants.TAB.BUILD.activeColor
    buildTab.Text = UIConstants.TAB.BUILD.label
    buildTab.TextColor3 = Color3.new(1, 1, 1)
    buildTab.Font = Enum.Font.GothamBold
    buildTab.TextSize = 13
    buildTab.Parent = tabContainer

    local buildCorner = Instance.new("UICorner")
    buildCorner.CornerRadius = UDim.new(0, 6)
    buildCorner.Parent = buildTab

    -- SERVE 탭
    local serveTab = Instance.new("TextButton")
    serveTab.Name = "ServeTab"
    serveTab.Size = UDim2.new(0.5, -3, 1, 0)
    serveTab.Position = UDim2.new(0.5, 3, 0, 0)
    serveTab.BackgroundColor3 = UIConstants.TAB.SERVE.inactiveColor
    serveTab.Text = UIConstants.TAB.SERVE.label
    serveTab.TextColor3 = Color3.fromRGB(150, 150, 150)
    serveTab.Font = Enum.Font.GothamBold
    serveTab.TextSize = 13
    serveTab.Parent = tabContainer

    local serveCorner = Instance.new("UICorner")
    serveCorner.CornerRadius = UDim.new(0, 6)
    serveCorner.Parent = serveTab

    -- 탭 클릭 이벤트
    buildTab.MouseButton1Click:Connect(function()
        self:SwitchTab("BUILD")
    end)

    serveTab.MouseButton1Click:Connect(function()
        self:SwitchTab("SERVE")
    end)

    -- P1: 콘텐츠 영역
    local contentArea = Instance.new("Frame")
    contentArea.Name = "ContentArea"
    contentArea.Size = UDim2.new(1, -10, 0, 195)
    contentArea.Position = UDim2.new(0, 5, 0, 85)
    contentArea.BackgroundColor3 = UIConstants.COLORS.SLOT_BACKGROUND
    contentArea.Parent = frame

    local contentCorner = Instance.new("UICorner")
    contentCorner.CornerRadius = UDim.new(0, 8)
    contentCorner.Parent = contentArea

    -- BUILD 패널
    local buildPanel = Instance.new("Frame")
    buildPanel.Name = "BuildPanel"
    buildPanel.Size = UDim2.new(1, 0, 1, 0)
    buildPanel.BackgroundTransparency = 1
    buildPanel.Visible = true
    buildPanel.Parent = contentArea

    -- BUILD 패널 내용: 레시피 정보 + 제작 버튼
    local recipeInfo = Instance.new("TextLabel")
    recipeInfo.Name = "RecipeInfo"
    recipeInfo.Size = UDim2.new(1, -20, 0, 60)
    recipeInfo.Position = UDim2.new(0, 10, 0, 15)
    recipeInfo.BackgroundTransparency = 1
    recipeInfo.Text = "레시피 정보\n⏱️ 0초 | 💰 0"
    recipeInfo.TextColor3 = Color3.new(1, 1, 1)
    recipeInfo.Font = Enum.Font.Gotham
    recipeInfo.TextSize = 14
    recipeInfo.TextXAlignment = Enum.TextXAlignment.Left
    recipeInfo.TextYAlignment = Enum.TextYAlignment.Top
    recipeInfo.Parent = buildPanel

    -- 진행 바 (제작 중 표시)
    local progressContainer = Instance.new("Frame")
    progressContainer.Name = "ProgressContainer"
    progressContainer.Size = UDim2.new(1, -20, 0, 25)
    progressContainer.Position = UDim2.new(0, 10, 0, 80)
    progressContainer.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    progressContainer.Visible = false
    progressContainer.Parent = buildPanel

    local progressCorner = Instance.new("UICorner")
    progressCorner.CornerRadius = UDim.new(0, 4)
    progressCorner.Parent = progressContainer

    local progressBar = Instance.new("Frame")
    progressBar.Name = "ProgressBar"
    progressBar.Size = UDim2.new(0, 0, 1, 0)
    progressBar.BackgroundColor3 = UIConstants.PHASE.BUILD.color
    progressBar.Parent = progressContainer

    local progressBarCorner = Instance.new("UICorner")
    progressBarCorner.CornerRadius = UDim.new(0, 4)
    progressBarCorner.Parent = progressBar

    local progressText = Instance.new("TextLabel")
    progressText.Name = "ProgressText"
    progressText.Size = UDim2.new(1, 0, 1, 0)
    progressText.BackgroundTransparency = 1
    progressText.Text = "⏳ 제작 중..."
    progressText.TextColor3 = Color3.new(1, 1, 1)
    progressText.Font = Enum.Font.GothamBold
    progressText.TextSize = 12
    progressText.Parent = progressContainer

    -- P1-UX-01: 제작 버튼 (ChatGPT 권장 구조)
    -- CraftButton (TextButton)
    --  ├─ BackgroundContainer (Frame, ClipsDescendants=true)
    --  │   └─ CraftProgressFill (Frame)
    --  └─ TextButton 자체 텍스트 (자동 최상위 렌더링)

    local craftBtn = Instance.new("TextButton")
    craftBtn.Name = "CraftButton"
    craftBtn.Size = UDim2.new(1, -20, 0, 45)
    craftBtn.Position = UDim2.new(0, 10, 1, -55)
    craftBtn.BackgroundColor3 = UIConstants.PHASE.BUILD.color
    craftBtn.Text = "🔧 제작 시작"
    craftBtn.TextColor3 = Color3.new(1, 1, 1)
    craftBtn.Font = Enum.Font.GothamBold
    craftBtn.TextSize = 16
    craftBtn.AutoButtonColor = false  -- 자동 색상 변경 비활성화
    craftBtn.Parent = buildPanel

    local craftBtnCorner = Instance.new("UICorner")
    craftBtnCorner.CornerRadius = UDim.new(0, 8)
    craftBtnCorner.Parent = craftBtn

    -- P1-UX-01: BackgroundContainer (Fill 컨테이너)
    local bgContainer = Instance.new("Frame")
    bgContainer.Name = "BackgroundContainer"
    bgContainer.Size = UDim2.new(1, 0, 1, 0)
    bgContainer.Position = UDim2.new(0, 0, 0, 0)
    bgContainer.BackgroundTransparency = 1  -- 투명 (Fill만 보이게)
    bgContainer.ClipsDescendants = true  -- Fill이 버튼 밖으로 안 나가게
    bgContainer.ZIndex = 1
    bgContainer.Parent = craftBtn

    local bgCorner = Instance.new("UICorner")
    bgCorner.CornerRadius = UDim.new(0, 8)
    bgCorner.Parent = bgContainer

    -- P1-UX-01: Progress Fill (항상 존재, 표시만 제어)
    local craftProgressFill = Instance.new("Frame")
    craftProgressFill.Name = "CraftProgressFill"
    craftProgressFill.Size = UDim2.new(0, 0, 1, 0)  -- 초기: 0%
    craftProgressFill.Position = UDim2.new(0, 0, 0, 0)
    craftProgressFill.BackgroundColor3 = Color3.fromRGB(76, 175, 80)  -- 진행 색상 (초록)
    craftProgressFill.BackgroundTransparency = 0
    craftProgressFill.ZIndex = 1
    craftProgressFill.Parent = bgContainer  -- BackgroundContainer 안에 배치

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 8)
    fillCorner.Parent = craftProgressFill

    craftBtn.MouseButton1Click:Connect(function()
        self:OnCraftButtonClicked()
    end)

    -- SERVE 패널
    local servePanel = Instance.new("Frame")
    servePanel.Name = "ServePanel"
    servePanel.Size = UDim2.new(1, 0, 1, 0)
    servePanel.BackgroundTransparency = 1
    servePanel.Visible = false
    servePanel.Parent = contentArea

    -- SERVE 패널 내용
    local serveInfo = Instance.new("TextLabel")
    serveInfo.Name = "ServeInfo"
    serveInfo.Size = UDim2.new(1, -20, 0, 60)
    serveInfo.Position = UDim2.new(0, 10, 0, 15)
    serveInfo.BackgroundTransparency = 1
    serveInfo.Text = "✅ 요리 완성!\n\n납품 대기 중..."
    serveInfo.TextColor3 = Color3.new(1, 1, 1)
    serveInfo.Font = Enum.Font.Gotham
    serveInfo.TextSize = 14
    serveInfo.TextXAlignment = Enum.TextXAlignment.Left
    serveInfo.TextYAlignment = Enum.TextYAlignment.Top
    serveInfo.Parent = servePanel

    -- 납품 버튼
    local serveBtn = Instance.new("TextButton")
    serveBtn.Name = "ServeButton"
    serveBtn.Size = UDim2.new(1, -20, 0, 45)
    serveBtn.Position = UDim2.new(0, 10, 1, -55)
    serveBtn.BackgroundColor3 = UIConstants.PHASE.SERVE.color
    serveBtn.Text = "📦 납품하기"
    serveBtn.TextColor3 = Color3.new(1, 1, 1)
    serveBtn.Font = Enum.Font.GothamBold
    serveBtn.TextSize = 16
    serveBtn.Parent = servePanel

    local serveBtnCorner = Instance.new("UICorner")
    serveBtnCorner.CornerRadius = UDim.new(0, 8)
    serveBtnCorner.Parent = serveBtn

    serveBtn.MouseButton1Click:Connect(function()
        self:OnServeButtonClicked()
    end)

    -- P1: 툴팁 영역 (탭 하단 1줄 고정)
    local tooltipLabel = Instance.new("TextLabel")
    tooltipLabel.Name = "TooltipLabel"
    tooltipLabel.Size = UDim2.new(1, -10, 0, 20)
    tooltipLabel.Position = UDim2.new(0, 5, 1, -25)
    tooltipLabel.BackgroundTransparency = 1
    tooltipLabel.Text = ""
    tooltipLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
    tooltipLabel.Font = Enum.Font.Gotham
    tooltipLabel.TextSize = 11
    tooltipLabel.Parent = frame

    -- DeliveryZone 안내
    local zoneHint = Instance.new("TextLabel")
    zoneHint.Name = "ZoneHint"
    zoneHint.Size = UDim2.new(1, -20, 0, 15)
    zoneHint.Position = UDim2.new(0, 10, 1, -18)
    zoneHint.BackgroundTransparency = 1
    zoneHint.Text = "💡 DeliveryZone(E키)도 사용 가능"
    zoneHint.TextColor3 = Color3.fromRGB(120, 120, 120)
    zoneHint.Font = Enum.Font.Gotham
    zoneHint.TextSize = 10
    zoneHint.Visible = false
    zoneHint.Parent = servePanel
end

--------------------------------------------------------------------------------
-- P1: 탭 전환
--------------------------------------------------------------------------------

function MainHUD:SwitchTab(tabName)
    if not CraftFrame then return end

    local tabContainer = CraftFrame:FindFirstChild("TabContainer")
    local contentArea = CraftFrame:FindFirstChild("ContentArea")
    local tooltipLabel = CraftFrame:FindFirstChild("TooltipLabel")

    if not tabContainer or not contentArea then return end

    local buildTab = tabContainer:FindFirstChild("BuildTab")
    local serveTab = tabContainer:FindFirstChild("ServeTab")
    local buildPanel = contentArea:FindFirstChild("BuildPanel")
    local servePanel = contentArea:FindFirstChild("ServePanel")

    -- 현재 Phase에 따른 비활성 체크
    local phase = self:GetTicketPhase(focusedSlot)

    -- 비활성 탭 클릭 시 툴팁 표시 (Patch P1-WF-02)
    -- Softlock Fix: Held Dish Guarantee 대응 (감리자 승인 2026-01-18)
    if tabName == "SERVE" and phase ~= "SERVE" then
        -- 예외 조건: focusedSlot의 주문에 맞는 dish 보유 시 SERVE 탭 허용
        local canOverride = false
        local recipeId = self:GetRecipeIdForSlot(focusedSlot)

        -- 가드 1: focusedSlot 유효
        -- 가드 2: recipeId 유효 (nil/0 차단)
        if focusedSlot and recipeId and recipeId > 0 then
            local dishKey = "dish_" .. recipeId
            local inventory = self._lastInventory
            -- 가드 3: inventory[dishKey] >= 1
            if inventory and inventory[dishKey] and inventory[dishKey] >= 1 then
                canOverride = true
                -- Studio 로그 (회귀 추적용)
                print(string.format(
                    "[UI] SERVE_TAB_OVERRIDE reason=held_dish_match slot=%d recipeId=%d dish=%d",
                    focusedSlot, recipeId, inventory[dishKey]
                ))
            end
        end

        if not canOverride then
            -- 기존 차단 로직 유지
            if tooltipLabel then
                tooltipLabel.Text = "제작 완료 후 납품 가능"
                task.delay(2, function()
                    if tooltipLabel and tooltipLabel.Text == "제작 완료 후 납품 가능" then
                        tooltipLabel.Text = ""
                    end
                end)
            end
            return  -- 탭 전환 차단
        end
        -- canOverride=true: SERVE 탭 허용 (held dish match)
    end

    if tabName == "BUILD" and phase == "SERVE" then
        if tooltipLabel then
            tooltipLabel.Text = "요리를 먼저 납품하세요"
            task.delay(2, function()
                if tooltipLabel and tooltipLabel.Text == "요리를 먼저 납품하세요" then
                    tooltipLabel.Text = ""
                end
            end)
        end
        return  -- 탭 전환 차단
    end

    -- 탭 전환
    currentTab = tabName

    if tabName == "BUILD" then
        if buildTab then
            buildTab.BackgroundColor3 = UIConstants.TAB.BUILD.activeColor
            buildTab.TextColor3 = Color3.new(1, 1, 1)
        end
        if serveTab then
            serveTab.BackgroundColor3 = UIConstants.TAB.SERVE.inactiveColor
            serveTab.TextColor3 = Color3.fromRGB(150, 150, 150)
        end
        if buildPanel then buildPanel.Visible = true end
        if servePanel then servePanel.Visible = false end
    else  -- SERVE
        if buildTab then
            buildTab.BackgroundColor3 = UIConstants.TAB.BUILD.inactiveColor
            buildTab.TextColor3 = Color3.fromRGB(150, 150, 150)
        end
        if serveTab then
            serveTab.BackgroundColor3 = UIConstants.TAB.SERVE.activeColor
            serveTab.TextColor3 = Color3.new(1, 1, 1)
        end
        if buildPanel then buildPanel.Visible = false end
        if servePanel then servePanel.Visible = true end

        -- Option A: SERVE 탭 전환 시 Inventory 체크하여 패널 갱신
        self:RefreshServePanel(focusedSlot)
    end

    print(string.format("[MainHUD] P1|TAB_SWITCHED tab=%s", tabName))
end

--------------------------------------------------------------------------------
-- P1: 툴팁 표시 (P1-WF-02 비활성 상호작용 피드백)
--------------------------------------------------------------------------------

function MainHUD:ShowTooltip(message)
    if not CraftFrame then return end

    local tooltipLabel = CraftFrame:FindFirstChild("TooltipLabel")
    if tooltipLabel then
        tooltipLabel.Text = message
        -- 2초 후 자동 숨김
        task.delay(2, function()
            if tooltipLabel and tooltipLabel.Text == message then
                tooltipLabel.Text = ""
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- P1: CraftPanel 탭 상태 갱신 (Phase 기반)
--------------------------------------------------------------------------------

function MainHUD:UpdateCraftPanelTabs()
    local phase = self:GetTicketPhase(focusedSlot)

    -- Phase에 따라 적절한 탭으로 전환
    if phase == "SERVE" then
        self:SwitchTab("SERVE")
    else
        self:SwitchTab("BUILD")
    end
end

--------------------------------------------------------------------------------
-- P1: 선택된 티켓 기준 CraftPanel 갱신
--------------------------------------------------------------------------------

function MainHUD:UpdateCraftPanelForTicket(slotIndex)
    if not CraftFrame then return end

    -- 선택된 티켓 표시 갱신
    local selectedTicket = CraftFrame:FindFirstChild("SelectedTicket")
    if selectedTicket then
        selectedTicket.Text = string.format("선택: #%d", slotIndex)
    end

    -- 해당 슬롯의 주문 정보로 패널 갱신
    self:RefreshBuildPanel(slotIndex)
    self:RefreshServePanel(slotIndex)  -- Option A: SERVE 패널도 갱신

    -- 탭 상태 갱신
    self:UpdateCraftPanelTabs()
end

--------------------------------------------------------------------------------
-- P1: BUILD 패널 레시피 정보 갱신
--------------------------------------------------------------------------------

function MainHUD:RefreshBuildPanel(slotIndex)
    if not CraftFrame or not OrderFrame then return end

    local contentArea = CraftFrame:FindFirstChild("ContentArea")
    if not contentArea then return end

    local buildPanel = contentArea:FindFirstChild("BuildPanel")
    if not buildPanel then return end

    local recipeInfo = buildPanel:FindFirstChild("RecipeInfo")
    local craftBtn = buildPanel:FindFirstChild("CraftButton")
    -- progressFill은 SetCraftButtonState에서 관리 (여기서 참조 불필요)

    -- 해당 슬롯의 주문 정보 가져오기 (OrderFrame에서)
    local slot = OrderFrame:FindFirstChild("Slot" .. slotIndex)
    if not slot then return end

    local recipeName = slot:FindFirstChild("RecipeName")
    local recipeText = recipeName and recipeName.Text or "주문 없음"

    -- P1-WF-01: nameKo + difficulty + craftTime + reward만 표시
    -- (재료 목록은 P2)
    if recipeInfo then
        recipeInfo.Text = recipeText .. "\n\n제작 버튼을 눌러 요리를 시작하세요"
    end

    ----------------------------------------------------------------------------
    -- P1-UX-01: 슬롯 전환 시 버튼 상태 갱신 (단일 세터 사용)
    -- Fill은 Heartbeat에서 관리
    ----------------------------------------------------------------------------
    if self._activeCraftSlot then
        -- 제작 진행 중
        if self._activeCraftSlot == slotIndex then
            -- 제작 중인 슬롯으로 전환: 진행 상태 + Fill 표시
            self:SetCraftButtonState("crafting")
        else
            -- 다른 슬롯 선택: Fill 숨김 + 안내 텍스트
            self:SetCraftButtonState("other_crafting")
        end
    else
        -- 제작 중 아님: 기본 상태
        self:SetCraftButtonState("idle")
    end
end

--------------------------------------------------------------------------------
-- P1: SERVE 패널 렌더링 (Option A - Inventory 체크)
--------------------------------------------------------------------------------

function MainHUD:RefreshServePanel(slotIndex)
    if not CraftFrame then return end

    local contentArea = CraftFrame:FindFirstChild("ContentArea")
    if not contentArea then return end

    local servePanel = contentArea:FindFirstChild("ServePanel")
    if not servePanel then return end

    local serveInfo = servePanel:FindFirstChild("ServeInfo")
    local serveBtn = servePanel:FindFirstChild("ServeButton")

    -- 해당 슬롯의 recipeId 가져오기
    local recipeId = self:GetRecipeIdForSlot(slotIndex)
    if not recipeId then
        -- 주문 없음
        if serveInfo then
            serveInfo.Text = "주문이 없습니다."
        end
        if serveBtn then
            serveBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
            serveBtn.Text = "📦 납품하기"
        end
        return
    end

    -- Option A: Inventory에서 해당 요리 보유 확인
    local dishKey = "dish_" .. recipeId
    local inventory = Controller and Controller:GetInventory() or {}
    local dishCount = inventory[dishKey] or 0

    if dishCount > 0 then
        -- ✅ 요리 있음: 납품 가능
        local recipe = GameData.GetRecipeById(recipeId)
        local recipeName = recipe and recipe.nameKo or ("레시피 #" .. recipeId)

        if serveInfo then
            serveInfo.Text = string.format("✅ %s 완성!\n\n납품 대기 중... (보유: %d개)", recipeName, dishCount)
        end
        if serveBtn then
            serveBtn.BackgroundColor3 = UIConstants.PHASE.SERVE.color
            serveBtn.Text = "📦 납품하기"
        end

        print(string.format("[MainHUD] P1|SERVE_PANEL_READY slot=%d dish=%s count=%d", slotIndex, dishKey, dishCount))
    else
        -- ❌ 요리 없음: 납품 불가
        if serveInfo then
            serveInfo.Text = "요리가 없습니다.\n\nBUILD에서 제작하세요."
        end
        if serveBtn then
            serveBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
            serveBtn.Text = "📦 납품 불가"
        end

        print(string.format("[MainHUD] P1|SERVE_PANEL_NO_DISH slot=%d dish=%s", slotIndex, dishKey))
    end
end

--------------------------------------------------------------------------------
-- P1: 제작 버튼 클릭
--------------------------------------------------------------------------------

function MainHUD:OnCraftButtonClicked()
    local phase = self:GetTicketPhase(focusedSlot)

    -- BUILD 중(제작 중)이면 무시 + 툴팁
    if phase == "BUILD" then
        print("[MainHUD] P1|CRAFT_IGNORED reason=already_building")
        self:ShowTooltip("이미 제작 중입니다")
        return
    end

    -- 선택된 슬롯의 recipeId 가져오기
    local recipeId = self:GetRecipeIdForSlot(focusedSlot)

    -- P1-WF-02: nil 시 툴팁 (주문 없음/로딩 중)
    if not recipeId then
        print("[MainHUD] P1|CRAFT_IGNORED reason=no_order")
        self:ShowTooltip("주문이 없습니다")
        return
    end

    ----------------------------------------------------------------------------
    -- Bug 4 수정 2: 재료 체크 (ChatGPT 감리 승인)
    -- 조건 A: 스냅샷 없으면 차단 금지, 요청은 보내고 실패 복구에 의존
    ----------------------------------------------------------------------------
    local inventory = self._lastInventory
    local syncPending = (inventory == nil)

    if syncPending then
        -- 조건 A: 동기화 전이면 차단하지 않고 요청 보냄 + 안내
        print("[MainHUD] P1|CRAFT_IGNORED reason=sync_pending (request sent anyway)")
        self:ShowTooltip("동기화 중... 잠시 후 다시 시도하세요")
        -- 요청은 보내되, 실패 시 수정 3~4로 복구
    else
        -- 스냅샷 있음: 재료 체크 (명백히 부족할 때만 차단)
        local recipe = GameData.GetRecipeById(recipeId)
        if recipe and recipe.ingredients then
            for materialId, requiredCount in pairs(recipe.ingredients) do
                local haveCount = inventory[tostring(materialId)] or 0
                if haveCount < requiredCount then
                    local mat = GameData.GetMaterialById(materialId)
                    local matName = mat and mat.nameKo or ("재료 " .. materialId)
                    print(string.format("[MainHUD] P1|CRAFT_IGNORED reason=insufficient_material mat=%s have=%d need=%d",
                        matName, haveCount, requiredCount))
                    self:ShowTooltip(string.format("재료 부족: %s (%d/%d)", matName, haveCount, requiredCount))
                    return
                end
            end
        end
    end

    ----------------------------------------------------------------------------
    -- P1-CRIT Fix B: 낙관적 업데이트 제거
    -- _activeCraftSlot과 SetTicketPhase(BUILD)는 서버 응답(phase=start) 후에만 설정
    -- 여기서는 요청만 전송하고, 상태 변경은 UpdateCraftingState에서 처리
    ----------------------------------------------------------------------------
    print(string.format("[MainHUD] P1-CRIT|CRAFT_REQ_SEND slot=%d", focusedSlot))

    if Controller and Controller.CraftItemForSlot then
        Controller:CraftItemForSlot(focusedSlot)
    elseif Controller and Controller.CraftItem then
        Controller:CraftItem(recipeId)
    end
    -- P1-CRIT: 상태 변경 없음 (서버 응답 대기)
end

--------------------------------------------------------------------------------
-- P1: 납품 버튼 클릭
--------------------------------------------------------------------------------

function MainHUD:OnServeButtonClicked()
    local phase = self:GetTicketPhase(focusedSlot)

    -- SERVE 상태가 아니면 무시 + 툴팁
    -- Softlock Fix: Held Dish Guarantee 예외 (감리자 승인 2026-01-18)
    if phase ~= "SERVE" then
        local recipeId = self:GetRecipeIdForSlot(focusedSlot)
        if not recipeId or recipeId <= 0 then
            print("[MainHUD] P1|SERVE_IGNORED reason=not_serve_phase")
            self:ShowTooltip("먼저 요리를 완성하세요")
            return
        end
        local inventory = self._lastInventory
        local dishKey = "dish_" .. recipeId
        local hasDish = inventory and inventory[dishKey] and inventory[dishKey] >= 1
        if not hasDish then
            print("[MainHUD] P1|SERVE_IGNORED reason=not_serve_phase_no_dish")
            self:ShowTooltip("먼저 요리를 완성하세요")
            return
        end
        -- Held dish exists → 예외 허용, 계속 진행
        print(string.format(
            "[UI] SERVE_BUTTON_OVERRIDE reason=held_dish_match slot=%d recipeId=%d",
            focusedSlot, recipeId
        ))
    end

    -- 주문 확인 (방어 코드)
    local recipeId = self:GetRecipeIdForSlot(focusedSlot)
    if not recipeId then
        print("[MainHUD] P1|SERVE_IGNORED reason=no_order")
        self:ShowTooltip("주문이 없습니다")
        return
    end

    -- Option A: Inventory 체크 (요리 없으면 서버 요청 차단)
    local dishKey = "dish_" .. recipeId
    local inventory = Controller and Controller:GetInventory() or {}
    local dishCount = inventory[dishKey] or 0

    if dishCount <= 0 then
        print(string.format("[MainHUD] P1|SERVE_IGNORED reason=no_dish dish=%s", dishKey))
        self:ShowTooltip("요리가 없습니다. BUILD에서 제작하세요.")
        -- SERVE 패널 갱신 (버튼 비활성화 상태 반영)
        self:RefreshServePanel(focusedSlot)
        return
    end

    if Controller and Controller.DeliverOrder then
        Controller:DeliverOrder(focusedSlot)
    end
end

--------------------------------------------------------------------------------
-- P1: 슬롯의 recipeId 가져오기 (캐시된 주문 데이터 기반)
--------------------------------------------------------------------------------

-- 주문 데이터 캐시 (UpdateOrders에서 갱신)
local cachedOrders = {}

function MainHUD:GetRecipeIdForSlot(slotIndex)
    local order = cachedOrders[slotIndex]
    if order then
        return order.recipeId
    end
    return nil
end

--------------------------------------------------------------------------------
-- 4. 인벤토리 (Inventory) - 하단
--------------------------------------------------------------------------------

function MainHUD:CreateInventoryPanel()
    local frame = Instance.new("Frame")
    frame.Name = "InventoryFrame"
    frame.Size = UDim2.new(0, 600, 0, 80)
    frame.AnchorPoint = Vector2.new(0.5, 1)
    frame.Position = UDim2.new(0.5, 0, 1, -20)
    frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    frame.BackgroundTransparency = 0.2
    frame.Parent = ScreenGui
    InventoryFrame = frame

    local corner = Instance.new("UICorner")
    corner.Parent = frame

    -- 재료 섹션
    local materialsLabel = Instance.new("TextLabel")
    materialsLabel.Name = "MaterialsLabel"
    materialsLabel.Size = UDim2.new(1, -20, 0, 35)
    materialsLabel.Position = UDim2.new(0, 10, 0, 5)
    materialsLabel.BackgroundTransparency = 1
    materialsLabel.Text = "📦 재료: 로딩 중..."
    materialsLabel.TextColor3 = Color3.new(1, 1, 1)
    materialsLabel.TextXAlignment = Enum.TextXAlignment.Left
    materialsLabel.Font = Enum.Font.Gotham
    materialsLabel.TextSize = 14
    materialsLabel.Parent = frame

    -- 요리 섹션
    local dishesLabel = Instance.new("TextLabel")
    dishesLabel.Name = "DishesLabel"
    dishesLabel.Size = UDim2.new(1, -20, 0, 35)
    dishesLabel.Position = UDim2.new(0, 10, 0, 40)
    dishesLabel.BackgroundTransparency = 1
    dishesLabel.Text = "🍔 요리: 없음"
    dishesLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
    dishesLabel.TextXAlignment = Enum.TextXAlignment.Left
    dishesLabel.Font = Enum.Font.Gotham
    dishesLabel.TextSize = 14
    dishesLabel.Parent = frame
end

--------------------------------------------------------------------------------
-- 5. 업그레이드 팝업 (UpgradePopup) - 중앙 모달
--------------------------------------------------------------------------------

function MainHUD:CreateUpgradePopup()
    local frame = Instance.new("Frame")
    frame.Name = "UpgradeFrame"
    frame.Size = UDim2.new(0, 400, 0, 320)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.new(0.5, 0, 0.5, 0)
    frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    frame.Visible = false
    frame.Parent = ScreenGui
    UpgradeFrame = frame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    -- 제목
    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Text = "🔧 업그레이드 상점"
    title.Size = UDim2.new(1, 0, 0, 45)
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 20
    title.Parent = frame

    -- 닫기 버튼
    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0, 50, 0, 30)
    closeBtn.Position = UDim2.new(1, -60, 0, 8)
    closeBtn.Text = "닫기"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.TextSize = 14
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = frame

    local cCorner = Instance.new("UICorner")
    cCorner.CornerRadius = UDim.new(0, 6)
    cCorner.Parent = closeBtn

    closeBtn.MouseButton1Click:Connect(function()
        frame.Visible = false
    end)

    -- 업그레이드 항목 컨테이너
    local container = Instance.new("Frame")
    container.Name = "Container"
    container.Size = UDim2.new(1, -40, 1, -65)
    container.Position = UDim2.new(0, 20, 0, 55)
    container.BackgroundTransparency = 1
    container.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 10)
    layout.Parent = container

    -- 3종 업그레이드 버튼 생성
    local upgrades = {
        { id = "quantity", name = "📦 재료 수량 증가", desc = "배달 시 받는 재료량 +1" },
        { id = "craftSpeed", name = "⚡ 제작 속도 증가", desc = "요리 시간 10% 감소" },
        { id = "slots", name = "🗄️ 창고 확장", desc = "재료 보관 한도 +5" },
    }

    for _, up in ipairs(upgrades) do
        local btn = Instance.new("TextButton")
        btn.Name = up.id
        btn.Size = UDim2.new(1, 0, 0, 75)
        btn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
        btn.Text = ""
        btn.AutoButtonColor = true
        btn.Parent = container

        local bCorner = Instance.new("UICorner")
        bCorner.CornerRadius = UDim.new(0, 8)
        bCorner.Parent = btn

        -- 업그레이드 이름
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Name = "NameLabel"
        nameLabel.Text = up.name
        nameLabel.Size = UDim2.new(0.6, 0, 0, 30)
        nameLabel.Position = UDim2.new(0, 15, 0, 10)
        nameLabel.BackgroundTransparency = 1
        nameLabel.TextColor3 = Color3.new(1, 1, 1)
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextSize = 16
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = btn

        -- 설명
        local descLabel = Instance.new("TextLabel")
        descLabel.Name = "DescLabel"
        descLabel.Text = up.desc
        descLabel.Size = UDim2.new(0.6, 0, 0, 20)
        descLabel.Position = UDim2.new(0, 15, 0, 38)
        descLabel.BackgroundTransparency = 1
        descLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
        descLabel.Font = Enum.Font.Gotham
        descLabel.TextSize = 12
        descLabel.TextXAlignment = Enum.TextXAlignment.Left
        descLabel.Parent = btn

        -- 비용/레벨 표시
        local costLabel = Instance.new("TextLabel")
        costLabel.Name = "CostLabel"
        costLabel.Text = "로딩..."
        costLabel.Size = UDim2.new(0.35, 0, 1, 0)
        costLabel.Position = UDim2.new(0.6, 0, 0, 0)
        costLabel.BackgroundTransparency = 1
        costLabel.TextColor3 = Color3.fromRGB(255, 220, 0)
        costLabel.Font = Enum.Font.GothamBold
        costLabel.TextSize = 14
        costLabel.TextXAlignment = Enum.TextXAlignment.Right
        costLabel.Parent = btn

        local upgradeId = up.id  -- 클로저용 캡처
        btn.MouseButton1Click:Connect(function()
            if Controller and Controller.BuyUpgrade then
                Controller:BuyUpgrade(upgradeId)
            end
        end)
    end
end

function MainHUD:ToggleUpgradePopup()
    if UpgradeFrame then
        UpgradeFrame.Visible = not UpgradeFrame.Visible
    end
end

--------------------------------------------------------------------------------
-- 갱신 메서드 (Update Methods)
--------------------------------------------------------------------------------

function MainHUD:UpdateWallet(walletData)
    if not TopBar or not walletData then return end

    local label = TopBar:FindFirstChild("WalletLabel")
    if label then
        -- camelCase 표준 (정규화된 데이터)
        local coins = walletData.coins or 0
        label.Text = string.format("💰 %d", coins)
    end
end

function MainHUD:UpdateDeliveryTimer()
    if not TopBar then return end

    local btn = TopBar:FindFirstChild("DeliveryButton")
    if not btn then return end

    local now = tick()
    local remaining = math.ceil(CooldownEndTime - now)

    if remaining <= 0 then
        btn.Text = "🚚 배달 받기"
        btn.AutoButtonColor = true
        btn.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
    else
        btn.Text = string.format("⏳ %ds", remaining)
        btn.AutoButtonColor = false
        btn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    end
end

function MainHUD:UpdateCooldown(cooldownData)
    if not cooldownData then return end

    -- Phase 3: Tutorial Active 예외 처리 (§12.1 [CLR])
    -- 튜토리얼 활성 시 항상 Ready 상태 유지
    if cooldownData.tutorialActive then
        -- Ready 상태를 시간축에서도 0으로 정규화
        CooldownEndTime = tick()  -- remaining ≈ 0
        self:UpdateDeliveryTimer()
        return
    end

    -- 일반 쿨다운 처리
    local remainingSeconds = tonumber(cooldownData.remainingSeconds) or 0
    remainingSeconds = math.max(0, remainingSeconds)

    CooldownEndTime = tick() + remainingSeconds
    self:UpdateDeliveryTimer()
end

function MainHUD:UpdateOrders(ordersData)
    if not OrderFrame or not ordersData then return end

    -- P1: 초기 포커스 계산용
    local firstValidSlot = nil

    -- ordersData는 array (slotId 순 정렬) 또는 map 형태 가능
    for i = 1, ServerFlags.ORDER_SLOT_COUNT do
        local slot = OrderFrame:FindFirstChild("Slot" .. i)
        if slot then
            -- P1: 티켓 카드 요소 참조
            local recipeName = slot:FindFirstChild("RecipeName")
            local rewardLabel = slot:FindFirstChild("RewardLabel")

            -- array 형태: ordersData[i] (배열 인덱스)
            -- map 형태: ordersData[i] 또는 ordersData에서 slotId 검색
            local order = nil

            -- 배열 형태 체크
            if ordersData[i] then
                order = ordersData[i]
            else
                -- slotId로 검색 (array of objects 형태)
                for _, o in pairs(ordersData) do
                    if o.slotId == i then
                        order = o
                        break
                    end
                end
            end

            -- P1: 이전 주문과 비교 (납품 후 새 주문 감지용)
            local previousOrder = cachedOrders[i]
            local previousRecipeId = previousOrder and previousOrder.recipeId

            -- P1: 주문 데이터 캐시 갱신
            cachedOrders[i] = order

            if order then
                -- P1: 새 주문 감지 → ORDER로 리셋 (납품 완료 또는 rotate)
                if not previousRecipeId or previousRecipeId ~= order.recipeId then
                    self:SetTicketPhase(i, "ORDER")
                    print(string.format("[MainHUD] P1|NEW_ORDER slot=%d recipeId=%d", i, order.recipeId))

                    -- P1-UX-01: 해당 슬롯이 제작 중이었으면 Progress 초기화
                    if self._activeCraftSlot == i then
                        self._activeCraftSlot = nil
                        self:ResetCraftProgressUI()
                    end
                end
                local recipe = GameData.GetRecipeById(order.recipeId)
                local reward = order.reward or 0

                -- P1: 첫 유효 슬롯 기록 (초기 포커스 규칙)
                if not firstValidSlot then
                    firstValidSlot = i
                end

                if recipe then
                    -- P1: 티켓 카드 형식 (nameKo + 난이도 뱃지)
                    local diffBadge = UIConstants.GetDifficultyBadge(recipe.difficulty)
                    if recipeName then
                        recipeName.Text = string.format("%s %s", recipe.nameKo, diffBadge)
                    end
                    if rewardLabel then
                        rewardLabel.Text = string.format("💰 %d  ⏱️ %ds", reward, recipe.craftTime or 0)
                    end
                else
                    if recipeName then
                        recipeName.Text = string.format("레시피 #%d", order.recipeId or 0)
                    end
                    if rewardLabel then
                        rewardLabel.Text = string.format("💰 %d", reward)
                    end
                end
            else
                -- 주문 없음
                if recipeName then
                    recipeName.Text = "주문 대기 중..."
                end
                if rewardLabel then
                    rewardLabel.Text = ""
                end

                -- 주문 없으면 ORDER 상태로 리셋
                self:SetTicketPhase(i, "ORDER")
            end
        end
    end

    -- P1: 초기 포커스 규칙 적용 (슬롯 1 우선, 없으면 2→3)
    if firstValidSlot and focusedSlot then
        -- 현재 포커스된 슬롯에 주문이 없으면 첫 유효 슬롯으로 이동
        if not cachedOrders[focusedSlot] and firstValidSlot ~= focusedSlot then
            self:SelectTicket(firstValidSlot)
        end
    end

    -- P1-FIX: Phase 불변식 강제 (동일 recipeId 리필 시 SERVE 잔존 방지)
    -- 감리 권고 Option 1: "SERVE 상태는 dish 존재를 전제로 한다"
    -- 감리 권고 (2026-01-17): 오탐 방지를 위해 self._lastInventory 사용
    -- C-3 (2026-01-18): 역방향 추가 - ORDER인데 dish 있으면 SERVE로 자동 전환
    local inventory = self._lastInventory
    if inventory then
        for slotIdx = 1, ServerFlags.ORDER_SLOT_COUNT do
            local phase = self:GetTicketPhase(slotIdx)
            local order = cachedOrders[slotIdx]
            if order and order.recipeId then
                local dishKey = "dish_" .. order.recipeId
                local dishCount = inventory[dishKey] or 0

                if phase == "SERVE" and dishCount <= 0 then
                    -- 기존: SERVE인데 dish 없음 → ORDER로 리셋
                    self:SetTicketPhase(slotIdx, "ORDER")
                    print(string.format("[MainHUD] P1-FIX|PHASE_INVARIANT_RESET slot=%d reason=no_dish dish=%s", slotIdx, dishKey))
                elseif phase == "ORDER" and dishCount >= 1 then
                    -- C-3: ORDER인데 dish 있음 → SERVE로 자동 전환
                    self:SetTicketPhase(slotIdx, "SERVE")
                    print(string.format("[MainHUD] C3|AUTO_SERVE slot=%d recipeId=%d dishCount=%d", slotIdx, order.recipeId, dishCount))
                end
            end
        end
    elseif not self._invariantSkipLogged then
        -- 인벤토리 미동기화 → 불변식 체크 스킵 (오탐 방지, 최초 1회만 로그)
        self._invariantSkipLogged = true
        print("[MainHUD] P1-FIX|INVARIANT_SKIP reason=inventory_not_ready")
    end

    -- P1: CraftPanel 갱신 (현재 선택된 티켓 기준)
    self:RefreshBuildPanel(focusedSlot)
end

function MainHUD:UpdateInventory(inventoryData)
    if not InventoryFrame then return end

    -- Bug 4 수정 1: 인벤토리 스냅샷 저장 (ChatGPT 감리 승인)
    -- 조건 A: nil도 저장 (Fail-Closed 방지 - 스냅샷 없으면 차단 금지)
    self._lastInventory = inventoryData

    local materialsLabel = InventoryFrame:FindFirstChild("MaterialsLabel")
    local dishesLabel = InventoryFrame:FindFirstChild("DishesLabel")

    if not inventoryData then
        if materialsLabel then materialsLabel.Text = "📦 재료: 동기화 중..." end
        if dishesLabel then dishesLabel.Text = "🍔 요리: 동기화 중..." end
        return
    end

    -- [HUD_IN] BindableEvent 수신 후 검증 로그 (감리자 포맷)
    do
        local strKeys, numKeys, dishKeys, dishTotal = 0, 0, 0, 0
        local sample = {}
        local hasDish1 = false

        if type(inventoryData) == "table" then
            for k, v in pairs(inventoryData) do
                if type(k) == "string" then
                    strKeys = strKeys + 1
                    if k:sub(1, 5) == "dish_" then
                        dishKeys = dishKeys + 1
                        dishTotal = dishTotal + (tonumber(v) or 0)
                    end
                else
                    numKeys = numKeys + 1
                end
                if #sample < 6 then
                    table.insert(sample, tostring(k) .. "=" .. tostring(v))
                end
            end
            hasDish1 = (inventoryData["dish_1"] ~= nil)
        end

        print(string.format(
            "[CL][HUD][INV][IN] keys_total=%d keyType={str=%d, num=%d} dishKeys=%d dishTotal=%d has_dish_1=%s sample={%s}",
            strKeys + numKeys, strKeys, numKeys, dishKeys, dishTotal,
            tostring(hasDish1), table.concat(sample, ",")
        ))
    end

    -- 재료 표시 (materialId 1~6) - B-0: 문자열 키로 접근
    local materialsText = "📦 "
    local hasMaterials = false
    for i = 1, 6 do
        local count = inventoryData[tostring(i)] or 0
        if count > 0 then
            local mat = GameData.GetMaterialById(i)
            materialsText = materialsText .. string.format("%s:%d  ", mat.nameKo, count)
            hasMaterials = true
        end
    end
    if not hasMaterials then
        materialsText = "📦 재료 없음"
    end
    if materialsLabel then
        materialsLabel.Text = materialsText
    end

    -- 요리 표시 (A-2+A-3: count>0만 + 총합 + 빈 상태)
    -- SSOT: GameData.GetAllRecipeIds() 동적, ServerFlags.DISH_CAP_TOTAL 참조
    local dishParts = {}
    local totalDishCount = 0

    for _, rid in ipairs(GameData.GetAllRecipeIds()) do
        local dishKey = "dish_" .. rid
        local count = inventoryData[dishKey] or 0
        totalDishCount = totalDishCount + count

        if count > 0 then
            local recipe = GameData.GetRecipeById(rid)
            local recipeName = recipe.nameKo or recipe.name or ("Recipe " .. rid)
            table.insert(dishParts, string.format("%s (%d)", recipeName, count))
        end
    end

    local dishCap = ServerFlags.DISH_CAP_TOTAL
    local dishesText

    if #dishParts > 0 then
        dishesText = "🍔 " .. table.concat(dishParts, " · ") .. string.format("  총 요리: %d/%d", totalDishCount, dishCap)
    else
        dishesText = string.format("🍔 요리 없음  총 요리: 0/%d", dishCap)
    end

    if dishesLabel then
        dishesLabel.Text = dishesText
    end

    -- C-3 (2026-01-18): Inventory 갱신 후 모든 슬롯 phase 재평가
    -- Session Load 시 UpdateOrders가 먼저 호출되어 ORDER로 설정되지만,
    -- UpdateInventory에서 dish 보유 상태를 알게 되면 SERVE로 전환
    for slotIdx = 1, ServerFlags.ORDER_SLOT_COUNT do
        local phase = self:GetTicketPhase(slotIdx)
        local order = cachedOrders[slotIdx]
        if order and order.recipeId then
            local dishKey = "dish_" .. order.recipeId
            local dishCount = inventoryData[dishKey] or 0

            if phase == "ORDER" and dishCount >= 1 then
                -- C-3: ORDER인데 dish 있음 → SERVE로 자동 전환
                self:SetTicketPhase(slotIdx, "SERVE")
                print(string.format("[MainHUD] C3|AUTO_SERVE_ON_INV slot=%d recipeId=%d dishCount=%d", slotIdx, order.recipeId, dishCount))
            elseif phase == "SERVE" and dishCount <= 0 then
                -- 기존 불변식: SERVE인데 dish 없음 → ORDER로 리셋
                self:SetTicketPhase(slotIdx, "ORDER")
                print(string.format("[MainHUD] C3|PHASE_RESET_ON_INV slot=%d reason=no_dish", slotIdx))
            end
        end
    end

    -- Option A: Inventory 변경 시 SERVE 패널 갱신 (요리 보유 상태 반영)
    local phase = self:GetTicketPhase(focusedSlot)
    if phase == "SERVE" then
        self:RefreshServePanel(focusedSlot)
    end
end

function MainHUD:UpdateUpgrades(upgradesData)
    if not UpgradeFrame or not upgradesData then return end

    local container = UpgradeFrame:FindFirstChild("Container")
    if not container then return end

    local upgradeConfigs = {
        { id = "quantity", baseKey = "UPGRADE_BASE_QUANTITY" },
        { id = "craftSpeed", baseKey = "UPGRADE_BASE_CRAFTSPEED" },
        { id = "slots", baseKey = "UPGRADE_BASE_SLOTS" },
    }

    for _, config in ipairs(upgradeConfigs) do
        local btn = container:FindFirstChild(config.id)
        if btn then
            local costLabel = btn:FindFirstChild("CostLabel")
            if costLabel then
                local currentLv = upgradesData[config.id] or 1

                -- 비용 계산: floor(Base * Growth^(level-1))
                local base = ServerFlags[config.baseKey] or 100
                local growth = ServerFlags.UPGRADE_GROWTH or 1.3
                local nextCost = math.floor(base * math.pow(growth, currentLv - 1))

                -- MAX LEVEL 체크
                if currentLv >= ServerFlags.MAX_LEVEL then
                    costLabel.Text = string.format("MAX (Lv.%d)", currentLv)
                    costLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                else
                    costLabel.Text = string.format("Lv.%d → %d💰", currentLv, nextCost)
                    costLabel.TextColor3 = Color3.fromRGB(255, 220, 0)
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- P1-UX-01: 버튼 상태 단일 세터 (ChatGPT 감리 승인)
-- 모든 버튼 텍스트/Fill 변경은 이 함수만 사용 (다른 경로 직접 수정 금지)
-- state: "idle" | "crafting" | "other_crafting"
--------------------------------------------------------------------------------

function MainHUD:SetCraftButtonState(state)
    if not CraftFrame then return end

    local contentArea = CraftFrame:FindFirstChild("ContentArea")
    if not contentArea then return end

    local buildPanel = contentArea:FindFirstChild("BuildPanel")
    if not buildPanel then return end

    local craftBtn = buildPanel:FindFirstChild("CraftButton")
    if not craftBtn then return end

    -- P1-UX-01: BackgroundContainer 내부의 Fill 참조
    local bgContainer = craftBtn:FindFirstChild("BackgroundContainer")
    local progressFill = bgContainer and bgContainer:FindFirstChild("CraftProgressFill")

    if state == "idle" then
        -- 기본 상태: Fill 숨김, 제작 시작 텍스트
        craftBtn.Text = "🔧 제작 시작"
        craftBtn.BackgroundColor3 = UIConstants.PHASE.BUILD.color
        if progressFill then
            progressFill.Size = UDim2.new(0, 0, 1, 0)
        end
        -- Heartbeat 업데이트 중지
        self._craftStartTime = nil
        self._craftEndTime = nil

    elseif state == "crafting" then
        -- 제작 중 (현재 슬롯 = 제작 슬롯): Fill 표시, 제작 중 텍스트
        craftBtn.Text = "⏳ 제작 중..."
        craftBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
        -- Fill은 Heartbeat에서 업데이트

    elseif state == "other_crafting" then
        -- 다른 슬롯 제작 중: Fill 숨김, 안내 텍스트
        craftBtn.Text = "다른 요리 준비 중..."
        craftBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
        if progressFill then
            progressFill.Size = UDim2.new(0, 0, 1, 0)
        end
    end

    print(string.format("[MainHUD] P1-UX-01|BUTTON_STATE state=%s", state))
end

--------------------------------------------------------------------------------
-- P1-UX-01: Progress Fill Heartbeat 업데이트
--------------------------------------------------------------------------------

function MainHUD:UpdateCraftProgressFill()
    -- 제작 타이밍 정보 없으면 스킵
    if not self._craftStartTime or not self._craftEndTime then return end
    if not self._activeCraftSlot then return end

    -- 현재 포커스가 제작 슬롯이 아니면 스킵 (Fill은 숨겨진 상태)
    if self._activeCraftSlot ~= focusedSlot then return end

    -- Fill 참조
    if not CraftFrame then return end
    local contentArea = CraftFrame:FindFirstChild("ContentArea")
    if not contentArea then return end
    local buildPanel = contentArea:FindFirstChild("BuildPanel")
    if not buildPanel then return end
    local craftBtn = buildPanel:FindFirstChild("CraftButton")
    if not craftBtn then return end
    local bgContainer = craftBtn:FindFirstChild("BackgroundContainer")
    local progressFill = bgContainer and bgContainer:FindFirstChild("CraftProgressFill")
    if not progressFill then return end

    -- ratio 계산
    local now = tick()
    local elapsed = now - self._craftStartTime
    local duration = self._craftEndTime - self._craftStartTime
    if duration <= 0 then duration = 5 end

    local ratio = math.clamp(elapsed / duration, 0, 1)
    progressFill.Size = UDim2.new(ratio, 0, 1, 0)
end

-- 호환성: 기존 ResetCraftProgressUI 호출을 SetCraftButtonState("idle")로 대체
function MainHUD:ResetCraftProgressUI()
    self:SetCraftButtonState("idle")
    print("[MainHUD] P1-UX-01|PROGRESS_RESET")
end

function MainHUD:UpdateCraftingState(craftingState)
    if not CraftFrame then return end

    ----------------------------------------------------------------------------
    -- CRIT-P1-02 Fix: Reject vs Fail 분리 (ChatGPT 감리 승인)
    -- Reject: already_crafting 등 → 상태 변경 0 (No-Op)
    -- Fail: insufficient_materials 등 → Phase 롤백 + _activeCraftSlot 정리
    ----------------------------------------------------------------------------
    if craftingState and craftingState.failed then
        local nc = craftingState.noticeCode

        -- Reject 타입: 실패가 아니라 "거절" → 상태 변경 0
        local REJECT_CODES = {
            already_crafting = true,
            craft_in_progress = true,
            slot_locked = true,
        }

        if REJECT_CODES[nc] then
            -- 상태 변경 0: Phase 유지, _activeCraftSlot 유지
            print(string.format("[MainHUD] P1|CRAFT_REJECTED_KEEP_STATE noticeCode=%s activeCraftSlot=%s focused=%d",
                tostring(nc), tostring(self._activeCraftSlot), focusedSlot))
            self:ShowTooltip("이미 제작 중입니다")
            return  -- No-Op: 상태 변경 없이 즉시 리턴
        end

        ------------------------------------------------------------------------
        -- 여기부터 Fail 타입: 진짜 실패 → Phase 롤백 + _activeCraftSlot 정리
        ------------------------------------------------------------------------
        local targetSlot = self._activeCraftSlot or focusedSlot
        local currentPhase = self:GetTicketPhase(targetSlot)

        if currentPhase == "BUILD" then
            self:SetTicketPhase(targetSlot, "ORDER")
            print(string.format("[MainHUD] P1|CRAFT_FAILED_ROLLBACK targetSlot=%d focusedSlot=%d error=%s noticeCode=%s",
                targetSlot, focusedSlot, tostring(craftingState.error), tostring(nc)))
        end

        -- 에러별 툴팁 메시지 (Contract v1.3 noticeCode 표준)
        local tooltipMsg = "제작 실패"
        if nc == "insufficient_materials" or nc == "not_enough_materials" then
            tooltipMsg = "재료가 부족합니다"
        elseif nc == "dish_cap_full" or nc == "dish_inventory_full" then
            tooltipMsg = "요리 보관함이 가득 찼습니다"
        elseif nc == "invalid_recipe" then
            tooltipMsg = "잘못된 레시피입니다"
        elseif nc == "no_order" then
            tooltipMsg = "주문이 없습니다"
        elseif nc == "bad_param" then
            tooltipMsg = "잘못된 요청입니다"
        elseif nc == "crafting_disabled" then
            tooltipMsg = "제작 기능이 비활성화되었습니다"
        elseif nc == "data_error" then
            tooltipMsg = "데이터 오류가 발생했습니다"
        end
        self:ShowTooltip(tooltipMsg)

        -- 진짜 실패이므로 _activeCraftSlot 정리
        self._activeCraftSlot = nil

        -- P1-UX-01: Progress UI 초기화
        self:ResetCraftProgressUI()
        return  -- 실패 처리 후 종료
    end

    local contentArea = CraftFrame:FindFirstChild("ContentArea")
    if not contentArea then return end

    local buildPanel = contentArea:FindFirstChild("BuildPanel")
    if not buildPanel then return end

    local progressContainer = buildPanel:FindFirstChild("ProgressContainer")
    local progressBar = progressContainer and progressContainer:FindFirstChild("ProgressBar")
    local progressText = progressContainer and progressContainer:FindFirstChild("ProgressText")
    local craftBtn = buildPanel:FindFirstChild("CraftButton")
    -- progressFill은 SetCraftButtonState/UpdateCraftProgressFill에서 관리
    local recipeInfo = buildPanel:FindFirstChild("RecipeInfo")

    if craftingState and craftingState.isActive then
        local recipe = GameData.GetRecipeById(craftingState.recipeId)
        local recipeName = recipe and recipe.nameKo or "요리"

        ------------------------------------------------------------------------
        -- P1-CRIT Fix B-2: phase=start에서만 _activeCraftSlot 설정
        -- SSOT: craftingState.slotId가 1순위, 없으면 focusedSlot 폴백
        -- 규칙: _activeCraftSlot은 phase=start에서만 설정됨
        ------------------------------------------------------------------------
        local targetSlot = craftingState.slotId or focusedSlot
        self._activeCraftSlot = targetSlot  -- P1-CRIT: 서버 확인 후에만 설정
        self:SetTicketPhase(targetSlot, "BUILD")
        print(string.format("[MainHUD] P1-CRIT|CRAFT_START_CONFIRMED targetSlot=%d focusedSlot=%d slotId=%s",
            targetSlot, focusedSlot, tostring(craftingState.slotId)))

        ------------------------------------------------------------------------
        -- P1-UX-01: 버튼 진행률 표시 (Heartbeat 기반)
        -- 조건: activeCraftSlot == focusedSlot 일 때만 진행률 표시
        -- 다른 슬롯 포커스 시 "다른 요리 준비 중..." 표시
        ------------------------------------------------------------------------
        local showProgressOnButton = (self._activeCraftSlot == focusedSlot)

        -- 타이밍 정보 저장 (Heartbeat에서 사용)
        if craftingState.startTime and craftingState.endTime then
            self._craftStartTime = craftingState.startTime
            self._craftEndTime = craftingState.endTime
            local duration = craftingState.endTime - craftingState.startTime
            print(string.format("[MainHUD] P1-UX-01|PROGRESS_START duration=%.1f", duration))
            -- PG-1 C-08: 감리 증거 로그 (TimerFlow Exit Evidence)
            print(string.format("[TimerFlow] START slotId=%d duration=%.1f",
                focusedSlot or 0, duration))
        end

        if showProgressOnButton then
            -- SetCraftButtonState로 텍스트/색상 변경 (단일 세터)
            self:SetCraftButtonState("crafting")
        else
            -- 다른 슬롯 포커스 중: "다른 요리 준비 중..."
            self:SetCraftButtonState("other_crafting")
        end

        -- 기존 진행 바 숨김 (P1-UX-01: 버튼 Fill로 대체)
        if progressContainer then
            progressContainer.Visible = false
        end

        print(string.format("[MainHUD] P1|CRAFT_PROGRESS recipe=%s showOnButton=%s", recipeName, tostring(showProgressOnButton)))
    else
        ------------------------------------------------------------------------
        -- P1-HF: phase=complete 처리 - slotId 기반 SERVE 전환
        -- SSOT: craftingState.slotId가 유일한 진실, focusedSlot 폴백 금지
        ------------------------------------------------------------------------
        local slotId = craftingState.slotId

        -- slotId 누락 시 경고 + _activeCraftSlot 폴백 (레거시 호환, 권장하지 않음)
        if not slotId then
            warn(string.format("[MainHUD] P1|CRAFT_COMPLETE_MISSING_SLOTID activeCraftSlot=%s focused=%d",
                tostring(self._activeCraftSlot), focusedSlot))
            slotId = self._activeCraftSlot
        end

        -- slotId가 여전히 없으면 처리 불가
        if not slotId then
            warn("[MainHUD] P1|CRAFT_COMPLETE_FAILED reason=no_slotId")
            self:ResetCraftProgressUI()
            return
        end

        local currentPhase = self:GetTicketPhase(slotId)

        -- Phase가 BUILD일 때만 SERVE로 전환 (상태 머신 검증)
        if currentPhase == "BUILD" then
            self:SetTicketPhase(slotId, "SERVE")
            print(string.format("[MainHUD] P1|PHASE_CHANGED slot=%d phase=SERVE cause=craft_complete focused=%d",
                slotId, focusedSlot))
            -- SERVE 탭으로 자동 전환 (완료된 슬롯이 현재 포커스일 때만)
            if slotId == focusedSlot then
                self:SwitchTab("SERVE")
            end
        elseif currentPhase ~= "SERVE" then
            -- IDEA-P1-FAILSAFE: BUILD가 아닌 상태에서 complete 수신 시 경고
            warn(string.format("[MainHUD] P1|CRAFT_COMPLETE_PHASE_MISMATCH slot=%d phase=%s expected=BUILD",
                slotId, currentPhase))
        end

        ------------------------------------------------------------------------
        -- P1-CRIT: 귀속 슬롯 정리 (완료 후)
        -- 규칙: 완료된 slotId가 _activeCraftSlot과 일치할 때만 해제
        ------------------------------------------------------------------------
        if self._activeCraftSlot == slotId then
            self._activeCraftSlot = nil
        else
            -- slotId 불일치 시 경고 (비정상 상태)
            warn(string.format("[MainHUD] P1-CRIT|CRAFT_COMPLETE_SLOT_MISMATCH activeCraftSlot=%s completedSlot=%d",
                tostring(self._activeCraftSlot), slotId))
            self._activeCraftSlot = nil  -- 안전하게 정리
        end

        -- P1-UX-01: Progress UI 초기화 (단일 루틴)
        self:ResetCraftProgressUI()

        -- 기존 진행 바 숨김 (호환성)
        if progressContainer then
            progressContainer.Visible = false
        end
        if progressBar then
            progressBar.Size = UDim2.new(0, 0, 1, 0)
        end

        print(string.format("[MainHUD] P1|CRAFT_COMPLETE slot=%d focused=%d activeCraftSlot=%s",
            slotId, focusedSlot, tostring(self._activeCraftSlot)))
    end
end

--------------------------------------------------------------------------------
-- 통합 업데이트 (Initial Data용 - camelCase 표준)
--------------------------------------------------------------------------------

function MainHUD:UpdateAll(data)
    if not data then return end

    -- camelCase 표준 (정규화된 ClientData)
    if data.wallet then self:UpdateWallet(data.wallet) end
    if data.inventory then self:UpdateInventory(data.inventory) end
    if data.orders then self:UpdateOrders(data.orders) end
    if data.upgrades then self:UpdateUpgrades(data.upgrades) end
    if data.cooldown then self:UpdateCooldown(data.cooldown) end
    if data.craftingState then self:UpdateCraftingState(data.craftingState) end
end

--------------------------------------------------------------------------------
-- P2: 납품 결과 표시 (Score/Tip/TotalRevenue)
-- Contract v1.4 §4.5 - DeliverResponse 확장 필드 UI 렌더링
--------------------------------------------------------------------------------

-- P2: 결과 표시용 프레임 (1회 생성, 재사용)
local DeliverResultFrame = nil
local DeliverResultTween = nil  -- 현재 진행 중인 Tween 참조
local DeliverResultChildTweens = {}  -- Fix-UI-DELIVER-01: 자식 Tween 참조 저장
local DeliverResultShowId = 0   -- P2-HF: Race Condition 방지용 토큰

function MainHUD:CreateDeliverResultUI()
    if DeliverResultFrame then return end
    if not ScreenGui then return end

    -- 결과 프레임 (화면 중앙 - 캐릭터 상반신 레벨)
    local frame = Instance.new("Frame")
    frame.Name = "DeliverResultFrame"
    frame.Size = UDim2.new(0, 280, 0, 140)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)  -- P2-HF: 중앙 앵커로 변경
    frame.Position = UDim2.new(0.5, 0, 0.42, 0)  -- P2-HF: Y 42% (ChatGPT 권장)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)  -- 더 어둡게
    frame.BackgroundTransparency = 0  -- 완전 불투명
    frame.Visible = false
    frame.ZIndex = 100  -- 높은 ZIndex
    frame.Parent = ScreenGui
    DeliverResultFrame = frame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 200, 100)
    stroke.Thickness = 3  -- 더 두껍게
    stroke.Parent = frame

    -- 제목 (ORDER COMPLETE!)
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, 0, 0, 30)
    titleLabel.Position = UDim2.new(0, 0, 0, 8)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "✅ ORDER COMPLETE!"
    titleLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 18
    titleLabel.ZIndex = 101  -- 부모보다 높게
    titleLabel.Parent = frame

    -- Score 표시 (예: ⭐ Good)
    local scoreLabel = Instance.new("TextLabel")
    scoreLabel.Name = "ScoreLabel"
    scoreLabel.Size = UDim2.new(1, 0, 0, 28)
    scoreLabel.Position = UDim2.new(0, 0, 0, 40)
    scoreLabel.BackgroundTransparency = 1
    scoreLabel.Text = "⭐ Good"
    scoreLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
    scoreLabel.Font = Enum.Font.GothamBold
    scoreLabel.TextSize = 22
    scoreLabel.ZIndex = 101
    scoreLabel.Parent = frame

    -- Reward 표시 (P2-HF: 왼쪽 절반 중앙 배치)
    local rewardLabel = Instance.new("TextLabel")
    rewardLabel.Name = "RewardLabel"
    rewardLabel.Size = UDim2.new(0.45, 0, 0, 22)  -- P2-HF: 겹침 방지
    rewardLabel.Position = UDim2.new(0.25, 0, 0, 72)  -- P2-HF: 왼쪽 절반의 중앙
    rewardLabel.AnchorPoint = Vector2.new(0.5, 0)  -- P2-HF: 중앙 앵커
    rewardLabel.BackgroundTransparency = 1
    rewardLabel.Text = "💰 Reward: 0"
    rewardLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
    rewardLabel.Font = Enum.Font.GothamBold
    rewardLabel.TextSize = 14
    rewardLabel.TextXAlignment = Enum.TextXAlignment.Center  -- P2-HF: 중앙 정렬
    rewardLabel.ZIndex = 101
    rewardLabel.Parent = frame

    -- Tip 표시 (P2-HF: 오른쪽 절반 중앙 배치)
    local tipLabel = Instance.new("TextLabel")
    tipLabel.Name = "TipLabel"
    tipLabel.Size = UDim2.new(0.45, 0, 0, 22)  -- P2-HF: 겹침 방지
    tipLabel.Position = UDim2.new(0.75, 0, 0, 72)  -- P2-HF: 오른쪽 절반의 중앙
    tipLabel.AnchorPoint = Vector2.new(0.5, 0)  -- P2-HF: 중앙 앵커
    tipLabel.BackgroundTransparency = 1
    tipLabel.Text = "💵 Tip: +0"
    tipLabel.TextColor3 = Color3.fromRGB(100, 255, 150)
    tipLabel.Font = Enum.Font.GothamBold
    tipLabel.TextSize = 14
    tipLabel.TextXAlignment = Enum.TextXAlignment.Center  -- P2-HF: 중앙 정렬
    tipLabel.ZIndex = 101
    tipLabel.Parent = frame

    -- TotalRevenue 표시 (강조)
    local totalLabel = Instance.new("TextLabel")
    totalLabel.Name = "TotalLabel"
    totalLabel.Size = UDim2.new(1, -20, 0, 28)
    totalLabel.Position = UDim2.new(0, 10, 0, 100)
    totalLabel.BackgroundTransparency = 1
    totalLabel.Text = "💎 Total: 0"
    totalLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
    totalLabel.Font = Enum.Font.GothamBlack
    totalLabel.TextSize = 20  -- 더 크게
    totalLabel.TextXAlignment = Enum.TextXAlignment.Center
    totalLabel.ZIndex = 101
    totalLabel.Parent = frame

    print("[MainHUD] P2|DELIVER_RESULT_UI_CREATED")
end

function MainHUD:ShowDeliverResult(data)
    if not data then return end

    -- P2-HF: Race Condition 방지 - showId 증가
    DeliverResultShowId = DeliverResultShowId + 1
    local thisShowId = DeliverResultShowId

    -- UI 생성 (최초 1회)
    self:CreateDeliverResultUI()
    if not DeliverResultFrame then return end

    -- 데이터 추출
    local score = data.score or "Good"
    local tip = data.tip or 0
    local reward = data.reward or 0
    local totalRevenue = data.totalRevenue or (reward + tip)

    -- Score 이모지 매핑 (MVP: Good만, 향후 확장)
    local scoreEmoji = "⭐"
    local scoreColor = Color3.fromRGB(255, 220, 100)
    if score == "Good" then
        scoreEmoji = "⭐"
        scoreColor = Color3.fromRGB(255, 220, 100)
    elseif score == "Great" then
        scoreEmoji = "🌟"
        scoreColor = Color3.fromRGB(255, 180, 50)
    elseif score == "Perfect" then
        scoreEmoji = "💫"
        scoreColor = Color3.fromRGB(255, 100, 255)
    end

    -- UI 업데이트
    local scoreLabel = DeliverResultFrame:FindFirstChild("ScoreLabel")
    local rewardLabel = DeliverResultFrame:FindFirstChild("RewardLabel")
    local tipLabel = DeliverResultFrame:FindFirstChild("TipLabel")
    local totalLabel = DeliverResultFrame:FindFirstChild("TotalLabel")

    if scoreLabel then
        scoreLabel.Text = string.format("%s %s", scoreEmoji, score)
        scoreLabel.TextColor3 = scoreColor
    end
    if rewardLabel then
        rewardLabel.Text = string.format("💰 Reward: %d", reward)
    end
    if tipLabel then
        tipLabel.Text = string.format("💵 Tip: +%d", tip)
    end
    if totalLabel then
        totalLabel.Text = string.format("💎 Total: %d", totalRevenue)
    end

    -- 기존 Tween 취소 (Fix-UI-DELIVER-01: 자식 Tween도 포함)
    if DeliverResultTween then
        DeliverResultTween:Cancel()
        DeliverResultTween = nil
    end
    for _, childTween in ipairs(DeliverResultChildTweens) do
        childTween:Cancel()
    end
    DeliverResultChildTweens = {}

    -- 표시
    DeliverResultFrame.Visible = true
    DeliverResultFrame.BackgroundTransparency = 0

    -- 자식 요소들 투명도 리셋
    for _, child in ipairs(DeliverResultFrame:GetChildren()) do
        if child:IsA("TextLabel") then
            child.TextTransparency = 0
        elseif child:IsA("UIStroke") then
            child.Transparency = 0  -- P2-HF: 재표시 시 UIStroke 리셋 필수
        end
    end

    -- 3초 후 페이드 아웃
    task.delay(3, function()
        -- P2-HF: Race Condition 방지 - 최신 show인지 체크
        if thisShowId ~= DeliverResultShowId then return end
        if not DeliverResultFrame or not DeliverResultFrame.Visible then return end

        -- 모든 요소 페이드 아웃
        local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

        -- 프레임 페이드
        DeliverResultTween = TweenService:Create(DeliverResultFrame, tweenInfo, {
            BackgroundTransparency = 1
        })
        DeliverResultTween:Play()

        -- 텍스트들도 페이드 (Fix-UI-DELIVER-01: 참조 저장)
        for _, child in ipairs(DeliverResultFrame:GetChildren()) do
            if child:IsA("TextLabel") then
                local tween = TweenService:Create(child, tweenInfo, { TextTransparency = 1 })
                table.insert(DeliverResultChildTweens, tween)
                tween:Play()
            elseif child:IsA("UIStroke") then
                local tween = TweenService:Create(child, tweenInfo, { Transparency = 1 })
                table.insert(DeliverResultChildTweens, tween)
                tween:Play()
            end
        end

        -- P2-HF: Once 사용으로 연결 누적 방지
        DeliverResultTween.Completed:Once(function()
            -- P2-HF: Completed에서도 showId 체크 (이중 게이트)
            if thisShowId ~= DeliverResultShowId then return end
            if DeliverResultFrame then
                DeliverResultFrame.Visible = false
                DeliverResultFrame.BackgroundTransparency = 0
                -- 텍스트 투명도 리셋
                for _, child in ipairs(DeliverResultFrame:GetChildren()) do
                    if child:IsA("TextLabel") then
                        child.TextTransparency = 0
                    elseif child:IsA("UIStroke") then
                        child.Transparency = 0
                    end
                end
            end
        end)
    end)

    print(string.format("[MainHUD] P2|DELIVER_RESULT_SHOWN score=%s reward=%d tip=%d total=%d",
        score, reward, tip, totalRevenue))
end

--------------------------------------------------------------------------------
-- P3: End Day 결과 표시
--------------------------------------------------------------------------------

-- P3: End Day 결과 UI 참조 (세션 단위)
local EndDayResultFrame = nil
local EndDayResultTween = nil

function MainHUD:CreateEndDayResultUI()
    if EndDayResultFrame then return end
    if not ScreenGui then return end

    -- 화면 중앙 상단 토스트 UI
    local frame = Instance.new("Frame")
    frame.Name = "EndDayResultFrame"
    frame.Size = UDim2.new(0, 280, 0, 80)
    frame.AnchorPoint = Vector2.new(0.5, 0)
    frame.Position = UDim2.new(0.5, 0, 0, 80)
    frame.BackgroundColor3 = Color3.fromRGB(50, 120, 80)
    frame.BackgroundTransparency = 0.1
    frame.Visible = false
    frame.Parent = ScreenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(100, 200, 100)
    stroke.Thickness = 2
    stroke.Parent = frame

    -- 타이틀 (Day X → Day Y)
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, -20, 0, 30)
    titleLabel.Position = UDim2.new(0, 10, 0, 10)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "🌙 Day 완료!"
    titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    titleLabel.Font = Enum.Font.GothamBlack
    titleLabel.TextSize = 20
    titleLabel.Parent = frame

    -- 상세 정보 (주문 수, 목표)
    local detailLabel = Instance.new("TextLabel")
    detailLabel.Name = "DetailLabel"
    detailLabel.Size = UDim2.new(1, -20, 0, 24)
    detailLabel.Position = UDim2.new(0, 10, 0, 42)
    detailLabel.BackgroundTransparency = 1
    detailLabel.Text = ""
    detailLabel.TextColor3 = Color3.fromRGB(200, 255, 200)
    detailLabel.Font = Enum.Font.Gotham
    detailLabel.TextSize = 14
    detailLabel.Parent = frame

    EndDayResultFrame = frame
    print("[MainHUD] P3|ENDDAY_RESULT_UI_CREATED")
end

function MainHUD:ShowEndDayResult(response)
    if not response then return end

    -- 성공/실패 분기
    if response.Success then
        -- UI 생성 (최초 1회)
        self:CreateEndDayResultUI()
        if not EndDayResultFrame then return end

        local dayBefore = response.DayBefore or 0
        local dayAfter = response.DayAfter or (dayBefore + 1)
        local ordersServed = response.OrdersServedAtEnd or 0
        local target = response.Target or 10

        -- UI 업데이트
        local titleLabel = EndDayResultFrame:FindFirstChild("TitleLabel")
        local detailLabel = EndDayResultFrame:FindFirstChild("DetailLabel")

        if titleLabel then
            titleLabel.Text = string.format("🌙 Day %d → Day %d", dayBefore, dayAfter)
        end
        if detailLabel then
            detailLabel.Text = string.format("주문 완료: %d건 (목표: %d)", ordersServed, target * dayBefore)
        end

        -- 기존 Tween 취소
        if EndDayResultTween then
            EndDayResultTween:Cancel()
            EndDayResultTween = nil
        end

        -- 표시
        EndDayResultFrame.Visible = true
        EndDayResultFrame.BackgroundTransparency = 0.1

        -- 자식 요소들 투명도 리셋
        for _, child in ipairs(EndDayResultFrame:GetChildren()) do
            if child:IsA("TextLabel") then
                child.TextTransparency = 0
            elseif child:IsA("UIStroke") then
                child.Transparency = 0
            end
        end

        -- 3초 후 페이드 아웃
        task.delay(3, function()
            if not EndDayResultFrame or not EndDayResultFrame.Visible then return end

            local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

            EndDayResultTween = TweenService:Create(EndDayResultFrame, tweenInfo, {
                BackgroundTransparency = 1
            })
            EndDayResultTween:Play()

            for _, child in ipairs(EndDayResultFrame:GetChildren()) do
                if child:IsA("TextLabel") then
                    TweenService:Create(child, tweenInfo, { TextTransparency = 1 }):Play()
                elseif child:IsA("UIStroke") then
                    TweenService:Create(child, tweenInfo, { Transparency = 1 }):Play()
                end
            end

            EndDayResultTween.Completed:Once(function()
                if EndDayResultFrame then
                    EndDayResultFrame.Visible = false
                end
            end)
        end)

        print(string.format("[MainHUD] P3|ENDDAY_RESULT_SHOWN dayBefore=%d dayAfter=%d orders=%d",
            dayBefore, dayAfter, ordersServed))
    else
        -- 실패 시: NoticeCode에 따른 메시지 표시
        local noticeCode = response.NoticeCode or response.Error or "unknown"

        -- NoticeUI를 통해 사용자에게 알림 표시
        -- severity: warning (not_ready) 또는 error (data_error, dayend_in_progress)
        local severity = "warning"
        if noticeCode == "data_error" then
            severity = "error"
        end

        NoticeUI.Show(noticeCode, severity, noticeCode)

        print(string.format("[MainHUD] P3|ENDDAY_FAILED noticeCode=%s severity=%s", noticeCode, severity))
    end
end

--------------------------------------------------------------------------------
-- P4: Day Summary UI (F-01~F-04, I-01~I-04 준수)
--------------------------------------------------------------------------------

-- P4: Day Summary UI 생성
function MainHUD:CreateDaySummaryUI()
    if DaySummaryFrame then return end
    if not ScreenGui then return end

    -- 화면 중앙 모달 UI
    local frame = Instance.new("Frame")
    frame.Name = "DaySummaryFrame"
    frame.Size = UDim2.new(0, 340, 0, 320)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.new(0.5, 0, 0.5, 0)
    frame.BackgroundColor3 = Color3.fromRGB(35, 45, 55)
    frame.BackgroundTransparency = 0.05
    frame.Visible = false
    frame.ZIndex = 50  -- 다른 UI보다 위
    frame.Parent = ScreenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 16)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(100, 180, 255)
    stroke.Thickness = 3
    stroke.Parent = frame

    -- 타이틀: "🎉 Day N 완료!"
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, -20, 0, 40)
    titleLabel.Position = UDim2.new(0, 10, 0, 10)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "🎉 Day 완료!"
    titleLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
    titleLabel.Font = Enum.Font.GothamBlack
    titleLabel.TextSize = 24
    titleLabel.ZIndex = 51
    titleLabel.Parent = frame

    -- 통계 영역
    local statsFrame = Instance.new("Frame")
    statsFrame.Name = "StatsFrame"
    statsFrame.Size = UDim2.new(1, -30, 0, 150)
    statsFrame.Position = UDim2.new(0, 15, 0, 55)
    statsFrame.BackgroundColor3 = Color3.fromRGB(25, 35, 45)
    statsFrame.BackgroundTransparency = 0.3
    statsFrame.ZIndex = 51
    statsFrame.Parent = frame

    local statsCorner = Instance.new("UICorner")
    statsCorner.CornerRadius = UDim.new(0, 10)
    statsCorner.Parent = statsFrame

    -- 통계 라벨들
    local statLabels = {
        { name = "OrdersLabel", y = 10, text = "완료한 주문: 0건" },
        { name = "RewardLabel", y = 35, text = "기본 수익: 0 코인" },
        { name = "TipLabel", y = 60, text = "팁: 0 코인" },
        { name = "Separator", y = 90, text = "─────────────────────" },
        { name = "RevenueLabel", y = 105, text = "총 수익: 0 코인", bold = true },
        { name = "WalletLabel", y = 130, text = "보유 코인: 0 코인", color = Color3.fromRGB(100, 255, 150) },
    }

    for _, stat in ipairs(statLabels) do
        local label = Instance.new("TextLabel")
        label.Name = stat.name
        label.Size = UDim2.new(1, -20, 0, 22)
        label.Position = UDim2.new(0, 10, 0, stat.y)
        label.BackgroundTransparency = 1
        label.Text = stat.text
        label.TextColor3 = stat.color or Color3.fromRGB(220, 220, 220)
        label.Font = stat.bold and Enum.Font.GothamBold or Enum.Font.Gotham
        label.TextSize = 16
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.ZIndex = 52
        label.Parent = statsFrame
    end

    -- 버튼 영역
    local buttonFrame = Instance.new("Frame")
    buttonFrame.Name = "ButtonFrame"
    buttonFrame.Size = UDim2.new(1, -30, 0, 50)
    buttonFrame.Position = UDim2.new(0, 15, 0, 215)
    buttonFrame.BackgroundTransparency = 1
    buttonFrame.ZIndex = 51
    buttonFrame.Parent = frame

    -- [🛒 상점 열기] 버튼
    local shopBtn = Instance.new("TextButton")
    shopBtn.Name = "ShopButton"
    shopBtn.Size = UDim2.new(0.48, 0, 0, 44)
    shopBtn.Position = UDim2.new(0, 0, 0, 0)
    shopBtn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
    shopBtn.Text = "🛒 상점 열기"
    shopBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    shopBtn.Font = Enum.Font.GothamBold
    shopBtn.TextSize = 16
    shopBtn.ZIndex = 52
    shopBtn.Parent = buttonFrame

    local shopCorner = Instance.new("UICorner")
    shopCorner.CornerRadius = UDim.new(0, 10)
    shopCorner.Parent = shopBtn

    shopBtn.MouseButton1Click:Connect(function()
        self:OpenShopFromSummary()
    end)

    -- [✓ 확인] 버튼
    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0.48, 0, 0, 44)
    closeBtn.Position = UDim2.new(0.52, 0, 0, 0)
    closeBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 80)
    closeBtn.Text = "✓ 확인"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 16
    closeBtn.ZIndex = 52
    closeBtn.Parent = buttonFrame

    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 10)
    closeCorner.Parent = closeBtn

    closeBtn.MouseButton1Click:Connect(function()
        self:CloseDaySummary()
    end)

    DaySummaryFrame = frame
    print("[MainHUD] P4|DAY_SUMMARY_UI_CREATED")
end

-- P4: Day Summary UI 업데이트 (Snapshot 데이터 적용)
function MainHUD:UpdateDaySummaryUI(snapshot)
    if not DaySummaryFrame then return end

    local statsFrame = DaySummaryFrame:FindFirstChild("StatsFrame")
    if not statsFrame then return end

    -- 타이틀 업데이트 (감리 권고: Day 표기 명확화)
    -- snapshot.Day = dayAfter (현재 Day), 완료된 Day = dayAfter - 1
    local titleLabel = DaySummaryFrame:FindFirstChild("TitleLabel")
    if titleLabel then
        local currentDay = snapshot.Day or 1
        local completedDay = currentDay - 1
        if completedDay < 1 then completedDay = 1 end  -- 최소 Day 1
        titleLabel.Text = string.format("🎉 Day %d 완료!", completedDay)
    end

    -- 통계 업데이트
    local ordersLabel = statsFrame:FindFirstChild("OrdersLabel")
    if ordersLabel then
        ordersLabel.Text = string.format("완료한 주문: %d건", snapshot.OrdersServed or 0)
    end

    local rewardLabel = statsFrame:FindFirstChild("RewardLabel")
    if rewardLabel then
        rewardLabel.Text = string.format("기본 수익: %s 코인", FormatCoins(snapshot.TotalReward))
    end

    local tipLabel = statsFrame:FindFirstChild("TipLabel")
    if tipLabel then
        tipLabel.Text = string.format("팁: %s 코인", FormatCoins(snapshot.TotalTip))
    end

    local revenueLabel = statsFrame:FindFirstChild("RevenueLabel")
    if revenueLabel then
        revenueLabel.Text = string.format("총 수익: %s 코인", FormatCoins(snapshot.TotalRevenue))
    end

    local walletLabel = statsFrame:FindFirstChild("WalletLabel")
    if walletLabel then
        walletLabel.Text = string.format("보유 코인: %s 코인", FormatCoins(snapshot.WalletCoins))
    end
end

-- P4: Day Summary 열기 (F-02, F-03, I-02 준수)
function MainHUD:OpenDaySummary(reason, dayAfter)
    -- F-02: 중복 오픈 방지
    if dayAfter and dayAfter <= LastShownDayAfter then
        print(string.format("[MainHUD] P4|DAY_SUMMARY_DUPLICATE_GUARD dayAfter=%d lastShown=%d",
            dayAfter, LastShownDayAfter))
        return
    end

    -- UI 생성 (최초 1회)
    self:CreateDaySummaryUI()
    if not DaySummaryFrame then return end

    -- RF_GetDayEnd 호출 (I-03: 1회만 호출)
    local RF_GetDayEnd = Remotes and Remotes:FindFirstChild("RF_GetDayEnd")
    if not RF_GetDayEnd then
        warn("[MainHUD] P4|DAY_SUMMARY_SNAPSHOT_FAIL error=RF_GetDayEnd_not_found noticeCode=data_error")
        NoticeUI.Show("data_error", "error", "data_error")
        return
    end

    local result = RF_GetDayEnd:InvokeServer()

    -- F-03: RF 실패 처리 (감리 아이디어: SNAPSHOT_FAIL 로그 추가)
    if not result or not result.Success then
        local errorCode = result and result.Error or "unknown"
        local noticeCode = result and result.NoticeCode or "data_error"
        warn(string.format("[MainHUD] P4|DAY_SUMMARY_SNAPSHOT_FAIL error=%s noticeCode=%s",
            tostring(errorCode), tostring(noticeCode)))
        NoticeUI.Show(noticeCode, "error", noticeCode)
        return
    end

    -- 스냅샷 캐시 및 UI 업데이트
    CachedSnapshot = result.Snapshot
    self:UpdateDaySummaryUI(CachedSnapshot)

    -- 중복 방지 가드 업데이트 (감리 권고: signal dayAfter 우선)
    LastShownDayAfter = dayAfter or CachedSnapshot.Day or 0

    -- 상태 전환: HIDDEN → SUMMARY
    DaySummaryUIState = "SUMMARY"
    DaySummaryFrame.Visible = true

    -- I-02: 증거 로그
    print(string.format("P4|DAY_SUMMARY_OPEN reason=%s dayAfter=%d",
        tostring(reason), LastShownDayAfter))
    print(string.format("P4|DAY_SUMMARY_SNAPSHOT_OK day=%d orders=%d revenue=%d wallet=%d",
        CachedSnapshot.Day or 0,
        CachedSnapshot.OrdersServed or 0,
        CachedSnapshot.TotalRevenue or 0,
        CachedSnapshot.WalletCoins or 0))
end

-- P4: Day Summary 닫기
function MainHUD:CloseDaySummary()
    if DaySummaryFrame then
        DaySummaryFrame.Visible = false
    end

    -- 상태 전환: → HIDDEN
    local previousDay = CachedSnapshot and CachedSnapshot.Day or 0
    DaySummaryUIState = "HIDDEN"
    CachedSnapshot = nil  -- 캐시 정리

    -- I-02: 증거 로그
    print(string.format("P4|DAY_SUMMARY_CLOSE day=%d", previousDay))
end

--------------------------------------------------------------------------------
-- P4: Shop UI (EC-P4-02, EC-P4-03 준수)
--------------------------------------------------------------------------------

-- P4: Shop UI 생성
function MainHUD:CreateShopUI()
    if ShopFrame then return end
    if not ScreenGui then return end

    -- 화면 중앙 모달 UI
    local frame = Instance.new("Frame")
    frame.Name = "ShopFrame"
    frame.Size = UDim2.new(0, 380, 0, 420)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.new(0.5, 0, 0.5, 0)
    frame.BackgroundColor3 = Color3.fromRGB(35, 45, 55)
    frame.BackgroundTransparency = 0.05
    frame.Visible = false
    frame.ZIndex = 50
    frame.Parent = ScreenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 16)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 180, 80)
    stroke.Thickness = 3
    stroke.Parent = frame

    -- 타이틀: "🛒 업그레이드 상점"
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, -20, 0, 40)
    titleLabel.Position = UDim2.new(0, 10, 0, 10)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "🛒 업그레이드 상점"
    titleLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
    titleLabel.Font = Enum.Font.GothamBlack
    titleLabel.TextSize = 22
    titleLabel.ZIndex = 51
    titleLabel.Parent = frame

    -- 업그레이드 목록 영역
    local listFrame = Instance.new("Frame")
    listFrame.Name = "ListFrame"
    listFrame.Size = UDim2.new(1, -30, 0, 270)
    listFrame.Position = UDim2.new(0, 15, 0, 55)
    listFrame.BackgroundTransparency = 1
    listFrame.ZIndex = 51
    listFrame.Parent = frame

    -- 업그레이드 카드 생성 (3개)
    for i, config in ipairs(UPGRADE_CONFIG) do
        local card = Instance.new("Frame")
        card.Name = "UpgradeCard_" .. config.id
        card.Size = UDim2.new(1, 0, 0, 82)
        card.Position = UDim2.new(0, 0, 0, (i - 1) * 88)
        card.BackgroundColor3 = Color3.fromRGB(25, 35, 45)
        card.BackgroundTransparency = 0.3
        card.ZIndex = 52
        card.Parent = listFrame

        local cardCorner = Instance.new("UICorner")
        cardCorner.CornerRadius = UDim.new(0, 10)
        cardCorner.Parent = card

        -- 업그레이드 이름
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Name = "NameLabel"
        nameLabel.Size = UDim2.new(0.65, 0, 0, 24)
        nameLabel.Position = UDim2.new(0, 10, 0, 8)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = config.name
        nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextSize = 16
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.ZIndex = 53
        nameLabel.Parent = card

        -- 설명
        local descLabel = Instance.new("TextLabel")
        descLabel.Name = "DescLabel"
        descLabel.Size = UDim2.new(0.65, 0, 0, 18)
        descLabel.Position = UDim2.new(0, 10, 0, 30)
        descLabel.BackgroundTransparency = 1
        descLabel.Text = config.desc
        descLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
        descLabel.Font = Enum.Font.Gotham
        descLabel.TextSize = 12
        descLabel.TextXAlignment = Enum.TextXAlignment.Left
        descLabel.ZIndex = 53
        descLabel.Parent = card

        -- 레벨 표시
        local levelLabel = Instance.new("TextLabel")
        levelLabel.Name = "LevelLabel"
        levelLabel.Size = UDim2.new(0.65, 0, 0, 20)
        levelLabel.Position = UDim2.new(0, 10, 0, 52)
        levelLabel.BackgroundTransparency = 1
        levelLabel.Text = "Lv. 1 → Lv. 2"
        levelLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
        levelLabel.Font = Enum.Font.GothamMedium
        levelLabel.TextSize = 14
        levelLabel.TextXAlignment = Enum.TextXAlignment.Left
        levelLabel.ZIndex = 53
        levelLabel.Parent = card

        -- 구매 버튼
        local buyBtn = Instance.new("TextButton")
        buyBtn.Name = "BuyButton"
        buyBtn.Size = UDim2.new(0, 90, 0, 50)
        buyBtn.Position = UDim2.new(1, -100, 0.5, -25)
        buyBtn.BackgroundColor3 = Color3.fromRGB(80, 160, 80)
        buyBtn.Text = "100 코인"
        buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        buyBtn.Font = Enum.Font.GothamBold
        buyBtn.TextSize = 14
        buyBtn.ZIndex = 53
        buyBtn.Parent = card

        local btnCorner = Instance.new("UICorner")
        btnCorner.CornerRadius = UDim.new(0, 8)
        btnCorner.Parent = buyBtn

        -- 버튼 참조 저장
        ShopUpgradeButtons[config.id] = buyBtn

        -- 구매 버튼 클릭 핸들러
        buyBtn.MouseButton1Click:Connect(function()
            self:OnUpgradePurchase(config.id)
        end)
    end

    -- 보유 코인 표시
    local walletLabel = Instance.new("TextLabel")
    walletLabel.Name = "WalletLabel"
    walletLabel.Size = UDim2.new(1, -30, 0, 30)
    walletLabel.Position = UDim2.new(0, 15, 0, 335)
    walletLabel.BackgroundTransparency = 1
    walletLabel.Text = "보유 코인: 0 코인"
    walletLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
    walletLabel.Font = Enum.Font.GothamBold
    walletLabel.TextSize = 18
    walletLabel.TextXAlignment = Enum.TextXAlignment.Center
    walletLabel.ZIndex = 51
    walletLabel.Parent = frame

    -- [닫기] 버튼
    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseButton"
    closeBtn.Size = UDim2.new(0.5, -20, 0, 40)
    closeBtn.Position = UDim2.new(0.25, 0, 0, 370)
    closeBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
    closeBtn.Text = "X 닫기"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 16
    closeBtn.ZIndex = 52
    closeBtn.Parent = frame

    local closeBtnCorner = Instance.new("UICorner")
    closeBtnCorner.CornerRadius = UDim.new(0, 10)
    closeBtnCorner.Parent = closeBtn

    closeBtn.MouseButton1Click:Connect(function()
        self:CloseShopUI()
    end)

    ShopFrame = frame
    print("[MainHUD] P4|SHOP_UI_CREATED")
end

-- P4: Shop UI 업데이트 (업그레이드 상태 갱신)
function MainHUD:UpdateShopUI()
    if not ShopFrame then return end

    local clientData = Controller:GetData()
    local upgrades = clientData.upgrades or {}
    local coins = clientData.wallet and clientData.wallet.coins or 0

    -- 보유 코인 업데이트
    local walletLabel = ShopFrame:FindFirstChild("WalletLabel")
    if walletLabel then
        walletLabel.Text = string.format("보유 코인: %s 코인", FormatCoins(coins))
    end

    local listFrame = ShopFrame:FindFirstChild("ListFrame")
    if not listFrame then return end

    -- 각 업그레이드 카드 업데이트
    for _, config in ipairs(UPGRADE_CONFIG) do
        local card = listFrame:FindFirstChild("UpgradeCard_" .. config.id)
        if not card then continue end

        local currentLevel = upgrades[config.id] or 1
        local isMaxLevel = currentLevel >= MAX_LEVEL
        local cost = CalculateUpgradeCost(config.base, currentLevel)

        -- 레벨 표시 업데이트
        local levelLabel = card:FindFirstChild("LevelLabel")
        if levelLabel then
            if isMaxLevel then
                levelLabel.Text = string.format("Lv. %d (MAX)", currentLevel)
                levelLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
            else
                levelLabel.Text = string.format("Lv. %d → Lv. %d", currentLevel, currentLevel + 1)
                levelLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
            end
        end

        -- 구매 버튼 업데이트
        local buyBtn = card:FindFirstChild("BuyButton")
        if buyBtn then
            if isMaxLevel then
                buyBtn.Text = "MAX"
                buyBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
                buyBtn.Active = false
            elseif coins < cost then
                buyBtn.Text = string.format("%s 코인", FormatCoins(cost))
                buyBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 60)
                buyBtn.Active = true  -- 클릭은 허용, 서버에서 거절
            else
                buyBtn.Text = string.format("%s 코인", FormatCoins(cost))
                buyBtn.BackgroundColor3 = Color3.fromRGB(80, 160, 80)
                buyBtn.Active = true
            end
        end

        -- EC-P4-02: 증거 로그 (각 업그레이드 렌더링)
        print(string.format("SHOP_UPGRADE_RENDERED id=%s level=%d cost=%d maxLevel=%s",
            config.id, currentLevel, cost, tostring(isMaxLevel)))
    end
end

-- P4: Shop UI 열기
function MainHUD:OpenShopUI(source)
    self:CreateShopUI()
    if not ShopFrame then return end

    -- UI 상태 갱신
    self:UpdateShopUI()

    -- Shop 표시
    ShopFrame.Visible = true
    DaySummaryUIState = "SHOP"
    ShopSource = source  -- 닫을 때 복귀 대상 저장

    -- EC-P4-02: 증거 로그
    print(string.format("SHOP_UI_OPEN source=%s upgradeCount=%d", tostring(source), #UPGRADE_CONFIG))
end

-- P4: Shop UI 닫기
function MainHUD:CloseShopUI()
    if ShopFrame then
        ShopFrame.Visible = false
    end

    -- 감리자 권고: pendingDayEnd가 있으면 Summary 오픈 (큐잉된 DayEnd 처리)
    if pendingDayEnd then
        local deferred = pendingDayEnd
        pendingDayEnd = nil  -- 처리 후 클리어
        ShopSource = nil

        -- 상태 전환: SHOP → SUMMARY (via OpenDaySummary)
        DaySummaryUIState = "HIDDEN"  -- OpenDaySummary가 SUMMARY로 전환

        -- EC-P4-05: 증거 로그
        print(string.format("SHOP_UI_CLOSE returnTo=pending_summary dayAfter=%d",
            deferred.dayAfter or 0))

        -- 큐잉된 Summary 오픈
        task.delay(0.2, function()
            self:OpenDaySummary(deferred.reason, deferred.dayAfter)
        end)
        return
    end

    -- returnTo 분기: day_summary에서 온 경우 Summary로 복귀
    local returnTo = "none"
    if ShopSource == "day_summary" and CachedSnapshot then
        -- Summary로 복귀 (캐시된 스냅샷 재사용)
        DaySummaryUIState = "SUMMARY"
        if DaySummaryFrame then
            DaySummaryFrame.Visible = true
        end
        returnTo = "day_summary"
    else
        -- HIDDEN으로 전환
        DaySummaryUIState = "HIDDEN"
        CachedSnapshot = nil  -- 캐시 정리
        returnTo = "none"
    end

    ShopSource = nil  -- 정리

    -- EC-P4-05: 증거 로그
    print(string.format("SHOP_UI_CLOSE returnTo=%s", returnTo))
end

-- P4: Shop 진입 (Summary → Shop 전환)
function MainHUD:OpenShopFromSummary()
    if DaySummaryUIState ~= "SUMMARY" then return end

    local currentDay = CachedSnapshot and CachedSnapshot.Day or 0

    -- Summary 숨기기 (전환, 오버레이 아님)
    if DaySummaryFrame then
        DaySummaryFrame.Visible = false
    end

    -- EC-P4-05: 증거 로그
    print(string.format("P4|DAY_SUMMARY_TO_SHOP day=%d", currentDay))

    -- Shop UI 열기
    self:OpenShopUI("day_summary")
end

-- P4: 업그레이드 구매 핸들러
function MainHUD:OnUpgradePurchase(upgradeId)
    local clientData = Controller:GetData()
    local upgrades = clientData.upgrades or {}
    local currentLevel = upgrades[upgradeId] or 1

    -- 클라이언트 가드: MAX 레벨
    if currentLevel >= MAX_LEVEL then
        NoticeUI.Show("upgrade_max_level", "warning", "upgrade_max_level")
        return
    end

    -- 비용 계산 (표시용)
    local config = nil
    for _, c in ipairs(UPGRADE_CONFIG) do
        if c.id == upgradeId then
            config = c
            break
        end
    end
    local cost = config and CalculateUpgradeCost(config.base, currentLevel) or 0

    -- EC-P4-03: 증거 로그 (구매 시도)
    print(string.format("UPGRADE_ATTEMPT upgradeId=%s currentLevel=%d cost=%d", upgradeId, currentLevel, cost))

    -- RE_BuyUpgrade 호출
    local RE_BuyUpgrade = Remotes and Remotes:FindFirstChild("RE_BuyUpgrade")
    if not RE_BuyUpgrade then
        warn("[MainHUD] P4|UPGRADE_FAIL reason=no_remote")
        NoticeUI.Show("data_error", "error", "data_error")
        return
    end

    RE_BuyUpgrade:FireServer(upgradeId)
    -- 응답은 ClientController의 StateChanged를 통해 처리됨
end

-- P4: 업그레이드 응답 처리 (StateChanged에서 호출)
function MainHUD:OnUpgradeResponse(response)
    if not response then return end

    -- Shop UI가 열려있으면 갱신
    if ShopFrame and ShopFrame.Visible then
        self:UpdateShopUI()
    end
end

-- P4: DayEndSignal 수신 핸들러 (ClientController에서 호출)
-- F-01: StateChanged 사용 X, 직접 메서드 호출
function MainHUD:OnDayEndSignal(signal)
    if not signal then return end

    -- CRIT 경미 가드: dayAfter 유효성 체크 (감리 권고)
    if type(signal.dayAfter) ~= "number" or signal.dayAfter <= 0 then
        print(string.format("P4|DAYEND_SIGNAL_INVALID reason=%s dayAfter=%s type=%s",
            tostring(signal.reason), tostring(signal.dayAfter), type(signal.dayAfter)))
        return
    end

    print(string.format("[MainHUD] P4|DAYEND_SIGNAL_RECV reason=%s dayAfter=%d",
        tostring(signal.reason), signal.dayAfter))

    -- 감리자 권고: Shop 열린 상태에서 DayEndResponse 수신 시 큐잉
    if DaySummaryUIState == "SHOP" then
        -- 감리자 권고 (A): 더 큰 dayAfter만 유지 (단조 증가 보장)
        local newDayAfter = signal.dayAfter or 0
        local existingDayAfter = pendingDayEnd and pendingDayEnd.dayAfter or 0

        if newDayAfter > existingDayAfter then
            pendingDayEnd = signal
            print(string.format("P4|DAYEND_DEFERRED reason=%s dayAfter=%d ui=SHOP",
                tostring(signal.reason), newDayAfter))
            -- 유효한 신규 신호: 토스트 표시 (P3 호환성)
            self:ShowEndDayResult({
                Success = true,
                DayBefore = signal.dayBefore,
                DayAfter = signal.dayAfter,
                OrdersServedAtEnd = signal.ordersServedAtEnd,
                Target = signal.target,
            })
        elseif newDayAfter == existingDayAfter then
            -- 동일 dayAfter: 무시 (중복 수신) - 토스트도 스킵 (감리 권고)
            print(string.format("P4|DAYEND_DEFERRED_SKIP reason=duplicate dayAfter=%d", newDayAfter))
        else
            -- 역행 dayAfter: 무시 + 경고 로그 - 토스트도 스킵 (감리 권고)
            print(string.format("P4|DAYEND_DEFERRED_SKIP reason=regression newDay=%d existingDay=%d",
                newDayAfter, existingDayAfter))
        end

        return  -- Summary 오픈은 Shop 닫을 때
    end

    -- F-04: ShowEndDayResult는 유지하되, 토스트 후 Summary로 전환
    -- P3 호환성: ShowEndDayResult가 먼저 토스트 표시
    self:ShowEndDayResult({
        Success = true,
        DayBefore = signal.dayBefore,
        DayAfter = signal.dayAfter,
        OrdersServedAtEnd = signal.ordersServedAtEnd,
        Target = signal.target,
    })

    -- 짧은 지연 후 Summary 오픈 (토스트 확인 시간)
    task.delay(0.5, function()
        self:OpenDaySummary(signal.reason, signal.dayAfter)
    end)
end

return MainHUD
