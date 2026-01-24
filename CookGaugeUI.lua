-- Client/UI/CookGaugeUI.lua
-- PG-1: Cook 미니게임 게이지 UI
-- Created: 2026-01-25
-- Reference: PG1_Implementation_Checklist.md C-01~C-04

--[[
    ============================================================================
    C-01 설계 계약 (감리자 승인 2026-01-25)
    ============================================================================

    1. 속도 단위
       - cookSession.gaugeSpeed는 0~100 position/sec (= %/sec)
       - 프레임 독립: gaugePos += gaugeDir * gaugeSpeed * dt

    2. 게이지 범위
       - gaugePos: [0, 100] clamp
       - 0/100 도달 시 direction 반전 (오버슈트 보정 포함)

    3. 입력 디바운스
       - 200ms 이내 중복 탭 무시
       - os.clock() 기반

    4. 세션 전환 정책
       - Show() 호출 시 isActive면 Hide→Show 재구성
       - 이전 세션 상태 재사용 금지

    5. UI 원칙
       - 로컬은 "임시 피드백"만 (탭 즉시 텍스트/아이콘)
       - 서버 판정 = 진실, 도착 시 확정 표시로 교체
       - Up-correct: 자연스럽게 업그레이드
       - Down-correct: 조용히 교체 (fade)

    6. 레이아웃
       - 세미 모달 (반투명 배경 + 중앙 패널)
       - 색각 보조 3중 표현 (색상 + 텍스트 + 아이콘)

    7. 생명주기
       - Heartbeat/Input 연결 핸들 저장
       - Hide()에서 반드시 Disconnect + nil
    ============================================================================
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local CookGaugeUI = {}

--------------------------------------------------------------------------------
-- 상수
--------------------------------------------------------------------------------
local DEBOUNCE_TIME = 0.2  -- 200ms 입력 디바운스
local GAUGE_MIN = 0
local GAUGE_MAX = 100
local GAUGE_CENTER = 50

-- 판정별 시각 설정 (색각 보조 3중 표현)
local JUDGMENT_VISUALS = {
    Perfect = { color = Color3.fromRGB(255, 215, 0),  text = "Perfect!", icon = "★" },
    Great   = { color = Color3.fromRGB(100, 149, 237), text = "Great!",   icon = "●" },
    Good    = { color = Color3.fromRGB(255, 255, 255), text = "Good",     icon = "○" },
    OK      = { color = Color3.fromRGB(150, 150, 150), text = "OK",       icon = "△" },
    Bad     = { color = Color3.fromRGB(255, 80, 80),   text = "Bad",      icon = "✗" },
}

--------------------------------------------------------------------------------
-- 상태 변수
--------------------------------------------------------------------------------
local isActive = false
local currentSession = nil
local gaugePos = GAUGE_CENTER
local gaugeDir = 1
local gaugeSpeed = 100  -- %/sec
local targetZone = {40, 60}
local lastTapTime = 0

-- 콜백
local onTapCallback = nil

-- UI 참조
local screenGui = nil
local backgroundFrame = nil
local mainPanel = nil
local gaugeFrame = nil
local gaugeBar = nil
local positionMarker = nil
local targetZoneFrame = nil
local judgmentLabel = nil
-- tapButton 제거됨: mainPanel 전체가 탭 영역 (감리 조건 3)

-- 연결 핸들 (생명주기 관리)
local heartbeatConnection = nil
local inputConnection = nil

--------------------------------------------------------------------------------
-- 내부 함수: UI 생성
--------------------------------------------------------------------------------
local function CreateUI()
    local player = Players.LocalPlayer
    local playerGui = player:WaitForChild("PlayerGui")

    -- ScreenGui (DisplayOrder 높게 설정하여 다른 UI 위에 표시)
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "CookGaugeUI"
    screenGui.DisplayOrder = 100
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui

    -- 반투명 배경 (세미 모달) - 입력 차단용
    -- (1) Backdrop 입력 차단: Active=true로 뒤 UI 클릭 방지
    backgroundFrame = Instance.new("TextButton")  -- Frame → TextButton (입력 흡수)
    backgroundFrame.Name = "Background"
    backgroundFrame.Size = UDim2.new(1, 0, 1, 0)
    backgroundFrame.Position = UDim2.new(0, 0, 0, 0)
    backgroundFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    backgroundFrame.BackgroundTransparency = 0.5
    backgroundFrame.BorderSizePixel = 0
    backgroundFrame.Text = ""  -- 텍스트 없음
    backgroundFrame.AutoButtonColor = false  -- 클릭 시 색상 변화 없음
    backgroundFrame.Active = true  -- 입력 차단 활성화
    backgroundFrame.Parent = screenGui
    -- 배경 탭 시 아무 동작 없음 (감리자 결정: 1번 - 입력만 차단)

    -- 메인 패널 (중앙) - (3) 전체 패널이 탭 영역
    -- (4) 접근성: 비율 기반 크기 + SafeArea 여백 고려
    mainPanel = Instance.new("TextButton")  -- Frame → TextButton (탭 영역 확장)
    mainPanel.Name = "MainPanel"
    mainPanel.Size = UDim2.new(0.85, 0, 0, 280)  -- 화면 너비 85%, 높이 280px
    mainPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
    mainPanel.AnchorPoint = Vector2.new(0.5, 0.5)  -- 중앙 앵커
    mainPanel.Text = ""
    mainPanel.AutoButtonColor = false
    mainPanel.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    mainPanel.BorderSizePixel = 0
    mainPanel.Parent = screenGui

    -- 패널 모서리 둥글게
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 16)
    corner.Parent = mainPanel

    -- 제목
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, 0, 0, 40)
    titleLabel.Position = UDim2.new(0, 0, 0, 10)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "🍳 Cook!"
    titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    titleLabel.TextSize = 28
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Parent = mainPanel

    -- 게이지 프레임 (배경)
    gaugeFrame = Instance.new("Frame")
    gaugeFrame.Name = "GaugeFrame"
    gaugeFrame.Size = UDim2.new(0.9, 0, 0, 40)
    gaugeFrame.Position = UDim2.new(0.05, 0, 0, 60)
    gaugeFrame.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
    gaugeFrame.BorderSizePixel = 0
    gaugeFrame.Parent = mainPanel

    local gaugeCorner = Instance.new("UICorner")
    gaugeCorner.CornerRadius = UDim.new(0, 8)
    gaugeCorner.Parent = gaugeFrame

    -- 목표 영역 (녹색)
    targetZoneFrame = Instance.new("Frame")
    targetZoneFrame.Name = "TargetZone"
    targetZoneFrame.BackgroundColor3 = Color3.fromRGB(80, 180, 80)
    targetZoneFrame.BackgroundTransparency = 0.3
    targetZoneFrame.BorderSizePixel = 0
    targetZoneFrame.Parent = gaugeFrame
    -- 크기/위치는 UpdateTargetZone()에서 설정

    local targetCorner = Instance.new("UICorner")
    targetCorner.CornerRadius = UDim.new(0, 4)
    targetCorner.Parent = targetZoneFrame

    -- 목표 영역 라벨
    local targetLabel = Instance.new("TextLabel")
    targetLabel.Name = "TargetLabel"
    targetLabel.Size = UDim2.new(1, 0, 1, 0)
    targetLabel.BackgroundTransparency = 1
    targetLabel.Text = "✓ TARGET"
    targetLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    targetLabel.TextSize = 12
    targetLabel.Font = Enum.Font.GothamBold
    targetLabel.Parent = targetZoneFrame

    -- 현재 위치 마커
    positionMarker = Instance.new("Frame")
    positionMarker.Name = "PositionMarker"
    positionMarker.Size = UDim2.new(0, 8, 1.2, 0)
    positionMarker.Position = UDim2.new(0.5, -4, -0.1, 0)
    positionMarker.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    positionMarker.BorderSizePixel = 0
    positionMarker.ZIndex = 2
    positionMarker.Parent = gaugeFrame

    local markerCorner = Instance.new("UICorner")
    markerCorner.CornerRadius = UDim.new(0, 4)
    markerCorner.Parent = positionMarker

    -- 퍼센트 라벨 (0% / 100%)
    local leftLabel = Instance.new("TextLabel")
    leftLabel.Name = "LeftLabel"
    leftLabel.Size = UDim2.new(0, 30, 0, 20)
    leftLabel.Position = UDim2.new(0.05, 0, 0, 105)
    leftLabel.BackgroundTransparency = 1
    leftLabel.Text = "0%"
    leftLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
    leftLabel.TextSize = 14
    leftLabel.Font = Enum.Font.Gotham
    leftLabel.Parent = mainPanel

    local rightLabel = Instance.new("TextLabel")
    rightLabel.Name = "RightLabel"
    rightLabel.Size = UDim2.new(0, 40, 0, 20)
    rightLabel.Position = UDim2.new(0.95, -40, 0, 105)
    rightLabel.BackgroundTransparency = 1
    rightLabel.Text = "100%"
    rightLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
    rightLabel.TextSize = 14
    rightLabel.Font = Enum.Font.Gotham
    rightLabel.Parent = mainPanel

    -- 판정 결과 라벨 (초기 숨김)
    judgmentLabel = Instance.new("TextLabel")
    judgmentLabel.Name = "JudgmentLabel"
    judgmentLabel.Size = UDim2.new(1, 0, 0, 50)
    judgmentLabel.Position = UDim2.new(0, 0, 0, 130)
    judgmentLabel.BackgroundTransparency = 1
    judgmentLabel.Text = ""
    judgmentLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    judgmentLabel.TextSize = 36
    judgmentLabel.Font = Enum.Font.GothamBold
    judgmentLabel.Visible = false
    judgmentLabel.Parent = mainPanel

    -- TAP 안내 라벨 (시각적 안내용 - 실제 입력은 mainPanel 전체에서 처리)
    -- (3) 멀티 탭 영역: 별도 버튼 대신 패널 전체가 탭 영역
    local tapHintFrame = Instance.new("Frame")
    tapHintFrame.Name = "TapHint"
    tapHintFrame.Size = UDim2.new(0.8, 0, 0, 50)
    tapHintFrame.Position = UDim2.new(0.1, 0, 0, 215)  -- 위치 조정 (패널 높이 증가로)
    tapHintFrame.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
    tapHintFrame.BorderSizePixel = 0
    tapHintFrame.Parent = mainPanel

    local tapCorner = Instance.new("UICorner")
    tapCorner.CornerRadius = UDim.new(0, 12)
    tapCorner.Parent = tapHintFrame

    local tapHintLabel = Instance.new("TextLabel")
    tapHintLabel.Name = "TapHintLabel"
    tapHintLabel.Size = UDim2.new(1, 0, 1, 0)
    tapHintLabel.BackgroundTransparency = 1
    tapHintLabel.Text = "🔥 TAP ANYWHERE to Cook!"
    tapHintLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    tapHintLabel.TextSize = 18
    tapHintLabel.Font = Enum.Font.GothamBold
    tapHintLabel.Parent = tapHintFrame

    print("[CookGaugeUI] UI created")
