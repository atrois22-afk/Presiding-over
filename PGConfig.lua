-- Server/Shared/PGConfig.lua
-- PG-1: Cook 미니게임 튜닝 상수 (SSOT)
-- Created: 2026-01-20
-- Reference: Docs/FoodTruck_Fun_Replication_Roadmap_v0.3.2.md §2

--[[
    튜닝 원칙:
    - 모든 수치 조정은 이 파일에서만 수행
    - 로드맵 문서와 동기화 유지
    - 변경 시 체인지로그 작성
]]

local PGConfig = {}

--------------------------------------------------------------------------------
-- 1. 난이도별 게이지 설정 (§2.2.3)
--------------------------------------------------------------------------------
--[[
    speed 계산 (position/sec):
    - 왕복 거리 = 200 (0→100→0)
    - Easy: 2초/왕복 → 200/2 = 100
    - Medium: 1.5초/왕복 → 200/1.5 ≈ 133.33
    - Hard: 1초/왕복 → 200/1 = 200

    targetZone (Perfect 영역, 중앙=50 기준):
    - Easy: 20% → {40, 60}
    - Medium: 15% → {42.5, 57.5}
    - Hard: 10% → {45, 55}
]]
PGConfig.GAUGE_CONFIG = {
    Easy = {
        speed = 100,
        targetZone = {40, 60},
    },
    Medium = {
        speed = 133.33,
        targetZone = {42.5, 57.5},
    },
    Hard = {
        speed = 200,
        targetZone = {45, 55},
    },
}

-- 기본 난이도 (fallback)
PGConfig.DEFAULT_DIFFICULTY = "Easy"

--------------------------------------------------------------------------------
-- 2. 판정 구간 (§2.7.5)
--------------------------------------------------------------------------------
--[[
    distance from center → 판정
    - 튜토리얼: 확대된 윈도우 (Easy 느낌)
    - 일반: 기본 윈도우

    값 = 중앙으로부터 최대 거리 (inclusive)
]]
PGConfig.JUDGMENT_ZONES = {
    tutorial = {
        Perfect = 8,
        Great = 13,
        Good = 18,
        OK = 28,
    },
    normal = {
        Perfect = 5,
        Great = 10,
        Good = 15,
        OK = 25,
    },
}

--------------------------------------------------------------------------------
-- 3. 판정별 점수 배율 (§2.2.2)
--------------------------------------------------------------------------------
PGConfig.JUDGMENT_SCORES = {
    Perfect = 1.00,
    Great = 0.90,
    Good = 0.75,
    OK = 0.50,
    Bad = 0.25,
}

--------------------------------------------------------------------------------
-- 4. 허용 윈도우 (§2.7.5)
--------------------------------------------------------------------------------
--[[
    TOLERANCE_WINDOW_MS: 판정 허용 윈도우 (고정값)
    - 실제 RTT가 아닌, 네트워크 지연을 감안한 고정 허용치
    - 판정 시 중심 거리에서 이 값만큼 보정 적용
    - 값이 클수록 판정이 관대해짐
]]
PGConfig.TOLERANCE_WINDOW_MS = 80  -- ±80ms 허용 윈도우 (고정값, 실제 RTT 아님)

--------------------------------------------------------------------------------
-- 5. 세션 타임아웃 (§2.7.6)
--------------------------------------------------------------------------------
PGConfig.SESSION_TTL = {
    normal = 60,     -- 일반 세션: 60초
    tutorial = 90,   -- 튜토리얼 세션: 90초 (여유 있게)
}

--------------------------------------------------------------------------------
-- 6. Perfect 보호 구간 (§2.2.2b)
--------------------------------------------------------------------------------
PGConfig.PROTECTION_EPSILON = 1   -- ±1 position
PGConfig.PERFECT_CENTER = 50      -- 게이지 중앙

--------------------------------------------------------------------------------
-- 7. 시간 검증 임계값 (§2.7.6)
--------------------------------------------------------------------------------
PGConfig.MIN_COOK_TIME = 1.5   -- 최소 조리 시간 (초)
PGConfig.MAX_COOK_TIME = 30    -- 최대 조리 시간 (초)

--------------------------------------------------------------------------------
-- 8. CraftSpeed 업그레이드 (§11.4)
--------------------------------------------------------------------------------
--[[
    speedMultiplier = max(FLOOR, 0.9^(level-1))
    - Level 1: 1.0
    - Level 5: 0.656 (하한선 직전)
    - Max Level = 5
]]
PGConfig.CRAFTSPEED_MAX_LEVEL = 5
PGConfig.CRAFTSPEED_FLOOR = 0.6   -- 하한선 (튜토리얼 80% Perfect 달성 기준)
PGConfig.CRAFTSPEED_DECAY = 0.9   -- 레벨당 감소율

--------------------------------------------------------------------------------
-- 9. 헬퍼 함수
--------------------------------------------------------------------------------

-- 난이도에 따른 게이지 설정 반환
function PGConfig.GetGaugeConfig(difficulty)
    return PGConfig.GAUGE_CONFIG[difficulty] or PGConfig.GAUGE_CONFIG[PGConfig.DEFAULT_DIFFICULTY]
end

-- CraftSpeed 레벨에 따른 속도 배율 계산
function PGConfig.GetSpeedMultiplier(craftSpeedLevel)
    local level = math.min(craftSpeedLevel or 1, PGConfig.CRAFTSPEED_MAX_LEVEL)
    local multiplier = math.pow(PGConfig.CRAFTSPEED_DECAY, level - 1)
    return math.max(PGConfig.CRAFTSPEED_FLOOR, multiplier)
end

-- 튜토리얼 여부에 따른 판정 구간 반환
function PGConfig.GetJudgmentZones(isTutorial)
    return isTutorial and PGConfig.JUDGMENT_ZONES.tutorial or PGConfig.JUDGMENT_ZONES.normal
end

-- 튜토리얼 여부에 따른 세션 TTL 반환
function PGConfig.GetSessionTTL(isTutorial)
    return isTutorial and PGConfig.SESSION_TTL.tutorial or PGConfig.SESSION_TTL.normal
end

return PGConfig
