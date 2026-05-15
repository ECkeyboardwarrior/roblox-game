--!strict
--[[
    WispController.client.lua
    -------------------------
    Renders and animates the local player's wisps. The server tells us *what*
    wisps the player owns (via WispRosterChanged); this script handles the
    *how* — spawning visuals and running per-frame movement on the client.

    Why client-side movement?
      A spring-driven follower for 30+ wisps per player would cost the server
      ~30 * N_players part updates every frame. Doing it on the client means
      each player only pays for their own wisps, and other players don't even
      need to see them (or we can replicate a low-frequency snapshot later).

    Movement model:
      Critically damped spring toward a target offset that orbits the player.
      Each wisp gets a unique phase so the swarm doesn't clump on the same
      point.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local WispTypes = require(Shared:WaitForChild("WispTypes"))

local LocalPlayer = Players.LocalPlayer

type WispInstance = {
    def: any,                 -- WispTypes.WispDefinition
    part: BasePart,
    velocity: Vector3,
    phase: number,            -- per-wisp orbit offset in radians
}

local wisps: { WispInstance } = {}
local container: Folder

local function ensureContainer()
    if container and container.Parent then return container end
    container = Instance.new("Folder")
    container.Name = "LocalWisps"
    container.Parent = workspace
    return container
end

local function makeWispPart(def: any): BasePart
    local p = Instance.new("Part")
    p.Name = "Wisp_" .. def.id
    p.Shape = Enum.PartType.Ball
    p.Size = Vector3.new(0.8, 0.8, 0.8)
    p.Material = Enum.Material.Neon
    p.Color = def.color
    p.Anchored = true        -- IMPORTANT: anchored so physics doesn't fight our movement
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false

    local light = Instance.new("PointLight")
    light.Color = def.color
    light.Range = 8
    light.Brightness = 1.5
    light.Parent = p

    p.Parent = ensureContainer()
    return p
end

local function clearWisps()
    for _, w in wisps do
        if w.part then w.part:Destroy() end
    end
    table.clear(wisps)
end

local function buildWisps(ownedIds: { string })
    clearWisps()
    for i, id in ownedIds do
        local def = WispTypes.get(id)
        if not def then continue end
        table.insert(wisps, {
            def = def,
            part = makeWispPart(def),
            velocity = Vector3.zero,
            phase = (i / math.max(1, #ownedIds)) * math.pi * 2,
        })
    end
end

Remotes.get(Constants.REMOTES.WispRosterChanged).OnClientEvent:Connect(buildWisps)

-- Critically damped spring step. Returns new position + velocity.
-- omega = angular frequency; higher = snappier. zeta = 1 is critically damped.
local function springStep(pos: Vector3, vel: Vector3, target: Vector3, dt: number, omega: number): (Vector3, Vector3)
    local zeta = 1
    local f = 1 + 2 * dt * zeta * omega
    local oo = omega * omega
    local hoo = dt * oo
    local hhoo = dt * hoo
    local detInv = 1 / (f + hhoo)
    local detX = f * pos + dt * vel + hhoo * target
    local detV = vel + hoo * (target - pos)
    return detX * detInv, detV * detInv
end

RunService.Heartbeat:Connect(function(dt: number)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local rootPart = hrp :: BasePart

    local now = os.clock()
    for _, w in wisps do
        -- Orbit target: small ring around the player at shoulder height, plus
        -- a slow bob so they feel alive.
        local angle = w.phase + now * 1.5
        local radius = 3
        local offset = Vector3.new(math.cos(angle) * radius, 2.5 + math.sin(now * 2 + w.phase) * 0.4, math.sin(angle) * radius)
        local target = rootPart.Position + offset

        local newPos, newVel = springStep(w.part.Position, w.velocity, target, dt, math.clamp(w.def.moveSpeed / 6, 4, 12))
        w.part.Position = newPos
        w.velocity = newVel
    end
end)

LocalPlayer.CharacterRemoving:Connect(function()
    -- Reset velocities so wisps don't fling on respawn.
    for _, w in wisps do w.velocity = Vector3.zero end
end)