end

--------------------------------------------------------------------------------
-- 내부 함수: 목표 영역 위치 업데이트
--------------------------------------------------------------------------------
local function UpdateTargetZone()
    if not targetZoneFrame or not gaugeFrame then return end

    local min, max = targetZone[1], targetZone[2]
    local width = (max - min) / 100  -- 비율
    local xPos = min / 100  -- 비율

    targetZoneFrame.Size = UDim2.new(width, 0, 1, 0)
    targetZoneFrame.Position = UDim2.new(xPos, 0, 0, 0)
end

--------------------------------------------------------------------------------
-- 내부 함수: 게이지 위치 업데이트 (Heartbeat)
--------------------------------------------------------------------------------
local function UpdateGauge(dt)
    if not isActive then return end

    -- 위치 업데이트 (dt 기반 프레임 독립)
    gaugePos = gaugePos + gaugeDir * gaugeSpeed * dt

    -- 범위 체크 및 반전 (오버슈트 보정)
    if gaugePos >= GAUGE_MAX then
        local overshoot = gaugePos - GAUGE_MAX
        gaugePos = GAUGE_MAX - overshoot
        gaugeDir = -1
    elseif gaugePos <= GAUGE_MIN then
        local overshoot = GAUGE_MIN - gaugePos
        gaugePos = GAUGE_MIN + overshoot
        gaugeDir = 1
    end

    -- Clamp (안전)
    gaugePos = math.clamp(gaugePos, GAUGE_MIN, GAUGE_MAX)

    -- 마커 위치 업데이트
    if positionMarker then
        local xRatio = gaugePos / 100
        positionMarker.Position = UDim2.new(xRatio, -4, -0.1, 0)
    end
