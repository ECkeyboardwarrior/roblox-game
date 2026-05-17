--!strict
--[[
    WorldBuilder.lua
    ----------------
    Server-side world generator. On start(), wipes any previous world and
    rebuilds: sky, atmosphere, ground (1500x1500), WorldTree, five biomes
    with their nodes/totems/decor, dense forest carpeting the map, winding
    cobblestone paths from the WorldTree to each biome, cottages near the
    fairy-tale biomes, and ambient fireflies.

    All world construction belongs here. When a future feature adds props
    (mob spawners, NPCs, quest shrines), add a builder section + call from
    start().

    Public API:
      .start()
]]

local Workspace = game:GetService("Workspace")
local Lighting  = game:GetService("Lighting")

local WorldBuilder = {}

-- =========================================================================
-- World dimensions
-- =========================================================================

local MAP_HALF = 720          -- ground extends ±720 studs on X/Z
local GROUND_THICKNESS = 4

-- =========================================================================
-- Forest tuning — change these to adjust density without hunting through code
-- =========================================================================
local FOREST_ENABLED = true        -- master kill-switch; set false to skip forest entirely
local FOREST_GROVE_TARGET = 30     -- number of grove clusters across the map
local FOREST_WANDERER_TARGET = 80  -- individual scatter trees
local FOREST_CLUTTER_TARGET = 200  -- bushes / logs / rocks
local FOREST_BIOME_MARGIN = 55     -- studs trees must stay outside biome perimeter
local FOREST_PATH_CLEAR = 18       -- studs corridor along paths
local FOREST_TEMPLATE_SCALE_MIN = 0.4  -- imported toolbox trees can be huge — shrink them
local FOREST_TEMPLATE_SCALE_MAX = 0.7

-- =========================================================================
-- Clearings — locations that must stay free of trees/clutter so players can
-- walk and interact (spawn plaza, cottage doorways, boss dens, shop NPCs, etc.)
-- =========================================================================

type Clearing = { center: Vector3, radius: number }

local clearings: { Clearing } = {}

local function resetClearings()
    table.clear(clearings)
end

local function addClearing(center: Vector3, radius: number)
    -- Store as Y=0 since scatter checks 2D distance.
    table.insert(clearings, { center = Vector3.new(center.X, 0, center.Z), radius = radius })
end

-- True if `pos` is within ANY clearing's radius.
local function inAnyClearing(pos: Vector3): boolean
    for _, c in clearings do
        local dx = pos.X - c.center.X
        local dz = pos.Z - c.center.Z
        if dx * dx + dz * dz < c.radius * c.radius then return true end
    end
    return false
end

-- =========================================================================
-- Biome catalog
-- =========================================================================

