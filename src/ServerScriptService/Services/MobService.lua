--!strict
--[[
    MobService.lua
    --------------
    Server-authoritative hostile-mob system.

    Responsibilities:
      * Spawn mobs in their assigned biomes at a steady rate (per-biome cap).
      * Run an AI loop on Heartbeat: pick nearest player target, move toward,
        attack when in range.
      * Take damage from wisps (driven by this service's own tick — wisps don't
        each run their own attack loop).
      * On death: clean up the mob, award shards to the killer.
      * Respect nightOnly mobs (Shadow Stalker only spawns 20:00–05:00).

    Public API:
      .start()

    A mob is represented in Workspace as a Model:
      mob (Model)
        ├─ Body (BasePart, Anchored = false, the mob's main visible body)
        ├─ Humanoid (so it can have a nameplate + take "damage" semantically)
        ├─ AlignPosition / AlignOrientation (smooth steering toward target)
        └─ Attributes: MobId, Health, MaxHealth, TargetUserId, NextAttackAt

    NOTE: We use AlignPosition for movement so we don't fight with Roblox's
    pathfinding while still feeling smooth. Mobs don't path around obstacles —
    they take a direct line at the target. Good enough for Alpha.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local MobTypes  = require(Shared:WaitForChild("MobTypes"))
local BiomeRegistry = require(Shared:WaitForChild("BiomeRegistry"))

local PlayerDataService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("PlayerDataService"))
local WispService       = require(ServerScriptService:WaitForChild("Services"):WaitForChild("WispService"))

local MobService = {}

-- =========================================================================
-- Configuration
-- =========================================================================

local MAX_MOBS_PER_BIOME = 6     -- cap so a biome isn't a wall of mobs
local SPAWN_TICK_INTERVAL = 4    -- seconds between spawn checks
local AI_TICK_INTERVAL = 1 / 20  -- 20 Hz AI tick (smooth without melting CPU)
local WISP_ATTACK_INTERVAL = 0.8 -- seconds between wisp damage ticks per player
local WISP_ATTACK_RANGE = 22     -- studs at which a wisp can hit a mob
local DEAGGRO_RANGE = 65         -- if target gets this far, lose aggro

-- =========================================================================
-- State
-- =========================================================================

type MobState = {
    model: Model,
    body: BasePart,
    humanoid: Humanoid,
    def: MobTypes.MobDefinition,
    health: number,
    targetPlayer: Player?,
    nextAttackAt: number,
    spawnedAt: number,
    biomeId: string,
    nameplate: BillboardGui,
    healthBarFill: Frame,
    healthBarText: TextLabel,
}

local activeMobs: { MobState } = {}
local lastWispAttackAt: { [Player]: number } = {}
local mobsFolder: Folder? = nil

-- =========================================================================
-- Helpers
-- =========================================================================

local function getMobsFolder(): Folder
    if mobsFolder and mobsFolder.Parent then return mobsFolder end
    local folder = Workspace:FindFirstChild("Mobs")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Mobs"
        folder.Parent = Workspace
    end
    mobsFolder = folder :: Folder
    return mobsFolder
end

local function findBiome(decorStyle: string): any?
    for _, b in BiomeRegistry do
        if b.decorStyle == decorStyle then return b end
    end
    return nil
end

local function getHRP(player: Player): BasePart?
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function nearestPlayerWithin(pos: Vector3, range: number): (Player?, number)
    local bestPlayer = nil
    local bestDist = range
    for _, player in Players:GetPlayers() do
        local hrp = getHRP(player)
        if not hrp then continue end
        local d = (hrp.Position - pos).Magnitude
        if d <= bestDist then
            bestDist = d
            bestPlayer = player
        end
    end
    return bestPlayer, bestDist
end

local function isNight(): boolean
    local h = Lighting.ClockTime
    return h >= 20 or h < 5
end

-- =========================================================================
-- Mob construction (Part-based; future: support templates from ServerStorage)
-- =========================================================================

local function makeNameplate(mob: MobState)
    local gui = Instance.new("BillboardGui")
    gui.Name = "Nameplate"
    gui.Size = UDim2.fromOffset(140, 36)
    gui.StudsOffset = Vector3.new(0, mob.def.bodySize.Y * 0.7 + 1, 0)
    gui.AlwaysOnTop = true
    gui.Parent = mob.body

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.Size = UDim2.new(1, 0, 0, 16)
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 12
    nameLabel.TextColor3 = Color3.fromRGB(255, 220, 220)
    nameLabel.TextStrokeTransparency = 0.2
    nameLabel.Text = mob.def.displayName
    nameLabel.Parent = gui

    local barBg = Instance.new("Frame")
    barBg.Position = UDim2.new(0, 0, 0, 18)
    barBg.Size = UDim2.new(1, 0, 0, 8)
    barBg.BackgroundColor3 = Color3.fromRGB(40, 30, 30)
    barBg.BorderSizePixel = 0
    barBg.Parent = gui
    local bgC = Instance.new("UICorner"); bgC.CornerRadius = UDim.new(1, 0); bgC.Parent = barBg

    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(1, 1)
    fill.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
    fill.BorderSizePixel = 0
    fill.Parent = barBg
    local fC = Instance.new("UICorner"); fC.CornerRadius = UDim.new(1, 0); fC.Parent = fill

    local hpText = Instance.new("TextLabel")
    hpText.Position = UDim2.new(0, 0, 0, 28)
    hpText.Size = UDim2.new(1, 0, 0, 12)
    hpText.BackgroundTransparency = 1
    hpText.Font = Enum.Font.Gotham
    hpText.TextSize = 10
    hpText.TextColor3 = Color3.fromRGB(255, 200, 200)
    hpText.Text = string.format("%d / %d", mob.health, mob.def.health)
    hpText.Parent = gui

    mob.nameplate = gui
    mob.healthBarFill = fill
    mob.healthBarText = hpText
end

local function refreshNameplate(mob: MobState)
    if not mob.nameplate.Parent then return end
    local pct = math.clamp(mob.health / mob.def.health, 0, 1)
    mob.healthBarFill.Size = UDim2.fromScale(pct, 1)
    mob.healthBarText.Text = string.format("%d / %d", math.max(0, math.floor(mob.health)), mob.def.health)
end

local function buildMobModel(def: MobTypes.MobDefinition, position: Vector3): (Model, BasePart, Humanoid)
    local model = Instance.new("Model")
    model.Name = def.id

    local body = Instance.new("Part")
    body.Name = "Body"
    body.Size = def.bodySize
    body.Color = def.bodyColor
    body.Material = def.isBoss and Enum.Material.Slate or Enum.Material.SmoothPlastic
    body.Position = position + Vector3.new(0, def.bodySize.Y / 2 + 1, 0)
    body.Anchored = false
    body.CanCollide = true
    body.Massless = false
    body.Parent = model

    -- Light tint glow for visibility
    local light = Instance.new("PointLight")
    light.Color = def.bodyColor
    light.Range = def.isBoss and 25 or 10
    light.Brightness = 1.2
    light.Parent = body

    -- Humanoid lets us use Roblox's nameplate hooks + death state if we want it.
    local humanoid = Instance.new("Humanoid")
    humanoid.MaxHealth = def.health
    humanoid.Health = def.health
    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
    humanoid.Parent = model

    model.PrimaryPart = body

    -- Steering: AlignPosition pulls the body toward a target attachment.
    local attach = Instance.new("Attachment")
    attach.Name = "BodyAttach"
    attach.Parent = body

    local targetAttach = Instance.new("Attachment")
    targetAttach.Name = "TargetAttach"
    targetAttach.WorldPosition = body.Position
    targetAttach.Parent = Workspace.Terrain

    local align = Instance.new("AlignPosition")
    align.Attachment0 = attach
    align.Attachment1 = targetAttach
    align.MaxForce = 50000
    align.MaxVelocity = def.moveSpeed
    align.Responsiveness = 25
    align.Parent = body

    local upright = Instance.new("AlignOrientation")
    upright.Attachment0 = attach
    upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
    upright.MaxTorque = 100000
    upright.Responsiveness = 30
    upright.Parent = body

    return model, body, humanoid
end

-- =========================================================================
-- Spawning
-- =========================================================================

local function countActiveInBiome(biomeId: string): number
    local n = 0
    for _, m in activeMobs do
        if m.biomeId == biomeId and m.health > 0 then n += 1 end
    end
    return n
end

local function randomSpawnPositionInBiome(biome: any, rng: Random): Vector3
    local theta = rng:NextNumber(0, math.pi * 2)
    local r = biome.radius * rng:NextNumber(0.3, 0.85)
    return Vector3.new(
        biome.center.X + math.cos(theta) * r,
        biome.center.Y + 2,
        biome.center.Z + math.sin(theta) * r
    )
end

local function spawnMob(def: MobTypes.MobDefinition, position: Vector3, biomeId: string)
    local model, body, humanoid = buildMobModel(def, position)
    model.Parent = getMobsFolder()

    local mob: MobState = {
        model = model,
        body = body,
        humanoid = humanoid,
        def = def,
        health = def.health,
        targetPlayer = nil,
        nextAttackAt = 0,
        spawnedAt = os.clock(),
        biomeId = biomeId,
        nameplate = nil :: any,
        healthBarFill = nil :: any,
        healthBarText = nil :: any,
    }
    makeNameplate(mob)
    table.insert(activeMobs, mob)
end

local rng = Random.new()
local function spawnTick()
    local night = isNight()
    for _, biome in BiomeRegistry do
        local count = countActiveInBiome(biome.id)
        if count >= MAX_MOBS_PER_BIOME then continue end

        local pool = MobTypes.regularSpawnsFor(biome.decorStyle)
        if #pool == 0 then continue end

        -- 30% chance to actually spawn each tick per biome — feels organic
        if rng:NextNumber() < 0.3 then
            local def = pool[rng:NextInteger(1, #pool)]
            if def.nightOnly and not night then continue end
            local pos = randomSpawnPositionInBiome(biome, rng)
            spawnMob(def, pos, biome.id)
        end
    end
end

-- =========================================================================
-- AI tick + combat
-- =========================================================================

local function killMob(mob: MobState, killer: Player?)
    if mob.health > 0 then return end  -- already alive somehow
    if not mob.model.Parent then return end

    -- Award shards to the killer
    if killer then
        local def = mob.def
        local award = rng:NextInteger(def.shardDrop.shardsMin, def.shardDrop.shardsMax)
        PlayerDataService.addShards(killer, award)
        Remotes.get(Constants.REMOTES.MobKilled):FireClient(killer, {
            mobId = def.id,
            position = mob.body.Position,
            shardsAwarded = award,
        })
    end

    -- Bosses get a 5-minute respawn cooldown so the encounter feels earned.
    if mob.def.isBoss then
        bossCooldownUntil[mob.def.id] = os.clock() + 300
        activeBossById[mob.def.id] = nil
    end

    mob.model:Destroy()
end

local function applyDamage(mob: MobState, amount: number, source: Player?)
    if mob.health <= 0 then return end
    mob.health -= amount
    refreshNameplate(mob)
    if source then
        Remotes.get(Constants.REMOTES.MobDamaged):FireClient(source, {
            mobId = mob.def.id,
            position = mob.body.Position,
            damage = amount,
        })
    end
    if mob.health <= 0 then
        killMob(mob, source)
    end
end

local function aiStep(mob: MobState, dt: number)
    if not mob.model.Parent or mob.health <= 0 then return false end

    -- Re-target if current target is gone or out of deaggro range
    local pos = mob.body.Position
    local currentTarget = mob.targetPlayer
    if currentTarget then
        local hrp = getHRP(currentTarget)
        if not hrp or (hrp.Position - pos).Magnitude > DEAGGRO_RANGE then
            mob.targetPlayer = nil
        end
    end

    if not mob.targetPlayer then
        local player, _ = nearestPlayerWithin(pos, mob.def.aggroRange)
        mob.targetPlayer = player
    end

    if not mob.targetPlayer then
        -- Idle: park steering attachment at current pos so we stop drifting.
        local align = mob.body:FindFirstChildOfClass("AlignPosition")
        if align and align.Attachment1 then
            align.Attachment1.WorldPosition = pos
        end
        return true
    end

    local hrp = getHRP(mob.targetPlayer)
    if not hrp then return true end

    -- Steer toward player
    local align = mob.body:FindFirstChildOfClass("AlignPosition")
    if align and align.Attachment1 then
        local targetPos = Vector3.new(hrp.Position.X, mob.body.Position.Y, hrp.Position.Z)
        align.Attachment1.WorldPosition = targetPos
        align.MaxVelocity = mob.def.moveSpeed
    end

    -- Attack if in range and off cooldown
    local now = os.clock()
    local dist = (hrp.Position - pos).Magnitude
    if dist <= mob.def.attackRange and now >= mob.nextAttackAt then
        local charHumanoid = mob.targetPlayer.Character and mob.targetPlayer.Character:FindFirstChildOfClass("Humanoid")
        if charHumanoid then
            charHumanoid:TakeDamage(mob.def.damage)
        end
        mob.nextAttackAt = now + mob.def.attackCooldown
    end

    return true
end

-- Per-player wisp attack tick.
-- Wisps damage the nearest mob within WISP_ATTACK_RANGE of each player every
-- WISP_ATTACK_INTERVAL seconds. Total damage = sum of owned wisps' attackDamage.
local function wispAttackTick(player: Player, now: number)
    local last = lastWispAttackAt[player] or 0
    if now - last < WISP_ATTACK_INTERVAL then return end
    lastWispAttackAt[player] = now

    local hrp = getHRP(player)
    if not hrp then return end

    local totalDamage = 0
    for _, def in WispService.getOwnedWisps(player) do
        totalDamage += def.attackDamage
    end
    if totalDamage <= 0 then return end

    -- Find nearest mob in range
    local bestMob: MobState? = nil
    local bestDist = WISP_ATTACK_RANGE
    for _, mob in activeMobs do
        if mob.health <= 0 then continue end
        if not mob.model.Parent then continue end
        local d = (mob.body.Position - hrp.Position).Magnitude
        if d <= bestDist then
            bestDist = d
            bestMob = mob
        end
    end

    if bestMob then
        applyDamage(bestMob, totalDamage, player)
    end
end

-- Master tick
local aiAccumulator = 0
local spawnAccumulator = 0

local function tick(dt: number)
    aiAccumulator += dt
    spawnAccumulator += dt
    local now = os.clock()

    -- Spawn tick
    if spawnAccumulator >= SPAWN_TICK_INTERVAL then
        spawnAccumulator = 0
        spawnTick()
    end

    -- AI tick
    if aiAccumulator >= AI_TICK_INTERVAL then
        aiAccumulator = 0

        -- Iterate mobs in reverse so we can remove cleanly
        for i = #activeMobs, 1, -1 do
            local mob = activeMobs[i]
            if not mob.model.Parent or mob.health <= 0 then
                table.remove(activeMobs, i)
            else
                aiStep(mob, AI_TICK_INTERVAL)
            end
        end

        -- Wisp attacks
        for _, player in Players:GetPlayers() do
            wispAttackTick(player, now)
        end
    end
end

-- =========================================================================
-- Boss summoning
-- =========================================================================

local activeBossById: { [string]: MobState } = {}
local bossCooldownUntil: { [string]: number } = {}

-- Returns true if the boss was spawned, false if blocked (already alive, on cooldown).
function MobService.summonBoss(mobId: string, position: Vector3): boolean
    local def = MobTypes.get(mobId)
    if not def or not def.isBoss then return false end
    local now = os.clock()
    local cd = bossCooldownUntil[mobId] or 0
    if now < cd then return false end
    if activeBossById[mobId] and activeBossById[mobId].model.Parent and activeBossById[mobId].health > 0 then
        return false
    end

    local model, body, humanoid = buildMobModel(def, position)
    model.Parent = getMobsFolder()

    local mob: MobState = {
        model = model,
        body = body,
        humanoid = humanoid,
        def = def,
        health = def.health,
        targetPlayer = nil,
        nextAttackAt = 0,
        spawnedAt = os.clock(),
        biomeId = def.biome,
        nameplate = nil :: any,
        healthBarFill = nil :: any,
        healthBarText = nil :: any,
    }
    makeNameplate(mob)
    table.insert(activeMobs, mob)
    activeBossById[mobId] = mob

    -- 5 minute cooldown after death before this boss can be summoned again.
    -- (Handled in killMob by reading isBoss on the def.)
    return true
end

-- =========================================================================
-- Public
-- =========================================================================

-- Wire up any ProximityPrompts that summon bosses. The pedestal Part stores
-- which boss + arena position via attributes (set in WorldBuilder).
local function wireBossPrompts()
    -- Initial scan
    local function tryHook(prompt: Instance)
        if not prompt:IsA("ProximityPrompt") then return end
        local pedestal = prompt.Parent
        if not pedestal or not pedestal:IsA("BasePart") then return end
        local bossId = pedestal:GetAttribute("BossId")
        if not bossId then return end

        prompt.Triggered:Connect(function(player)
            local x = pedestal:GetAttribute("ArenaCenterX") or 0
            local y = pedestal:GetAttribute("ArenaCenterY") or 0
            local z = pedestal:GetAttribute("ArenaCenterZ") or 0
            local ok = MobService.summonBoss(bossId, Vector3.new(x, y, z))
            if not ok then
                -- On cooldown / already alive — give the player a quiet ping.
                print(("[MobService] Boss '%s' could not be summoned (alive or cooldown)."):format(bossId))
            end
        end)
    end

    for _, d in Workspace:GetDescendants() do
        tryHook(d)
    end
    Workspace.DescendantAdded:Connect(tryHook)
end

function MobService.start()
    -- Ensure folder exists
    getMobsFolder()

    RunService.Heartbeat:Connect(tick)
    wireBossPrompts()

    Players.PlayerRemoving:Connect(function(p)
        lastWispAttackAt[p] = nil
    end)
end

return MobService