end

--------------------------------------------------------------------------------
-- 내부 함수: 탭 처리
--------------------------------------------------------------------------------
local function HandleTap()
    if not isActive then return end

    -- 디바운스 체크 (200ms)
    local now = os.clock()
    if now - lastTapTime < DEBOUNCE_TIME then
        print("[CookGaugeUI] Tap debounced")
        return
    end
    lastTapTime = now

    --[[
        콜백 호출 (감리 지적 B: 페이로드 사용 범위 명시)

        ⚠️ 서버 전송 페이로드: sessionId, slotId만 (최소 필드)
        ⚠️ clientPos/clientTime: UI 로그/디버그 전용 (서버 전송 금지)

        이유: PG-1 원칙 "서버=진실, 서버가 독립 재현"
        - 서버는 sessionId + elapsed로 자체 계산
        - 클라 위치값을 신뢰하면 보안/무결성 위반
    ]]
    if onTapCallback then
        onTapCallback({
            -- 서버 전송용 (필수)
            sessionId = currentSession and currentSession.sessionId or nil,
            slotId = currentSession and currentSession.slotId or nil,
            -- 로컬 디버그/로그용 (서버 전송 금지)
            clientPos = gaugePos,
            clientTime = now,
        })
    end

    print(string.format("[CookGaugeUI] Tap at pos=%.2f", gaugePos))

    -- 임시 로컬 피드백 (서버 응답 전까지 표시)
    -- 실제 판정은 서버가 결정하므로 여기서는 "..." 표시
    CookGaugeUI:ShowLocalFeedback("...")