type Biome = {
    id: string,
    displayName: string,
    center: Vector3,
    radius: number,
    nodeCount: number,
    nodeColor: Color3,
    nodeMaterial: Enum.Material,
    nodeShape: Enum.PartType,
    nodeSize: Vector3,
    requiredWisps: number,
    essenceMultiplier: number,
    groundColor: Color3,
    decorStyle: "glimmer" | "verdant" | "ember" | "whispering" | "frostpeak",
    hasCottage: boolean,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BIOMES: { Biome } = require(ReplicatedStorage.Shared.BiomeRegistry) :: any

-- =========================================================================
-- Helpers
-- =========================================================================

local function rngOf(seed: number): Random
    return Random.new(seed)
end

local function destroyIfExists(name: string)
    local existing = Workspace:FindFirstChild(name)
    if existing then existing:Destroy() end
end

local function distanceToAnyBiome(pos: Vector3): (number, Biome?)
    local best = math.huge
    local nearestBiome = nil
    for _, b in BIOMES do
        local d = (Vector3.new(pos.X, b.center.Y, pos.Z) - b.center).Magnitude
        if d < best then
            best = d
            nearestBiome = b
        end
    end
    return best, nearestBiome
end

-- =========================================================================
-- Lighting / Sky / Atmosphere (initial state; DayNightService takes over after)
-- =========================================================================

local function configureLighting()
    Lighting.ClockTime = 7
    Lighting.GeographicLatitude = 41
    Lighting.ExposureCompensation = 0.1
    Lighting.Brightness = 1.6
    Lighting.GlobalShadows = true
    Lighting.ShadowSoftness = 0.5
    Lighting.EnvironmentDiffuseScale = 0.5
    Lighting.EnvironmentSpecularScale = 0.5
end

local function makeAtmosphere()
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
    atmosphere.Density = 0.35
    atmosphere.Offset = 0.2
    atmosphere.Color = Color3.fromRGB(180, 190, 210)
    atmosphere.Decay = Color3.fromRGB(100, 110, 140)
    atmosphere.Glare = 0.1
    atmosphere.Haze = 1.2
    atmosphere.Parent = Lighting
end

local function makeSky()
    local existing = Lighting:FindFirstChildOfClass("Sky")
    if existing then existing:Destroy() end
    local sky = Instance.new("Sky")
    sky.StarCount = 3000
    sky.SunAngularSize = 18
    sky.MoonAngularSize = 14
    sky.CelestialBodiesShown = true
    sky.Parent = Lighting
end

-- =========================================================================
-- Spawn — sits at the edge of the WorldTree plaza so players never spawn
-- inside the trunk. Default Roblox SpawnLocation behavior: players randomly
-- spawn ON any SpawnLocation, so we make exactly one.
-- =========================================================================

local function makeSpawn()
    -- Remove any prior SpawnLocations (including the default one).
    for _, s in Workspace:GetDescendants() do
        if s:IsA("SpawnLocation") then s:Destroy() end
    end

    local spawnPos = Vector3.new(0, 4, 30)  -- 30 studs south of WorldTree
    local pad = Instance.new("SpawnLocation")
    pad.Name = "SpiritGroveSpawn"
    pad.Anchored = true
    pad.CanCollide = true
    pad.Size = Vector3.new(12, 1, 12)
    pad.Position = spawnPos
    pad.Material = Enum.Material.Cobblestone
    pad.Color = Color3.fromRGB(140, 130, 110)
    pad.TopSurface = Enum.SurfaceType.Smooth
    pad.BottomSurface = Enum.SurfaceType.Smooth
    -- Prevent the default leaderboard team color from tinting it.
    pad.Neutral = true
    -- No "you are here" SpawnLocation glow ring.
    pad.Enabled = true

    -- Decorative ring of light around the pad
    local ring = Instance.new("Part")
    ring.Anchored = true
    ring.CanCollide = false
    ring.Shape = Enum.PartType.Cylinder
    ring.Size = Vector3.new(0.3, 16, 16)
    ring.Orientation = Vector3.new(0, 0, 90)
    ring.Position = spawnPos + Vector3.new(0, 0.7, 0)
    ring.Material = Enum.Material.Neon
    ring.Color = Color3.fromRGB(180, 240, 255)
    ring.Transparency = 0.3
    ring.CastShadow = false
    ring.Parent = Workspace

    pad.Parent = Workspace

    -- Critical: reserve a big clear area around spawn so terrain hills,
    -- trees, and clutter can't bury players when they land. Generous radius
    -- because imported tree models have huge canopies that overhang their
    -- trunks by 15-25 studs.
    addClearing(spawnPos, 80)

    return pad
end

-- =========================================================================
-- Ground
-- =========================================================================

local function makeGround(): Folder
    destroyIfExists("Baseplate")
    destroyIfExists("Ground")

    local folder = Instance.new("Folder")
    folder.Name = "Ground"

    local ground = Instance.new("Part")
    ground.Name = "MainGround"
    ground.Anchored = true
    ground.CanCollide = true
    ground.Size = Vector3.new(MAP_HALF * 2 + 200, GROUND_THICKNESS, MAP_HALF * 2 + 200)
    ground.Position = Vector3.new(0, 0, 0)
    ground.Material = Enum.Material.Grass
    ground.Color = Color3.fromRGB(70, 100, 65)
    ground.TopSurface = Enum.SurfaceType.Smooth
    ground.BottomSurface = Enum.SurfaceType.Smooth
    ground.Parent = folder

    folder.Parent = Workspace
    return folder
end

-- =========================================================================
-- Landscape: Terrain hills + dirt/mud patches across the open ground.
-- Avoids biome interiors, paths, and named clearings (spawn, cottages, den).
-- Designed to add elevation + material variety so the floor isn't a flat
-- carpet of grass.
-- =========================================================================

local function makeLandscape(pathPositions: { Vector3 })
    local terrain = Workspace.Terrain

    -- Helper: is this candidate position safe to modify?
    -- Excludes biome interiors (+ buffer), paths, clearings, and a wider zone
    -- around the WorldTree clearing.
    local function isLandscapableSpot(pos: Vector3, hillRadius: number): boolean
        local nearBiomeDist, nearestBiome = distanceToAnyBiome(pos)
        if nearestBiome and nearBiomeDist < nearestBiome.radius + hillRadius + 6 then
            return false
        end
        if inAnyClearing(pos) then return false end
        -- Path proximity
        for _, tilePos in pathPositions do
            local dx = pos.X - tilePos.X
            local dz = pos.Z - tilePos.Z
            if dx * dx + dz * dz < (hillRadius + 6) * (hillRadius + 6) then
                return false
            end
        end
        return true
    end

    local rng = rngOf(4242)  -- different seed so hills don't align with forest

    -- ---------- Grass hills ----------
    -- Hills are domes, not balls — center is BELOW ground so the top bulges
    -- only ~r * 0.4 studs above the floor. Max visible height ~8 studs.
    local hillsPlaced = 0
    for _ = 1, 100 do
        if hillsPlaced >= 30 then break end
        local x = rng:NextNumber(-MAP_HALF + 50, MAP_HALF - 50)
        local z = rng:NextNumber(-MAP_HALF + 50, MAP_HALF - 50)
        local r = rng:NextNumber(8, 16)
        local pos = Vector3.new(x, 0, z)
        if not isLandscapableSpot(pos, r) then continue end

        -- Sink the ball half its radius below ground -> visible dome only.
        local centerY = -r * 0.55
        terrain:FillBall(Vector3.new(x, centerY, z), r, Enum.Material.Grass)
        -- Subtle LeafyGrass cap for variety on larger hills
        if r > 13 then
            terrain:FillBall(Vector3.new(x, centerY + r * 0.65, z), r * 0.5, Enum.Material.LeafyGrass)
        end
        hillsPlaced += 1
    end

    -- ---------- Dirt / mud patches ----------
    local patches = 0
    for _ = 1, 60 do
        if patches >= 25 then break end
        local x = rng:NextNumber(-MAP_HALF + 30, MAP_HALF - 30)
        local z = rng:NextNumber(-MAP_HALF + 30, MAP_HALF - 30)
        local r = rng:NextNumber(8, 16)
        local pos = Vector3.new(x, 0, z)
        if not isLandscapableSpot(pos, r) then continue end

        -- Low, flat patches just at ground level.
        local material = (rng:NextNumber() < 0.6) and Enum.Material.Ground or Enum.Material.Mud
        terrain:FillCylinder(CFrame.new(x, 1.5, z), 1.6, r, material)
        patches += 1
    end

    -- ---------- A few small sand spots near origin (path-adjacent feel) ----------
    for _ = 1, 8 do
        local x = rng:NextNumber(-90, 90)
        local z = rng:NextNumber(-90, 90)
        if Vector3.new(x, 0, z).Magnitude < 70 then continue end
        local pos = Vector3.new(x, 0, z)
        if not isLandscapableSpot(pos, 6) then continue end
        terrain:FillCylinder(CFrame.new(x, 1.4, z), 1.2, rng:NextNumber(4, 7), Enum.Material.Sand)
    end

    print(("[WorldBuilder] Landscape: %d hills, %d ground patches."):format(hillsPlaced, patches))
end

local function makeBiomeGroundPatch(biome: Biome, parent: Instance)
    local patch = Instance.new("Part")
    patch.Name = string.format("%sGround", biome.displayName:gsub(" ", ""))
    patch.Anchored = true
    patch.CanCollide = false
    patch.Shape = Enum.PartType.Cylinder
    patch.Size = Vector3.new(0.5, biome.radius * 2.3, biome.radius * 2.3)
    patch.Orientation = Vector3.new(0, 0, 90)
    patch.Position = Vector3.new(biome.center.X, 2.2, biome.center.Z)
    patch.Material = (biome.decorStyle == "frostpeak") and Enum.Material.Sand or Enum.Material.Grass
    patch.Color = biome.groundColor
    patch.CastShadow = false
    patch.Parent = parent
end

-- =========================================================================
-- WorldTree v2
-- =========================================================================

local function makeWorldTree(): Model
    destroyIfExists("WorldTree")
    local model = Instance.new("Model")
    model.Name = "WorldTree"

    local rng = Random.new(1234) -- deterministic for the tree

    -- Core Trunk
    local trunkHeight = 70
    local trunkRadius = 11
    
    local trunk = Instance.new("Part")
    trunk.Name = "Trunk"
    trunk.Anchored = true
    trunk.CanCollide = true
    trunk.Shape = Enum.PartType.Cylinder
    trunk.Size = Vector3.new(trunkHeight, trunkRadius * 2, trunkRadius * 2)
    trunk.Position = Vector3.new(0, trunkHeight / 2, 0)
    trunk.Orientation = Vector3.new(0, 0, 90)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(75, 50, 35)
    trunk.Parent = model

    -- Bark Ridges & Knots
    local ridgeCount = 14
    for i = 1, ridgeCount do
        if i == 1 or i == ridgeCount then continue end
        
        local angle = (i / ridgeCount) * math.pi * 2
        local ridge = Instance.new("Part")
        ridge.Anchored = true
        ridge.CanCollide = true
        ridge.Shape = Enum.PartType.Cylinder
        local height = rng:NextNumber(trunkHeight * 0.5, trunkHeight * 0.95)
        local thick = rng:NextNumber(3, 6)
        ridge.Size = Vector3.new(height, thick, thick)
        local leanAngle = rng:NextNumber(2, 6)
        
        local r = trunkRadius - 1
        ridge.Position = Vector3.new(math.cos(angle) * r, height / 2, math.sin(angle) * r)
        ridge.Orientation = Vector3.new(math.deg(-leanAngle), math.deg(-angle), 90)
        ridge.Material = Enum.Material.Wood
        ridge.Color = Color3.fromRGB(70, 45, 30)
        ridge.Parent = model
        -- Knots removed for a cleaner trunk silhouette.
    end

    -- Fractal Roots
    local function createRoot(cframe: CFrame, size: Vector3, iterations: number)
        if iterations <= 0 then return end
        
        local rootPart = Instance.new("Part")
        rootPart.Anchored = true
        rootPart.CanCollide = true
        rootPart.Shape = Enum.PartType.Cylinder
        rootPart.Size = size
        rootPart.CFrame = cframe
        rootPart.Material = Enum.Material.Wood
        rootPart.Color = Color3.fromRGB(65, 40, 25)
        rootPart.Parent = model

        for j = 1, 2 do
            local newSize = Vector3.new(size.X * rng:NextNumber(0.6, 0.8), size.Y * 0.7, size.Z * 0.7)
            local pitch = math.rad(rng:NextNumber(5, 25)) -- bend downwards into ground
            local yaw = math.rad(rng:NextNumber(-30, 30))
            if j == 1 then yaw = math.rad(rng:NextNumber(15, 40)) else yaw = math.rad(rng:NextNumber(-40, -15)) end
            
            local nextCFrame = cframe * CFrame.new(size.X/2, 0, 0) * CFrame.Angles(0, yaw, -pitch) * CFrame.new(newSize.X/2, 0, 0)
            createRoot(nextCFrame, newSize, iterations - 1)
        end
    end

    for i = 1, 10 do
        local angle = (i / 10) * math.pi * 2
        local rAngle = angle + rng:NextNumber(-0.1, 0.1)
        local baseCFrame = CFrame.new(Vector3.new(math.cos(rAngle) * 10, 1.5, math.sin(rAngle) * 10)) * CFrame.Angles(0, -rAngle, 0) * CFrame.Angles(0, 0, 0)
        createRoot(baseCFrame, Vector3.new(rng:NextNumber(12, 18), 6, 6), 3)
    end

    -- All face details (mouth, nose, mustache, eyes, eyebrows) removed.
    -- The trunk is just clean wood now — the canopy below + the floating
    -- motes are the visual focus of the World Tree.

    -- Leaf Cluster Generator
    local function makeLeafCluster(cframe: CFrame, radius: number)
        local clusterCount = math.random(4, 7)
        local baseColor = Color3.fromRGB(110, 200, 120)
        
        for i = 1, clusterCount do
            local leaf = Instance.new("Part")
            leaf.Anchored = true
            leaf.CanCollide = false
            leaf.Shape = Enum.PartType.Ball
            
            local s = rng:NextNumber(radius * 0.6, radius * 1.2)
            leaf.Size = Vector3.new(s, s, s)
            
            local offset = Vector3.new(
                rng:NextNumber(-radius*0.4, radius*0.4),
                rng:NextNumber(-radius*0.2, radius*0.5),
                rng:NextNumber(-radius*0.4, radius*0.4)
            )
            leaf.CFrame = cframe * CFrame.new(offset)
            
            local jitter = rng:NextInteger(-15, 15)
            leaf.Color = Color3.fromRGB(
                math.clamp(baseColor.R*255 + jitter, 0, 255),
                math.clamp(baseColor.G*255 + jitter, 0, 255),
                math.clamp(baseColor.B*255 + jitter, 0, 255)
            )
            leaf.Material = Enum.Material.LeafyGrass
            leaf.CastShadow = false
            leaf.Parent = model
        end
    end

    -- Fractal Canopy Branches
    local function createCanopyBranch(cframe: CFrame, size: Vector3, iterations: number)
        if iterations <= 0 then
            makeLeafCluster(cframe, size.X * 2.5)
            return
        end
        
        local branch = Instance.new("Part")
        branch.Anchored = true
        branch.CanCollide = true
        branch.Shape = Enum.PartType.Cylinder
        branch.Size = size
        branch.CFrame = cframe
        branch.Material = Enum.Material.Wood
        branch.Color = Color3.fromRGB(70, 45, 30)
        branch.Parent = model

        for j = 1, 2 do
            local newSize = Vector3.new(size.X * rng:NextNumber(0.6, 0.8), size.Y * 0.7, size.Z * 0.7)
            local pitch = math.rad(rng:NextNumber(-10, 30)) -- curve upwards
            local yaw = math.rad(rng:NextNumber(-45, 45))
            if j == 1 then yaw = math.rad(rng:NextNumber(20, 50)) else yaw = math.rad(rng:NextNumber(-50, -20)) end
            
            local nextCFrame = cframe * CFrame.new(size.X/2, 0, 0) * CFrame.Angles(0, yaw, pitch) * CFrame.new(newSize.X/2, 0, 0)
            createCanopyBranch(nextCFrame, newSize, iterations - 1)
        end
        
        if rng:NextNumber() < 0.4 then
            makeLeafCluster(cframe * CFrame.new(size.X/4, 0, 0), size.X * 1.5)
        end
    end

    for i = 1, 6 do
        local angle = (i / 6) * math.pi * 2
        local baseCFrame = CFrame.new(Vector3.new(math.cos(angle) * 8, trunkHeight - 8, math.sin(angle) * 8)) * CFrame.Angles(0, -angle, math.rad(45))
        createCanopyBranch(baseCFrame, Vector3.new(28, 6, 6), 4)
    end
    
    makeLeafCluster(CFrame.new(0, trunkHeight + 5, 0), 25)

    -- Motes (ambient fireflies)
    for i = 1, 30 do
        local mote = Instance.new("Part")
        mote.Anchored = true
        mote.CanCollide = false
        mote.CanQuery = false
        mote.Shape = Enum.PartType.Ball
        mote.Size = Vector3.new(1.2, 1.2, 1.2)
        mote.Material = Enum.Material.Neon
        mote.Color = Color3.fromRGB(220, 255, 200)
        local theta = (i / 30) * math.pi * 2
        local r = rng:NextNumber(25, 45)
        mote.Position = Vector3.new(math.cos(theta) * r, trunkHeight + math.sin(theta * 1.7) * 8 + rng:NextNumber(-5, 15), math.sin(theta) * r)
        mote.CastShadow = false
        local pl = Instance.new("PointLight")
        pl.Color = mote.Color
        pl.Range = 14
        pl.Brightness = 1.8
        pl.Parent = mote
        mote.Parent = model
    end

    local baseLight = Instance.new("PointLight")
    baseLight.Color = Color3.fromRGB(180, 255, 200)
    baseLight.Range = 65
    baseLight.Brightness = 3
    baseLight.Parent = trunk

    local attach = Instance.new("Attachment")
    attach.Position = Vector3.new(0, 8, 0)
    attach.Parent = trunk
    local emitter = Instance.new("ParticleEmitter")
    emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    emitter.Color = ColorSequence.new(Color3.fromRGB(200, 255, 210))
    emitter.Lifetime = NumberRange.new(2, 4)
    emitter.Rate = 14
    emitter.Speed = NumberRange.new(0.5, 2)
    emitter.Size = NumberSequence.new(0.8)
    emitter.LightEmission = 0.8
    emitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 1),
    })
    emitter.Parent = attach

    model.PrimaryPart = trunk
    model.Parent = Workspace

    -- Big clear plaza around the World Tree so players have room to gather,
    -- access the deposit prompt, browse the shop, and chat with NPCs.
    -- Generous radius accounts for imported tree canopies that overhang.
    addClearing(Vector3.new(0, 0, 0), 90)

    return model
end

-- =========================================================================
-- Tree variants — used by forest scattering and biome decor
-- =========================================================================

local function tintLeaves(base: Color3, rng: Random): Color3
    -- ±15 RGB jitter per channel for organic forest variation.
    local function jitter(c: number) return math.clamp(c + rng:NextInteger(-15, 15), 0, 255) end
    return Color3.fromRGB(jitter(base.R * 255), jitter(base.G * 255), jitter(base.B * 255))
end

local function createBranch(cframe: CFrame, size: Vector3, iterations: number, parent: Instance, rng: Random, woodColor: Color3, leafColor: Color3?, leafMaterial: Enum.Material?, woodMaterial: Enum.Material?)
    if iterations <= 0 then return end
    
    local branch = Instance.new("Part")
    branch.Size = size
    branch.Anchored = true
    branch.CanCollide = false
    branch.CFrame = cframe
    branch.Material = woodMaterial or Enum.Material.Wood
    branch.Color = woodColor
    branch.CastShadow = true
    branch.Parent = parent

    -- Attach leaves to the ends of branches if requested
    if iterations == 1 and leafColor then
        local leaves = Instance.new("Part")
        leaves.Shape = Enum.PartType.Ball
        leaves.Size = Vector3.new(size.Y * 1.8, size.Y * 1.8, size.Y * 1.8)
        leaves.CFrame = cframe * CFrame.new(0, size.Y/2, 0)
        leaves.Color = tintLeaves(leafColor, rng)
        leaves.Material = leafMaterial or Enum.Material.LeafyGrass
        leaves.Anchored = true
        leaves.CanCollide = false
        leaves.Parent = parent
    end

    -- Recursive call for new branches
    for i = 1, 2 do
        local newSize = size * 0.7
        
        -- Generate random angles to split the branch
        local angleX = math.rad(rng:NextNumber(-20, 20))
        local angleY = math.rad(rng:NextNumber(-45, 45))
        local angleZ
        if i == 1 then
            angleZ = math.rad(rng:NextNumber(15, 35))
        else
            angleZ = math.rad(rng:NextNumber(-35, -15))
        end
        
        local nextCFrame = cframe * CFrame.new(0, size.Y/2, 0) * CFrame.Angles(angleX, angleY, angleZ) * CFrame.new(0, newSize.Y/2, 0)
        createBranch(nextCFrame, newSize, iterations - 1, parent, rng, woodColor, leafColor, leafMaterial, woodMaterial)
    end
