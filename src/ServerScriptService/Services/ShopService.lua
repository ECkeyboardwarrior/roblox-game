--!strict
--[[
    ShopService.lua
    ---------------
    Server-authoritative purchase handling. The client sends an item id; we
    look it up in ShopItems, validate everything (cost, prereqs, already-owned,
    already-maxed), then mutate the player's profile and reply.

    Public API:
      .start()

    Reply format (PurchaseResult fired back to client):
      {
        ok = bool,
        itemId = string,
        reason = string?,    -- present when ok = false
      }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local ShopItems = require(Shared:WaitForChild("ShopItems"))

local PlayerDataService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("PlayerDataService"))
local WispService       = require(ServerScriptService:WaitForChild("Services"):WaitForChild("WispService"))

local ShopService = {}

local function fail(player: Player, itemId: string, reason: string)
    Remotes.get(Constants.REMOTES.PurchaseResult):FireClient(player, {
        ok = false, itemId = itemId, reason = reason,
    })
end

local function succeed(player: Player, itemId: string)
    Remotes.get(Constants.REMOTES.PurchaseResult):FireClient(player, {
        ok = true, itemId = itemId,
    })
end

local function ownsWisp(profile: any, wispId: string): boolean
    for _, id in profile.ownedWispIds do
        if id == wispId then return true end
    end
    return false
end

local function handlePurchase(player: Player, rawId: any)
    if typeof(rawId) ~= "string" then return end
    local itemId = rawId
    local item = ShopItems.get(itemId)
    if not item then return fail(player, itemId, "Unknown item.") end

    local profile = PlayerDataService.get(player)
    if not profile then return fail(player, itemId, "Profile not loaded.") end

    if item.kind == "upgrade" then
        local cost = ShopItems.nextTierCost(item, profile)
        if not cost then return fail(player, itemId, "Already at max tier.") end
        if (profile.shards or 0) < cost then return fail(player, itemId, "Not enough shards.") end

        local newValue = ShopItems.nextTierValue(item, profile)
        assert(item.profileField and newValue, "upgrade item missing fields")

        profile.shards -= cost
        profile[item.profileField] = newValue

        PlayerDataService.update(player, "shards", profile.shards)
        PlayerDataService.update(player, item.profileField, newValue)

        succeed(player, itemId)
        return
    end

    if item.kind == "wisp_unlock" then
        assert(item.wispId and item.cost, "wisp_unlock missing fields")
        if ownsWisp(profile, item.wispId) then
            return fail(player, itemId, "Already owned.")
        end
        if item.requires then
            for _, prereq in item.requires do
                if not ownsWisp(profile, prereq) then
                    return fail(player, itemId, "Requires another wisp first.")
                end
            end
        end
        if (profile.shards or 0) < item.cost then
            return fail(player, itemId, "Not enough shards.")
        end

        profile.shards -= item.cost
        PlayerDataService.update(player, "shards", profile.shards)
        WispService.grantWisp(player, item.wispId)

        succeed(player, itemId)
        return
    end

    fail(player, itemId, "Unknown item kind.")
end

function ShopService.start()
    Remotes.get(Constants.REMOTES.RequestPurchase).OnServerEvent:Connect(handlePurchase)
end

return ShopService
