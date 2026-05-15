local Biomes = script.Parent:WaitForChild("Biomes")

return {
    require(Biomes:WaitForChild("GlimmerGlade")),
    require(Biomes:WaitForChild("VerdantHollow")),
    require(Biomes:WaitForChild("EmberReach")),
    require(Biomes:WaitForChild("WhisperingWood")),
    require(Biomes:WaitForChild("FrostpeakSpire")),
}
