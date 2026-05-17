--!strict
--[[
    HudController.client.lua
    ------------------------
    Builds the in-game HUD at runtime and keeps it in sync with the player's
    profile and wisp roster.

    Why build it in code instead of pre-authoring a ScreenGui?
      Pure-Rojo workflows where the GUI lives in code mean *one* artifact
      (this file) defines the look and the behavior. No .rbxmx blob to sync
      that someone could accidentally change in Studio without committing.

    HUD layout (top-left):
        Spirit Shards: 0
        Lantern: 0 / 50  [====           ]
        Wisps: 1 / 5
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local profile = LocalPlayer:WaitForChild("Profile", 10)  -- created by Main.client.lua

-- ---------- build the GUI ----------

local screen = Instance.new("ScreenGui")
screen.Name = "SpiritGroveHUD"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = false  -- respect Roblox top-bar so labels aren't clipped
screen.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0, 0)
panel.Position = UDim2.fromOffset(16, 16)
panel.Size = UDim2.fromOffset(260, 120)
panel.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
panel.BackgroundTransparency = 0.25
panel.BorderSizePixel = 0
panel.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(120, 180, 220)
stroke.Thickness = 1.5
stroke.Transparency = 0.4
stroke.Parent = panel

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 10)
pad.PaddingBottom = UDim.new(0, 10)
pad.PaddingLeft = UDim.new(0, 12)
pad.PaddingRight = UDim.new(0, 12)
pad.Parent = panel

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local function makeLabel(order: number, name: string): TextLabel
    local label = Instance.new("TextLabel")
    label.Name = name
    label.LayoutOrder = order
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 0, 22)
    label.Font = Enum.Font.GothamSemibold
    label.TextSize = 16
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = Color3.fromRGB(240, 240, 245)
    label.Text = ""
    label.Parent = panel
    return label
end

local shardsLabel = makeLabel(1, "Shards")
local lanternLabel = makeLabel(2, "Lantern")

local barFrame = Instance.new("Frame")
barFrame.Name = "LanternBar"
barFrame.LayoutOrder = 3
barFrame.Size = UDim2.new(1, 0, 0, 10)
barFrame.BackgroundColor3 = Color3.fromRGB(50, 55, 70)
barFrame.BorderSizePixel = 0
barFrame.Parent = panel

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = barFrame

local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.fromRGB(120, 220, 255)
barFill.BorderSizePixel = 0
barFill.Parent = barFrame

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = barFill

local wispsLabel = makeLabel(4, "Wisps")

-- HP row (added on top of the existing layout via LayoutOrder)
local hpLabel = makeLabel(5, "HP")

local hpBarFrame = Instance.new("Frame")
hpBarFrame.Name = "HpBar"
hpBarFrame.LayoutOrder = 6
hpBarFrame.Size = UDim2.new(1, 0, 0, 10)
hpBarFrame.BackgroundColor3 = Color3.fromRGB(60, 40, 40)
hpBarFrame.BorderSizePixel = 0
hpBarFrame.Parent = panel

local hpBarCorner = Instance.new("UICorner")
hpBarCorner.CornerRadius = UDim.new(1, 0)
hpBarCorner.Parent = hpBarFrame

local hpFill = Instance.new("Frame")
hpFill.Name = "Fill"
hpFill.Size = UDim2.fromScale(1, 1)
hpFill.BackgroundColor3 = Color3.fromRGB(220, 70, 70)
hpFill.BorderSizePixel = 0
hpFill.Parent = hpBarFrame
local hpFillCorner = Instance.new("UICorner")
hpFillCorner.CornerRadius = UDim.new(1, 0)
hpFillCorner.Parent = hpFill

-- Auto-resize the panel to fit the new rows
panel.Size = UDim2.fromOffset(260, 168)

-- ---------- data + redraw ----------

local function num(name: string, default: number): number
    local v = profile and profile:GetAttribute(name)
    if typeof(v) == "number" then return v end
    return default
end

local wispCount = 0

local function redraw()
    local shards = num("shards", 0)
    local contents = num("lanternContents", 0)
    local capacity = num("lanternCapacity", 1)
    local slots = num("wispSlots", 5)

    shardsLabel.Text = string.format("Spirit Shards: %d", shards)
    lanternLabel.Text = string.format("Lantern: %d / %d", contents, capacity)
    wispsLabel.Text = string.format("Wisps: %d / %d", wispCount, slots)

    local pct = (capacity > 0) and math.clamp(contents / capacity, 0, 1) or 0
    barFill.Size = UDim2.fromScale(pct, 1)
    -- color shifts cyan -> warm amber as it fills
    barFill.BackgroundColor3 = Color3.fromRGB(120, 220, 255):Lerp(Color3.fromRGB(255, 200, 90), pct)
end

if profile then
    profile.AttributeChanged:Connect(redraw)
end

-- ---------- HP tracking ----------

local function refreshHp(humanoid: Humanoid)
    local h = humanoid.Health
    local m = humanoid.MaxHealth
    if m <= 0 then m = 1 end
    local pct = math.clamp(h / m, 0, 1)
    hpFill.Size = UDim2.fromScale(pct, 1)
    hpLabel.Text = string.format("HP: %d / %d", math.max(0, math.floor(h)), math.floor(m))
    -- Red when low, orange mid, green when healthy.
    if pct < 0.3 then
        hpFill.BackgroundColor3 = Color3.fromRGB(220, 70, 70)
    elseif pct < 0.6 then
        hpFill.BackgroundColor3 = Color3.fromRGB(230, 140, 60)
    else
        hpFill.BackgroundColor3 = Color3.fromRGB(120, 200, 90)
    end
end

local function bindCharacter(character: Model)
    local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
    if not humanoid then return end
    refreshHp(humanoid)
    humanoid.HealthChanged:Connect(function() refreshHp(humanoid) end)
    humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function() refreshHp(humanoid) end)
end

if LocalPlayer.Character then bindCharacter(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(bindCharacter)

Remotes.get(Constants.REMOTES.WispRosterChanged).OnClientEvent:Connect(function(ownedIds)
    wispCount = (typeof(ownedIds) == "table") and #ownedIds or 0
    redraw()
end)

redraw()