end

--------------------------------------------------------------------------------
-- 공개 함수: UI 표시
--------------------------------------------------------------------------------
function CookGaugeUI:Show(cookSession, onTap)
    -- 세션 전환 정책: 기존 세션 있으면 정리
    if isActive then
        print("[CookGaugeUI] Session transition - hiding previous")
        self:Hide()
    end

    -- 상태 초기화
    isActive = true
    currentSession = cookSession
    gaugePos = GAUGE_CENTER
    gaugeDir = cookSession.initialDirection or 1
    gaugeSpeed = cookSession.gaugeSpeed or 100
    targetZone = cookSession.uiTargetZone or {40, 60}
    lastTapTime = 0
    onTapCallback = onTap

    -- UI 생성
    CreateUI()
    UpdateTargetZone()

    -- Heartbeat 연결 (프레임 독립 애니메이션)
    heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
        UpdateGauge(dt)
    end)

    -- 입력 연결 (Touch/Click 동일 경로)
    -- (3) 멀티 탭 영역: mainPanel 전체가 탭 영역 (버튼만이 아닌 패널 전체)
    inputConnection = mainPanel.Activated:Connect(function()
        HandleTap()
    end)

    print(string.format(
        "[CookGaugeUI] Show session=%s speed=%.1f target={%.1f,%.1f}",
        cookSession.sessionId or "nil",
        gaugeSpeed,
        targetZone[1], targetZone[2]
    ))
end

