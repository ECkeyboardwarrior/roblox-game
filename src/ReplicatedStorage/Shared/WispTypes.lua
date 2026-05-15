--!strict
--[[
    WispTypes.lua
    ----------------
    Catalog of every wisp variant in the game. To add a new wisp, append a new
    entry to the table below — no other file needs to change.

    Each entry's `ability` is a string id; the actual ability code lives in
    WispClass (client) and WispService (server-side AoE harvest logic).
]]

export type WispAbility = "none" | "spark" | "mist" | "ember"

export type WispDefinition = {
    id: string,                 -- stable key for saves
    displayName: string,        -- shown in UI
    rarity: "common" | "rare" | "epic" | "legendary" | "prismatic",
    color: Color3,              -- glow color
    collectionAmount: number,   -- essence per pollinate
    attackDamage: number,       -- vs. mobs (Beta+)
    moveSpeed: number,          -- studs/sec follow speed
    ability: WispAbility,
    abilityCooldown: number,    -- seconds
}

local WispTypes: { [string]: WispDefinition } = {
    spark = {
        id = "spark",
        displayName = "Spark Wisp",
        rarity = "common",
        color = Color3.fromRGB(255, 220, 120),
        collectionAmount = 1,
        attackDamage = 1,
        moveSpeed = 22,
        ability = "spark",
        abilityCooldown = 8,
    },

    mist = {
        id = "mist",
        displayName = "Mist Wisp",
        rarity = "rare",
        color = Color3.fromRGB(160, 220, 255),
        collectionAmount = 2,
        attackDamage = 0,
        moveSpeed = 18,
        ability = "mist",
        abilityCooldown = 10,
    },

    ember = {
        id = "ember",
        displayName = "Ember Wisp",
        rarity = "epic",
        color = Color3.fromRGB(255, 130, 60),
        collectionAmount = 3,
        attackDamage = 4,
        moveSpeed = 26,
        ability = "ember",
        abilityCooldown = 12,
    },
}

local module = {}

function module.get(id: string): WispDefinition?
    return WispTypes[id]
end

function module.all(): { [string]: WispDefinition }
    return WispTypes
end

return module