end

local function makeOakTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local baseCFrame = CFrame.new(position + Vector3.new(0, 4.5 * scale, 0))
    local baseSize = Vector3.new(2 * scale, 9 * scale, 2 * scale)
    createBranch(baseCFrame, baseSize, 4, parent, rng, Color3.fromRGB(68, 48, 35), Color3.fromRGB(75, 130, 70))
end

local function makePineTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local baseCFrame = CFrame.new(position + Vector3.new(0, 4 * scale, 0))
    local baseSize = Vector3.new(1.4 * scale, 8 * scale, 1.4 * scale)
    createBranch(baseCFrame, baseSize, 5, parent, rng, Color3.fromRGB(55, 38, 28), Color3.fromRGB(40, 75, 45))
end

local function makeWillowTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local baseCFrame = CFrame.new(position + Vector3.new(0, 5 * scale, 0))
    local baseSize = Vector3.new(2.2 * scale, 10 * scale, 2.2 * scale)
    createBranch(baseCFrame, baseSize, 4, parent, rng, Color3.fromRGB(60, 50, 40), Color3.fromRGB(90, 140, 95))
end

local function makeAspenTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local baseCFrame = CFrame.new(position + Vector3.new(0, 7 * scale, 0))
    local baseSize = Vector3.new(1.2 * scale, 14 * scale, 1.2 * scale)
    createBranch(baseCFrame, baseSize, 4, parent, rng, Color3.fromRGB(210, 210, 200), Color3.fromRGB(130, 220, 140), Enum.Material.LeafyGrass, Enum.Material.WoodPlanks)
end

local function makeBareTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local baseCFrame = CFrame.new(position + Vector3.new(0, 5.5 * scale, 0))
    local baseSize = Vector3.new(1.6 * scale, 11 * scale, 1.6 * scale)
    createBranch(baseCFrame, baseSize, 4, parent, rng, Color3.fromRGB(38, 30, 25))
end

local function makeSnowPine(position: Vector3, scale: number, parent: Instance)
    local rng = Random.new()
    local baseCFrame = CFrame.new(position + Vector3.new(0, 4 * scale, 0))
    local baseSize = Vector3.new(1.4 * scale, 8 * scale, 1.4 * scale)
    createBranch(baseCFrame, baseSize, 5, parent, rng, Color3.fromRGB(60, 40, 30), Color3.fromRGB(225, 235, 245), Enum.Material.Snow)
end

-- =========================================================================
-- Forest scattering — denser, mixed
-- =========================================================================

-- A small leafy bush, made of 3-5 overlapping spheres. Used to fill the
-- ground layer between trees and break up "flat carpet of grass" syndrome.
local function makeBush(position: Vector3, parent: Instance, rng: Random)
    local count = rng:NextInteger(3, 5)
    local baseColor = Color3.fromRGB(60, 110, 55)
    local model = Instance.new("Model")
    model.Name = "Bush"
    for i = 1, count do
        local ball = Instance.new("Part")
        ball.Anchored = true
        ball.CanCollide = false
        ball.Shape = Enum.PartType.Ball
        local s = rng:NextNumber(1.6, 2.6)
        ball.Size = Vector3.new(s, s * 0.85, s)
        ball.Position = position + Vector3.new(
            rng:NextNumber(-1, 1),
            s * 0.4 + rng:NextNumber(-0.2, 0.4),
            rng:NextNumber(-1, 1)
        )
        ball.Material = Enum.Material.LeafyGrass
        ball.Color = tintLeaves(baseColor, rng)
        ball.CastShadow = false
        ball.Parent = model
    end
    model.Parent = parent
end

-- A horizontal mossy log. Slightly random rotation so they don't all align.
local function makeFallenLog(position: Vector3, parent: Instance, rng: Random)
    local length = rng:NextNumber(7, 12)
    local thickness = rng:NextNumber(1.4, 2.2)
    local model = Instance.new("Model")
    model.Name = "FallenLog"

    local log = Instance.new("Part")
    log.Anchored = true
    log.CanCollide = false  -- walkable; visual only
    log.Shape = Enum.PartType.Cylinder
    log.Size = Vector3.new(length, thickness, thickness)
    log.Position = position + Vector3.new(0, thickness / 2, 0)
    log.Orientation = Vector3.new(0, rng:NextNumber(0, 360), 0)
    log.Material = Enum.Material.Wood
    log.Color = Color3.fromRGB(70, 50, 38)
    log.Parent = model

    -- Two patches of moss on top
    for i = 1, 2 do
        local moss = Instance.new("Part")
        moss.Anchored = true
        moss.CanCollide = false
        moss.Shape = Enum.PartType.Ball
        local s = thickness * rng:NextNumber(1.0, 1.4)
        moss.Size = Vector3.new(s, s * 0.4, s * 0.8)
        local along = rng:NextNumber(-length * 0.35, length * 0.35)
        local localOffset = Vector3.new(along, thickness * 0.6, 0)
        moss.CFrame = log.CFrame * CFrame.new(localOffset)
        moss.Material = Enum.Material.Grass
        moss.Color = Color3.fromRGB(70, 130, 60)
        moss.CastShadow = false
        moss.Parent = model
    end

    model.Parent = parent
end

-- A pile of dark rocks for ground variety. Cheap (1-3 parts).
local function makeRockPile(position: Vector3, parent: Instance, rng: Random)
    local count = rng:NextInteger(1, 3)
    for i = 1, count do
        local rock = Instance.new("Part")
        rock.Anchored = true
        rock.CanCollide = true
        local s = rng:NextNumber(1.5, 3)
        rock.Size = Vector3.new(s, s * 0.6, s)
        rock.Position = position + Vector3.new(
            rng:NextNumber(-1.5, 1.5),
            s * 0.3,
            rng:NextNumber(-1.5, 1.5)
        )
        rock.Orientation = Vector3.new(rng:NextNumber(-15, 15), rng:NextNumber(0, 360), rng:NextNumber(-15, 15))
        rock.Material = Enum.Material.Slate
        rock.Color = Color3.fromRGB(60, 65, 75)
        rock.CastShadow = false
        rock.Parent = parent
    end
end

-- Tree-species roll, biased by which biome the position is closest to.
-- Returns a function that places a tree at a given position.
local function pickTreeBuilder(nearestBiome: Biome?, rng: Random)
    local style = nearestBiome and nearestBiome.decorStyle or "default"
    local roll = rng:NextNumber()

    if style == "whispering" then
        -- Dense pines + willows for the enchanted-forest feel.
        if roll < 0.45 then return makePineTree
        elseif roll < 0.75 then return makeWillowTree
        elseif roll < 0.9 then return makeOakTree
        else return makeBareTree end

    elseif style == "ember" then
        -- Mostly dead/bare trees, a few clinging pines.
        if roll < 0.7 then return makeBareTree
        elseif roll < 0.9 then return makePineTree
        else return makeOakTree end

    elseif style == "frostpeak" then
        -- Snow pines dominant, some bare trees clinging to the cold.
        if roll < 0.7 then return makeSnowPine
        elseif roll < 0.9 then return makePineTree
        else return makeBareTree end

    elseif style == "verdant" then
        -- Lush deciduous mix.
        if roll < 0.4 then return makeOakTree
        elseif roll < 0.7 then return makeAspenTree
        elseif roll < 0.9 then return makeWillowTree
        else return makePineTree end

    else  -- glimmer / default
        if roll < 0.35 then return makeOakTree
        elseif roll < 0.65 then return makePineTree
        elseif roll < 0.85 then return makeWillowTree
        else return makeAspenTree end
    end
end

