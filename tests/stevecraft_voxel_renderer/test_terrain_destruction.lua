package.path = "mods/stevecraft/?.lua;" .. package.path

SURFACE_POOL_STATIC = 0
SURFACE_POOL_DYNAMIC = 1
SURFACE_POOL_SOC = 2
SURFACE_FLAG_INTANGIBLE = 4
SURFACE_DEFAULT = 0
SURFACE_VERY_SLIPPERY = 0x13
SURFACE_SLIPPERY = 0x14
SURFACE_NOT_SLIPPERY = 0x15
SURFACE_NOISE_DEFAULT = 0x29
SURFACE_NOISE_SLIPPERY = 0x2A
SURFACE_NOISE_VERY_SLIPPERY = 0x75
SURFACE_ICE = 0x2E
SURFACE_HARD = 0x30
SURFACE_HARD_SLIPPERY = 0x35
SURFACE_HARD_VERY_SLIPPERY = 0x36
SURFACE_HARD_NOT_SLIPPERY = 0x37
SURFACE_BURNING = 0x01
SURFACE_DEATH_PLANE = 0x0A
SURFACE_WATER = 0x0D
SURFACE_WARP = 0x32

local delete_calls = 0
function smlua_collision_delete_surface(surface)
    delete_calls = delete_calls + 1
    surface.deleted = true
end

local Terrain = require("systems/terrain_destruction")
local surface = {
    type = SURFACE_DEFAULT,
    room = 2,
    poolType = SURFACE_POOL_STATIC,
    flags = 0,
    vertex1 = { x = 0, y = 100, z = 0 },
    vertex2 = { x = 100, y = 100, z = 0 },
    vertex3 = { x = 0, y = 100, z = 100 },
    normal = { x = 0, y = 1, z = 0 },
}

assert(Terrain.is_mineable_surface(surface) == true,
    "ordinary static level terrain should be mineable")
local signature = Terrain.surface_signature(surface)
assert(type(signature) == "string" and signature ~= "",
    "surface fingerprint was not generated")

local snapshot = Terrain.snapshot(surface)
assert(snapshot and snapshot.signature == signature, "surface snapshot lost its fingerprint")
assert(snapshot.vertices[2].x == 100 and snapshot.normal.y == 1,
    "surface snapshot did not copy vertex and normal data")

local serialized = Terrain.serialize(snapshot)
assert(type(serialized) == "string", "destroyed surface did not serialize")
local restored = Terrain.deserialize(serialized)
assert(restored and restored.signature == signature,
    "destroyed surface fingerprint did not survive storage serialization")
assert(restored.vertices[3].z == 100, "surface triangle vertex was corrupted by serialization")

local deleted, returned_snapshot = Terrain.delete_surface(surface)
assert(deleted == true and returned_snapshot.signature == signature,
    "native static surface deletion did not return its saved geometry")
assert(delete_calls == 1 and surface.deleted == true,
    "smlua_collision_delete_surface was not called exactly once")

local intangible = { flags = 0, type = SURFACE_DEFAULT }
assert(Terrain.make_intangible(intangible) == true)
assert((intangible.flags & SURFACE_FLAG_INTANGIBLE) ~= 0,
    "persisted terrain surface was not made intangible")

local dynamic = {
    type = SURFACE_DEFAULT, room = 1, poolType = SURFACE_POOL_DYNAMIC, flags = 0,
    vertex1 = { x = 0, y = 0, z = 0 }, vertex2 = { x = 10, y = 0, z = 0 },
    vertex3 = { x = 0, y = 0, z = 10 },
}
local allowed, reason = Terrain.is_mineable_surface(dynamic)
assert(allowed == false and reason == "not_static_level_terrain",
    "dynamic object collision must not be mined as level terrain")

local hazard = {
    type = SURFACE_BURNING, room = 1, poolType = SURFACE_POOL_STATIC, flags = 0,
    vertex1 = { x = 0, y = 0, z = 0 }, vertex2 = { x = 10, y = 0, z = 0 },
    vertex3 = { x = 0, y = 0, z = 10 },
}
allowed, reason = Terrain.is_mineable_surface(hazard)
assert(allowed == false and reason == "protected_surface_type",
    "lava/burning surfaces must stay protected")

local warp = {
    type = SURFACE_WARP, room = 1, poolType = SURFACE_POOL_STATIC, flags = 0,
    vertex1 = { x = 0, y = 0, z = 0 }, vertex2 = { x = 10, y = 0, z = 0 },
    vertex3 = { x = 0, y = 0, z = 10 },
}
allowed = Terrain.is_mineable_surface(warp)
assert(allowed == false, "warp/transition surfaces must stay protected")

print("PASS: static terrain ray-surface fingerprint, persistence encoding, safe whitelist and native deletion")
