--!strict
--[[
    EssenceService.lua
    ------------------
    Handles harvest requests from clients. Server-authoritative — never trust
    the client about distance, cooldown, or yield.

    Expected world setup (build this in Studio):
      Workspace.EssenceNodes  -> Folder containing Parts named like "GlimmerNode".
      Workspace.WorldTree     -> a Part (or Model with a PrimaryPart) where
                                 players stand to deposit their lantern.

    Each node tracks a per-player cooldown via attribute, plus a global
    "Depleted" attribute that hides it briefly while it respawns.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local PlayerDataService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("PlayerDataService"))
local WispService       = require(ServerScriptService:WaitForChild("Services"):WaitForChild("WispService"))
-- Lazy-load AbilityService so we don't create a require cycle at top level.
local AbilityService    = nil :: any

local EssenceService = {}

-- last-harvest timestamps so each player has their own cooldown
local lastHarvestAt: { [Player]: number } = {}

local function getHRP(player: Player): BasePart?
    local char = player.Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function respawnNode(node: BasePart)
    node:SetAttribute("Depleted", true)
    node.Transparency = 0.85
    node.CanCollide = false
    task.delay(Constants.NODE_RESPAWN_TIME, function()
        if not node.Parent then return end
        node:SetAttribute("Depleted", false)
        node.Transparency = 0
        node.CanCollide = true
    end)
end

local function handleHarvest(player: Player, node: any)
    if typeof(node) ~= "Instance" or not node:IsA("BasePart") then return end
    if node.Parent ~= Workspace:FindFirstChild("EssenceNodes") then return end
    if node:GetAttribute("Depleted") then return end

    -- distance check (anti-cheat)
    local hrp = getHRP(player)
    if not hrp then return end
    if (hrp.Position - node.Position).Magnitude > Constants.HARVEST_RANGE then return end

    -- biome gate check: locked if the player doesn't own enough wisps yet.
    local profile = PlayerDataService.get(player)
    if not profile then return end
    local required = node:GetAttribute("BiomeRequiredWisps") or 0
    local ownedCount = #profile.ownedWispIds
    if ownedCount < required then
        Remotes.get(Constants.REMOTES.HarvestRejected):FireClient(player, {
            reason = "locked",
            required = required,
            owned = ownedCount,
            position = node.Position,
        })
        return
    end

    -- cooldown check (anti-cheat)
    local now = os.clock()
    local last = lastHarvestAt[player] or 0
    if now - last < Constants.HARVEST_COOLDOWN then return end
    lastHarvestAt[player] = now

    -- yield = (base + wisp bonus) * mist buff * biome multiplier
    local mistMult = (AbilityService and AbilityService.getMistMultiplier(player)) or 1
    local biomeMult = node:GetAttribute("BiomeMultiplier") or 1
    local yieldAmt = math.floor((Constants.NODE_BASE_ESSENCE + WispService.totalCollectionBonus(player)) * mistMult * biomeMult)
    local space = math.max(0, profile.lanternCapacity - profile.lanternContents)
    yieldAmt = math.min(yieldAmt, space)
    if yieldAmt <= 0 then return end

    profile.lanternContents += yieldAmt
    profile.totalEssenceEver += yieldAmt
    PlayerDataService.update(player, "lanternContents", profile.lanternContents)

    Remotes.get(Constants.REMOTES.EssenceAwarded):FireClient(player, yieldAmt, node.Position)

    respawnNode(node)
end

local function handleDeposit(player: Player)
    local tree = Workspace:FindFirstChild("WorldTree")
    if not tree then return end
    local treePos
    if tree:IsA("BasePart") then
        treePos = tree.Position
    elseif tree:IsA("Model") and tree.PrimaryPart then
        treePos = tree.PrimaryPart.Position
    else
        return
    end

    local hrp = getHRP(player)
    if not hrp then return end
    if (hrp.Position - treePos).Magnitude > Constants.DEPOSIT_RANGE then return end

    local profile = PlayerDataService.get(player)
    if not profile or profile.lanternContents <= 0 then return end

    -- Reward full deposits with a small multiplier so it's worth waiting to top up.
    local fillRatio = profile.lanternContents / math.max(1, profile.lanternCapacity)
    local multiplier = (fillRatio >= 0.9) and Constants.DEPOSIT_FULL_BONUS or 1
    local shards = math.floor(profile.lanternContents * multiplier)

    profile.lanternContents = 0
    PlayerDataService.update(player, "lanternContents", 0)
    PlayerDataService.addShards(player, shards)
end

-- Build a ProximityPrompt on the WorldTree so players have a visible "Press E
-- to deposit" affordance instead of a hidden RemoteEvent.
local function attachDepositPrompt()
    local tree = Workspace:WaitForChild("WorldTree", 15)
    if not tree then
        warn("[EssenceService] WorldTree not found in Workspace within 15s — deposit prompt not attached.")
        return
    end

    -- Pick the attachment part: if Model, use PrimaryPart; else the tree itself.
    local promptHost: Instance = tree
    if tree:IsA("Model") then
        if tree.PrimaryPart then
            promptHost = tree.PrimaryPart
        else
            warn("[EssenceService] WorldTree is a Model without a PrimaryPart — prompt may not appear.")
            return
        end
    end

    -- Avoid creating duplicates if this runs twice (e.g. during hot-reload).
    local existing = promptHost:FindFirstChildOfClass("ProximityPrompt")
    if existing then existing:Destroy() end

    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = "Deposit Essence"
    prompt.ObjectText = "World Tree"
    prompt.HoldDuration = 0
    prompt.MaxActivationDistance = Constants.DEPOSIT_RANGE
    prompt.RequiresLineOfSight = false
    prompt.KeyboardKeyCode = Enum.KeyCode.E
    prompt.Parent = promptHost

    prompt.Triggered:Connect(handleDeposit)
end

function EssenceService.start()
    -- Resolved here (not at top of file) to avoid require cycles.
    AbilityService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("AbilityService"))

    Remotes.get(Constants.REMOTES.RequestHarvest).OnServerEvent:Connect(handleHarvest)
    Remotes.get(Constants.REMOTES.RequestDeposit).OnServerEvent:Connect(handleDeposit)

    Players.PlayerRemoving:Connect(function(p)
        lastHarvestAt[p] = nil
    end)

    task.spawn(attachDepositPrompt)
end

return EssenceService
