--!strict
--[[
    AbilityController.client.lua
    ----------------------------
    Wires the ability keybinds and plays the visuals when the server confirms.

    Keys (only fire if the player owns the relevant wisp):
      Q -> Spark    (AoE shockwave + auto-harvest)
      R -> Mist     (buff aura: 2x yield for a few seconds)
      F -> Ember    (fiery shockwave + 3x auto-harvest)

    A small ability bar appears bottom-center, showing each ability the player
    owns with its key, cooldown, and current state (ready / on cooldown).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local WispTypes = require(Shared:WaitForChild("WispTypes"))

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Which ability id maps to which KeyCode for this client.
local KEY_FOR_ABILITY: { [string]: Enum.KeyCode } = {
    spark = Enum.KeyCode.Q,
    mist  = Enum.KeyCode.R,
    ember = Enum.KeyCode.F,
}

-- ---------- track which abilities player has via wisp roster ----------

local ownedAbilities: { [string]: boolean } = {}

Remotes.get(Constants.REMOTES.WispRosterChanged).OnClientEvent:Connect(function(ids)
    ownedAbilities = {}
    if typeof(ids) ~= "table" then return end
    for _, wispId in ids do
        local def = WispTypes.get(wispId)
        if def and def.ability ~= "none" then
            ownedAbilities[def.ability] = true
        end
    end
    -- HUD bar updates on the next Heartbeat tick (cleaner than poking it here)
end)

-- ---------- ability bar HUD ----------

local screen = Instance.new("ScreenGui")
screen.Name = "SpiritGroveAbilities"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = false
screen.Parent = playerGui

local bar = Instance.new("Frame")
bar.Name = "Bar"
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.new(0.5, 0, 1, -20)
bar.Size = UDim2.fromOffset(360, 70)
bar.BackgroundTransparency = 1
bar.Parent = screen

local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Horizontal
barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
barLayout.VerticalAlignment = Enum.VerticalAlignment.Center
barLayout.Padding = UDim.new(0, 10)
barLayout.Parent = bar

type Slot = {
    abilityId: string,
    frame: Frame,
    keyLabel: TextLabel,
    nameLabel: TextLabel,
    cooldownOverlay: Frame,
    cooldownText: TextLabel,
    readyAt: number,
}

local slots: { [string]: Slot } = {}

local function makeSlot(abilityId: string, accent: Color3): Slot
    local frame = Instance.new("Frame")
    frame.Name = abilityId
    frame.Size = UDim2.fromOffset(110, 64)
    frame.BackgroundColor3 = Color3.fromRGB(25, 28, 38)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Parent = bar
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = frame
    local s = Instance.new("UIStroke"); s.Color = accent; s.Thickness = 2; s.Transparency = 0.3; s.Parent = frame

    local key = Instance.new("TextLabel")
    key.BackgroundTransparency = 1
    key.Position = UDim2.fromOffset(8, 4)
    key.Size = UDim2.fromOffset(24, 24)
    key.Font = Enum.Font.GothamBold
    key.TextSize = 16
    key.TextColor3 = accent
    key.Text = Constants.ABILITIES[abilityId].keyHint
    key.Parent = frame

    local name = Instance.new("TextLabel")
    name.BackgroundTransparency = 1
    name.Position = UDim2.fromOffset(34, 4)
    name.Size = UDim2.new(1, -40, 0, 24)
    name.Font = Enum.Font.GothamSemibold
    name.TextSize = 14
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextColor3 = Color3.fromRGB(240, 240, 245)
    name.Text = abilityId:sub(1,1):upper() .. abilityId:sub(2)
    name.Parent = frame

    local hint = Instance.new("TextLabel")
    hint.BackgroundTransparency = 1
    hint.Position = UDim2.fromOffset(34, 26)
    hint.Size = UDim2.new(1, -40, 0, 18)
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 12
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextColor3 = Color3.fromRGB(170, 180, 200)
    hint.Text = "Ready"
    hint.Parent = frame

    -- Cooldown shade overlay (covers slot, transparent at full, opaque after fire).
    local overlay = Instance.new("Frame")
    overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 1
    overlay.BorderSizePixel = 0
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.ZIndex = 2
    overlay.Parent = frame
    local oc = Instance.new("UICorner"); oc.CornerRadius = UDim.new(0, 8); oc.Parent = overlay

    return {
        abilityId = abilityId,
        frame = frame,
        keyLabel = key,
        nameLabel = name,
        cooldownOverlay = overlay,
        cooldownText = hint,
        readyAt = 0,
    }
end

local function ensureSlots()
    for abilityId, _ in ownedAbilities do
        if not slots[abilityId] then
            -- Pick an accent color matching the wisp that grants this ability.
            local accent = Color3.fromRGB(150, 200, 255)
            for _, def in WispTypes.all() do
                if def.ability == abilityId then accent = def.color break end
            end
            slots[abilityId] = makeSlot(abilityId, accent)
        end
    end
    for abilityId, slot in slots do
        slot.frame.Visible = ownedAbilities[abilityId] == true
    end
end

RunService.Heartbeat:Connect(function()
    ensureSlots()
    local now = os.clock()
    for _, slot in slots do
        local remaining = slot.readyAt - now
        if remaining > 0 then
            slot.cooldownOverlay.BackgroundTransparency = 0.45
            slot.cooldownText.Text = string.format("%.1fs", remaining)
            slot.cooldownText.TextColor3 = Color3.fromRGB(220, 160, 110)
        else
            slot.cooldownOverlay.BackgroundTransparency = 1
            slot.cooldownText.Text = "Ready"
            slot.cooldownText.TextColor3 = Color3.fromRGB(170, 220, 180)
        end
    end
end)

-- ---------- input ----------

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    for abilityId, key in KEY_FOR_ABILITY do
        if input.KeyCode == key and ownedAbilities[abilityId] then
            local slot = slots[abilityId]
            if slot and os.clock() < slot.readyAt then return end
            -- Optimistically set the cooldown so the UI feels snappy; server
            -- will silently no-op if it disagrees.
            local tune = Constants.ABILITIES[abilityId]
            if slot then slot.readyAt = os.clock() + tune.cooldown end
            Remotes.get(Constants.REMOTES.RequestAbility):FireServer(abilityId)
            break
        end
    end
end)

-- ---------- VFX ----------

local function shockwave(position: Vector3, range: number, color: Color3)
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(2, 2, 2)
    part.Position = position
    part.Material = Enum.Material.Neon
    part.Color = color
    part.Transparency = 0.2
    part.CastShadow = false
    part.Parent = Workspace

    local goal = { Size = Vector3.new(range * 2, range * 2, range * 2), Transparency = 1 }
    local tween = TweenService:Create(part, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
    tween:Play()
    tween.Completed:Connect(function() part:Destroy() end)
end

local function mistAura(durationSec: number)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not hrp then return end

    local attach = Instance.new("Attachment")
    attach.Parent = hrp

    local emitter = Instance.new("ParticleEmitter")
    emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    emitter.Color = ColorSequence.new(Color3.fromRGB(160, 220, 255))
    emitter.Lifetime = NumberRange.new(0.8, 1.6)
    emitter.Rate = 40
    emitter.Speed = NumberRange.new(2, 6)
    emitter.Size = NumberSequence.new(0.6)
    emitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.2),
        NumberSequenceKeypoint.new(1, 1),
    })
    emitter.LightEmission = 0.7
    emitter.Parent = attach

    task.delay(durationSec, function()
        emitter.Enabled = false
        task.wait(2)  -- let in-flight particles die
        attach:Destroy()
    end)
end

Remotes.get(Constants.REMOTES.AbilityFeedback).OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" then return end
    if payload.id == "spark" and payload.origin then
        shockwave(payload.origin, payload.range or 28, Color3.fromRGB(255, 220, 120))
    elseif payload.id == "ember" and payload.origin then
        shockwave(payload.origin, payload.range or 22, Color3.fromRGB(255, 130, 60))
    elseif payload.id == "mist" then
        mistAura(payload.duration or 6)
    end
end)
