--!strict
--[[
    HarvestController.client.lua
    ----------------------------
    Listens for mouse clicks / taps. If the player clicks on an EssenceNode
    within range, fires RequestHarvest to the server. The server is the
    authority — it re-validates everything, so this is just for input.

    Also listens for EssenceAwarded so we can play a quick "+N" floating
    number effect at the harvest location (placeholder for now).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer
local mouse = LocalPlayer:GetMouse()

local function getHRP(): BasePart?
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function tryHarvest()
    local target = mouse.Target
    if not target or not target:IsA("BasePart") then return end

    local nodesFolder = Workspace:FindFirstChild("EssenceNodes")
    if not nodesFolder or target.Parent ~= nodesFolder then return end
    if target:GetAttribute("Depleted") then return end

    local hrp = getHRP()
    if not hrp then return end
    if (hrp.Position - target.Position).Magnitude > Constants.HARVEST_RANGE then return end

    Remotes.get(Constants.REMOTES.RequestHarvest):FireServer(target)
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        tryHarvest()
    end
end)

-- Reusable floating-text widget. Spawns a short-lived anchor part with a
-- BillboardGui above the given world position. Animates upward + fades.
local function floatText(text: string, worldPos: Vector3, color: Color3, sizeOffset: Vector2?)
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.Transparency = 1
    part.Size = Vector3.new(0.1, 0.1, 0.1)
    part.Position = worldPos + Vector3.new(0, 2, 0)
    part.Parent = Workspace

    local gui = Instance.new("BillboardGui")
    gui.Size = sizeOffset and UDim2.fromOffset(sizeOffset.X, sizeOffset.Y) or UDim2.fromOffset(180, 40)
    gui.AlwaysOnTop = true
    gui.Parent = part

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.Text = text
    label.TextScaled = true
    label.TextColor3 = color
    label.TextStrokeTransparency = 0.2
    label.Parent = gui

    task.spawn(function()
        local start = os.clock()
        while os.clock() - start < 1.2 do
            local t = (os.clock() - start) / 1.2
            part.Position = part.Position + Vector3.new(0, 0.04, 0)
            label.TextTransparency = t
            task.wait()
        end
        part:Destroy()
    end)
end

-- "+N" on successful harvest
Remotes.get(Constants.REMOTES.EssenceAwarded).OnClientEvent:Connect(function(amount: number, worldPos: Vector3)
    floatText("+" .. tostring(amount), worldPos, Color3.fromRGB(255, 240, 180), nil)
end)

-- "🔒 Requires N wisps" when biome is locked
Remotes.get(Constants.REMOTES.HarvestRejected).OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" or not payload.position then return end
    if payload.reason == "locked" then
        local req = payload.required or 0
        floatText(
            string.format("🔒 Requires %d wisps", req),
            payload.position,
            Color3.fromRGB(255, 130, 130),
            Vector2.new(240, 40)
        )
    end
end)
