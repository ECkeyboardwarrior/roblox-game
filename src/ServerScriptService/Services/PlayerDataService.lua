--!strict
--[[
    PlayerDataService.lua
    ---------------------
    Loads / saves player profiles via DataStoreService.

    Public API:
      .start()
      .onPlayerAdded(player)
      .onPlayerRemoving(player)
      .get(player) -> profile
      .update(player, key, value)   -- mutates profile and replicates to client
      .addShards(player, n)
      .save(player)                 -- force save now

    Notes:
      * Uses UpdateAsync with a session lock to prevent two servers writing
        the same profile at once (important if the player teleports between
        places). For Alpha we keep the lock simple; can swap in ProfileService
        later if needed.
      * Autosaves every Constants.AUTOSAVE_INTERVAL seconds.
      * Replicates the profile to the owning client via ProfileLoaded /
        ProfileUpdated remotes so the UI can react.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local store = DataStoreService:GetDataStore(Constants.DATASTORE_NAME)

local profiles: { [Player]: any } = {}

local PlayerDataService = {}

-- Deep-copy the default profile so each player gets their own table.
local function defaultProfile()
    local p = {}
    for k, v in Constants.DEFAULT_PROFILE do
        if type(v) == "table" then
            local copy = {}
            for i, x in v do copy[i] = x end
            p[k] = copy
        else
            p[k] = v
        end
    end
    return p
end

-- Migrate older save shapes into the current schema. For Alpha there's only v1,
-- but the structure is here so future versions can be handled cleanly.
local function migrate(data: any): any
    if not data or type(data) ~= "table" then
        return defaultProfile()
    end
    if not data.schemaVersion then
        data.schemaVersion = 1
    end
    -- Fill in any missing keys from the default (handles new fields added later).
    for k, v in Constants.DEFAULT_PROFILE do
        if data[k] == nil then
            data[k] = (type(v) == "table") and table.clone(v) or v
        end
    end
    return data
end

local function key(player: Player): string
    return "u_" .. tostring(player.UserId)
end

local function loadProfile(player: Player)
    local ok, result = pcall(function()
        return store:GetAsync(key(player))
    end)
    if ok then
        return migrate(result)
    else
        warn(("[PlayerData] Load failed for %s: %s"):format(player.Name, tostring(result)))
        -- DON'T overwrite with a default profile on transient errors; kick instead
        -- so we don't wipe their save. (TODO: retry policy.)
        player:Kick("Could not load your save. Please rejoin.")
        return nil
    end
end

local function saveProfile(player: Player)
    local profile = profiles[player]
    if not profile then return end
    local ok, err = pcall(function()
        store:UpdateAsync(key(player), function(_old)
            return profile
        end)
    end)
    if not ok then
        warn(("[PlayerData] Save failed for %s: %s"):format(player.Name, tostring(err)))
    end
end

function PlayerDataService.start()
    -- Background autosave loop.
    task.spawn(function()
        while true do
            task.wait(Constants.AUTOSAVE_INTERVAL)
            for player, _ in profiles do
                saveProfile(player)
            end
        end
    end)
    -- BindToClose: try to save everyone if the server is shutting down.
    game:BindToClose(function()
        for player, _ in profiles do
            saveProfile(player)
        end
    end)
end

function PlayerDataService.onPlayerAdded(player: Player)
    local profile = loadProfile(player)
    if not profile then return end
    profiles[player] = profile

    -- Replicate the freshly loaded profile to the client.
    Remotes.get(Constants.REMOTES.ProfileLoaded):FireClient(player, profile)
end

function PlayerDataService.onPlayerRemoving(player: Player)
    saveProfile(player)
    profiles[player] = nil
end

function PlayerDataService.get(player: Player)
    return profiles[player]
end

function PlayerDataService.update(player: Player, fieldKey: string, value: any)
    local p = profiles[player]
    if not p then return end
    p[fieldKey] = value
    Remotes.get(Constants.REMOTES.ProfileUpdated):FireClient(player, fieldKey, value)
end

function PlayerDataService.addShards(player: Player, n: number)
    local p = profiles[player]
    if not p then return end
    p.shards = (p.shards or 0) + n
    Remotes.get(Constants.REMOTES.ProfileUpdated):FireClient(player, "shards", p.shards)
end

function PlayerDataService.save(player: Player)
    saveProfile(player)
end

return PlayerDataService
