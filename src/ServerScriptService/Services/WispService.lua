--!strict
--[[
    WispService.lua
    ---------------
    Tracks which wisps each player owns and replicates the roster to their
    client. Movement / rendering is NOT done here — that's the client's job
    (see WispController.client.lua). This is critical for performance: with
    20 players * 30 wisps each, server-side spring math would melt the server.

    The server only handles:
      * which wisps a player owns (persistent, in their profile)
      * authoritative essence multipliers when harvesting

    Public API:
      .start()
      .onPlayerAdded(player)
      .onPlayerRemoving(player)
      .getOwnedWisps(player) -> { WispDefinition }
      .totalCollectionBonus(player) -> number  (sum of all owned wisp collectionAmount)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local WispTypes = require(Shared:WaitForChild("WispTypes"))

local PlayerDataService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("PlayerDataService"))

local WispService = {}

local function pushRosterToClient(player: Player)
    local profile = PlayerDataService.get(player)
    if not profile then return end
    -- Send the list of owned wisp ids; client looks each up in WispTypes.
    Remotes.get(Constants.REMOTES.WispRosterChanged):FireClient(player, profile.ownedWispIds)
end

function WispService.start()
    -- nothing global to set up for Alpha
end

function WispService.onPlayerAdded(player: Player)
    -- Push once after a brief defer, and again on every CharacterAdded so the
    -- client is guaranteed to have its listeners attached at least once.
    task.defer(function()
        pushRosterToClient(player)
    end)
    player.CharacterAdded:Connect(function()
        task.wait(0.25)  -- let client scripts re-init on respawn
        pushRosterToClient(player)
    end)
end

function WispService.onPlayerRemoving(_player: Player)
    -- nothing to clean up server-side; client cleans its own wisps
end

function WispService.getOwnedWisps(player: Player)
    local profile = PlayerDataService.get(player)
    if not profile then return {} end
    local out = {}
    for _, id in profile.ownedWispIds do
        local def = WispTypes.get(id)
        if def then table.insert(out, def) end
    end
    return out
end

function WispService.totalCollectionBonus(player: Player): number
    local total = 0
    for _, def in WispService.getOwnedWisps(player) do
        total += def.collectionAmount
    end
    return total
end

function WispService.grantWisp(player: Player, wispId: string)
    local def = WispTypes.get(wispId)
    if not def then return false end
    local profile = PlayerDataService.get(player)
    if not profile then return false end
    table.insert(profile.ownedWispIds, wispId)
    PlayerDataService.update(player, "ownedWispIds", profile.ownedWispIds)
    pushRosterToClient(player)
    return true
end

return WispService
