--!strict
--[[
    Init.server.lua
    ---------------
    Bootstrap script. Runs once when the server starts.

    Responsibilities:
      1. Ensure Remotes exist (Remotes module creates them on require).
      2. Start each service in the correct order: PlayerData -> Wisp -> Essence.
      3. Wire up Players.PlayerAdded / PlayerRemoving.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Require shared modules first so RemoteEvents are created before any client connects.
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local Services = ServerScriptService:WaitForChild("Services")
local WorldBuilder      = require(Services:WaitForChild("WorldBuilder"))
local DayNightService   = require(Services:WaitForChild("DayNightService"))
local PlayerDataService = require(Services:WaitForChild("PlayerDataService"))
local WispService       = require(Services:WaitForChild("WispService"))
local AbilityService    = require(Services:WaitForChild("AbilityService"))
local EssenceService    = require(Services:WaitForChild("EssenceService"))
local ShopService       = require(Services:WaitForChild("ShopService"))

-- Build the world FIRST so EssenceService's WorldTree proximity-prompt attaches
-- to the freshly-built tree (and so players spawn into a populated map).
WorldBuilder.start()
DayNightService.start()  -- continuously animates Lighting after WorldBuilder's initial state

PlayerDataService.start()
WispService.start()
AbilityService.start()
EssenceService.start()
ShopService.start()

local function onPlayerAdded(player: Player)
    -- Load (or create) the player's profile first; everything else depends on it.
    local ok, err = pcall(PlayerDataService.onPlayerAdded, player)
    if not ok then
        warn(("[Init] PlayerDataService failed for %s: %s"):format(player.Name, tostring(err)))
        return
    end
    WispService.onPlayerAdded(player)
end

local function onPlayerRemoving(player: Player)
    WispService.onPlayerRemoving(player)
    PlayerDataService.onPlayerRemoving(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Catch players who joined before scripts finished loading.
for _, player in Players:GetPlayers() do
    task.spawn(onPlayerAdded, player)
end

print("[SpiritGrove] Server initialized.")