-- =========================================================================
-- Template sanitizer
-- =========================================================================
-- Toolbox models often contain Scripts, Sounds, Decals, and other assets
-- that reference asset IDs the user doesn't own. These error out on load with
-- messages like "lacking capability LoadUnownedAsset" or "The experience
-- doesn't have access permission to use asset id". We don't need any of these
-- for static world decor — strip them so the model loads cleanly.
local function sanitizeTemplate(inst: Instance)
    local toKill = {}
    for _, d in inst:GetDescendants() do
        -- Scripts (could try to load external modules)
        if d:IsA("BaseScript") or d:IsA("ModuleScript") then
            table.insert(toKill, d)
        -- Sounds (often reference asset IDs the user doesn't own)
        elseif d:IsA("Sound") then
            table.insert(toKill, d)
        -- Animations / track refs (also asset-ID based)
        elseif d:IsA("Animation") or d:IsA("AnimationController") or d:IsA("Animator") then
            table.insert(toKill, d)
        end
    end
    for _, s in toKill do
        s:Destroy()
    end

    -- Also strip unowned-asset Decal/Texture references (replace with blank).
    -- We don't destroy these because the parent Part may rely on their presence;
    -- we just null out their Texture so they don't try to fetch a forbidden ID.
    for _, d in inst:GetDescendants() do
        if d:IsA("Decal") or d:IsA("Texture") then
            -- Texture URLs that start with rbxasset:// are bundled with Roblox
            -- and always safe; anything else (rbxassetid://, content://) might
            -- be unowned. Safer to wipe.
            local t = d.Texture
            if t and not string.find(t, "rbxasset://") then
                d.Texture = ""
            end
        elseif d:IsA("MeshPart") then
            -- MeshPart's TextureID can also be unowned; clear if it's an ID.
            local tid = d.TextureID
            if tid and tid ~= "" and not string.find(tid, "rbxasset://") then
                d.TextureID = ""
            end
        end
    end
end

-- =========================================================================
-- Template-based tree spawning (ServerStorage.TreeTemplates)
-- =========================================================================
-- If the user has populated ServerStorage.TreeTemplates with Toolbox tree
-- models, we'll use those instead of procedural Parts. Folder layout:
--   ServerStorage/TreeTemplates/
--     Glimmer/      (any Models or Parts — randomized per spawn)
--     Verdant/
--     Whispering/
--     Ember/
--     Frostpeak/
--     Default/      (used when no biome-specific folder exists)
--
-- If no Default and no biome folder exists, falls back to procedural builders.

local function findTemplatesForBiome(biome: Biome?): { Instance }?
    local ServerStorage = game:GetService("ServerStorage")
    local templatesRoot = ServerStorage:FindFirstChild("TreeTemplates")
    if not templatesRoot then return nil end

    -- Map decorStyle -> folder name (PascalCase)
    local map = {
        glimmer    = "Glimmer",
        verdant    = "Verdant",
        whispering = "Whispering",
        ember      = "Ember",
        frostpeak  = "Frostpeak",
    }
    local style = biome and biome.decorStyle or nil
    local folderName = style and map[style] or "Default"

    local folder = templatesRoot:FindFirstChild(folderName)
        or templatesRoot:FindFirstChild("Default")
    if folder then
        local children = folder:GetChildren()
        if #children > 0 then return children end
    end

    -- If no sub-folders at all, treat the root as flat templates.
    local flat = templatesRoot:GetChildren()
    if #flat > 0 then
        -- Filter out sub-folders so we don't try to clone an empty folder
        local out = {}
        for _, c in flat do
            if not c:IsA("Folder") then table.insert(out, c) end
        end
        if #out > 0 then return out end
    end

    return nil
end

local function placeTemplateTree(templates: { Instance }, pos: Vector3, _scale: number, parent: Instance, rng: Random)
    local template = templates[rng:NextInteger(1, #templates)]
    local clone = template:Clone()
    sanitizeTemplate(clone)
    local rotY = math.rad(rng:NextNumber(0, 360))
    clone:PivotTo(CFrame.new(pos) * CFrame.Angles(0, rotY, 0))
    if clone:IsA("Model") then
        -- Toolbox tree models vary wildly in size — clamp to a sane range so
        -- one giant template doesn't dominate the map.
        local s = rng:NextNumber(FOREST_TEMPLATE_SCALE_MIN, FOREST_TEMPLATE_SCALE_MAX)
        pcall(function() clone:ScaleTo(s) end)
    end
    clone.Parent = parent
end

-- =========================================================================
-- Raycast helper for accurate ground placement
-- =========================================================================
local function groundedPosition(x: number, z: number): Vector3?
    local origin = Vector3.new(x, 500, z)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    -- Skip the WorldDecor folder so we don't pile trees on existing trees.
    local decorFolder = Workspace:FindFirstChild("WorldDecor")
    params.FilterDescendantsInstances = decorFolder and { decorFolder } or {}
    params.IgnoreWater = true
    local result = Workspace:Raycast(origin, Vector3.new(0, -1000, 0), params)
    if not result then return nil end
    return result.Position
end

local function scatterForest(parent: Instance, rng: Random, pathPositions: { Vector3 })
    -- Heavy three-pass scatter:
    --   1. Groves: ~120 cluster centers, each with 5-8 closely-packed trees.
    --   2. Wanderers: ~500 individually-scattered trees filling the gaps.
    --   3. Ground clutter: ~600 bushes/logs/rocks.
    --
    -- Exclusion checks: biome interiors (+ margin), WorldTree clearing, and
    -- a corridor (~5 studs) around every path tile so paths stay walkable.

    local PATH_CLEAR_RADIUS = FOREST_PATH_CLEAR
    local PATH_CLEAR_SQ = PATH_CLEAR_RADIUS * PATH_CLEAR_RADIUS

    local function clearOfPath(pos: Vector3): boolean
        for _, tilePos in pathPositions do
            local dx = pos.X - tilePos.X
            local dz = pos.Z - tilePos.Z
            if dx * dx + dz * dz < PATH_CLEAR_SQ then return false end
        end
        return true
    end

    local function tryPick(margin: number): (Vector3?, Biome?)
        local x = rng:NextNumber(-MAP_HALF, MAP_HALF)
        local z = rng:NextNumber(-MAP_HALF, MAP_HALF)
        local pos = Vector3.new(x, 2, z)
        local nearBiomeDist, nearestBiome = distanceToAnyBiome(pos)
        if nearestBiome and nearBiomeDist < nearestBiome.radius + margin then return nil, nil end
        if inAnyClearing(pos) then return nil, nil end       -- spawn, cottages, boss den, etc.
        if not clearOfPath(pos) then return nil, nil end
        return pos, nearestBiome
    end

    -- Optional: use raycast to snap Y to actual ground height (handles terrain
    -- slopes once trees-on-mountains becomes a thing). Disabled by default since
    -- our ground is flat and raycasting 1000+ times slows the build.
    local USE_RAYCAST = false
    local function groundY(x: number, z: number): number
        if USE_RAYCAST then
            local g = groundedPosition(x, z)
            if g then return g.Y end
        end
        return 2  -- flat-ground fallback (matches MainGround top surface)
    end

    -- Snow pine handler closure: makeSnowPine has a different signature (no rng arg).
    -- Wrapped in pcall so one bad tree builder doesn't kill the whole forest pass.
    local builderNames = {
        [makeOakTree] = "Oak",
        [makePineTree] = "Pine",
        [makeWillowTree] = "Willow",
        [makeAspenTree] = "Aspen",
        [makeBareTree] = "Bare",
        [makeSnowPine] = "SnowPine",
    }
    local errorReported: { [string]: boolean } = {}
    local function placeProceduralTree(builder: any, pos: Vector3, scale: number)
        local ok, err
        if builder == makeSnowPine then
            ok, err = pcall(makeSnowPine, pos, scale, parent)
        else
            ok, err = pcall(builder, pos, scale, parent, rng)
        end
        if not ok then
            local name = builderNames[builder] or "Unknown"
            if not errorReported[name] then
                warn(("[WorldBuilder] %s tree failed: %s"):format(name, tostring(err)))
                errorReported[name] = true
            end
        end
    end

    -- Dispatcher: prefer templates from ServerStorage if available for this biome,
    -- otherwise fall back to procedural builders.
    local function placeTree(pos: Vector3, nearestBiome: Biome?, scale: number)
        local templates = findTemplatesForBiome(nearestBiome)
        if templates then
            local ok, err = pcall(placeTemplateTree, templates, pos, scale, parent, rng)
            if not ok and not errorReported["Template"] then
                warn(("[WorldBuilder] Template tree failed: %s"):format(tostring(err)))
                errorReported["Template"] = true
            end
        else
            local builder = pickTreeBuilder(nearestBiome, rng)
            placeProceduralTree(builder, pos, scale)
        end
    end

    -- ---------- Pass 1: Groves ----------
    local groveCount = 0
    for _ = 1, FOREST_GROVE_TARGET * 5 do
        if groveCount >= FOREST_GROVE_TARGET then break end
        local center, nearestBiome = tryPick(FOREST_BIOME_MARGIN)
        if not center then continue end

        local treesInGrove = rng:NextInteger(3, 5)
        for _ = 1, treesInGrove do
            local offset = Vector3.new(rng:NextNumber(-12, 12), 0, rng:NextNumber(-12, 12))
            local tx, tz = center.X + offset.X, center.Z + offset.Z
            local treePos = Vector3.new(tx, groundY(tx, tz), tz)
            if clearOfPath(treePos) and not inAnyClearing(treePos) then
                placeTree(treePos, nearestBiome, rng:NextNumber(1.0, 1.4))
            end
        end
        groveCount += 1
    end

    -- ---------- Pass 2: Wanderers ----------
    local wandererPlaced = 0
    for _ = 1, FOREST_WANDERER_TARGET * 4 do
        if wandererPlaced >= FOREST_WANDERER_TARGET then break end
        local pos, nearestBiome = tryPick(FOREST_BIOME_MARGIN)
        if not pos then continue end
        placeTree(pos, nearestBiome, rng:NextNumber(1.0, 1.4))
        wandererPlaced += 1
    end

    -- ---------- Pass 3: Ground clutter ----------
    local clutterPlaced = 0
    for _ = 1, FOREST_CLUTTER_TARGET * 4 do
        if clutterPlaced >= FOREST_CLUTTER_TARGET then break end
        local pos, _ = tryPick(20)
        if not pos then continue end
        local roll = rng:NextNumber()
        if roll < 0.55 then
            makeBush(pos, parent, rng)
        elseif roll < 0.8 then
            makeRockPile(pos, parent, rng)
        else
            makeFallenLog(pos, parent, rng)
        end
        clutterPlaced += 1
    end

    print(("[WorldBuilder] Forest: %d groves (~%d trees), %d wanderers, %d clutter."):format(
        groveCount, groveCount * 6, wandererPlaced, clutterPlaced))
end

-- =========================================================================
-- Biome-thematic decor
-- =========================================================================

local function makeGlimmerMushroom(position: Vector3, parent: Instance)
    local stem = Instance.new("Part")
    stem.Anchored = true
    stem.CanCollide = false
    stem.Size = Vector3.new(0.7, 1.8, 0.7)
    stem.Position = position + Vector3.new(0, 0.9, 0)
    stem.Material = Enum.Material.SmoothPlastic
    stem.Color = Color3.fromRGB(220, 220, 230)
    stem.Parent = parent

    local cap = Instance.new("Part")
    cap.Anchored = true
    cap.CanCollide = false
    cap.Shape = Enum.PartType.Ball
    cap.Size = Vector3.new(2.4, 1.4, 2.4)
    cap.Position = position + Vector3.new(0, 2, 0)
    cap.Material = Enum.Material.Neon
    cap.Color = Color3.fromRGB(140, 220, 255)
    cap.CastShadow = false
    cap.Parent = parent

    local pl = Instance.new("PointLight")
    pl.Color = cap.Color
    pl.Range = 9
    pl.Brightness = 1
    pl.Parent = cap
end

local function makeRedMushroom(position: Vector3, parent: Instance)
    -- Classic Amanita: white stem, red cap with white spots
    local stem = Instance.new("Part")
    stem.Anchored = true
    stem.CanCollide = false
    stem.Size = Vector3.new(0.9, 2.2, 0.9)
    stem.Position = position + Vector3.new(0, 1.1, 0)
    stem.Material = Enum.Material.SmoothPlastic
    stem.Color = Color3.fromRGB(240, 235, 220)
    stem.Parent = parent

    local cap = Instance.new("Part")
    cap.Anchored = true
    cap.CanCollide = false
    cap.Shape = Enum.PartType.Ball
    cap.Size = Vector3.new(3.2, 2, 3.2)
    cap.Position = position + Vector3.new(0, 2.5, 0)
    cap.Material = Enum.Material.SmoothPlastic
    cap.Color = Color3.fromRGB(200, 40, 40)
    cap.CastShadow = true
    cap.Parent = parent

    -- A couple of white spots on the cap
    for i = 1, 3 do
        local spot = Instance.new("Part")
        spot.Anchored = true
        spot.CanCollide = false
        spot.Shape = Enum.PartType.Ball
        spot.Size = Vector3.new(0.5, 0.5, 0.5)
        local theta = (i / 3) * math.pi * 2
        spot.Position = cap.Position + Vector3.new(math.cos(theta) * 1, 0.7, math.sin(theta) * 1)
        spot.Material = Enum.Material.SmoothPlastic
        spot.Color = Color3.fromRGB(240, 235, 220)
        spot.Parent = parent
    end
end

local function makeGlimmerCrystal(position: Vector3, parent: Instance)
    local crystal = Instance.new("Part")
    crystal.Anchored = true
    crystal.CanCollide = false
    crystal.Size = Vector3.new(1.3, 4, 1.3)
    crystal.Position = position + Vector3.new(0, 2, 0)
    crystal.Orientation = Vector3.new(15, 0, 8)
    crystal.Material = Enum.Material.Neon
    crystal.Color = Color3.fromRGB(180, 240, 255)
    crystal.Transparency = 0.2
    crystal.CastShadow = false
    crystal.Parent = parent
end

local function makeVerdantTuft(position: Vector3, parent: Instance)
    for i = 1, 4 do
        local blade = Instance.new("Part")
        blade.Anchored = true
        blade.CanCollide = false
        blade.Size = Vector3.new(0.3, 1.8, 0.3)
        blade.Position = position + Vector3.new((i - 2.5) * 0.3, 0.9, math.sin(i) * 0.3)
        blade.Orientation = Vector3.new(0, i * 30, (i - 2) * 8)
        blade.Material = Enum.Material.Grass
        blade.Color = Color3.fromRGB(95, 180, 100)
        blade.CastShadow = false
        blade.Parent = parent
    end
end

local function makeEmberLavaRock(position: Vector3, parent: Instance, rng: Random)
    local rock = Instance.new("Part")
    rock.Anchored = true
    rock.CanCollide = true
    rock.Size = Vector3.new(rng:NextNumber(2.8, 4.5), rng:NextNumber(1.8, 2.8), rng:NextNumber(2.8, 4.5))
    rock.Position = position + Vector3.new(0, rock.Size.Y / 2, 0)
    rock.Material = Enum.Material.Slate
    rock.Color = Color3.fromRGB(40, 30, 28)
    rock.Orientation = Vector3.new(0, rng:NextNumber(0, 360), 0)
    rock.CastShadow = true
    rock.Parent = parent

    local glow = Instance.new("Part")
    glow.Anchored = true
    glow.CanCollide = false
    glow.Size = rock.Size * 0.7
    glow.Position = rock.Position + Vector3.new(0, 0.1, 0)
    glow.Material = Enum.Material.Neon
    glow.Color = Color3.fromRGB(255, 110, 50)
    glow.Transparency = 0.5
    glow.CastShadow = false
    glow.Parent = parent

    local pl = Instance.new("PointLight")
    pl.Color = glow.Color
    pl.Range = 11
    pl.Brightness = 1.6
    pl.Parent = glow
end

local function makeIceShard(position: Vector3, parent: Instance, rng: Random)
    for i = 1, rng:NextInteger(1, 3) do
        local shard = Instance.new("Part")
        shard.Anchored = true
        shard.CanCollide = false
        shard.Size = Vector3.new(rng:NextNumber(0.8, 1.5), rng:NextNumber(3, 6), rng:NextNumber(0.8, 1.5))
        shard.Position = position + Vector3.new(rng:NextNumber(-1, 1), shard.Size.Y / 2, rng:NextNumber(-1, 1))
        shard.Orientation = Vector3.new(rng:NextNumber(-15, 15), 0, rng:NextNumber(-15, 15))
        shard.Material = Enum.Material.Ice
        shard.Color = Color3.fromRGB(190, 220, 240)
        shard.Transparency = 0.3
        shard.CastShadow = false
        shard.Parent = parent
    end
end

local function scatterBiomeDecor(biome: Biome, parent: Instance, rng: Random)
    local count = math.floor(biome.radius * 0.7)
    for _ = 1, count do
        local angle = rng:NextNumber(0, math.pi * 2)
        local r = biome.radius * rng:NextNumber(0.15, 0.95)
        local pos = Vector3.new(
            biome.center.X + math.cos(angle) * r,
            2,
            biome.center.Z + math.sin(angle) * r
        )

        -- NOTE: no trees inside biomes — they obscure essence nodes and make
        -- harvesting hard. Only low-profile thematic clutter goes here.
        if biome.decorStyle == "glimmer" then
            if rng:NextNumber() < 0.6 then
                makeGlimmerMushroom(pos, parent)
            else
                makeGlimmerCrystal(pos, parent)
            end
        elseif biome.decorStyle == "verdant" then
            -- Just tufts of tall grass — clovers are part of the Giant Flowers
            -- landmark grove which is defined later in the file.
            makeVerdantTuft(pos, parent)
        elseif biome.decorStyle == "ember" then
            -- Just lava rocks scattered around — no charred trees inside.
            makeEmberLavaRock(pos, parent, rng)
        elseif biome.decorStyle == "whispering" then
            -- Red mushrooms + crystals; trees stay outside the biome perimeter.
            if rng:NextNumber() < 0.65 then
                makeRedMushroom(pos, parent)
            else
                makeGlimmerCrystal(pos, parent)
            end
        elseif biome.decorStyle == "frostpeak" then
            -- Ice shards only — pines stay outside.
            makeIceShard(pos, parent, rng)
        end
    end
end

-- =========================================================================
-- Cottages (fairy-tale flavor near non-starter biomes)
-- =========================================================================

local function makeCottage(position: Vector3, parent: Instance, accentRoof: Color3)
    local model = Instance.new("Model")
    model.Name = "Cottage"

    local wallColor = Color3.fromRGB(150, 110, 80)
    local W, H, D = 10, 6, 10
    local cx, cy, cz = position.X, position.Y + H / 2, position.Z

    -- 4 walls (with simple openings carved by leaving a door part below)
    local function wall(name: string, size: Vector3, posOffset: Vector3)
        local p = Instance.new("Part")
        p.Name = name
        p.Anchored = true
        p.CanCollide = true
        p.Size = size
        p.Position = Vector3.new(cx + posOffset.X, cy + posOffset.Y, cz + posOffset.Z)
        p.Material = Enum.Material.WoodPlanks
        p.Color = wallColor
        p.Parent = model
    end
    wall("Wall_N", Vector3.new(W, H, 0.5), Vector3.new(0, 0, -D / 2))
    wall("Wall_S_L", Vector3.new(W * 0.4, H, 0.5), Vector3.new(-W * 0.3, 0, D / 2))
    wall("Wall_S_R", Vector3.new(W * 0.4, H, 0.5), Vector3.new(W * 0.3, 0, D / 2))
    wall("Wall_S_Top", Vector3.new(W * 0.2, H * 0.3, 0.5), Vector3.new(0, H * 0.35, D / 2))
    wall("Wall_E", Vector3.new(0.5, H, D), Vector3.new(W / 2, 0, 0))
    wall("Wall_W", Vector3.new(0.5, H, D), Vector3.new(-W / 2, 0, 0))

    -- Door (slightly darker, slightly inset)
    local door = Instance.new("Part")
    door.Anchored = true
    door.CanCollide = true
    door.Size = Vector3.new(W * 0.2, H * 0.7, 0.3)
    door.Position = Vector3.new(cx, cy - H * 0.15, cz + D / 2 + 0.1)
    door.Material = Enum.Material.Wood
    door.Color = Color3.fromRGB(85, 55, 35)
    door.Parent = model

    -- Glowing window
    local window = Instance.new("Part")
    window.Anchored = true
    window.CanCollide = false
    window.Size = Vector3.new(2, 2, 0.2)
    window.Position = Vector3.new(cx + W * 0.5 + 0.1, cy + 0.5, cz)
    window.Material = Enum.Material.Neon
    window.Color = Color3.fromRGB(255, 220, 130)
    window.Transparency = 0.1
    window.Parent = model

    local pl = Instance.new("PointLight")
    pl.Color = window.Color
    pl.Range = 16
    pl.Brightness = 2
    pl.Parent = window

    -- Pitched roof: two angled slabs meeting at the ridge
    local roofY = cy + H / 2 + 1
    local roofL = Instance.new("Part")
    roofL.Anchored = true
    roofL.CanCollide = true
    roofL.Size = Vector3.new(W * 0.62, 0.6, D + 1)
    roofL.Position = Vector3.new(cx - W * 0.18, roofY + 1, cz)
    roofL.Orientation = Vector3.new(0, 0, 35)
    roofL.Material = Enum.Material.Slate
    roofL.Color = accentRoof
    roofL.Parent = model

    local roofR = Instance.new("Part")
    roofR.Anchored = true
    roofR.CanCollide = true
    roofR.Size = Vector3.new(W * 0.62, 0.6, D + 1)
    roofR.Position = Vector3.new(cx + W * 0.18, roofY + 1, cz)
    roofR.Orientation = Vector3.new(0, 0, -35)
    roofR.Material = Enum.Material.Slate
    roofR.Color = accentRoof
    roofR.Parent = model

    -- Chimney
    local chimney = Instance.new("Part")
    chimney.Anchored = true
    chimney.CanCollide = true
    chimney.Size = Vector3.new(1.5, 4, 1.5)
    chimney.Position = Vector3.new(cx - W * 0.3, roofY + 3, cz - D * 0.2)
    chimney.Material = Enum.Material.Brick
    chimney.Color = Color3.fromRGB(120, 70, 60)
    chimney.Parent = model

    -- Smoke
    local attach = Instance.new("Attachment")
    attach.Position = Vector3.new(0, 2, 0)
    attach.Parent = chimney
    local smoke = Instance.new("ParticleEmitter")
    smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
    smoke.Color = ColorSequence.new(Color3.fromRGB(200, 200, 210), Color3.fromRGB(120, 120, 130))
    smoke.Lifetime = NumberRange.new(3, 5)
    smoke.Rate = 6
    smoke.Speed = NumberRange.new(2, 4)
    smoke.Size = NumberSequence.new(1, 4)
    smoke.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.4),
        NumberSequenceKeypoint.new(1, 1),
    })
    smoke.LightEmission = 0.1
    smoke.Parent = attach

    model.Parent = parent
end

local function placeBiomeCottage(biome: Biome, parent: Instance, rng: Random)
    -- Just outside the biome perimeter, on the side facing the WorldTree.
    local dirFromOrigin = (biome.center - Vector3.new(0, biome.center.Y, 0))
    local sideDir = (dirFromOrigin.Magnitude > 0) and dirFromOrigin.Unit or Vector3.new(0, 0, 1)
    local cottagePos = biome.center - sideDir * (biome.radius + 12)
    cottagePos = Vector3.new(cottagePos.X, 2, cottagePos.Z)

    local roofColor
    if biome.decorStyle == "whispering" then
        roofColor = Color3.fromRGB(160, 50, 50)  -- red riding hood red
    elseif biome.decorStyle == "frostpeak" then
        roofColor = Color3.fromRGB(180, 195, 215)
    else
        roofColor = Color3.fromRGB(110, 75, 55)
    end

    -- If the user has dropped a cottage Model in ServerStorage.CottageTemplates,
    -- use that instead of the procedural cabin. Sub-folders work like the tree
    -- system (Whispering / Frostpeak / Verdant / Default) — defaults to Default
    -- if no biome-specific folder is present.
    local ServerStorage = game:GetService("ServerStorage")
    local cottageRoot = ServerStorage:FindFirstChild("CottageTemplates")
    local templateUsed = false
    if cottageRoot then
        local map = {
            glimmer    = "Glimmer",
            verdant    = "Verdant",
            whispering = "Whispering",
            ember      = "Ember",
            frostpeak  = "Frostpeak",
        }
        local folder = cottageRoot:FindFirstChild(map[biome.decorStyle] or "Default")
            or cottageRoot:FindFirstChild("Default")
        local pool = folder and folder:GetChildren() or cottageRoot:GetChildren()
        -- Filter out sub-folders so we don't pick an empty folder
        local valid = {}
        for _, c in pool do
            if not c:IsA("Folder") then table.insert(valid, c) end
        end
        if #valid > 0 then
            local chosen = valid[rng:NextInteger(1, #valid)]
            local clone = chosen:Clone()
            sanitizeTemplate(clone)
            if clone:IsA("Model") then
                clone:PivotTo(CFrame.new(cottagePos))
                for _, d in clone:GetDescendants() do
                    if d:IsA("BasePart") then d.Anchored = true end
                end
            elseif clone:IsA("BasePart") then
                clone.CFrame = CFrame.new(cottagePos)
                clone.Anchored = true
            end
            clone.Parent = parent
            templateUsed = true
        end
    end

    if not templateUsed then
        makeCottage(cottagePos, parent, roofColor)
    end

    -- Reserve walking space around the cottage doorway.
    addClearing(cottagePos, 18)
end

-- =========================================================================
-- Biome Landmarks — towering set pieces that make each biome readable from
-- across the map. Each landmark is positioned BEHIND the biome (away from
-- origin) so players see it as they approach.
-- =========================================================================

local function makeVolcano(position: Vector3, parent: Instance, rng: Random)
    -- Voxel-Terrain volcano (Gemini's stacked-cone idea, with crater carved
    -- and a CrackedLava pool inside). The lava streams + steam plume + lights
    -- stay Part-based so they animate and glow properly.
    local terrain = Workspace.Terrain
    local model = Instance.new("Model")
    model.Name = "EmberVolcano"

    local baseRadius = 95
    local apexRadius = 14
    local height = 200
    local stepHeight = 4   -- voxel resolution; smaller = smoother but slower
    local steps = math.floor(height / stepHeight)

    -- Stacked cylinders shrinking toward the apex.
    for i = 0, steps do
        local t = i / steps
        -- Slight outward jitter at lower layers makes the slope look less perfect.
        local jitter = (i < steps * 0.7) and rng:NextNumber(-3, 3) or 0
        local r = math.max(2, baseRadius * (1 - t) + apexRadius * t + jitter)
        local layerCFrame = CFrame.new(position + Vector3.new(0, i * stepHeight, 0))
        terrain:FillCylinder(layerCFrame, stepHeight, r, Enum.Material.Basalt)
    end

    -- Carve the crater: a ball of Air subtracted from the top.
    -- NOTE: FillBall takes a Vector3 (not a CFrame like FillCylinder does).
    local craterCenter = position + Vector3.new(0, height - 6, 0)
    terrain:FillBall(craterCenter, apexRadius + 4, Enum.Material.Air)

    -- Pool of CrackedLava at the bottom of the crater.
    local lavaCenter = position + Vector3.new(0, height - 14, 0)
    terrain:FillBall(lavaCenter, apexRadius + 1, Enum.Material.CrackedLava)

    -- Glowing magma surface disc inside the crater (visual emphasis).
    local magma = Instance.new("Part")
    magma.Anchored = true
    magma.CanCollide = false
    magma.Shape = Enum.PartType.Cylinder
    magma.Size = Vector3.new(2, apexRadius * 1.8, apexRadius * 1.8)
    magma.Position = position + Vector3.new(0, height - 7, 0)
    magma.Orientation = Vector3.new(0, 0, 90)
    magma.Material = Enum.Material.Neon
    magma.Color = Color3.fromRGB(255, 120, 50)
    magma.Parent = model

    local magmaLight = Instance.new("PointLight")
    magmaLight.Color = magma.Color
    magmaLight.Range = 90
    magmaLight.Brightness = 5
    magmaLight.Parent = magma

    -- Lava rivulets running down the cone.
    local streamCount = 6
    for i = 1, streamCount do
        local theta = (i / streamCount) * math.pi * 2 + rng:NextNumber(-0.35, 0.35)
        local topY = height - 12
        local botY = height * 0.18
        local topR = apexRadius + 5
        local botR = baseRadius * 0.85
        local topPos = position + Vector3.new(math.cos(theta) * topR, topY, math.sin(theta) * topR)
        local bottomPos = position + Vector3.new(math.cos(theta) * botR, botY, math.sin(theta) * botR)
        local midPos = (topPos + bottomPos) / 2
        local len = (topPos - bottomPos).Magnitude

        local stream = Instance.new("Part")
        stream.Anchored = true
        stream.CanCollide = false
        stream.Size = Vector3.new(rng:NextNumber(2.5, 3.5), len, rng:NextNumber(2.5, 3.5))
        stream.CFrame = CFrame.lookAt(midPos, bottomPos) * CFrame.Angles(math.rad(90), 0, 0)
        stream.Material = Enum.Material.Neon
        stream.Color = Color3.fromRGB(255, 120, 40)
        stream.Transparency = 0.05
        stream.CastShadow = false
        stream.Parent = model

        local pl = Instance.new("PointLight")
        pl.Color = stream.Color
        pl.Range = 20
        pl.Brightness = 2.5
        pl.Parent = stream
    end

    -- Steam plume + ember sparks rising from the crater.
    local plumeAnchor = Instance.new("Part")
    plumeAnchor.Anchored = true
    plumeAnchor.CanCollide = false
    plumeAnchor.Transparency = 1
    plumeAnchor.Size = Vector3.new(1, 1, 1)
    plumeAnchor.Position = position + Vector3.new(0, height + 4, 0)
    plumeAnchor.Parent = model

    local plumeAttach = Instance.new("Attachment")
    plumeAttach.Parent = plumeAnchor

    local smoke = Instance.new("ParticleEmitter")
    smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
    smoke.Color = ColorSequence.new(Color3.fromRGB(50, 45, 45), Color3.fromRGB(180, 130, 110))
    smoke.Lifetime = NumberRange.new(7, 12)
    smoke.Rate = 35
    smoke.Speed = NumberRange.new(10, 16)
    smoke.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 6),
        NumberSequenceKeypoint.new(1, 24),
    })
    smoke.SpreadAngle = Vector2.new(12, 12)
    smoke.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.2),
        NumberSequenceKeypoint.new(1, 1),
    })
    smoke.LightEmission = 0.2
    smoke.Parent = plumeAttach

    local embers = Instance.new("ParticleEmitter")
    embers.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    embers.Color = ColorSequence.new(Color3.fromRGB(255, 160, 60), Color3.fromRGB(255, 80, 30))
    embers.Lifetime = NumberRange.new(3, 5)
    embers.Rate = 30
    embers.Speed = NumberRange.new(6, 12)
    embers.SpreadAngle = Vector2.new(45, 45)
    embers.Size = NumberSequence.new(1.4)
    embers.LightEmission = 0.9
    embers.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(1, 1),
    })
    embers.Parent = plumeAttach

    model.Parent = parent
