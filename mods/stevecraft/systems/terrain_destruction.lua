-- Destructible static level-terrain surfaces.
-- Uses SM64CoopDX's own C collision pool APIs exposed to Lua:
-- smlua_collision_delete_surface() removes one Surface from its spatial
-- partitions and returns the pool slot. No custom native library is loaded.

local Terrain = {}

local function read_vertex(vertex)
    if vertex == nil then return nil end
    local ok, x, y, z = pcall(function()
        return tonumber(vertex.x), tonumber(vertex.y), tonumber(vertex.z)
    end)
    if not ok or x == nil or y == nil or z == nil then return nil end
    return {
        x = math.floor(x + 0.5),
        y = math.floor(y + 0.5),
        z = math.floor(z + 0.5),
    }
end

local function vertex_key(vertex)
    return tostring(vertex.x) .. "," .. tostring(vertex.y) .. "," .. tostring(vertex.z)
end

function Terrain.surface_signature(surface)
    if surface == nil then return nil end
    local ok, type_id, room, v1, v2, v3 = pcall(function()
        return tonumber(surface.type), tonumber(surface.room),
            read_vertex(surface.vertex1), read_vertex(surface.vertex2), read_vertex(surface.vertex3)
    end)
    if not ok or type_id == nil or not v1 or not v2 or not v3 then return nil end
    local vertices = { vertex_key(v1), vertex_key(v2), vertex_key(v3) }
    table.sort(vertices)
    return tostring(type_id) .. ":" .. tostring(room or 0) .. ":" .. table.concat(vertices, "|")
end

function Terrain.is_mineable_surface(surface)
    if surface == nil then return false, "no_surface" end
    local ok, pool_type, type_id, flags = pcall(function()
        return tonumber(surface.poolType), tonumber(surface.type), tonumber(surface.flags)
    end)
    if not ok or pool_type == nil or type_id == nil then
        return false, "surface_data_unavailable"
    end

    local static_pool = type(SURFACE_POOL_STATIC) == "number" and SURFACE_POOL_STATIC or 0
    if pool_type ~= static_pool then
        return false, "not_static_level_terrain"
    end
    if type(SURFACE_FLAG_INTANGIBLE) == "number"
        and flags ~= nil and (flags & SURFACE_FLAG_INTANGIBLE) ~= 0 then
        return false, "already_intangible"
    end

    -- Only ordinary solid terrain can be mined. Keep lava, death planes,
    -- water, quicksand, warps, camera triggers, switches, vines and other
    -- gameplay-control surfaces intact so mining cannot break level logic.
    local safe_types = {
        type(SURFACE_DEFAULT) == "number" and SURFACE_DEFAULT or 0,
        SURFACE_VERY_SLIPPERY,
        SURFACE_SLIPPERY,
        SURFACE_NOT_SLIPPERY,
        SURFACE_NOISE_DEFAULT,
        SURFACE_NOISE_SLIPPERY,
        SURFACE_NOISE_VERY_SLIPPERY,
        SURFACE_ICE,
        SURFACE_HARD,
        SURFACE_HARD_SLIPPERY,
        SURFACE_HARD_VERY_SLIPPERY,
        SURFACE_HARD_NOT_SLIPPERY,
    }
    for _, safe_type in ipairs(safe_types) do
        if type(safe_type) == "number" and type_id == safe_type then
            return true
        end
    end
    return false, "protected_surface_type"
end

function Terrain.snapshot(surface)
    local ok, type_id, room, v1, v2, v3, normal = pcall(function()
        return tonumber(surface.type), tonumber(surface.room),
            read_vertex(surface.vertex1), read_vertex(surface.vertex2), read_vertex(surface.vertex3),
            surface.normal
    end)
    if not ok or type_id == nil or not v1 or not v2 or not v3 then return nil end
    local nx, ny, nz = 0, 1, 0
    if normal ~= nil then
        pcall(function()
            nx = tonumber(normal.x) or 0
            ny = tonumber(normal.y) or 1
            nz = tonumber(normal.z) or 0
        end)
    end
    local snapshot = {
        type = type_id,
        room = room or 0,
        vertices = { v1, v2, v3 },
        normal = { x = nx, y = ny, z = nz },
    }
    snapshot.signature = Terrain.surface_signature(surface)
    return snapshot
end

function Terrain.make_intangible(surface)
    if surface == nil then return false end
    local ok = pcall(function()
        if type(SURFACE_FLAG_INTANGIBLE) == "number" then
            surface.flags = (tonumber(surface.flags) or 0) | SURFACE_FLAG_INTANGIBLE
        elseif type(SURFACE_INTANGIBLE) == "number" then
            surface.type = SURFACE_INTANGIBLE
        else
            error("surface intangible flag is unavailable")
        end
    end)
    return ok
end

function Terrain.delete_surface(surface)
    local allowed, reason = Terrain.is_mineable_surface(surface)
    if not allowed then return false, reason end
    if type(smlua_collision_delete_surface) ~= "function" then
        return false, "smlua_collision_delete_surface_unavailable"
    end
    local snapshot = Terrain.snapshot(surface)
    if snapshot == nil or snapshot.signature == nil then
        return false, "surface_snapshot_failed"
    end
    local ok, result = pcall(smlua_collision_delete_surface, surface)
    if not ok or result == false then
        return false, tostring(result or "surface_delete_failed")
    end
    -- The C function invalidates the Lua Surface reference. Never retain it.
    return true, snapshot
end

function Terrain.serialize(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.vertices) ~= "table"
        or #snapshot.vertices ~= 3 then return nil end
    local values = {
        tostring(math.floor(tonumber(snapshot.type) or 0)),
        tostring(math.floor(tonumber(snapshot.room) or 0)),
    }
    for _, vertex in ipairs(snapshot.vertices) do
        values[#values + 1] = tostring(math.floor(tonumber(vertex.x) or 0))
        values[#values + 1] = tostring(math.floor(tonumber(vertex.y) or 0))
        values[#values + 1] = tostring(math.floor(tonumber(vertex.z) or 0))
    end
    local normal = snapshot.normal or { x = 0, y = 1, z = 0 }
    values[#values + 1] = string.format("%.5f", tonumber(normal.x) or 0)
    values[#values + 1] = string.format("%.5f", tonumber(normal.y) or 1)
    values[#values + 1] = string.format("%.5f", tonumber(normal.z) or 0)
    return table.concat(values, ",")
end

function Terrain.deserialize(record)
    if type(record) ~= "string" then return nil end
    local values = {}
    for value in record:gmatch("[^,]+") do values[#values + 1] = tonumber(value) end
    if #values ~= 14 then return nil end
    for index = 1, 11 do
        if values[index] == nil then return nil end
    end
    for index = 12, 14 do
        if values[index] == nil then return nil end
    end
    local snapshot = {
        type = values[1],
        room = values[2],
        vertices = {
            { x = values[3], y = values[4], z = values[5] },
            { x = values[6], y = values[7], z = values[8] },
            { x = values[9], y = values[10], z = values[11] },
        },
        normal = { x = values[12], y = values[13], z = values[14] },
    }
    local keys = {
        vertex_key(snapshot.vertices[1]),
        vertex_key(snapshot.vertices[2]),
        vertex_key(snapshot.vertices[3]),
    }
    table.sort(keys)
    snapshot.signature = tostring(snapshot.type) .. ":" .. tostring(snapshot.room)
        .. ":" .. table.concat(keys, "|")
    return snapshot
end

return Terrain
