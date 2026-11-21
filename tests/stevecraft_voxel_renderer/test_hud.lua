package.path = "mods/stevecraft/?.lua;" .. package.path

local allowed = {}
for _, path in ipairs({
    "textures/gui/sprites/hud/hotbar.png",
    "textures/gui/sprites/hud/hotbar_selection.png",
    "textures/gui/sprites/hud/crosshair.png",
    "textures/gui/sprites/hud/heart/full.png",
    "textures/gui/sprites/hud/heart/half.png",
    "textures/gui/sprites/hud/heart/container.png",
    "textures/gui/sprites/hud/food_full.png",
    "textures/gui/sprites/hud/food_half.png",
    "textures/gui/sprites/hud/food_empty.png",
    "textures/gui/sprites/hud/armor_full.png",
    "textures/gui/sprites/hud/armor_half.png",
    "textures/gui/sprites/hud/armor_empty.png",
    "textures/stevecraft/icons/stone.png",
    "textures/stevecraft/icons/grass_block.png",
}) do
    allowed[path] = true
end

local requested = {}
local draw_calls = 0
MOD_FS_URI_FORMAT = "modfs:/%s/%s"
function mod_fs_get() return { modPath = "SteveCraft" } end
function get_texture_info(uri)
    local prefix = "modfs:/SteveCraft/assets/"
    assert(uri:sub(1, #prefix) == prefix, "HUD used the wrong ModFS root: " .. tostring(uri))
    local path = uri:sub(#prefix + 1)
    assert(allowed[path] == true, "HUD requested an unbundled/wrong texture path: " .. path)
    requested[path] = true
    local width, height = 16, 16
    if path == "textures/gui/sprites/hud/hotbar.png" then width, height = 182, 22 end
    if path == "textures/gui/sprites/hud/hotbar_selection.png" then width, height = 22, 22 end
    if path == "textures/gui/sprites/hud/crosshair.png" then width, height = 15, 15 end
    if path:find("heart/", 1, true) then width, height = 9, 9 end
    if path:find("food_", 1, true) or path:find("armor_", 1, true) then width, height = 9, 9 end
    if path:find("textures/stevecraft/icons/", 1, true) == 1 then width, height = 32, 32 end
    return { texture = { name = path }, width = width, height = height, name = path }
end

RESOLUTION_DJUI = 1
FONT_NORMAL = 1
function djui_hud_set_resolution() end
function djui_hud_set_font() end
function djui_hud_get_screen_width() return 320 end
function djui_hud_get_screen_height() return 240 end
function djui_hud_render_texture(info)
    assert(info and info.width and info.height, "HUD passed invalid texture metadata")
    assert((info.width & (info.width - 1)) == 0 and (info.height & (info.height - 1)) == 0,
        "HUD attempted to render an MPOT texture")
    draw_calls = draw_calls + 1
end
function djui_hud_render_texture_tile() error("old atlas/tile renderer must not be used") end
function djui_hud_set_color() end
function djui_hud_render_rect() end
function djui_hud_print_text() end

local HUD = require("hud")
HUD.render({
    inventory_loaded = false,
    inventory = {
        [1] = { id = "minecraft:stone", count = 64 },
        [2] = { id = "minecraft:grass_block", count = 63 },
    },
    selected_slot = 1,
    health_points = 20,
    hunger_points = 20,
    armor_points = 0,
    camera_active = true,
    catalog = { ["minecraft:stone"] = { name = "Stone" } },
})

assert(requested["textures/gui/sprites/hud/hotbar.png"], "hotbar sprite was not loaded")
assert(requested["textures/gui/sprites/hud/hotbar_selection.png"], "selection sprite was not loaded")
assert(requested["textures/gui/sprites/hud/heart/full.png"], "heart sprite was not loaded")
assert(requested["textures/stevecraft/icons/stone.png"], "bundled isometric stone icon was not loaded")
assert(requested["textures/stevecraft/icons/grass_block.png"], "bundled isometric grass icon was not loaded")
assert(requested["textures/hud/hotbar_selection.png"] ~= true, "obsolete HUD path was requested")
assert(requested["textures/stevecraft_atlas.png"] ~= true, "missing atlas path was requested")
assert(draw_calls >= 2, "HUD did not render bundled 32x32 block icons")
assert(requested["textures/gui/sprites/hud/hotbar.png"], "MPOT hotbar was not checked")
print("PASS: HUD skips MPOT sprites and renders bundled isometric 3D block icons")