end

local function makeGlacierPeak(position: Vector3, peakHeight: number, baseRadius: number, rng: Random)
    -- Voxel-Terrain peak: Glacier rock body topped with Snow cap. Wider jitter
    -- on lower layers makes it look weathered instead of perfectly conical.
    local terrain = Workspace.Terrain
    local stepHeight = 4
    local steps = math.floor(peakHeight / stepHeight)

    for i = 0, steps do
        local t = i / steps
        local jitter = (i < steps * 0.7) and rng:NextNumber(-4, 4) or rng:NextNumber(-1, 1)
        local r = math.max(2, baseRadius * (1 - t) + 2 * t + jitter)
        local layerCFrame = CFrame.new(position + Vector3.new(0, i * stepHeight, 0))
        -- Lower 55% = Glacier rock; upper 45% = Snow cap.
        local mat = (t > 0.55) and Enum.Material.Snow or Enum.Material.Glacier
        terrain:FillCylinder(layerCFrame, stepHeight, r, mat)
    end
end

local function makeGlacierMountains(position: Vector3, parent: Instance, rng: Random)
    local model = Instance.new("Model")
    model.Name = "FrostpeakGlaciers"

    -- Four peaks in a slight arc behind the biome. Mix of heights/radii so
    -- the silhouette reads as a range, not a row of duplicates.
    local peakConfigs = {
        { offset = Vector3.new(-65, 0, 10),  height = 130, radius = 55 },
        { offset = Vector3.new(-15, 0, -5),  height = 195, radius = 70 },
        { offset = Vector3.new(40,  0, 15),  height = 160, radius = 60 },
        { offset = Vector3.new(85,  0, 30),  height = 115, radius = 50 },
    }
    for _, cfg in peakConfigs do
        makeGlacierPeak(position + cfg.offset, cfg.height, cfg.radius, rng)
    end

    -- A ruined ice cavern entrance (Boss Den scaffolding) at the base of the
    -- middle peak. Frame: two leaning ice pillars + a lintel + dark interior.
    local denX, denY, denZ = position.X, position.Y + 6, position.Z - 30

    -- Reserve a generous clearing in front of the den so the eventual boss
    -- fight has room and trees don't block sightlines / movement.
    addClearing(Vector3.new(denX, 0, denZ + 10), 30)

    local function pillar(xOff: number)
        local p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = true
        p.Size = Vector3.new(4, 14, 4)
        p.Position = Vector3.new(denX + xOff, denY, denZ)
        p.Orientation = Vector3.new(0, 0, xOff > 0 and -8 or 8)
        p.Material = Enum.Material.Ice
        p.Color = Color3.fromRGB(190, 220, 240)
        p.Transparency = 0.2
        p.Parent = model
    end
    pillar(-7)
    pillar(7)

    local lintel = Instance.new("Part")
    lintel.Anchored = true
    lintel.CanCollide = true
    lintel.Size = Vector3.new(20, 3, 5)
    lintel.Position = Vector3.new(denX, denY + 9, denZ)
    lintel.Material = Enum.Material.Ice
    lintel.Color = Color3.fromRGB(170, 200, 225)
    lintel.Transparency = 0.15
    lintel.Parent = model

    -- Dark interior — black plane behind the entrance to suggest a deep cave.
    local interior = Instance.new("Part")
    interior.Anchored = true
    interior.CanCollide = false
    interior.Size = Vector3.new(16, 14, 0.5)
    interior.Position = Vector3.new(denX, denY + 2, denZ - 2)
    interior.Material = Enum.Material.SmoothPlastic
    interior.Color = Color3.fromRGB(8, 10, 18)
    interior.Parent = model

    -- BillboardGui marking it as the Boss Den (placeholder until Pass 2 wires
    -- up the actual encounter).
    local sign = Instance.new("Part")
    sign.Anchored = true
    sign.CanCollide = false
    sign.Transparency = 1
    sign.Size = Vector3.new(1, 1, 1)
    sign.Position = Vector3.new(denX, denY + 16, denZ)
    sign.Parent = model

    local gui = Instance.new("BillboardGui")
    gui.Size = UDim2.fromOffset(280, 50)
    gui.AlwaysOnTop = true
    gui.Parent = sign

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBlack
    label.TextSize = 24
    label.TextColor3 = Color3.fromRGB(220, 230, 245)
    label.TextStrokeTransparency = 0.2
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.Text = "Boss Den"
    label.Parent = gui

    -- Subtle cold breath from the cave mouth.
    local attach = Instance.new("Attachment")
    attach.Position = Vector3.new(0, -8, -2)
    attach.Parent = sign
    local breath = Instance.new("ParticleEmitter")
    breath.Texture = "rbxasset://textures/particles/smoke_main.dds"
    breath.Color = ColorSequence.new(Color3.fromRGB(200, 220, 240))
    breath.Lifetime = NumberRange.new(3, 5)
    breath.Rate = 8
    breath.Speed = NumberRange.new(2, 4)
    breath.Size = NumberSequence.new(3, 7)
    breath.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.5),
        NumberSequenceKeypoint.new(1, 1),
    })
    breath.LightEmission = 0.4
    breath.Parent = attach

    -- Summon prompt: a glowing pedestal in front of the entrance with a
    -- ProximityPrompt that calls into MobService to spawn the Frost Titan.
    local pedestal = Instance.new("Part")
    pedestal.Name = "FrostTitanSummonPedestal"
    pedestal.Anchored = true
    pedestal.CanCollide = true
    pedestal.Shape = Enum.PartType.Cylinder
    pedestal.Size = Vector3.new(2, 6, 6)
    pedestal.Orientation = Vector3.new(0, 0, 90)
    pedestal.Position = Vector3.new(denX, denY - 4, denZ + 14)
    pedestal.Material = Enum.Material.Ice
    pedestal.Color = Color3.fromRGB(170, 210, 240)
    pedestal.Transparency = 0.1
    pedestal.Parent = model
    -- Mark where the boss should appear (read by the prompt handler via attribute).
    pedestal:SetAttribute("BossId", "frost_titan")
    pedestal:SetAttribute("ArenaCenterX", denX)
    pedestal:SetAttribute("ArenaCenterY", position.Y + 4)
    pedestal:SetAttribute("ArenaCenterZ", denZ - 8)

    local pedestalLight = Instance.new("PointLight")
    pedestalLight.Color = Color3.fromRGB(180, 220, 255)
    pedestalLight.Range = 14
    pedestalLight.Brightness = 2
    pedestalLight.Parent = pedestal

    local summonPrompt = Instance.new("ProximityPrompt")
    summonPrompt.Name = "SummonFrostTitan"
    summonPrompt.ActionText = "Summon Frost Titan"
    summonPrompt.ObjectText = "Boss Den"
    summonPrompt.HoldDuration = 2  -- hold to confirm (no accidental triggers)
    summonPrompt.MaxActivationDistance = 12
    summonPrompt.RequiresLineOfSight = false
    summonPrompt.KeyboardKeyCode = Enum.KeyCode.E
    summonPrompt.Parent = pedestal

    model.Parent = parent
