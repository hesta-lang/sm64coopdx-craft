-- SteveCraft runtime voxel display-list renderer.
-- Reuses the existing breakable-box GeoLayout as a carrier and swaps its
-- GraphNodeDisplayList pointer during HOOK_BEFORE_GEO_PROCESS. No APK rebuild
-- or additional native library is required.

local Renderer = {}

local texture_info = {}
local meshes = {} -- per-object mesh instances; vertex color values encode AO
local material_meshes = {}
local object_blocks = {}
local display_nodes = {}
local hooks_installed = false
local warned = {}

local FACE_LAYOUTS = {
    {
        normal = { 0, 0, 1 },
        texture = "side",
        vertices = {
            { -100, -100,  100 }, {  100, -100,  100 },
            { -100,  100,  100 }, {  100,  100,  100 },
        },
    },
    {
        normal = { 0, 0, -1 },
        texture = "side",
        vertices = {
            {  100, -100, -100 }, { -100, -100, -100 },
            {  100,  100, -100 }, { -100,  100, -100 },
        },
    },
    {
        normal = { 0, 1, 0 },
        texture = "top",
        vertices = {
            { -100,  100,  100 }, {  100,  100,  100 },
            { -100,  100, -100 }, {  100,  100, -100 },
        },
    },
    {
        normal = { 0, -1, 0 },
        texture = "bottom",
        vertices = {
            { -100, -100, -100 }, {  100, -100, -100 },
            { -100, -100,  100 }, {  100, -100,  100 },
        },
    },
    {
        normal = { 1, 0, 0 },
        texture = "side",
        vertices = {
            {  100, -100,  100 }, {  100, -100, -100 },
            {  100,  100,  100 }, {  100,  100, -100 },
        },
    },
    {
        normal = { -1, 0, 0 },
        texture = "side",
        vertices = {
            { -100, -100, -100 }, { -100, -100,  100 },
            { -100,  100, -100 }, { -100,  100,  100 },
        },
    },
}

local BLOCK_TEXTURES = {
    ["minecraft:stone"] = { side = "stone", top = "stone", bottom = "stone" },
    ["minecraft:dirt"] = { side = "dirt", top = "dirt", bottom = "dirt" },
    ["minecraft:grass_block"] = { side = "grass_side", top = "grass_top", bottom = "dirt" },
    ["minecraft:oak_planks"] = { side = "oak_planks", top = "oak_planks", bottom = "oak_planks" },
    ["minecraft:cobblestone"] = { side = "cobblestone", top = "cobblestone", bottom = "cobblestone" },
    ["minecraft:glass"] = { side = "glass", top = "glass", bottom = "glass" },
    ["minecraft:bricks"] = { side = "bricks", top = "bricks", bottom = "bricks" },
    ["minecraft:sand"] = { side = "sand", top = "sand", bottom = "sand" },
    ["minecraft:bedrock"] = { side = "bedrock", top = "bedrock", bottom = "bedrock" },
}

local FACE_SHADING = {
    -- Tangent axes and corner order correspond exactly to FACE_LAYOUTS vertices.
    { n = { 0, 0, 1 }, u = { 1, 0, 0 }, v = { 0, 1, 0 }, corners = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }, directional = 0.80 },
    { n = { 0, 0, -1 }, u = { 1, 0, 0 }, v = { 0, 1, 0 }, corners = { { 1, -1 }, { -1, -1 }, { 1, 1 }, { -1, 1 } }, directional = 0.80 },
    { n = { 0, 1, 0 }, u = { 1, 0, 0 }, v = { 0, 0, 1 }, corners = { { -1, 1 }, { 1, 1 }, { -1, -1 }, { 1, -1 } }, directional = 1.00 },
    { n = { 0, -1, 0 }, u = { 1, 0, 0 }, v = { 0, 0, 1 }, corners = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }, directional = 0.50 },
    { n = { 1, 0, 0 }, u = { 0, 0, 1 }, v = { 0, 1, 0 }, corners = { { 1, -1 }, { -1, -1 }, { 1, 1 }, { -1, 1 } }, directional = 0.60 },
    { n = { -1, 0, 0 }, u = { 0, 0, 1 }, v = { 0, 1, 0 }, corners = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }, directional = 0.60 },
}

