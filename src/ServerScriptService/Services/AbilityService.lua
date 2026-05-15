--!strict
--[[
    AbilityService.lua
    ------------------
    Server-authoritative wisp abilities. Handles RequestAbility from clients,
    validates wisp ownership + cooldown, applies the effect, and fires
    AbilityFeedback so clients can play VFX.

    Three abilities:
      spark  -> AoE auto-harvest in radius
      mist   -> harvest-yield buff window (multiplier x duration)
      ember  -> AoE auto-harvest with bonus multiplier

    Public API:
      .start()
      .getMistMultiplier(player) -> number   (1 if no buff active)
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local PlayerDataService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("PlayerDataService"))
local WispService       = require(ServerScriptService:WaitForChild("Services"):WaitForChild("WispService"))

local AbilityService = {}

-- Per-player ability state.
type AbilityState = {
    cooldowns: { [string]: number },  -- abilityId -> os.clock() until ready
    mistUntil: number?,                -- os.clock() when Mist buff expires
}

local states: { [Player]: AbilityState } = {}

local function getState(player: Player): AbilityState
    local s = states[player]
    if not s then
        s = { cooldowns = {}, mistUntil = nil }
        states[player] = s
    end
    return s
end

local function ownsAbility(player: Player, abilityId: string): boolean
    -- A player has an ability if they own a wisp whose `ability` field matches.
    for _, def in WispService.getOwnedWisps(player) do
        if def.ability == abilityId then return true end
    end
    return false
end

local function getHRP(player: Player): BasePart?
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Helper: AoE-harvest every essence node within `radius` of `origin` and award
-- essence with the given multiplier. Mirrors EssenceService.handleHarvest's
-- lantern + replication behaviour, but skipping the per-node click validation
-- because the ability is the validation.
local function aoeHarvest(player: Player, origin: Vector3, radius: number, yieldMultiplier: number): number
    local nodes = Workspace:FindFirstChild("EssenceNodes")
    if not nodes then return 0 end

    local profile = PlayerDataService.get(player)
    if not profile then return 0 end

    local NODE_BASE = Constants.NODE_BASE_ESSENCE
    local wispBonus = WispService.totalCollectionBonus(player)
    local mistMult = AbilityService.getMistMultiplier(player)

    local totalAwarded = 0

    for _, node in nodes:GetChildren() do
        if not node:IsA("BasePart") then continue end
        if node:GetAttribute("Depleted") then continue end
        if (node.Position - origin).Magnitude > radius then continue end

        local space = math.max(0, profile.lanternCapacity - profile.lanternContents)
        if space <= 0 then break end

        local rawYield = (NODE_BASE + wispBonus) * yieldMultiplier * mistMult
        local yieldAmt = math.min(math.floor(rawYield), space)
        if yieldAmt <= 0 then continue end

        profile.lanternContents += yieldAmt
        profile.totalEssenceEver += yieldAmt
        totalAwarded += yieldAmt

        -- Visual: fade + respawn this node.
        node:SetAttribute("Depleted", true)
        node.Transparency = 0.85
        node.CanCollide = false
        task.delay(Constants.NODE_RESPAWN_TIME, function()
            if not node.Parent then return end
            node:SetAttribute("Depleted", false)
            node.Transparency = 0
            node.CanCollide = true
        end)

        Remotes.get(Constants.REMOTES.EssenceAwarded):FireClient(player, yieldAmt, node.Position)
    end

    if totalAwarded > 0 then
        PlayerDataService.update(player, "lanternContents", profile.lanternContents)
    end

    return totalAwarded
end

-- ---- handlers per ability ----

local handlers = {} :: { [string]: (Player) -> () }

handlers.spark = function(player: Player)
    local hrp = getHRP(player); if not hrp then return end
    local tune = Constants.ABILITIES.spark
    aoeHarvest(player, hrp.Position, tune.range, tune.yieldMultiplier)
    Remotes.get(Constants.REMOTES.AbilityFeedback):FireClient(player, {
        id = "spark", origin = hrp.Position, range = tune.range,
    })
end

handlers.mist = function(player: Player)
    local state = getState(player)
    local tune = Constants.ABILITIES.mist
    state.mistUntil = os.clock() + tune.duration
    Remotes.get(Constants.REMOTES.AbilityFeedback):FireClient(player, {
        id = "mist", duration = tune.duration,
    })
end

handlers.ember = function(player: Player)
    local hrp = getHRP(player); if not hrp then return end
    local tune = Constants.ABILITIES.ember
    aoeHarvest(player, hrp.Position, tune.range, tune.yieldMultiplier)
    Remotes.get(Constants.REMOTES.AbilityFeedback):FireClient(player, {
        id = "ember", origin = hrp.Position, range = tune.range,
    })
end

-- ---- request handler ----

local function handleRequest(player: Player, rawId: any)
    if typeof(rawId) ~= "string" then return end
    local abilityId = rawId
    local tune = Constants.ABILITIES[abilityId]
    if not tune then return end

    if not ownsAbility(player, abilityId) then return end

    local state = getState(player)
    local now = os.clock()
    local readyAt = state.cooldowns[abilityId] or 0
    if now < readyAt then return end
    state.cooldowns[abilityId] = now + tune.cooldown

    local handler = handlers[abilityId]
    if handler then handler(player) end
end

-- ---- public ----

function AbilityService.getMistMultiplier(player: Player): number
    local s = states[player]
    if not s or not s.mistUntil then return 1 end
    if os.clock() < s.mistUntil then
        return Constants.ABILITIES.mist.multiplier
    end
    return 1
end

function AbilityService.start()
    Remotes.get(Constants.REMOTES.RequestAbility).OnServerEvent:Connect(handleRequest)
    Players.PlayerRemoving:Connect(function(p) states[p] = nil end)
end

return AbilityService
