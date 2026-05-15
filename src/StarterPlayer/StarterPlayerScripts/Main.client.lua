--!strict
--[[
    Init.client.lua
    ---------------
    Client bootstrap. Loads the local profile cache and starts the per-frame
    controllers (Wisp, Harvest).

    The "profile cache" is a client-side mirror of the player's profile,
    populated by ProfileLoaded and kept in sync via ProfileUpdated. UI scripts
    will read from this (added in a later pass).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

-- The profile mirror lives on the LocalPlayer as a folder of attributes for
-- easy UI binding. Other client scripts can read these directly.
local profileAttrs = Instance.new("Folder")
profileAttrs.Name = "Profile"
profileAttrs.Parent = LocalPlayer

local function applyProfile(profile)
    for k, v in profile do
        if typeof(v) == "table" then
            -- attributes can't hold tables; skip — controllers should listen
            -- for ProfileUpdated and read whatever they need directly.
            continue
        end
        profileAttrs:SetAttribute(k, v)
    end
end

Remotes.get(Constants.REMOTES.ProfileLoaded).OnClientEvent:Connect(applyProfile)
Remotes.get(Constants.REMOTES.ProfileUpdated).OnClientEvent:Connect(function(fieldKey, value)
    if typeof(value) == "table" then return end
    profileAttrs:SetAttribute(fieldKey, value)
end)

-- The other controllers are LocalScripts themselves and start independently.
-- This script's job is just to set up the profile mirror before they need it.

print("[SpiritGrove] Client initialized.")