--------------------------------------------------------------------------------
-- 공개 함수: UI 숨김
--------------------------------------------------------------------------------
function CookGaugeUI:Hide()
    isActive = false
    currentSession = nil
    onTapCallback = nil

    -- 연결 해제 (필수 - 메모리 누수 방지)
    if heartbeatConnection then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
    if inputConnection then
        inputConnection:Disconnect()
        inputConnection = nil
    end

    -- UI 제거
    if screenGui then
        screenGui:Destroy()
        screenGui = nil
    end

    -- 참조 정리
    backgroundFrame = nil
    mainPanel = nil
    gaugeFrame = nil
    gaugeBar = nil
    positionMarker = nil
    targetZoneFrame = nil
    judgmentLabel = nil
    -- tapButton 제거됨 (mainPanel이 탭 영역)

    print("[CookGaugeUI] Hidden and cleaned up")
end

--------------------------------------------------------------------------------
-- 공개 함수: 로컬 임시 피드백 표시 (서버 응답 대기 중)
--------------------------------------------------------------------------------
function CookGaugeUI:ShowLocalFeedback(text)
    if not judgmentLabel then return end

    judgmentLabel.Text = text
    judgmentLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    judgmentLabel.Visible = true
end

--------------------------------------------------------------------------------
-- 공개 함수: 서버 확정 판정 표시 (C-04, C-05~C-06)
-- 감리 지적 B: corrected는 "불일치 여부"이지 "up/down"이 아님
-- → 중립 연출로 처리 (corrected=true면 약한 펄스, 구분 없음)
--------------------------------------------------------------------------------
function CookGaugeUI:ShowJudgment(judgment, wasCorrected)
    if not judgmentLabel then return end

    local visual = JUDGMENT_VISUALS[judgment]
    if not visual then
        warn("[CookGaugeUI] Unknown judgment: " .. tostring(judgment))
        return
    end

    -- 색각 보조 3중 표현: 아이콘 + 텍스트
    judgmentLabel.Text = visual.icon .. " " .. visual.text
    judgmentLabel.TextColor3 = visual.color
    judgmentLabel.Visible = true

    -- 기본 애니메이션 (모든 판정에 적용)
    judgmentLabel.TextSize = 40
    local tween = TweenService:Create(
        judgmentLabel,
        TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { TextSize = 36 }
    )
    tween:Play()

    -- wasCorrected: 클라-서버 불일치 여부 (중립 연출)
    -- Up/Down 구분하지 않음 - "보정되었음"만 표시
    if wasCorrected then
        -- 약한 투명도 펄스로 "보정됨" 힌트 (과한 연출 금지)
        judgmentLabel.TextTransparency = 0.3
        task.delay(0.15, function()
            if judgmentLabel then
                judgmentLabel.TextTransparency = 0
            end
        end)
    end

    print(string.format("[CookGaugeUI] Judgment shown: %s (corrected=%s)", judgment, tostring(wasCorrected)))

    -- 1.5초 후 자동 숨김 (감리 지적 A: sessionId 가드로 레이스 방지)
    local capturedSessionId = currentSession and currentSession.sessionId or nil
    task.delay(1.5, function()
        -- 세션이 바뀌었으면 Hide 스킵 (새 세션 UI 보호)
        local currentSessionId = currentSession and currentSession.sessionId or nil
        if capturedSessionId == currentSessionId then
            self:Hide()
        else
            print(string.format(
                "[CookGaugeUI] Hide skipped: session changed (captured=%s, current=%s)",
                tostring(capturedSessionId), tostring(currentSessionId)
            ))
        end
    end)
end

--------------------------------------------------------------------------------
-- 공개 함수: 활성 상태 확인
--------------------------------------------------------------------------------
function CookGaugeUI:IsActive()
    return isActive
end

--------------------------------------------------------------------------------
-- 공개 함수: 현재 세션 ID 확인
--------------------------------------------------------------------------------
function CookGaugeUI:GetSessionId()
    return currentSession and currentSession.sessionId or nil
end

return CookGaugeUI