end

local function makeGiantWillow(position: Vector3, parent: Instance, rng: Random)
    -- A massive pink/purple weeping willow with hanging vines and fairy dust.
    local model = Instance.new("Model")
    model.Name = "GiantWillow"

    local trunkHeight = 70
    local trunkRadius = 6

    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = true
    trunk.Shape = Enum.PartType.Cylinder
    trunk.Size = Vector3.new(trunkHeight, trunkRadius * 2, trunkRadius * 2)
    trunk.Position = position + Vector3.new(0, trunkHeight / 2, 0)
    trunk.Orientation = Vector3.new(0, 0, 90)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(95, 70, 90)
    trunk.Parent = model

    -- Splaying low branches + leaf masses.
    local function leafCluster(center: Vector3, size: number, color: Color3)
        for _ = 1, 5 do
            local leaf = Instance.new("Part")
            leaf.Anchored = true
            leaf.CanCollide = false
            leaf.Shape = Enum.PartType.Ball
            local s = size * rng:NextNumber(0.7, 1.3)
            leaf.Size = Vector3.new(s, s * 0.85, s)
            leaf.Position = center + Vector3.new(
                rng:NextNumber(-size * 0.4, size * 0.4),
                rng:NextNumber(-size * 0.3, size * 0.5),
                rng:NextNumber(-size * 0.4, size * 0.4)
            )
            leaf.Material = Enum.Material.LeafyGrass
            local jitter = rng:NextInteger(-20, 20)
            leaf.Color = Color3.fromRGB(
                math.clamp(color.R * 255 + jitter, 0, 255),
                math.clamp(color.G * 255 + jitter, 0, 255),
                math.clamp(color.B * 255 + jitter, 0, 255)
            )
            leaf.CastShadow = false
            leaf.Parent = model
        end
    end

    -- Crown clusters at the top.
    local crownColor = Color3.fromRGB(220, 130, 200)
    leafCluster(position + Vector3.new(0, trunkHeight + 6, 0), 24, crownColor)
    for i = 1, 6 do
        local theta = (i / 6) * math.pi * 2
        leafCluster(position + Vector3.new(math.cos(theta) * 18, trunkHeight + 2, math.sin(theta) * 18), 16, crownColor)
    end

    -- Drooping vines — long thin neon-ish cylinders hanging from the canopy edge.
    for i = 1, 20 do
        local theta = (i / 20) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
        local r = rng:NextNumber(14, 22)
        local vineLen = rng:NextNumber(25, 45)
        local topX, topZ = math.cos(theta) * r, math.sin(theta) * r
        local vine = Instance.new("Part")
        vine.Anchored = true
        vine.CanCollide = false
        vine.Size = Vector3.new(0.4, vineLen, 0.4)
        vine.Position = position + Vector3.new(topX, trunkHeight - vineLen / 2 + 5, topZ)
        vine.Material = Enum.Material.SmoothPlastic
        vine.Color = Color3.fromRGB(180, 100, 170)
        vine.Parent = model
        -- A small leaf-blob at the tip
        local tip = Instance.new("Part")
        tip.Anchored = true
        tip.CanCollide = false
        tip.Shape = Enum.PartType.Ball
        tip.Size = Vector3.new(2, 2, 2)
        tip.Position = vine.Position + Vector3.new(0, -vineLen / 2 - 0.5, 0)
        tip.Material = Enum.Material.LeafyGrass
        tip.Color = Color3.fromRGB(255, 170, 220)
        tip.Parent = model
    end

    -- Pulsing soft purple base light.
    local baseLight = Instance.new("PointLight")
    baseLight.Color = Color3.fromRGB(220, 140, 230)
    baseLight.Range = 70
    baseLight.Brightness = 3
    baseLight.Parent = trunk

    -- Drifting fairy dust at the canopy.
    local attach = Instance.new("Attachment")
    attach.Position = Vector3.new(0, trunkHeight - 10, 0)
    attach.Parent = trunk
    local dust = Instance.new("ParticleEmitter")
    dust.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    dust.Color = ColorSequence.new(Color3.fromRGB(255, 200, 240))
    dust.Lifetime = NumberRange.new(4, 7)
    dust.Rate = 25
    dust.Speed = NumberRange.new(1, 3)
    dust.SpreadAngle = Vector2.new(180, 180)
    dust.Size = NumberSequence.new(0.8)
    dust.LightEmission = 0.9
    dust.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.3, 0.2),
        NumberSequenceKeypoint.new(0.7, 0.3),
        NumberSequenceKeypoint.new(1, 1),
    })
    dust.Parent = attach

    model.Parent = parent
