-- Mod asset installer: copies extracted Minecraft Java files into SteveCraft ModFS.
local M = {}
local active_modfs = nil

local function resolve_modfs()
    if active_modfs ~= nil and type(active_modfs.modPath) == "string" then
        return active_modfs
    end
    if type(mod_fs_get) ~= "function" then
        return nil, "SM64CoopDX ModFS API is unavailable"
    end
    local ok, modfs = pcall(mod_fs_get)
    if ok and modfs == nil and type(mod_fs_create) == "function" then
        ok, modfs = pcall(mod_fs_create)
    end
    if not ok or type(modfs) ~= "table"
        or type(modfs.modPath) ~= "string" or modfs.modPath == "" then
        return nil, "could not obtain the active mod filesystem"
    end
    active_modfs = modfs
    return modfs
end

function M.get_uri(path)
    if type(path) ~= "string" or path == "" then return nil end
    local modfs = resolve_modfs()
    if modfs == nil or type(MOD_FS_URI_FORMAT) ~= "string" then return nil end
    local relative = path:gsub("\\", "/"):gsub("^/+", "")
    if relative:sub(1, 7) ~= "assets/" then
        relative = "assets/" .. relative
    end
    return string.format(MOD_FS_URI_FORMAT, modfs.modPath, relative)
end

function M.import_all(root)
    local modfs, err = resolve_modfs()
    if modfs == nil then
        print("[SteveCraft] WARNING: asset import skipped: " .. tostring(err))
        return false, err
    end
    root = root or "mods/stevecraft/"
    local ok, result = M.install(root, modfs)
    if not ok then
        local failures = type(result) == "table" and result.failures or nil
        local first = failures and failures[1] or "unknown asset import error"
        print("[SteveCraft] WARNING: some assets could not be imported: " .. tostring(first))
    else
        print("[SteveCraft] Imported " .. tostring(result.installed or 0)
            .. " assets; reused " .. tostring(result.skipped or 0) .. ".")
    end
    return ok, result
end
local required = {
    "textures/gui/sprites/hud/hotbar.png",
    "textures/gui/sprites/hud/hotbar_selection.png",
    "textures/gui/sprites/hud/crosshair.png",
    "textures/gui/sprites/hud/experience_bar_background.png",
    "textures/gui/sprites/hud/experience_bar_progress.png",
    "textures/gui/sprites/hud/heart/full.png",
    "textures/gui/sprites/hud/heart/half.png",
    "textures/gui/sprites/hud/heart/container.png",
    "textures/gui/sprites/hud/food_full.png",
    "textures/gui/sprites/hud/food_half.png",
    "textures/gui/sprites/hud/food_empty.png",
    "textures/gui/sprites/hud/armor_full.png",
    "textures/gui/sprites/hud/armor_half.png",
    "textures/gui/sprites/hud/armor_empty.png",
    "textures/block/stone.png",
    "textures/block/dirt.png",
    "textures/block/grass_block_top.png",
    "textures/block/grass_block_side.png",
    "textures/block/oak_planks.png",
    "textures/block/cobblestone.png",
    "textures/block/glass.png",
    "textures/block/bricks.png",
    "textures/block/sand.png",
    "textures/block/bedrock.png",
    "sounds/stone_step.ogg", "sounds/stone_place.ogg", "sounds/stone_break.ogg",
    "sounds/dirt_step.ogg", "sounds/dirt_place.ogg", "sounds/dirt_break.ogg",
    "sounds/grass_step.ogg", "sounds/grass_place.ogg", "sounds/grass_break.ogg",
    "sounds/wood_step.ogg", "sounds/wood_place.ogg", "sounds/wood_break.ogg",
    "sounds/glass_step.ogg", "sounds/glass_place.ogg", "sounds/glass_break.ogg",
    "sounds/sand_step.ogg", "sounds/sand_place.ogg", "sounds/sand_break.ogg",
}
local texture_names = {
    "hotbar", "hotbar_selection", "crosshair",
    "heart_full", "heart_half", "heart_empty",
    "food_full", "food_half", "food_empty",
    "armor_full", "armor_half", "armor_empty",
    "stone", "dirt", "grass_block_top", "grass_block_side",
    "oak_planks", "cobblestone", "glass", "bricks", "sand", "bedrock",
}
local function file_bytes(path)
    if type(io) ~= "table" or type(io.open) ~= "function" then
        return nil, "Lua IO library is unavailable"
    end
    local file, err = io.open(path, "rb")
    if file == nil then return nil, err end
    local data = file:read("*a")
    file:close()
    return data
