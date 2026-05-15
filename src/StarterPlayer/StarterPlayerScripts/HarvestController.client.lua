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

-- Floating "+N" feedback when the server confirms a harvest.
Remotes.get(Constants.REMOTES.EssenceAwarded).OnClientEvent:Connect(function(amount: number, worldPos: Vector3)
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.Transparency = 1
    part.Size = Vector3.new(0.1, 0.1, 0.1)
    part.Position = worldPos + Vector3.new(0, 2, 0)
    part.Parent = Workspace

    local gui = Instance.new("BillboardGui")
    gui.Size = UDim2.fromOffset(120, 40)
    gui.AlwaysOnTop = true
    gui.Parent = part

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.Text = "+" .. tostring(amount)
    label.TextScaled = true
    label.TextColor3 = Color3.fromRGB(255, 240, 180)
    label.TextStrokeTransparency = 0.2
    label.Parent = gui

    -- Animate upward + fade, then clean up.
    task.spawn(function()
        local start = os.clock()
        while os.clock() - start < 1 do
            local t = os.clock() - start
            part.Position = part.Position + Vector3.new(0, 0.04, 0)
            label.TextTransparency = t
            task.wait()
        end
        part:Destroy()
    end)
end)
