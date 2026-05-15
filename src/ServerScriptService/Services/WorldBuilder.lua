--!strict
--[[
    WorldBuilder.lua
    ----------------
    Generates the world on server start. Idempotent — clears anything it would
    create before rebuilding, so you can hot-reload without piling up duplicates.

    Currently builds one biome ("Glimmer Glade") plus the central WorldTree.
    The biomes table is structured so adding new ones is a one-row change.

    Public API:
      .start()
]]

local Workspace = game:GetService("Workspace")
local Lighting  = game:GetService("Lighting")

local WorldBuilder = {}

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
    requiredWisps: number?,  -- for future progression gates
}

local BIOMES: { Biome } = {
    {
        id = "glimmer_glade",
        displayName = "Glimmer Glade",
        center = Vector3.new(0, 4, -50),
        radius = 40,
        nodeCount = 12,
        nodeColor = Color3.fromRGB(150, 220, 255),
        nodeMaterial = Enum.Material.Neon,
        nodeShape = Enum.PartType.Cylinder,
        nodeSize = Vector3.new(3, 4, 4),
        requiredWisps = 0,
    },
    -- Add future biomes here. Example:
    -- {
    --     id = "verdant_hollow",
    --     displayName = "Verdant Hollow",
    --     center = Vector3.new(150, 4, 0),
    --     radius = 50,
    --     nodeCount = 16,
    --     nodeColor = Color3.fromRGB(150, 255, 170),
    --     ...
    --     requiredWisps = 3,
    -- },
}

-- --------- helpers ---------

local function deterministic(seed: number)
    -- Roblox's Random is fine; using a fixed seed so the same world appears
    -- each server boot (predictable for testing).
    return Random.new(seed)
end

local function destroyIfExists(name: string)
    local existing = Workspace:FindFirstChild(name)
    if existing then existing:Destroy() end
end

local function makeWorldTree(): Model
    destroyIfExists("WorldTree")

    local model = Instance.new("Model")
    model.Name = "WorldTree"

    -- Trunk: tall green pillar
    local trunk = Instance.new("Part")
    trunk.Name = "Trunk"
    trunk.Anchored = true
    trunk.CanCollide = true
    trunk.Size = Vector3.new(8, 28, 8)
    trunk.Position = Vector3.new(0, 14, 0)
    trunk.Material = Enum.Material.Wood
    trunk.Color = Color3.fromRGB(80, 55, 40)
    trunk.Parent = model

    -- Canopy: large glowing sphere
    local canopy = Instance.new("Part")
    canopy.Name = "Canopy"
    canopy.Anchored = true
    canopy.CanCollide = false
    canopy.Shape = Enum.PartType.Ball
    canopy.Size = Vector3.new(20, 20, 20)
    canopy.Position = Vector3.new(0, 34, 0)
    canopy.Material = Enum.Material.Neon
    canopy.Color = Color3.fromRGB(120, 220, 140)
    canopy.Transparency = 0.15
    canopy.Parent = model

    -- Floating wisps of light around the canopy (decorative)
    for i = 1, 6 do
        local mote = Instance.new("Part")
        mote.Anchored = true
        mote.CanCollide = false
        mote.CanQuery = false
        mote.Shape = Enum.PartType.Ball
        mote.Size = Vector3.new(1.2, 1.2, 1.2)
        mote.Material = Enum.Material.Neon
        mote.Color = Color3.fromRGB(220, 255, 200)
        local theta = (i / 6) * math.pi * 2
        mote.Position = Vector3.new(math.cos(theta) * 12, 34 + math.sin(theta) * 3, math.sin(theta) * 12)
        mote.CastShadow = false
        local light = Instance.new("PointLight")
        light.Color = mote.Color
        light.Range = 14
        light.Brightness = 2
        light.Parent = mote
        mote.Parent = model
    end

    -- Ambient light at the base so it pops at night.
    local baseLight = Instance.new("PointLight")
    baseLight.Color = Color3.fromRGB(180, 255, 200)
    baseLight.Range = 40
    baseLight.Brightness = 3
    baseLight.Parent = trunk

    model.PrimaryPart = trunk
    model.Parent = Workspace

    return model