local function object_key(object)
    if object == nil then return nil end
    local ok, pointer = pcall(function() return object._pointer end)
    if not ok or pointer == nil then return nil end
    return tostring(pointer)
end

local function node_key(node)
    if node == nil then return nil end
    local ok, pointer = pcall(function() return node._pointer end)
    if ok and pointer ~= nil then return tostring(pointer) end
    return tostring(node)
end

local function texture_for_block(block_id, face)
    local mapping = BLOCK_TEXTURES[block_id]
    if not mapping then return nil end
    local key = mapping[face.texture]
    local info = key and texture_info[key] or nil
    if type(info) ~= "table" or info.texture == nil then return nil end
    local width = math.floor(tonumber(info.width) or 0)
    local height = math.floor(tonumber(info.height) or 0)
    if width < 1 or height < 1 or width > 64 or height > 64 then return nil end
    return info, width, height
end

local function set_vertices(vtx, block_id, face_shading, visible_faces)
    local mapping = BLOCK_TEXTURES[block_id]
    if not mapping then return false, "unknown block id" end

    local vertex_index = 0
    for mesh_face_index, entry in ipairs(visible_faces) do
        local face = entry.face
        local info, width, height = texture_for_block(block_id, face)
        if not info then
            return false, "missing texture for " .. tostring(block_id) .. "/" .. face.texture
        end
        local max_s = (width - 1) * 32
        local max_t = (height - 1) * 32
        local uv = {
            { 0, max_t }, { max_s, max_t },
            { 0, 0 }, { max_s, 0 },
        }
        local shade_values = face_shading[entry.shading_index]
        for index, position in ipairs(face.vertices) do
            local vertex = vtx_get_vertex(vtx, vertex_index)
            if vertex == nil then return false, "vtx_get_vertex returned nil" end
            vertex.x = position[1]
            vertex.y = position[2]
            vertex.z = position[3]
            vertex.tu = uv[index][1]
            vertex.tv = uv[index][2]
            local shade = shade_values and shade_values[index] or 1.0
            local brightness = math.max(0, math.min(255, math.floor(shade * 255 + 0.5)))
            vertex.r = brightness
            vertex.g = brightness
            vertex.b = brightness
            vertex.a = 0xFF
            vertex_index = vertex_index + 1
        end
    end
    return true, vertex_index
end

