--!strict
--[[
    Constants.lua
    ----------------
    Single source of truth for tunable numbers and identifiers used across
    server + client. Anything you'd want to tweak for balancing lives here.
]]

local Constants = {}

-- DataStore schema version. Bump when player save shape changes; PlayerDataService
-- will read the version and migrate older saves.
Constants.DATA_SCHEMA_VERSION = 1

-- Default starting values for a brand-new player profile.
Constants.DEFAULT_PROFILE = {
    schemaVersion = 1,
    shards = 0,                -- Spirit Shards (currency)
    lanternCapacity = 50,      -- starting essence storage
    lanternContents = 0,
    ownedWispIds = { "spark" },-- start with one Spark wisp
    wispSlots = 5,             -- max wisps a player can have following them
    discoveredLogs = {},       -- bestiary / Spirit Logs (set of string ids)
    staff = "twig",            -- equipped staff id
    totalEssenceEver = 0,      -- for stats / achievements
    ascensions = 0,            -- rebirth count (set in full release)
}

-- Gameplay numbers.
Constants.HARVEST_RANGE = 18           -- max studs between player and node for a valid click
Constants.HARVEST_COOLDOWN = 0.15      -- seconds between staff swings (server-validated)
Constants.NODE_RESPAWN_TIME = 3        -- seconds for an essence node to come back
Constants.NODE_BASE_ESSENCE = 5        -- essence yield per harvest before staff/wisp multipliers
Constants.DEPOSIT_RANGE = 10           -- studs from World Tree required to deposit
Constants.DEPOSIT_FULL_BONUS = 1.25    -- multiplier applied when depositing a >=90% full lantern

-- DataStore.
Constants.DATASTORE_NAME = "SpiritGrove_PlayerData_v1"
Constants.AUTOSAVE_INTERVAL = 60       -- seconds between background saves

-- Remote names. Use these constants everywhere so we don't typo them.
Constants.REMOTES = {
    RequestHarvest = "RequestHarvest",   -- client -> server: please harvest this node
    EssenceAwarded = "EssenceAwarded",   -- server -> client: you got X essence
    RequestDeposit = "RequestDeposit",   -- client -> server: I'm at the World Tree
    ProfileLoaded  = "ProfileLoaded",    -- server -> client: here's your data
    ProfileUpdated = "ProfileUpdated",   -- server -> client: a field changed
    WispRosterChanged = "WispRosterChanged", -- server -> client: your owned wisp list changed
    RequestPurchase = "RequestPurchase",     -- client -> server: try to buy item id
    PurchaseResult  = "PurchaseResult",      -- server -> client: success/fail + reason
    RequestAbility  = "RequestAbility",      -- client -> server: fire wisp ability
    AbilityFeedback = "AbilityFeedback",     -- server -> client: ability fired, with metadata for VFX
    HarvestRejected = "HarvestRejected",     -- server -> client: harvest blocked (e.g. locked biome)
}

-- Wisp abilities. Each entry is the per-wisp tuning for active abilities.
-- Cooldowns are server-authoritative; clients only mirror them for HUD.
Constants.ABILITIES = {
    spark = {
        keyHint = "Q",
        cooldown = 8,
        range = 28,           -- AoE radius for harvest
        yieldMultiplier = 1,  -- nodes burst-harvest at normal yield
    },
    mist = {
        keyHint = "R",
        cooldown = 14,
        duration = 6,         -- seconds of doubled harvest yield
        multiplier = 2,
    },
    ember = {
        keyHint = "F",
        cooldown = 18,
        range = 22,
        yieldMultiplier = 3,  -- AoE harvest with triple yield
    },
}

return Constants