end

local function makeGiantFlower(position: Vector3, parent: Instance, rng: Random, color: Color3)
    -- Tall stem + petal ring + center bud. Each "flower" is ~15-22 studs tall.
    local height = rng:NextNumber(15, 22)
    local stem = Instance.new("Part")
    stem.Anchored = true
    stem.CanCollide = false
    stem.Size = Vector3.new(0.8, height, 0.8)
    stem.Position = position + Vector3.new(0, height / 2, 0)
    stem.Material = Enum.Material.Grass
    stem.Color = Color3.fromRGB(80, 145, 70)
    stem.Parent = parent

    local headPos = position + Vector3.new(0, height + 0.5, 0)

    -- Center bud
    local center = Instance.new("Part")
    center.Anchored = true
    center.CanCollide = false
    center.Shape = Enum.PartType.Ball
    center.Size = Vector3.new(2, 2, 2)
    center.Position = headPos
    center.Material = Enum.Material.Neon
    center.Color = Color3.fromRGB(255, 220, 90)
    center.Parent = parent

    -- Petal ring
    local petalCount = 6
    for i = 1, petalCount do
        local theta = (i / petalCount) * math.pi * 2
        local petal = Instance.new("Part")
        petal.Anchored = true
        petal.CanCollide = false
        petal.Shape = Enum.PartType.Ball
        petal.Size = Vector3.new(3, 0.8, 4)
        petal.Position = headPos + Vector3.new(math.cos(theta) * 2.5, 0, math.sin(theta) * 2.5)
        petal.Orientation = Vector3.new(0, math.deg(theta), 0)
        petal.Material = Enum.Material.SmoothPlastic
        petal.Color = color
        petal.CastShadow = false
        petal.Parent = parent
    end

    -- Soft glow from center
    local pl = Instance.new("PointLight")
    pl.Color = center.Color
    pl.Range = 8
    pl.Brightness = 0.8
    pl.Parent = center
end

local function makeGiantClover(position: Vector3, parent: Instance, rng: Random)
    -- A wide 3-leaf clover, low to the ground.
    local stem = Instance.new("Part")
    stem.Anchored = true
    stem.CanCollide = false
    stem.Size = Vector3.new(0.6, 4, 0.6)
    stem.Position = position + Vector3.new(0, 2, 0)
    stem.Material = Enum.Material.Grass
    stem.Color = Color3.fromRGB(80, 150, 70)
    stem.Parent = parent

    for i = 1, 3 do
        local theta = (i / 3) * math.pi * 2
        local leaf = Instance.new("Part")
        leaf.Anchored = true
        leaf.CanCollide = false
        leaf.Shape = Enum.PartType.Ball
        leaf.Size = Vector3.new(3.5, 1.2, 3)
        leaf.Position = position + Vector3.new(math.cos(theta) * 1.8, 4.2, math.sin(theta) * 1.8)
        leaf.Orientation = Vector3.new(0, math.deg(theta), 10)
        leaf.Material = Enum.Material.LeafyGrass
        leaf.Color = Color3.fromRGB(95, 175, 90)
        leaf.CastShadow = false
        leaf.Parent = parent
    end
end

local function makeGiantFlowers(position: Vector3, parent: Instance, rng: Random)
    -- Position is the landmark anchor; spread flowers in a small grove around it.
    local model = Instance.new("Model")
    model.Name = "VerdantGiantFlowers"

    local palette = {
        Color3.fromRGB(255, 240, 240),  -- white
        Color3.fromRGB(255, 180, 200),  -- pink
        Color3.fromRGB(200, 160, 255),  -- lavender
        Color3.fromRGB(255, 220, 100),  -- yellow
        Color3.fromRGB(160, 220, 255),  -- sky blue
    }
    -- Big flowers
    for i = 1, 8 do
        local theta = rng:NextNumber(0, math.pi * 2)
        local r = rng:NextNumber(0, 25)
        local pos = Vector3.new(position.X + math.cos(theta) * r, 2, position.Z + math.sin(theta) * r)
        local color = palette[rng:NextInteger(1, #palette)]
        makeGiantFlower(pos, model, rng, color)
    end
    -- Clovers in between
    for _ = 1, 14 do
        local theta = rng:NextNumber(0, math.pi * 2)
        local r = rng:NextNumber(0, 30)
        local pos = Vector3.new(position.X + math.cos(theta) * r, 2, position.Z + math.sin(theta) * r)
        makeGiantClover(pos, model, rng)
    end

    -- Soft green particle drift over the whole grove.
    local anchor = Instance.new("Part")
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(1, 1, 1)
    anchor.Position = Vector3.new(position.X, 12, position.Z)
    anchor.Parent = model

    local attach = Instance.new("Attachment")
    attach.Parent = anchor
    local petals = Instance.new("ParticleEmitter")
    petals.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    petals.Color = ColorSequence.new(Color3.fromRGB(180, 255, 180))
    petals.Lifetime = NumberRange.new(5, 9)
    petals.Rate = 15
    petals.Speed = NumberRange.new(1, 3)
    petals.SpreadAngle = Vector2.new(180, 180)
    petals.Size = NumberSequence.new(0.6)
    petals.LightEmission = 0.6
    petals.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.3, 0.3),
        NumberSequenceKeypoint.new(1, 1),
    })
    petals.Parent = attach

    model.Parent = parent
end

-- Dispatch: pick the right landmark builder for a biome and place it
-- "behind" the biome center (away from origin).
local function makeBiomeLandmark(biome: Biome, parent: Instance, rng: Random)
    local awayDir2D = Vector3.new(biome.center.X, 0, biome.center.Z)
    awayDir2D = (awayDir2D.Magnitude > 0.1) and awayDir2D.Unit or Vector3.new(0, 0, 1)
    local landmarkPos = Vector3.new(biome.center.X, 0, biome.center.Z) + awayDir2D * (biome.radius + 60)

    if biome.decorStyle == "ember" then
        makeVolcano(landmarkPos, parent, rng)
    elseif biome.decorStyle == "frostpeak" then
        makeGlacierMountains(landmarkPos, parent, rng)
    elseif biome.decorStyle == "whispering" then
        makeGiantWillow(landmarkPos, parent, rng)
    elseif biome.decorStyle == "verdant" then
        -- Flowers sit INSIDE the biome perimeter rather than far behind, so
        -- they pop visually right at the biome itself.
        local insidePos = Vector3.new(biome.center.X, 0, biome.center.Z) - awayDir2D * (biome.radius * 0.45)
        makeGiantFlowers(insidePos, parent, rng)
    end
    -- glimmer's centerpiece is the WorldTree itself; no extra landmark.
end

-- =========================================================================
-- Paths between WorldTree and biomes
-- =========================================================================

local function makePathTile(pos: Vector3, parent: Instance, rng: Random, recordedPositions: { Vector3 }?)
    local tile = Instance.new("Part")
    tile.Anchored = true
    tile.CanCollide = false
    tile.Size = Vector3.new(4 + rng:NextNumber(-0.5, 0.5), 0.4, 4 + rng:NextNumber(-0.5, 0.5))
    tile.Position = Vector3.new(pos.X, 2.4, pos.Z)
    tile.Orientation = Vector3.new(0, rng:NextNumber(0, 360), 0)
    tile.Material = Enum.Material.Cobblestone
    tile.Color = Color3.fromRGB(120, 110, 95)
    tile.CastShadow = false
    tile.Parent = parent

    -- Remember tile center on the ground plane (Y=0) for tree-avoidance later.
    if recordedPositions then
        table.insert(recordedPositions, Vector3.new(pos.X, 0, pos.Z))
    end