local function build_mesh(block_id, face_shading, mesh_key, visible_faces)
    if type(gfx_create) ~= "function" or type(vtx_create) ~= "function"
        or type(gfx_set_command) ~= "function" or type(cast_graph_node) ~= "function"
        or type(gfx_get_next_command) ~= "function"
        or type(gfx_get_from_name) ~= "function" or type(gfx_resize) ~= "function"
        or type(vtx_get_vertex) ~= "function" or type(vtx_get_from_name) ~= "function"
        or type(vtx_resize) ~= "function" then
        return nil, "dynamic Gfx/Vtx APIs are unavailable"
    end

    local name = tostring(mesh_key or block_id):gsub("[^%w_]", "_")
    local vtx_name = "stevecraft_voxel_" .. name .. "_vtx"
    local gfx_name = "stevecraft_voxel_" .. name .. "_dl"

    local vtx = type(vtx_get_from_name) == "function" and vtx_get_from_name(vtx_name) or nil
    local requested_vertices = #visible_faces * 4
    local allocated_vertices = math.max(1, requested_vertices)
    if vtx == nil then
        vtx = vtx_create(vtx_name, allocated_vertices)
    else
        vtx_resize(vtx, allocated_vertices)
    end
    if vtx == nil then return nil, "could not allocate voxel vertices" end

    local vertices_ok, vertices_error = set_vertices(vtx, block_id, face_shading, visible_faces)
    if not vertices_ok then return nil, vertices_error end

    local gfx = type(gfx_get_from_name) == "function" and gfx_get_from_name(gfx_name) or nil
    if gfx == nil then
        gfx = gfx_create(gfx_name, 64)
    else
        gfx_resize(gfx, 64)
    end
    if gfx == nil then return nil, "could not allocate display list" end

    local cursor = gfx
    local command_count = 0
    local function add(command, ...)
        if cursor == nil then return false, "display list is full before " .. command end
        local ok, err = pcall(gfx_set_command, cursor, command, ...)
        if not ok then return false, tostring(err) end
        command_count = command_count + 1
        cursor = gfx_get_next_command(cursor)
        return true
    end
    local function require_command(command, ...)
        local ok, err = add(command, ...)
        if not ok then error(err, 0) end
    end

    local ok, err = pcall(function()
        require_command("gsSPGeometryMode(G_TEXTURE_GEN | G_CULL_BOTH | G_LIGHTING, 0)")
        require_command("gsDPSetTextureFilter(G_TF_POINT)")
        require_command("gsDPSetCombineMode(G_CC_MODULATERGBA, G_CC_MODULATERGBA)")
        require_command("gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_ON)")
        require_command("gsDPSetTile(G_IM_FMT_RGBA, G_IM_SIZ_32b, 0, 0, G_TX_LOADTILE, 0, G_TX_CLAMP, 0, G_TX_NOLOD, G_TX_CLAMP, 0, G_TX_NOLOD)")
        if #visible_faces > 0 then
            require_command("gsSPVertex(%v, %i, 0)", vtx, #visible_faces * 4)
        end

        for face_index, entry in ipairs(visible_faces) do
            local face = entry.face
            local info, width, height = texture_for_block(block_id, face)
            if info == nil then error("texture disappeared during display-list generation", 0) end
            local row_bytes = width * 4
            local line_words = math.floor((row_bytes + 7) / 8)
            local dxt = math.floor((2048 + row_bytes - 1) / row_bytes)
            local first = (face_index - 1) * 4

            require_command("gsDPSetTextureImage(G_IM_FMT_RGBA, G_IM_SIZ_32b, 1, %t)", info.texture)
            require_command("gsDPLoadSync()")
            require_command("gsDPLoadBlock(G_TX_LOADTILE, 0, 0, %i, %i)", width * height - 1, dxt)
            require_command("gsDPPipeSync()")
            require_command("gsDPTileSync()")
            require_command("gsDPSetTile(G_IM_FMT_RGBA, G_IM_SIZ_32b, %i, 0, G_TX_RENDERTILE, 0, G_TX_CLAMP, 0, G_TX_NOLOD, G_TX_CLAMP, 0, G_TX_NOLOD)", line_words)
            require_command("gsDPSetTileSize(G_TX_RENDERTILE, 0, 0, %i, %i)", (width - 1) * 4, (height - 1) * 4)
            require_command(
                "gsSP2Triangles(%i, %i, %i, 0, %i, %i, %i, 0)",
                first, first + 1, first + 2,
                first + 2, first + 1, first + 3
            )
        end

        require_command("gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_OFF)")
        require_command("gsDPPipeSync()")
        require_command("gsDPSetTextureFilter(G_TF_POINT)")
        require_command("gsDPSetCombineMode(G_CC_SHADE, G_CC_SHADE)")
        require_command("gsSPEndDisplayList()")
    end)

    if not ok then return nil, "Gfx command generation failed: " .. tostring(err) end
    local mesh = {
        block_id = block_id,
        gfx = gfx,
        vtx = vtx,
        command_count = command_count,
        vertex_count = requested_vertices,
        face_count = #visible_faces,
        face_signature = nil,
        shade_signature = nil,
    }
    return mesh
end


local function grid_key(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function visible_faces_for_block(blocks, x, y, z)
    local visible = {}
    for face_index, face in ipairs(FACE_LAYOUTS) do
        local normal = face.normal
        local neighbour_key = grid_key(
            x + normal[1], y + normal[2], z + normal[3]
        )
        local neighbour = blocks and blocks[neighbour_key] or nil
        if neighbour == nil then
            visible[#visible + 1] = {
                face = face,
                shading_index = face_index,
            }
        end
    end
    return visible
end

local function face_signature(visible_faces)
    local parts = {}
    for _, entry in ipairs(visible_faces) do
        parts[#parts + 1] = tostring(entry.shading_index)
    end
    return table.concat(parts, ",")
end

local function block_ao_brightness(blocks, x, y, z)
    local cell = blocks and blocks[grid_key(x, y, z)] or nil
    if cell == nil or cell.id == "minecraft:glass" then
        return 1.0 -- air and transparent blocks do not occlude AO
    end
    return 0.2 -- solid blocks (leaf-like opacity categories can be added later)
end

local function calculate_face_shading(blocks, x, y, z)
    local result = {}
    for face_index, face in ipairs(FACE_SHADING) do
        local face_values = {}
        for corner_index, corner in ipairs(face.corners) do
            local su, sv = corner[1], corner[2]
            local facing = block_ao_brightness(
                blocks,
                x + face.n[1], y + face.n[2], z + face.n[3]
            )
            local side_a = block_ao_brightness(
                blocks,
                x + face.n[1] + face.u[1] * su,
                y + face.n[2] + face.u[2] * su,
                z + face.n[3] + face.u[3] * su
            )
            local side_b = block_ao_brightness(
                blocks,
                x + face.n[1] + face.v[1] * sv,
                y + face.n[2] + face.v[2] * sv,
                z + face.n[3] + face.v[3] * sv
            )
            local corner_brightness = block_ao_brightness(
                blocks,
                x + face.n[1] + face.u[1] * su + face.v[1] * sv,
                y + face.n[2] + face.u[2] * su + face.v[2] * sv,
                z + face.n[3] + face.u[3] * su + face.v[3] * sv
            )

            -- Minecraft's documented traditional AO approximation averages
            -- the facing, two side and diagonal/corner block samples per vertex.
            local ao_light = (facing + side_a + side_b + corner_brightness) * 0.25
            face_values[corner_index] = face.directional * ao_light
        end
        result[face_index] = face_values
    end
    return result
end

local function shading_signature(shading)
    local parts = {}
    for face_index = 1, #FACE_SHADING do
        for corner_index = 1, 4 do
            parts[#parts + 1] = tostring(math.floor(shading[face_index][corner_index] * 255 + 0.5))
        end
    end
    return table.concat(parts, ",")
end

local function remember_display_nodes(first_node)
    local seen = {}
    local function visit(first)
        local node = first
        while node ~= nil do
            local key = node_key(node)
            if key == nil or seen[key] then break end
            seen[key] = true

            if node.type == GRAPH_NODE_TYPE_DISPLAY_LIST then
                local record = display_nodes[key]
                if record == nil then
                    local ok, typed = pcall(cast_graph_node, node)
                    if ok and typed ~= nil then
                        record = {
                            node = node,
                            typed = typed,
                            original_display_list = typed.displayList,
                            original_flags = node.flags,
                        }
                        display_nodes[key] = record
                    end
                end
                if record ~= nil then node.hookProcess = 1 end
            end

            local child_ok, child = pcall(function() return node.children end)
            if child_ok and child ~= nil then visit(child) end
            local next_ok, next_node = pcall(function() return node.next end)
            if not next_ok then break end
            node = next_node
        end
    end
    visit(first_node)
end

local function on_before_geo_process(node)
    local key = node_key(node)
    local record = key and display_nodes[key] or nil
    if record == nil then return end

    local object = nil
    if type(geo_get_current_object) == "function" then
        local ok, result = pcall(geo_get_current_object)
        if ok then object = result end
    end
    local object_id = object_key(object)
    local block_id = object_id and object_blocks[object_id] or nil
    local mesh = object_id and meshes[object_id] or nil

    if mesh ~= nil then
        record.typed.displayList = mesh.gfx
        if block_id == "minecraft:glass" and type(LAYER_TRANSPARENT) == "number"
            and type(record.original_flags) == "number" then
            record.node.flags = (record.original_flags % 256) + (LAYER_TRANSPARENT * 256)
        else
            record.node.flags = record.original_flags
        end
    else
        record.typed.displayList = record.original_display_list
        record.node.flags = record.original_flags
    end
end

local function on_object_unload(object)
    local key = object_key(object)
    if key ~= nil then
        object_blocks[key] = nil
        meshes[key] = nil
    end
end

local function on_level_init()
    object_blocks = {}
    display_nodes = {}
end

function Renderer.configure(textures)
    texture_info = type(textures) == "table" and textures or {}
    return next(texture_info) ~= nil
end

function Renderer.install_hooks()
    if hooks_installed then return true end
    if type(hook_event) ~= "function"
        or type(HOOK_BEFORE_GEO_PROCESS) ~= "number"
        or type(HOOK_ON_OBJECT_UNLOAD) ~= "number" then
        print("[SteveCraft] WARNING: GeoLayout hooks are unavailable; vanilla block display lists remain active.")
        return false
    end
    hook_event(HOOK_BEFORE_GEO_PROCESS, on_before_geo_process)
    hook_event(HOOK_ON_OBJECT_UNLOAD, on_object_unload)
    if type(HOOK_ON_LEVEL_INIT) == "number" then
        hook_event(HOOK_ON_LEVEL_INIT, on_level_init)
    end
    hooks_installed = true
    return true
end

function Renderer.attach(object, block_id, world_blocks)
    local key = object_key(object)
    if key == nil or BLOCK_TEXTURES[block_id] == nil then return false end

    local x = math.floor((tonumber(object.oPosX) or 0) / 90)
    local y = math.floor((tonumber(object.oPosY) or 0) / 90)
    local z = math.floor((tonumber(object.oPosZ) or 0) / 90)
    local face_shading = calculate_face_shading(world_blocks, x, y, z)
    local visible_faces = visible_faces_for_block(world_blocks, x, y, z)
    local signature = shading_signature(face_shading)
    local visible_signature = face_signature(visible_faces)
    local mesh = meshes[key]

    if mesh == nil or mesh.block_id ~= block_id
        or mesh.shade_signature ~= signature
        or mesh.face_signature ~= visible_signature then
        local err
        mesh, err = build_mesh(block_id, face_shading, key, visible_faces)
        if mesh == nil then
            if not warned[block_id] then
                print("[SteveCraft] WARNING: voxel renderer disabled for " .. tostring(block_id) .. ": " .. tostring(err))
                warned[block_id] = true
            end
            return false
        end
        mesh.shade_signature = signature
        mesh.face_signature = visible_signature
        meshes[key] = mesh
        material_meshes[block_id] = mesh
    end

    object_blocks[key] = block_id
    local ok, root = pcall(function() return object.header.gfx.sharedChild end)
    if not ok or root == nil then return false end
    remember_display_nodes(root)
    return true
end

function Renderer.compute_face_shading(world_blocks, x, y, z)
    return calculate_face_shading(world_blocks or {}, x, y, z)
end

function Renderer.compute_visible_faces(world_blocks, x, y, z)
    return visible_faces_for_block(world_blocks or {}, x, y, z)
end

function Renderer.detach(object)
    local key = object_key(object)
    if key == nil then return false end
    object_blocks[key] = nil
    meshes[key] = nil
    return true
end

function Renderer.get_mesh(block_id)
    return material_meshes[block_id]
end

function Renderer.get_attached_block(object)
    local key = object_key(object)
    return key and object_blocks[key] or nil
end

function Renderer.debug_counts()
    local mesh_count, node_count, object_count = 0, 0, 0
    for _ in pairs(meshes) do mesh_count = mesh_count + 1 end
    for _ in pairs(display_nodes) do node_count = node_count + 1 end
    for _ in pairs(object_blocks) do object_count = object_count + 1 end
    return { meshes = mesh_count, display_nodes = node_count, objects = object_count }
end

return Renderer
