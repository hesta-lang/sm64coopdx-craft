package.path = "mods/stevecraft/?.lua;" .. package.path

local hooks = {}
local current_object = nil
local gfx_buffers = {}
local vtx_buffers = {}

GRAPH_NODE_TYPE_DISPLAY_LIST = 27
LAYER_OPAQUE = 1
LAYER_TRANSPARENT = 5
HOOK_BEFORE_GEO_PROCESS = 71
HOOK_ON_OBJECT_UNLOAD = 72
HOOK_ON_LEVEL_INIT = 73

function hook_event(event, callback)
    hooks[event] = callback
end

function geo_get_current_object()
    return current_object
end

function cast_graph_node(node)
    return node
end

function gfx_get_from_name(name)
    local buffer = gfx_buffers[name]
    return buffer and { buffer = buffer, index = 0 } or nil
end

function gfx_create(name, length)
    if gfx_buffers[name] then return nil end
    local buffer = { name = name, length = length, commands = {} }
    gfx_buffers[name] = buffer
    return { buffer = buffer, index = 0 }
end

function gfx_resize(pointer, length)
    pointer.buffer.length = length
    pointer.buffer.commands = {}
end

function gfx_get_next_command(pointer)
    local next_index = pointer.index + 1
    if next_index >= pointer.buffer.length then return nil end
    return { buffer = pointer.buffer, index = next_index }
end

function gfx_set_command(pointer, command, ...)
    pointer.buffer.commands[pointer.index + 1] = {
        command = command,
        args = { ... },
    }
    return true
end

function vtx_get_from_name(name)
    local buffer = vtx_buffers[name]
    return buffer
end

function vtx_create(name, count)
    local buffer = { name = name, vertices = {} }
    for i = 1, count do buffer.vertices[i] = {} end
    vtx_buffers[name] = buffer
    return buffer
end

function vtx_resize(buffer, count)
    for i = #buffer.vertices + 1, count do buffer.vertices[i] = {} end
end

function vtx_get_vertex(buffer, offset)
    return buffer.vertices[offset + 1]
end

local Renderer = require("systems/voxel_renderer")
local map = {
    stone = { texture = { name = "stone" }, width = 16, height = 16 },
    dirt = { texture = { name = "dirt" }, width = 16, height = 16 },
    grass_top = { texture = { name = "grass_top" }, width = 16, height = 16 },
    grass_side = { texture = { name = "grass_side" }, width = 16, height = 16 },
    oak_planks = { texture = { name = "oak_planks" }, width = 16, height = 16 },
    cobblestone = { texture = { name = "cobblestone" }, width = 16, height = 16 },
    glass = { texture = { name = "glass" }, width = 16, height = 16 },
    bricks = { texture = { name = "bricks" }, width = 16, height = 16 },
    sand = { texture = { name = "sand" }, width = 16, height = 16 },
    bedrock = { texture = { name = "bedrock" }, width = 16, height = 16 },
}
assert(Renderer.configure(map) == true, "texture map was not accepted")
assert(Renderer.install_hooks() == true, "renderer hooks did not install")

local original = { name = "vanilla_breakable_box" }
local node = {
    _pointer = 501,
    type = GRAPH_NODE_TYPE_DISPLAY_LIST,
    hookProcess = 0,
    flags = LAYER_OPAQUE * 256 + 3,
    displayList = original,
}
node.next = node

local stone = {
    _pointer = 1001,
    oPosX = 45, oPosY = 45, oPosZ = 45,
    header = { gfx = { sharedChild = node } },
}
local glass = {
    _pointer = 1002,
    oPosX = 45, oPosY = 45, oPosZ = 45,
    header = { gfx = { sharedChild = node } },
}

assert(Renderer.attach(stone, "minecraft:stone") == true, "stone mesh failed to attach")
assert(Renderer.attach(glass, "minecraft:glass") == true, "glass mesh failed to attach")
assert(node.hookProcess == 1, "display-list node was not marked for processing")
assert(Renderer.get_attached_block(stone) == "minecraft:stone")
assert(Renderer.get_attached_block(glass) == "minecraft:glass")