end

local function makePath(startPos: Vector3, target: Vector3, parent: Instance, rng: Random, recordedPositions: { Vector3 }?)
    -- Quadratic Bezier with a perpendicular kink for a winding feel.
    local mid = (startPos + target) / 2
    local dir = (target - startPos)
    if dir.Magnitude < 0.1 then return end
    local unitDir = dir.Unit
    local perp = Vector3.new(-unitDir.Z, 0, unitDir.X)
    local kink = perp * rng:NextNumber(-30, 30)
    local control = mid + kink

    local segments = math.floor(dir.Magnitude / 5)
    for i = 0, segments do
        local t = i / math.max(1, segments)
        local p = (1 - t) * (1 - t) * startPos + 2 * (1 - t) * t * control + t * t * target
        makePathTile(p, parent, rng, recordedPositions)
    end
end

-- Returns a list of (Y-zeroed) path tile centers so scatterForest can avoid them.
local function buildAllPaths(parent: Instance, rng: Random): { Vector3 }
    local pathPositions: { Vector3 } = {}
    for _, biome in BIOMES do
        if biome.id == "glimmer_glade" then continue end  -- starter biome stays naturally connected
        local startPos = Vector3.new(0, 0, 0)
        local target = biome.center - (biome.center.Unit * (biome.radius + 2))
        target = Vector3.new(target.X, 0, target.Z)
        makePath(startPos, target, parent, rng, pathPositions)
    end
    return pathPositions
end

-- =========================================================================
-- Essence node + biome marker
-- =========================================================================

-- Look up an essence-node template from ServerStorage.EssenceNodeTemplates,
-- preferring a biome-specific subfolder. Returns nil if templates aren't set up.
--
-- Expected layout:
--   ServerStorage/EssenceNodeTemplates/
--     Glimmer/     (cyan crystals / orbs — any Models or Parts)
--     Verdant/     (green flowers / mana clusters)
--     Whispering/  (pink / purple gems)
--     Ember/       (lava crystals / magma rocks)
--     Frostpeak/   (icicles / ice shards)
--     Default/     (fallback for any biome)
local function findNodeTemplate(biome: Biome, rng: Random): Instance?
    local ServerStorage = game:GetService("ServerStorage")
    local root = ServerStorage:FindFirstChild("EssenceNodeTemplates")
    if not root then return nil end

    local map = {
        glimmer    = "Glimmer",
        verdant    = "Verdant",
        whispering = "Whispering",
        ember      = "Ember",
        frostpeak  = "Frostpeak",
    }
    local folderName = map[biome.decorStyle] or "Default"
    local folder = root:FindFirstChild(folderName) or root:FindFirstChild("Default")
    if not folder then return nil end

    local children = folder:GetChildren()
    if #children == 0 then return nil end
    return children[rng:NextInteger(1, #children)]
end

local function makeEssenceNode(biome: Biome, position: Vector3, rng: Random?): Instance
    rng = rng or Random.new()

    -- Try template first
    local template = findNodeTemplate(biome, rng :: Random)
    if template then
        local clone = template:Clone()
        sanitizeTemplate(clone)
        local rotY = math.rad((rng :: Random):NextNumber(0, 360))
        if clone:IsA("BasePart") then
            clone.CFrame = CFrame.new(position) * CFrame.Angles(0, rotY, 0)
            clone.Anchored = true
        elseif clone:IsA("Model") then
            clone:PivotTo(CFrame.new(position) * CFrame.Angles(0, rotY, 0))
            -- Make sure every descendant is anchored so the node sits still.
            for _, d in clone:GetDescendants() do
                if d:IsA("BasePart") then d.Anchored = true end
            end
        end
        clone.Name = string.format("%sNode", biome.displayName:gsub(" ", ""))
        clone:SetAttribute("BiomeId", biome.id)
        clone:SetAttribute("BiomeRequiredWisps", biome.requiredWisps)
        clone:SetAttribute("BiomeMultiplier", biome.essenceMultiplier)
        return clone
    end

    -- Procedural fallback (original cylinder node)
    local part = Instance.new("Part")
    part.Name = string.format("%sNode", biome.displayName:gsub(" ", ""))
    part.Anchored = true
    part.CanCollide = true
    part.Shape = biome.nodeShape
    part.Size = biome.nodeSize
    part.Position = position
    part.Material = biome.nodeMaterial
    part.Color = biome.nodeColor
    part.CastShadow = false
    if biome.nodeShape == Enum.PartType.Cylinder then
        part.Orientation = Vector3.new(0, 0, 90)
    end

    local light = Instance.new("PointLight")
    light.Color = biome.nodeColor
    light.Range = 12
    light.Brightness = 1.2
    light.Parent = part

    part:SetAttribute("BiomeId", biome.id)
    part:SetAttribute("BiomeRequiredWisps", biome.requiredWisps)
    part:SetAttribute("BiomeMultiplier", biome.essenceMultiplier)
    return part
end

local function makeBiomeMarker(biome: Biome, parent: Instance)
    local totem = Instance.new("Part")
    totem.Name = string.format("%sTotem", biome.displayName:gsub(" ", ""))
    totem.Anchored = true
    totem.CanCollide = true
    totem.Shape = Enum.PartType.Cylinder
    totem.Size = Vector3.new(8, 3, 3)
    totem.Orientation = Vector3.new(0, 0, 90)
    totem.Position = biome.center + Vector3.new(0, 4, 0)
    totem.Material = Enum.Material.Neon
    totem.Color = biome.nodeColor
    totem.Transparency = 0.2
    totem.CastShadow = false
    totem:SetAttribute("BiomeId", biome.id)
    totem.Parent = parent

    local pl = Instance.new("PointLight")
    pl.Color = biome.nodeColor
    pl.Range = 16
    pl.Brightness = 2
    pl.Parent = totem

    local anchor = Instance.new("Part")
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(1, 1, 1)
    anchor.Position = biome.center + Vector3.new(0, 14, 0)
    anchor.Parent = parent

    local gui = Instance.new("BillboardGui")
    gui.Size = UDim2.fromOffset(260, 70)
    gui.AlwaysOnTop = true
    gui.Parent = anchor

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.Size = UDim2.new(1, 0, 0, 32)
    nameLabel.Font = Enum.Font.GothamBlack
    nameLabel.TextSize = 22
    nameLabel.TextColor3 = biome.nodeColor
    nameLabel.TextStrokeTransparency = 0.3
    nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    nameLabel.Text = biome.displayName
    nameLabel.Parent = gui

    if biome.requiredWisps > 0 then
        local reqLabel = Instance.new("TextLabel")
        reqLabel.BackgroundTransparency = 1
        reqLabel.Position = UDim2.fromOffset(0, 34)
        reqLabel.Size = UDim2.new(1, 0, 0, 26)
        reqLabel.Font = Enum.Font.GothamSemibold
        reqLabel.TextSize = 16
        reqLabel.TextColor3 = Color3.fromRGB(255, 220, 170)
        reqLabel.TextStrokeTransparency = 0.3
        reqLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
        reqLabel.Text = string.format("🔒 Requires %d wisps  •  %dx essence",
            biome.requiredWisps, biome.essenceMultiplier)
        reqLabel.Parent = gui
    else
        local subLabel = Instance.new("TextLabel")
        subLabel.BackgroundTransparency = 1
        subLabel.Position = UDim2.fromOffset(0, 34)
        subLabel.Size = UDim2.new(1, 0, 0, 26)
        subLabel.Font = Enum.Font.Gotham
        subLabel.TextSize = 14
        subLabel.TextColor3 = Color3.fromRGB(180, 220, 220)
        subLabel.TextStrokeTransparency = 0.4
        subLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
        subLabel.Text = "Starter biome"
        subLabel.Parent = gui
    end
end

local function makeBiome(biome: Biome, nodesParent: Instance, decorParent: Instance, rng: Random)
    makeBiomeMarker(biome, decorParent)
    makeBiomeGroundPatch(biome, decorParent)
    makeBiomeLandmark(biome, decorParent, rng)
    scatterBiomeDecor(biome, decorParent, rng)
    if biome.hasCottage then
        placeBiomeCottage(biome, decorParent, rng)
    end

    for i = 1, biome.nodeCount do
        local angle = (i / biome.nodeCount) * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
        local r = biome.radius * rng:NextNumber(0.45, 1.0)
        local x = biome.center.X + math.cos(angle) * r
        local z = biome.center.Z + math.sin(angle) * r
        local y = biome.center.Y
        local node = makeEssenceNode(biome, Vector3.new(x, y, z), rng)
        node.Parent = nodesParent
    end
end

-- =========================================================================
-- Ambient fireflies near the WorldTree
-- =========================================================================

local function makeFireflies(parent: Instance)
    for i = 1, 6 do
        local host = Instance.new("Part")
        host.Anchored = true
        host.CanCollide = false
        host.CanQuery = false
        host.Transparency = 1
        host.Size = Vector3.new(1, 1, 1)
        local theta = (i / 6) * math.pi * 2
        host.Position = Vector3.new(math.cos(theta) * 60, 6, math.sin(theta) * 60)
        host.Parent = parent

        local attach = Instance.new("Attachment")
        attach.Parent = host

        local emitter = Instance.new("ParticleEmitter")
        emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
        emitter.Color = ColorSequence.new(Color3.fromRGB(255, 235, 140))
        emitter.Lifetime = NumberRange.new(3, 6)
        emitter.Rate = 4
        emitter.Speed = NumberRange.new(1, 3)
        emitter.SpreadAngle = Vector2.new(180, 180)
        emitter.Size = NumberSequence.new(0.5)
        emitter.LightEmission = 0.9
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.2, 0.2),
            NumberSequenceKeypoint.new(0.8, 0.4),
            NumberSequenceKeypoint.new(1, 1),
        })
        emitter.Parent = attach
    end
end

-- =========================================================================
-- Public entrypoint
-- =========================================================================

-- StreamingEnabled has a Plugin-only security capability — regular Scripts
-- cannot set it. The user must configure it via Studio's Workspace properties
-- panel manually (see README). We try-and-catch here just so a future Plugin
-- runner could set it programmatically without breaking the normal startup.
local function tryConfigureStreaming()
    pcall(function()
        Workspace.StreamingEnabled = true
        Workspace.StreamingMinRadius = 96
        Workspace.StreamingTargetRadius = 256
        Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Default
    end)
end

function WorldBuilder.start()
    -- Wipe any previously-generated terrain so rebuilds are idempotent.
    Workspace.Terrain:Clear()

    -- Reset clearings (filled in by makeWorldTree, placeBiomeCottage, etc.)
    resetClearings()

    tryConfigureStreaming()
    configureLighting()
    makeAtmosphere()
    makeSky()
    makeGround()
    makeSpawn()
    makeWorldTree()

    destroyIfExists("EssenceNodes")
    local nodes = Instance.new("Folder")
    nodes.Name = "EssenceNodes"
    nodes.Parent = Workspace

    destroyIfExists("WorldDecor")
    local decor = Instance.new("Folder")
    decor.Name = "WorldDecor"
    decor.Parent = Workspace

    local rng = rngOf(1337)

    for _, biome in BIOMES do
        makeBiome(biome, nodes, decor, rng)
    end

    local pathPositions = buildAllPaths(decor, rng)
    makeLandscape(pathPositions)
    if FOREST_ENABLED then
        scatterForest(decor, rng, pathPositions)
    else
        print("[WorldBuilder] Forest disabled via FOREST_ENABLED constant.")
    end
    makeFireflies(decor)

    print(string.format("[WorldBuilder] Built %d biome(s) + paths (%d tiles), forest, decor.",
        #BIOMES, #pathPositions))
end

return WorldBuilder
