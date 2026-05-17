--!strict
--[[
    MobTypes.lua
    ------------
    Catalog of every hostile mob in the game. Plain data — both server (AI,
    combat, loot) and client (UI labels, health bars) read from it.

    To add a new mob: append an entry below. The MobService picks up new
    entries automatically based on the `biome` field for spawning.

    Fields:
      id              stable key
      displayName     shown in nameplate
      health          starting HP
      damage          damage per attack hit
      moveSpeed       studs per second toward target
      aggroRange      studs at which the mob notices a player
      attackRange     studs at which the mob attacks
      attackCooldown  seconds between attacks
      biome           which biome's decorStyle this mob spawns in
      bodyColor       fallback Part color if no model template available
      bodySize        Vector3 for fallback Part body
      shardDrop       { min, max } range of shards awarded on death
      isBoss          true for bosses (spawned manually, not via random tick)
      nightOnly       if true, only spawns during the night cycle (hour 20-5)
]]

export type LootDrop = {
    shardsMin: number,
    shardsMax: number,
}

export type MobDefinition = {
    id: string,
    displayName: string,
    health: number,
    damage: number,
    moveSpeed: number,
    aggroRange: number,
    attackRange: number,
    attackCooldown: number,
    biome: string,
    bodyColor: Color3,
    bodySize: Vector3,
    shardDrop: LootDrop,
    isBoss: boolean?,
    nightOnly: boolean?,
}

local mobs: { [string]: MobDefinition } = {

    -- ============= Verdant Hollow =============

    vine_beetle = {
        id = "vine_beetle",
        displayName = "Vine Beetle",
        health = 35,
        damage = 4,
        moveSpeed = 9,
        aggroRange = 24,
        attackRange = 4,
        attackCooldown = 1.5,
        biome = "verdant",
        bodyColor = Color3.fromRGB(60, 110, 50),
        bodySize = Vector3.new(3, 2.5, 4),
        shardDrop = { shardsMin = 3, shardsMax = 6 },
    },

    sprout_slime = {
        id = "sprout_slime",
        displayName = "Sprout Slime",
        health = 22,
        damage = 2,
        moveSpeed = 7,
        aggroRange = 20,
        attackRange = 3,
        attackCooldown = 2,
        biome = "verdant",
        bodyColor = Color3.fromRGB(120, 200, 100),
        bodySize = Vector3.new(2.5, 2, 2.5),
        shardDrop = { shardsMin = 2, shardsMax = 4 },
    },

    -- ============= Whispering Wood =============

    enchanted_owl = {
        id = "enchanted_owl",
        displayName = "Enchanted Owl",
        health = 50,
        damage = 6,
        moveSpeed = 12,
        aggroRange = 30,
        attackRange = 5,
        attackCooldown = 1.4,
        biome = "whispering",
        bodyColor = Color3.fromRGB(170, 100, 200),
        bodySize = Vector3.new(2.5, 3, 2.5),
        shardDrop = { shardsMin = 6, shardsMax = 12 },
    },

    shadow_stalker = {
        id = "shadow_stalker",
        displayName = "Shadow Stalker",
        health = 220,
        damage = 18,
        moveSpeed = 14,
        aggroRange = 38,
        attackRange = 6,
        attackCooldown = 1.2,
        biome = "whispering",
        bodyColor = Color3.fromRGB(35, 20, 50),
        bodySize = Vector3.new(4, 5, 3),
        shardDrop = { shardsMin = 80, shardsMax = 140 },
        isBoss = true,
        nightOnly = true,  -- only stalks at night
    },

    -- ============= Ember Reach =============

    lava_slime = {
        id = "lava_slime",
        displayName = "Lava Slime",
        health = 60,
        damage = 8,
        moveSpeed = 6,
        aggroRange = 22,
        attackRange = 3,
        attackCooldown = 1.8,
        biome = "ember",
        bodyColor = Color3.fromRGB(255, 100, 40),
        bodySize = Vector3.new(3, 2.5, 3),
        shardDrop = { shardsMin = 10, shardsMax = 18 },
    },

    magma_golem = {
        id = "magma_golem",
        displayName = "Magma Golem",
        health = 180,
        damage = 14,
        moveSpeed = 7,
        aggroRange = 28,
        attackRange = 5,
        attackCooldown = 2,
        biome = "ember",
        bodyColor = Color3.fromRGB(110, 50, 40),
        bodySize = Vector3.new(4, 6, 4),
        shardDrop = { shardsMin = 25, shardsMax = 45 },
    },

    -- ============= Frostpeak Spire =============

    frost_titan = {
        id = "frost_titan",
        displayName = "Frost Titan",
        health = 2500,
        damage = 35,
        moveSpeed = 5,
        aggroRange = 50,
        attackRange = 9,
        attackCooldown = 2.5,
        biome = "frostpeak",
        bodyColor = Color3.fromRGB(200, 230, 250),
        bodySize = Vector3.new(7, 12, 6),
        shardDrop = { shardsMin = 800, shardsMax = 1500 },
        isBoss = true,
    },
}

local module = {}

function module.get(id: string): MobDefinition?
    return mobs[id]
end

function module.all(): { [string]: MobDefinition }
    return mobs
end

-- All non-boss mobs that spawn in a given biome (used by spawner ticks).
function module.regularSpawnsFor(decorStyle: string): { MobDefinition }
    local out = {}
    for _, def in mobs do
        if def.biome == decorStyle and not def.isBoss then
            table.insert(out, def)
        end
    end
    return out
end

return module