current_object = stone
hooks[HOOK_BEFORE_GEO_PROCESS](node, 0)
local stone_mesh = Renderer.get_mesh("minecraft:stone")
assert(stone_mesh ~= nil and stone_mesh.vertex_count == 24, "stone cube did not build 24 vertices")
assert(stone_mesh.command_count == #stone_mesh.gfx.buffer.commands, "stone Gfx command count mismatch")
assert(stone_mesh.gfx ~= Renderer.get_mesh("minecraft:glass").gfx,
    "per-object meshes unexpectedly share their Gfx buffer")
local modulate_found = false
for _, entry in ipairs(stone_mesh.gfx.buffer.commands) do
    if entry.command == "gsDPSetCombineMode(G_CC_MODULATERGBA, G_CC_MODULATERGBA)" then
        modulate_found = true
    end
end
assert(modulate_found, "voxel renderer did not multiply texture colors by vertex shade")
assert(stone_mesh.vtx.vertices[1].r == 204, "front side directional shade incorrect")
assert(stone_mesh.vtx.vertices[9].r == 255, "top face directional shade incorrect")
assert(stone_mesh.vtx.vertices[13].r == 128, "bottom face directional shade incorrect")
local open_shading = Renderer.compute_face_shading({}, 0, 0, 0)
local open_faces = Renderer.compute_visible_faces({}, 0, 0, 0)
assert(#open_faces == 6, "isolated cube should expose six faces")
assert(open_shading[1][1] > 0.79 and open_shading[1][1] < 0.81,
    "front face direction factor incorrect")
assert(open_shading[3][1] == 1.0, "top face should be brightest")
assert(open_shading[4][1] == 0.5, "bottom face should be darkest")
local facing_shading = Renderer.compute_face_shading({
    ["0,0,1"] = { id = "minecraft:stone" },
}, 0, 0, 0)
assert(math.abs(facing_shading[1][1] - 0.64) < 0.001,
    "facing solid-block sample did not apply Minecraft's 0.2 AO brightness")
local ao_shading = Renderer.compute_face_shading({
    ["1,0,1"] = { id = "minecraft:stone" },
    ["0,1,1"] = { id = "minecraft:dirt" },
}, 0, 0, 0)
assert(math.abs(ao_shading[1][4] - 0.48) < 0.001,
    "side/corner samples did not match Minecraft's four-sample AO average")
local glass_shading = Renderer.compute_face_shading({
    ["1,0,1"] = { id = "minecraft:glass" },
    ["0,1,1"] = { id = "minecraft:glass" },
}, 0, 0, 0)
assert(glass_shading[1][4] == open_shading[1][4],
    "transparent glass should not darken ambient-occlusion corners")

-- One adjacent block hides exactly the common face; all remaining faces stay.
local one_neighbour = { ["0,0,1"] = { id = "minecraft:stone" } }
local culled_faces = Renderer.compute_visible_faces(one_neighbour, 0, 0, 0)
assert(#culled_faces == 5, "shared face was not removed from the exposed-face list")
assert(culled_faces[1].shading_index ~= 1, "front face remained visible against a neighbour")
assert(Renderer.attach(stone, "minecraft:stone", one_neighbour),
    "mesh could not be rebuilt for a local block edit")
stone_mesh = Renderer.get_mesh("minecraft:stone")
assert(stone_mesh.face_count == 5 and stone_mesh.vertex_count == 20,
    "face-culling did not reduce a cube to five faces / 20 vertices")

-- An enclosed full cube is collision-only and owns an empty display list.
local enclosed = {
    ["0,0,1"] = { id = "minecraft:stone" },
    ["0,0,-1"] = { id = "minecraft:stone" },
    ["0,1,0"] = { id = "minecraft:stone" },
    ["0,-1,0"] = { id = "minecraft:stone" },
    ["1,0,0"] = { id = "minecraft:stone" },
    ["-1,0,0"] = { id = "minecraft:stone" },
}
assert(#Renderer.compute_visible_faces(enclosed, 0, 0, 0) == 0,
    "fully enclosed block must not emit any render faces")
local point_filter_found = false
for _, entry in ipairs(stone_mesh.gfx.buffer.commands) do
    if entry.command == "gsDPSetTextureFilter(G_TF_POINT)" then point_filter_found = true end
end
assert(point_filter_found, "voxel renderer did not force nearest-neighbor texture filtering")
assert(node.displayList == stone_mesh.gfx, "stone display list was not substituted")
assert(node.flags == LAYER_OPAQUE * 256 + 3, "opaque block display layer changed unexpectedly")

current_object = glass
hooks[HOOK_BEFORE_GEO_PROCESS](node, 0)
local glass_mesh = Renderer.get_mesh("minecraft:glass")
assert(glass_mesh ~= nil and node.displayList == glass_mesh.gfx, "glass display list was not substituted")
assert(math.floor(node.flags / 256) == LAYER_TRANSPARENT, "glass did not move to the transparent render layer")

current_object = nil
hooks[HOOK_BEFORE_GEO_PROCESS](node, 0)
assert(node.displayList == original, "vanilla display list was not restored for an unmanaged object")
assert(node.flags == LAYER_OPAQUE * 256 + 3, "original display-list flags were not restored")

-- A mined terrain collision triangle receives a separate, non-colliding
-- dark prism mask. The original level GeoLayout is not modified by this mod.
local mask_original = { name = "vanilla_mask_carrier" }
local mask_node = {
    _pointer = 503,
    type = GRAPH_NODE_TYPE_DISPLAY_LIST,
    hookProcess = 0,
    flags = LAYER_OPAQUE * 256 + 3,
    displayList = mask_original,
}
mask_node.next = mask_node
local mask_object = {
    _pointer = 1003,
    oPosX = 100, oPosY = 100, oPosZ = 100,
    header = { gfx = { sharedChild = mask_node } },
}
local terrain_snapshot = {
    signature = "0:0:0,100,0|100,100,0|0,100,100",
    vertices = {
        { x = 0, y = 100, z = 0 },
        { x = 100, y = 100, z = 0 },
        { x = 0, y = 100, z = 100 },
    },
    normal = { x = 0, y = 1, z = 0 },
}
assert(Renderer.attach_surface_mask(mask_object, terrain_snapshot),
    "terrain hole mask failed to attach")
assert(Renderer.is_ready(mask_object) and Renderer.is_surface_mask(mask_object),
    "terrain hole mask was not marked ready")
assert(Renderer.get_attached_block(mask_object) == "stevecraft:terrain_hole",
    "terrain hole mask did not receive its special renderer id")
local mask_mesh = gfx_buffers["stevecraft_terrain_hole_"
    .. terrain_snapshot.signature:gsub("[^%w_]", "_") .. "_dl"]
assert(mask_mesh ~= nil and mask_mesh.commands[1] ~= nil,
    "terrain mask did not create its dark-prism display list")
assert(Renderer.attach_surface_mask(mask_object, terrain_snapshot),
    "repeated terrain-mask attachment should be idempotent")
current_object = mask_object
hooks[HOOK_BEFORE_GEO_PROCESS](mask_node, 0)
assert(mask_node.displayList ~= mask_original,
    "terrain mask display list was not substituted into the object GeoLayout")
current_object = nil
hooks[HOOK_BEFORE_GEO_PROCESS](mask_node, 0)
assert(mask_node.displayList == mask_original,
    "terrain mask did not restore the original carrier display list")

local counts = Renderer.debug_counts()
assert(counts.meshes == 2 and counts.display_nodes == 1 and counts.objects == 2,
    "renderer resource registry counts are inconsistent")

print("PASS: per-object display lists, AO, per-face culling, empty enclosed blocks, glass layer and vanilla fallback")
