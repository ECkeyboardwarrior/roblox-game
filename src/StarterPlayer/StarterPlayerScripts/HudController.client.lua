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

Remotes.get(Constants.REMOTES.WispRosterChanged).OnClientEvent:Connect(function(ownedIds)
    wispCount = (typeof(ownedIds) == "table") and #ownedIds or 0
    redraw()
end)

redraw()
