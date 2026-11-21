package.path = "mods/stevecraft/?.lua;" .. package.path

local Sections = require("systems/section_updates")
assert(Sections.SECTION_SIZE == 16, "Minecraft-style section dimensions must be 16 blocks")

local interior = Sections.sections_for_edit(8, 8, 8)
assert(#interior == 1, "an interior edit should dirty only its owning section")
assert(interior[1].key == "0,0,0")

local corner = Sections.sections_for_edit(15, 15, 15)
assert(#corner == 8, "a corner edit must dirty up to eight adjacent sections")
local corner_seen = {}
for _, section in ipairs(corner) do corner_seen[section.key] = true end
for _, key in ipairs({
    "0,0,0", "0,0,1", "0,1,0", "0,1,1",
    "1,0,0", "1,0,1", "1,1,0", "1,1,1",
}) do
    assert(corner_seen[key], "section halo omitted " .. key)
end

local blocks = {
    ["8,8,8"] = { id = "minecraft:stone" },
    ["9,8,8"] = { id = "minecraft:dirt" },
    ["7,8,8"] = { id = "minecraft:glass" },
    ["9,9,9"] = { id = "minecraft:oak_planks" },
    ["11,8,8"] = { id = "minecraft:sand" },
}
local affected, sections = Sections.affected_cells(blocks, 8, 8, 8)
assert(#affected == 4, "only existing blocks inside the 3x3x3 edit halo should be refreshed")
assert(#sections == 1, "interior edit unexpectedly dirtied multiple sections")
assert(affected[1].cell ~= nil and affected[1].section_key == "0,0,0")
assert(Sections.section_key(-1, 0, 0) == "-1,0,0",
    "negative block coordinates must use floor-based section indexing")

print("PASS: Minecraft-style 16x16x16 dirty sections, 3x3x3 local halo and up-to-eight boundary sections")