end

function M.install(root, modfs)
    if type(root) ~= "string" or type(modfs) ~= "table" then
        return false, "missing mod root or ModFS"
    end
    active_modfs = modfs
    local installed, skipped, failures = 0, 0, {}
    for _, relative in ipairs(required) do
        local data, err = file_bytes(root .. "assets/" .. relative)
        if data == nil then
            failures[#failures + 1] = relative .. ": " .. tostring(err)
        else
            local uri_path = "assets/" .. relative
            local ok, file = pcall(function()
                return modfs:get_file(uri_path) or modfs:create_file(uri_path, false)
            end)
            if not ok or file == nil then
                failures[#failures + 1] = uri_path .. ": ModFS file creation failed"
            elseif file.size == #data then
                skipped = skipped + 1
            else
                local write_ok, write_result = pcall(function()
                    file:set_text_mode(false)
                    if file.size > 0 then file:erase(file.size) end
                    file:rewind()
                    return file:write_bytes(data)
                end)
                if write_ok and write_result ~= false and file.size == #data then
                    installed = installed + 1
                else
                    failures[#failures + 1] = uri_path .. ": write failed"
                end
            end
        end
    end
    if installed > 0 then
        local ok, result = pcall(function() return modfs:save() end)
        if not ok or result == false then
            failures[#failures + 1] = "ModFS save failed"
        end
    end
    return #failures == 0, {
        installed = installed, skipped = skipped, failures = failures,
    }
end

function M.load_textures(modfs, texture_getter, uri_format)
    if type(texture_getter) ~= "function" or type(modfs) ~= "table" then return {} end
    local map = {}
    local paths = {
        hotbar = "textures/gui/sprites/hud/hotbar.png",
        hotbar_selection = "textures/gui/sprites/hud/hotbar_selection.png",
        crosshair = "textures/gui/sprites/hud/crosshair.png",
        experience_background = "textures/gui/sprites/hud/experience_bar_background.png",
        experience_progress = "textures/gui/sprites/hud/experience_bar_progress.png",
        heart_full = "textures/gui/sprites/hud/heart/full.png",
        heart_half = "textures/gui/sprites/hud/heart/half.png",
        heart_empty = "textures/gui/sprites/hud/heart/container.png",
        food_full = "textures/gui/sprites/hud/food_full.png",
        food_half = "textures/gui/sprites/hud/food_half.png",
        food_empty = "textures/gui/sprites/hud/food_empty.png",
        armor_full = "textures/gui/sprites/hud/armor_full.png",
        armor_half = "textures/gui/sprites/hud/armor_half.png",
        armor_empty = "textures/gui/sprites/hud/armor_empty.png",
        stone = "textures/block/stone.png", dirt = "textures/block/dirt.png",
        grass_block = "textures/block/grass_block_top.png",
        oak_planks = "textures/block/oak_planks.png",
        cobblestone = "textures/block/cobblestone.png", glass = "textures/block/glass.png",
        bricks = "textures/block/bricks.png", sand = "textures/block/sand.png",
        bedrock = "textures/block/bedrock.png",
    }
    for name, relative in pairs(paths) do
        local uri = string.format(uri_format, modfs.modPath, "assets/" .. relative)
        local ok, texture = pcall(texture_getter, uri)
        if ok and texture ~= nil then map[name] = texture end
    end
    return map
end

function M.sound_manifest()
    return {
        stone_step = "stone_step", stone_place = "stone_place", stone_break = "stone_break",
        dirt_step = "dirt_step", dirt_place = "dirt_place", dirt_break = "dirt_break",
        grass_step = "grass_step", grass_place = "grass_place", grass_break = "grass_break",
        wood_step = "wood_step", wood_place = "wood_place", wood_break = "wood_break",
        glass_step = "glass_step", glass_place = "glass_place", glass_break = "glass_break",
        sand_step = "sand_step", sand_place = "sand_place", sand_break = "sand_break",
    }
end

return M
