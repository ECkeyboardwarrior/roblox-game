--!strict
--[[
    ShopItems.lua
    -------------
    Catalog of everything for sale at the Spirit Shrine. Plain data — no
    closures or side-effects — so both server (validates purchases) and client
    (renders the UI) can require it.

    Two item kinds:
      * "upgrade" — tier-based. Each purchase bumps `profileField` to the next
        tier's `value`. Cost comes from `tiers[currentTier + 1].cost`.
      * "wisp_unlock" — one-time. Adds `wispId` to profile.ownedWispIds.
        May have a `requires` list of wispIds the player must already own.

    To add a new shop item: append an entry below. No code changes elsewhere.
]]

export type Tier = { cost: number, value: number }

export type ShopItem = {
    id: string,
    kind: "upgrade" | "wisp_unlock",
    displayName: string,
    description: string,
    -- upgrade fields:
    profileField: string?,
    tiers: { Tier }?,
    -- wisp_unlock fields:
    wispId: string?,
    cost: number?,
    requires: { string }?,
}

local items: { [string]: ShopItem } = {
    -- Lantern capacity: 9 tiers, cost ~3x per step. Early tiers stay cheap,
    -- late tiers become real long-term sinks.
    lantern_capacity = {
        id = "lantern_capacity",
        kind = "upgrade",
        displayName = "Bigger Lantern",
        description = "Carry more essence between deposits.",
        profileField = "lanternCapacity",
        tiers = {
            { cost = 15,     value = 80 },
            { cost = 50,     value = 120 },
            { cost = 175,    value = 180 },
            { cost = 600,    value = 280 },
            { cost = 2000,   value = 450 },
            { cost = 7000,   value = 750 },
            { cost = 25000,  value = 1200 },
            { cost = 90000,  value = 2000 },
            { cost = 350000, value = 3500 },
        },
    },

    -- Wisp slots: more slots = more passive yield per click. Caps at 22 wisps
    -- which is intentionally a Big Number for late-game flex.
    wisp_slots = {
        id = "wisp_slots",
        kind = "upgrade",
        displayName = "Extra Wisp Slot",
        description = "Recruit one more wisp to follow you.",
        profileField = "wispSlots",
        tiers = {
            { cost = 30,     value = 6 },
            { cost = 120,    value = 7 },
            { cost = 450,    value = 8 },
            { cost = 1800,   value = 10 },
            { cost = 7000,   value = 13 },
            { cost = 28000,  value = 17 },
            { cost = 120000, value = 22 },
        },
    },

    mist_wisp = {
        id = "mist_wisp",
        kind = "wisp_unlock",
        displayName = "Mist Wisp",
        description = "Rare wisp. Collects 2x essence.",
        wispId = "mist",
        cost = 50,
    },

    ember_wisp = {
        id = "ember_wisp",
        kind = "wisp_unlock",
        displayName = "Ember Wisp",
        description = "Epic wisp. Collects 3x essence and deals damage.",
        wispId = "ember",
        cost = 1200,
        requires = { "mist" },
    },
}

-- Stable display order for the UI (tables are unordered in Lua).
local order: { string } = {
    "lantern_capacity",
    "wisp_slots",
    "mist_wisp",
    "ember_wisp",
}

local module = {}

function module.get(id: string): ShopItem?
    return items[id]
end

function module.order(): { string }
    return order
end

function module.all(): { [string]: ShopItem }
    return items
end

-- For upgrades: which tier index the player is currently at (0 if base).
function module.currentTier(item: ShopItem, profile: any): number
    if item.kind ~= "upgrade" or not item.profileField or not item.tiers then
        return 0
    end
    local current = profile[item.profileField]
    local tier = 0
    for i, t in item.tiers do
        if current >= t.value then tier = i end
    end
    return tier
end

-- For upgrades: cost of the *next* tier, or nil if maxed.
function module.nextTierCost(item: ShopItem, profile: any): number?
    if item.kind ~= "upgrade" or not item.tiers then return nil end
    local tier = module.currentTier(item, profile)
    local next_t = item.tiers[tier + 1]
    return next_t and next_t.cost or nil
end

function module.nextTierValue(item: ShopItem, profile: any): number?
    if item.kind ~= "upgrade" or not item.tiers then return nil end
    local tier = module.currentTier(item, profile)
    local next_t = item.tiers[tier + 1]
    return next_t and next_t.value or nil
end

return module
