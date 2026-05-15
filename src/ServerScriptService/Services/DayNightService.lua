--!strict
--[[
    DayNightService.lua
    -------------------
    Continuous day/night cycle. Advances Lighting.ClockTime smoothly and
    re-tints Atmosphere + fog at key times so dawn/day/dusk/night each feel
    distinct rather than just "the same scene with the sun in a different
    spot".

    One full 24h game-cycle takes CYCLE_SECONDS real seconds. Defaults to 720s
    (12 minutes) which is comfortable: long enough to feel atmospheric, short
    enough to see all four times of day in a session.

    Public API:
      .start()
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local DayNightService = {}

local CYCLE_SECONDS = 720         -- 12 real-time minutes per in-game day
local START_HOUR = 7              -- spawn into early morning

-- Time-of-day style points. Linearly interpolated between adjacent entries.
type Style = {
    hour: number,
    ambient: Color3,
    outdoorAmbient: Color3,
    fogColor: Color3,
    fogEnd: number,
    atmosphereDensity: number,
    atmosphereHaze: number,
    atmosphereColor: Color3,
}

local STYLES: { Style } = {
    {  -- midnight
        hour = 0,
        ambient = Color3.fromRGB(20, 25, 50),
        outdoorAmbient = Color3.fromRGB(50, 60, 100),
        fogColor = Color3.fromRGB(40, 50, 80),
        fogEnd = 500,
        atmosphereDensity = 0.5,
        atmosphereHaze = 1.5,
        atmosphereColor = Color3.fromRGB(80, 100, 150),
    },
    {  -- dawn
        hour = 6,
        ambient = Color3.fromRGB(70, 60, 80),
        outdoorAmbient = Color3.fromRGB(160, 130, 130),
        fogColor = Color3.fromRGB(220, 180, 170),
        fogEnd = 700,
        atmosphereDensity = 0.4,
        atmosphereHaze = 1.8,
        atmosphereColor = Color3.fromRGB(240, 200, 180),
    },
    {  -- midday
        hour = 12,
        ambient = Color3.fromRGB(120, 130, 140),
        outdoorAmbient = Color3.fromRGB(200, 210, 220),
        fogColor = Color3.fromRGB(180, 200, 220),
        fogEnd = 1100,
        atmosphereDensity = 0.25,
        atmosphereHaze = 0.8,
        atmosphereColor = Color3.fromRGB(200, 210, 220),
    },
    {  -- dusk
        hour = 18,
        ambient = Color3.fromRGB(70, 50, 70),
        outdoorAmbient = Color3.fromRGB(180, 100, 90),
        fogColor = Color3.fromRGB(220, 140, 100),
        fogEnd = 750,
        atmosphereDensity = 0.45,
        atmosphereHaze = 1.6,
        atmosphereColor = Color3.fromRGB(230, 150, 120),
    },
    {  -- night
        hour = 21,
        ambient = Color3.fromRGB(30, 35, 60),
        outdoorAmbient = Color3.fromRGB(70, 90, 130),
        fogColor = Color3.fromRGB(60, 70, 110),
        fogEnd = 550,
        atmosphereDensity = 0.5,
        atmosphereHaze = 1.4,
        atmosphereColor = Color3.fromRGB(90, 110, 160),
    },
}

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

local function lerpColor(a: Color3, b: Color3, t: number): Color3
    return a:Lerp(b, t)
end

local function styleForHour(hour: number): Style
    -- Find the two style anchors that bracket `hour` and interpolate.
    local prev = STYLES[#STYLES]
    local prevHour = prev.hour - 24
    for _, s in STYLES do
        if hour < s.hour then
            local t = (hour - prevHour) / math.max(0.001, s.hour - prevHour)
            return {
                hour = hour,
                ambient = lerpColor(prev.ambient, s.ambient, t),
                outdoorAmbient = lerpColor(prev.outdoorAmbient, s.outdoorAmbient, t),
                fogColor = lerpColor(prev.fogColor, s.fogColor, t),
                fogEnd = lerp(prev.fogEnd, s.fogEnd, t),
                atmosphereDensity = lerp(prev.atmosphereDensity, s.atmosphereDensity, t),
                atmosphereHaze = lerp(prev.atmosphereHaze, s.atmosphereHaze, t),
                atmosphereColor = lerpColor(prev.atmosphereColor, s.atmosphereColor, t),
            }
        end
        prev = s
        prevHour = s.hour
    end
    return STYLES[#STYLES]  -- shouldn't hit, but a sane default
end

local function applyStyle(s: Style)
    Lighting.ClockTime = s.hour
    Lighting.Ambient = s.ambient
    Lighting.OutdoorAmbient = s.outdoorAmbient
    Lighting.FogColor = s.fogColor
    Lighting.FogEnd = s.fogEnd

    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if atmosphere then
        atmosphere.Density = s.atmosphereDensity
        atmosphere.Haze = s.atmosphereHaze
        atmosphere.Color = s.atmosphereColor
    end
end

function DayNightService.start()
    -- Drive the cycle from server time so it's consistent across players.
    local epoch = os.clock()
    task.spawn(function()
        while true do
            local elapsed = os.clock() - epoch
            local progress = (elapsed / CYCLE_SECONDS) % 1
            local hour = (START_HOUR + progress * 24) % 24
            applyStyle(styleForHour(hour))
            RunService.Heartbeat:Wait()
        end
    end)
end

return DayNightService
