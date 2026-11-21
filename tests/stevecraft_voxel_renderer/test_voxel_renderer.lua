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
    header = { gfx = { sharedChild = node } },
}
local glass = {
    _pointer = 1002,
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

local counts = Renderer.debug_counts()
assert(counts.meshes == 2 and counts.display_nodes == 1 and counts.objects == 2,
    "renderer resource registry counts are inconsistent")

print("PASS: per-material voxel Gfx/Vtx generation, per-object GeoLayout swapping, glass layer, and vanilla fallback")
