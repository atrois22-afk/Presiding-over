-- Server/Config/FeatureFlags.lua
-- PG-1: Feature Flags (런타임 토글)
-- Created: 2026-01-20

--[[
    Feature Flag 정책:
    - 런타임에 기능 On/Off를 제어하는 플래그만 포함
    - 튜닝 상수는 PGConfig.lua에 분리
    - 신규 기능 출시 시 먼저 false로 배포 → 확인 후 true로 활성화
]]

local FeatureFlags = {
    -- PG-1: Cook 미니게임 활성화
    -- false: 기존 타이머 방식 유지
    -- true: 타이밍 게이지 미니게임 적용
    COOK_MINIGAME_ENABLED = false,
}

return FeatureFlags