end

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

    -- Cylinders default to lying on their side; rotate so they stand up.
    if biome.nodeShape == Enum.PartType.Cylinder then
        part.Orientation = Vector3.new(0, 0, 90)
    end

    -- Soft glow
    local light = Instance.new("PointLight")
    light.Color = biome.nodeColor
    light.Range = 12
    light.Brightness = 1.2
    light.Parent = part

    -- Tag for future scripts (e.g. which biome it belongs to)
    part:SetAttribute("BiomeId", biome.id)

    return part
end

local function makeBiome(biome: Biome, parent: Instance, rng: Random)
    -- Optional progression sign — visible label in Studio + telemetry.
    local sign = Instance.new("Part")
    sign.Name = string.format("%sMarker", biome.displayName:gsub(" ", ""))
    sign.Anchored = true
    sign.CanCollide = false
    sign.Transparency = 1
    sign.Size = Vector3.new(2, 2, 2)
    sign.Position = biome.center + Vector3.new(0, 12, 0)
    sign.Parent = parent

    local gui = Instance.new("BillboardGui")
    gui.Size = UDim2.fromOffset(220, 50)
    gui.AlwaysOnTop = true
    gui.Parent = sign
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBlack
    label.TextSize = 20
    label.TextColor3 = biome.nodeColor
    label.TextStrokeTransparency = 0.4
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.Text = biome.displayName
    label.Parent = gui

    -- Place nodes in a low-discrepancy-ish ring around the biome center.
    -- Pure random can clump; jittered ring spread feels intentional.
    for i = 1, biome.nodeCount do
        local angle = (i / biome.nodeCount) * math.pi * 2 + rng:NextNumber(-0.15, 0.15)
        local r = biome.radius * rng:NextNumber(0.45, 1.0)
        local x = biome.center.X + math.cos(angle) * r
        local z = biome.center.Z + math.sin(angle) * r
        local y = biome.center.Y
        local node = makeEssenceNode(biome, Vector3.new(x, y, z))
        node.Parent = parent
    end
end

local function makeDecorRocks(parent: Instance, rng: Random)
    -- Scatter a few small dark rocks for visual interest.
    for _ = 1, 18 do
        local rock = Instance.new("Part")
        rock.Anchored = true
        rock.CanCollide = true
        rock.Material = Enum.Material.Slate
        rock.Color = Color3.fromRGB(60, 65, 75)
        local s = rng:NextNumber(1.5, 3.5)
        rock.Size = Vector3.new(s, s * 0.6, s)
        rock.Position = Vector3.new(rng:NextNumber(-90, 90), 1, rng:NextNumber(-90, 90))
        rock.Orientation = Vector3.new(0, rng:NextNumber(0, 360), 0)
        rock.CastShadow = false
        rock.Parent = parent
    end
end

-- --------- public ---------

function WorldBuilder.start()
    -- A bit of atmosphere — slightly dim, blueish ambient for the magical mood.
    Lighting.Ambient = Color3.fromRGB(40, 45, 60)
    Lighting.OutdoorAmbient = Color3.fromRGB(100, 110, 140)
    Lighting.FogColor = Color3.fromRGB(120, 140, 170)
    Lighting.FogEnd = 800

    makeWorldTree()

    -- Fresh EssenceNodes folder (kills anything left over from manual edits).
    destroyIfExists("EssenceNodes")
    local nodes = Instance.new("Folder")
    nodes.Name = "EssenceNodes"
    nodes.Parent = Workspace

    destroyIfExists("WorldDecor")
    local decor = Instance.new("Folder")
    decor.Name = "WorldDecor"
    decor.Parent = Workspace

    local rng = deterministic(1337)

    for _, biome in BIOMES do
        makeBiome(biome, nodes, rng)
    end

    makeDecorRocks(decor, rng)

    print(string.format("[WorldBuilder] Built %d biome(s).", #BIOMES))
end

return WorldBuilder
