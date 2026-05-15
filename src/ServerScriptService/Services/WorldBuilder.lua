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

local BIOMES: { Biome } = {
    {
        id = "glimmer_glade",
        displayName = "Glimmer Glade",
        center = Vector3.new(0, 4, -60),
        radius = 40,
        nodeCount = 14,
        nodeColor = Color3.fromRGB(150, 220, 255),
        nodeMaterial = Enum.Material.Neon,
        nodeShape = Enum.PartType.Cylinder,
        nodeSize = Vector3.new(3, 4, 4),
        requiredWisps = 0,
        essenceMultiplier = 1,
        groundColor = Color3.fromRGB(80, 110, 125),
        decorStyle = "glimmer",
        hasCottage = false,
    },
    {
        id = "verdant_hollow",
        displayName = "Verdant Hollow",
        center = Vector3.new(220, 4, 60),
        radius = 50,
        nodeCount = 16,
        nodeColor = Color3.fromRGB(140, 255, 170),
        nodeMaterial = Enum.Material.Neon,
        nodeShape = Enum.PartType.Cylinder,
        nodeSize = Vector3.new(3.5, 4.5, 4.5),
        requiredWisps = 3,
        essenceMultiplier = 2,
        groundColor = Color3.fromRGB(68, 115, 70),
        decorStyle = "verdant",
        hasCottage = true,
    },
    {
        id = "ember_reach",
        displayName = "Ember Reach",
        center = Vector3.new(-220, 4, 130),
        radius = 55,
        nodeCount = 18,
        nodeColor = Color3.fromRGB(255, 130, 80),
        nodeMaterial = Enum.Material.Neon,
        nodeShape = Enum.PartType.Cylinder,
        nodeSize = Vector3.new(4, 5, 5),
        requiredWisps = 8,
        essenceMultiplier = 4,
        groundColor = Color3.fromRGB(85, 55, 50),
        decorStyle = "ember",
        hasCottage = false,
    },
    {
        id = "whispering_wood",
        displayName = "Whispering Wood",
        center = Vector3.new(80, 4, 260),
        radius = 60,
        nodeCount = 18,
        nodeColor = Color3.fromRGB(200, 130, 200),
        nodeMaterial = Enum.Material.Neon,
        nodeShape = Enum.PartType.Cylinder,
        nodeSize = Vector3.new(3.5, 5, 5),
        requiredWisps = 6,
        essenceMultiplier = 3,
        groundColor = Color3.fromRGB(50, 65, 55),
        decorStyle = "whispering",
        hasCottage = true,
    },
    {
        id = "frostpeak_spire",
        displayName = "Frostpeak Spire",
        center = Vector3.new(-130, 4, -320),
        radius = 65,
        nodeCount = 20,
        nodeColor = Color3.fromRGB(170, 220, 255),
        nodeMaterial = Enum.Material.Neon,
        nodeShape = Enum.PartType.Cylinder,
        nodeSize = Vector3.new(4, 6, 6),
        requiredWisps = 12,
        essenceMultiplier = 6,
        groundColor = Color3.fromRGB(195, 210, 225),
        decorStyle = "frostpeak",
        hasCottage = true,
    },
}

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

    for i = 1, 5 do
        local root = Instance.new("Part")
        root.Anchored = true
        root.CanCollide = false
        root.Shape = Enum.PartType.Cylinder
        root.Size = Vector3.new(8, 4, 4)
        local angle = (i / 5) * math.pi * 2
        root.Position = Vector3.new(math.cos(angle) * 5, 2, math.sin(angle) * 5)
        root.Orientation = Vector3.new(0, math.deg(-angle), 70)
        root.Material = Enum.Material.Wood
        root.Color = Color3.fromRGB(75, 50, 35)
        root.Parent = model
    end

    local trunk = Instance.new("Part")
    trunk.Name = "Trunk"
    trunk.Anchored = true
    trunk.CanCollide = true
    trunk.Size = Vector3.new(10, 36, 10)
    trunk.Position = Vector3.new(0, 18, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(80, 55, 40)
    trunk.Parent = model

    local canopySpheres = {
        { offset = Vector3.new(0, 42, 0),   size = 30, color = Color3.fromRGB(120, 220, 140), transparency = 0.1 },
        { offset = Vector3.new(9, 38, 5),   size = 19, color = Color3.fromRGB(140, 230, 160), transparency = 0.15 },
        { offset = Vector3.new(-8, 39, -6), size = 21, color = Color3.fromRGB(130, 225, 150), transparency = 0.12 },
        { offset = Vector3.new(4, 46, -8),  size = 16, color = Color3.fromRGB(150, 240, 170), transparency = 0.18 },
        { offset = Vector3.new(-5, 45, 7),  size = 15, color = Color3.fromRGB(135, 230, 155), transparency = 0.2 },
    }
    for _, c in canopySpheres do
        local canopy = Instance.new("Part")
        canopy.Anchored = true
        canopy.CanCollide = false
        canopy.Shape = Enum.PartType.Ball
        canopy.Size = Vector3.new(c.size, c.size, c.size)
        canopy.Position = c.offset
        canopy.Material = Enum.Material.LeafyGrass
        canopy.Color = c.color
        canopy.Transparency = c.transparency
        canopy.CastShadow = false
        canopy.Parent = model
    end

    for i = 1, 12 do
        local mote = Instance.new("Part")
        mote.Anchored = true
        mote.CanCollide = false
        mote.CanQuery = false
        mote.Shape = Enum.PartType.Ball
        mote.Size = Vector3.new(0.9, 0.9, 0.9)
        mote.Material = Enum.Material.Neon
        mote.Color = Color3.fromRGB(220, 255, 200)
        local theta = (i / 12) * math.pi * 2
        local r = 16 + (i % 2) * 4
        mote.Position = Vector3.new(math.cos(theta) * r, 40 + math.sin(theta * 1.7) * 5, math.sin(theta) * r)
        mote.CastShadow = false
        local pl = Instance.new("PointLight")
        pl.Color = mote.Color
        pl.Range = 12
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

local function makeOakTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = false
    trunk.Size = Vector3.new(2 * scale, 9 * scale, 2 * scale)
    trunk.Position = position + Vector3.new(0, 4.5 * scale, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(68, 48, 35)
    trunk.CastShadow = true
    trunk.Parent = parent

    local leafBase = Color3.fromRGB(75, 130, 70)
    for i = 1, 3 do
        local canopy = Instance.new("Part")
        canopy.Anchored = true
        canopy.CanCollide = false
        canopy.Shape = Enum.PartType.Ball
        canopy.Size = Vector3.new(8 * scale, 8 * scale, 8 * scale) * (i == 1 and 1 or 0.85)
        canopy.Position = position + Vector3.new(
            (i - 2) * scale * 1.6,
            (10 + i * 0.7) * scale,
            ((i + 1) % 2) * scale * 1.6 - scale * 0.8
        )
        canopy.Material = Enum.Material.LeafyGrass
        canopy.Color = tintLeaves(leafBase, rng)
        canopy.CastShadow = true
        canopy.Parent = parent
    end
end

local function makePineTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = false
    trunk.Size = Vector3.new(1.4 * scale, 8 * scale, 1.4 * scale)
    trunk.Position = position + Vector3.new(0, 4 * scale, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(55, 38, 28)
    trunk.CastShadow = true
    trunk.Parent = parent

    local leafBase = Color3.fromRGB(40, 75, 45)
    for i = 0, 4 do
        local tier = Instance.new("Part")
        tier.Anchored = true
        tier.CanCollide = false
        tier.Shape = Enum.PartType.Ball
        local tierScale = (6 - i * 1.0) * scale
        tier.Size = Vector3.new(tierScale, tierScale * 0.55, tierScale)
        tier.Position = position + Vector3.new(0, (7 + i * 2.6) * scale, 0)
        tier.Material = Enum.Material.LeafyGrass
        tier.Color = tintLeaves(leafBase, rng)
        tier.CastShadow = true
        tier.Parent = parent
    end
end

local function makeWillowTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = false
    trunk.Size = Vector3.new(2.2 * scale, 10 * scale, 2.2 * scale)
    trunk.Position = position + Vector3.new(0, 5 * scale, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(60, 50, 40)
    trunk.CastShadow = true
    trunk.Parent = parent

    -- Droopy canopy: 4 lower spheres around a central one
    local leafBase = Color3.fromRGB(90, 140, 95)
    for i = 1, 5 do
        local canopy = Instance.new("Part")
        canopy.Anchored = true
        canopy.CanCollide = false
        canopy.Shape = Enum.PartType.Ball
        canopy.Size = Vector3.new(6 * scale, 5 * scale, 6 * scale)
        local theta = ((i - 1) / 4) * math.pi * 2
        local r = (i == 5) and 0 or 3.5
        canopy.Position = position + Vector3.new(
            math.cos(theta) * r * scale,
            (10 + (i == 5 and 1 or 0)) * scale,
            math.sin(theta) * r * scale
        )
        canopy.Material = Enum.Material.LeafyGrass
        canopy.Color = tintLeaves(leafBase, rng)
        canopy.CastShadow = true
        canopy.Parent = parent
    end
end

local function makeAspenTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = false
    trunk.Size = Vector3.new(1.2 * scale, 14 * scale, 1.2 * scale)
    trunk.Position = position + Vector3.new(0, 7 * scale, 0)
    trunk.Material = Enum.Material.WoodPlanks
    trunk.Color = Color3.fromRGB(210, 210, 200)
    trunk.CastShadow = true
    trunk.Parent = parent

    local leafBase = Color3.fromRGB(130, 220, 140)
    for i = 1, 2 do
        local canopy = Instance.new("Part")
        canopy.Anchored = true
        canopy.CanCollide = false
        canopy.Shape = Enum.PartType.Ball
        canopy.Size = Vector3.new(5.5 * scale, 7 * scale, 5.5 * scale)
        canopy.Position = position + Vector3.new(0, (14 + i * 2.2) * scale, 0)
        canopy.Material = Enum.Material.LeafyGrass
        canopy.Color = tintLeaves(leafBase, rng)
        canopy.CastShadow = true
        canopy.Parent = parent
    end
end

local function makeBareTree(position: Vector3, scale: number, parent: Instance, rng: Random)
    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = false
    trunk.Size = Vector3.new(1.6 * scale, 11 * scale, 1.6 * scale)
    trunk.Position = position + Vector3.new(0, 5.5 * scale, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(38, 30, 25)
    trunk.CastShadow = true
    trunk.Parent = parent

    for i = 1, 5 do
        local branch = Instance.new("Part")
        branch.Anchored = true
        branch.CanCollide = false
        branch.Size = Vector3.new(0.6 * scale, 3.5 * scale, 0.6 * scale)
        local angle = rng:NextNumber(0, math.pi * 2)
        branch.Position = position + Vector3.new(
            math.cos(angle) * scale * 1.2,
            (9 + i * 0.6) * scale,
            math.sin(angle) * scale * 1.2
        )
        branch.Orientation = Vector3.new(math.deg(angle * 0.4), math.deg(angle), rng:NextInteger(15, 45))
        branch.Material = Enum.Material.Wood
        branch.Color = Color3.fromRGB(38, 30, 25)
        branch.Parent = parent
    end
end

local function makeSnowPine(position: Vector3, scale: number, parent: Instance)
    local trunk = Instance.new("Part")
    trunk.Anchored = true
    trunk.CanCollide = false
    trunk.Size = Vector3.new(1.4 * scale, 8 * scale, 1.4 * scale)
    trunk.Position = position + Vector3.new(0, 4 * scale, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(60, 40, 30)
    trunk.CastShadow = true
    trunk.Parent = parent

    for i = 0, 4 do
        local tier = Instance.new("Part")
        tier.Anchored = true
        tier.CanCollide = false
        tier.Shape = Enum.PartType.Ball
        local tierScale = (6 - i * 1.0) * scale
        tier.Size = Vector3.new(tierScale, tierScale * 0.6, tierScale)
        tier.Position = position + Vector3.new(0, (7 + i * 2.6) * scale, 0)
        tier.Material = Enum.Material.Snow
        tier.Color = Color3.fromRGB(225, 235, 245)
        tier.CastShadow = true
        tier.Parent = parent
    end
end

-- =========================================================================
-- Forest scattering — denser, mixed
-- =========================================================================

local function scatterForest(parent: Instance, rng: Random)
    local TARGET_COUNT = 280
    local placed = 0
    local attempts = 0
    while placed < TARGET_COUNT and attempts < TARGET_COUNT * 10 do
        attempts += 1
        local x = rng:NextNumber(-MAP_HALF, MAP_HALF)
        local z = rng:NextNumber(-MAP_HALF, MAP_HALF)
        local pos = Vector3.new(x, 2, z)

        local nearBiomeDist, nearestBiome = distanceToAnyBiome(pos)
        -- Keep biome interiors clear but allow trees right up to the edge.
        if nearestBiome and nearBiomeDist < nearestBiome.radius + 8 then continue end
        -- WorldTree clearing
        if pos.Magnitude < 36 then continue end

        local roll = rng:NextNumber()
        local scale = rng:NextNumber(1.0, 1.7)
        if roll < 0.35 then
            makeOakTree(pos, scale, parent, rng)
        elseif roll < 0.7 then
            makePineTree(pos, scale, parent, rng)
        elseif roll < 0.9 then
            makeWillowTree(pos, scale, parent, rng)
        else
            makeAspenTree(pos, scale, parent, rng)
        end
        placed += 1
    end
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

        if biome.decorStyle == "glimmer" then
            if rng:NextNumber() < 0.6 then
                makeGlimmerMushroom(pos, parent)
            else
                makeGlimmerCrystal(pos, parent)
            end
        elseif biome.decorStyle == "verdant" then
            if rng:NextNumber() < 0.6 then
                makeVerdantTuft(pos, parent)
            else
                makeAspenTree(pos, rng:NextNumber(0.9, 1.4), parent, rng)
            end
        elseif biome.decorStyle == "ember" then
            if rng:NextNumber() < 0.5 then
                makeEmberLavaRock(pos, parent, rng)
            else
                makeBareTree(pos, rng:NextNumber(1.0, 1.5), parent, rng)
            end
        elseif biome.decorStyle == "whispering" then
            local roll = rng:NextNumber()
            if roll < 0.4 then
                makeRedMushroom(pos, parent)
            elseif roll < 0.75 then
                makePineTree(pos, rng:NextNumber(1.0, 1.6), parent, rng)
            else
                makeOakTree(pos, rng:NextNumber(1.0, 1.5), parent, rng)
            end
        elseif biome.decorStyle == "frostpeak" then
            local roll = rng:NextNumber()
            if roll < 0.55 then
                makeSnowPine(pos, rng:NextNumber(1.0, 1.5), parent)
            else
                makeIceShard(pos, parent, rng)
            end
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

    makeCottage(cottagePos, parent, roofColor)
end

-- =========================================================================
-- Paths between WorldTree and biomes
-- =========================================================================

local function makePathTile(pos: Vector3, parent: Instance, rng: Random)
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
end

local function makePath(startPos: Vector3, target: Vector3, parent: Instance, rng: Random)
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
        makePathTile(p, parent, rng)
    end
end

local function buildAllPaths(parent: Instance, rng: Random)
    for _, biome in BIOMES do
        if biome.id == "glimmer_glade" then continue end  -- starter biome stays naturally connected
        local startPos = Vector3.new(0, 0, 0)
        local target = biome.center - (biome.center.Unit * (biome.radius + 2))
        target = Vector3.new(target.X, 0, target.Z)
        makePath(startPos, target, parent, rng)
    end
end

-- =========================================================================
-- Essence node + biome marker
-- =========================================================================

local function makeEssenceNode(biome: Biome, position: Vector3): Part
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
        local node = makeEssenceNode(biome, Vector3.new(x, y, z))
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

function WorldBuilder.start()
    configureLighting()
    makeAtmosphere()
    makeSky()
    makeGround()
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

    buildAllPaths(decor, rng)
    scatterForest(decor, rng)
    makeFireflies(decor)

    print(string.format("[WorldBuilder] Built %d biome(s), forest, paths, decor.", #BIOMES))
end

return WorldBuilder
