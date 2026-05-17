--!strict
--[[
    MobFeedbackController.client.lua
    --------------------------------
    Shows floating damage numbers when wisps hit a mob, and a "+shards" pop
    when a mob dies. Server is authoritative; this is pure VFX.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

local function floatText(text: string, worldPos: Vector3, color: Color3, size: Vector2?)
    local part = Instance.new("Part")
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.Transparency = 1
    part.Size = Vector3.new(0.1, 0.1, 0.1)
    part.Position = worldPos + Vector3.new(0, 3, 0)
    part.Parent = Workspace

    local gui = Instance.new("BillboardGui")
    gui.Size = size and UDim2.fromOffset(size.X, size.Y) or UDim2.fromOffset(140, 40)
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
        while os.clock() - start < 1.0 do
            local t = (os.clock() - start) / 1.0
            part.Position = part.Position + Vector3.new(0, 0.07, 0)
            label.TextTransparency = t
            task.wait()
        end
        part:Destroy()
    end)
end

Remotes.get(Constants.REMOTES.MobDamaged).OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" or not payload.position then return end
    floatText("-" .. tostring(payload.damage), payload.position, Color3.fromRGB(255, 130, 130), nil)
end)

Remotes.get(Constants.REMOTES.MobKilled).OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" or not payload.position then return end
    floatText("+" .. tostring(payload.shardsAwarded) .. " ✦",
        payload.position, Color3.fromRGB(255, 220, 140), Vector2.new(200, 50))
end)
