--!strict
--[[
    Remotes.lua
    -----------
    Creates (server) or fetches (client) all RemoteEvents used by the game,
    living under a single Folder in ReplicatedStorage called "Remotes".

    On the server this runs once at startup and *creates* the events.
    On the client we WaitForChild so we don't race the server's setup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))

local Remotes = {}

local function buildOrFetch()
    if RunService:IsServer() then
        local folder = ReplicatedStorage:FindFirstChild("Remotes")
        if not folder then
            folder = Instance.new("Folder")
            folder.Name = "Remotes"
            folder.Parent = ReplicatedStorage
        end
        for _, name in Constants.REMOTES do
            if not folder:FindFirstChild(name) then
                local ev = Instance.new("RemoteEvent")
                ev.Name = name
                ev.Parent = folder
            end
        end
        return folder
    else
        return ReplicatedStorage:WaitForChild("Remotes")
    end
end

local folder = buildOrFetch()

function Remotes.get(name: string): RemoteEvent
    local ev = folder:WaitForChild(name, 5)
    if not ev then
        error(string.format("Remote %q not found in ReplicatedStorage.Remotes", name))
    end
    return ev :: RemoteEvent
end

return Remotes
