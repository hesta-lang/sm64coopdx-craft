-- Mod asset installer: copies extracted Minecraft Java files into SteveCraft ModFS.
local M = {}
local active_modfs = nil

local function is_modfs(value)
    local value_type = type(value)
    if value_type ~= "table" and value_type ~= "userdata" then return false end
    local ok, path = pcall(function() return value.modPath end)
    return ok and type(path) == "string" and path ~= ""
end

local function resolve_modfs()
    if is_modfs(active_modfs) then return active_modfs end
    if type(mod_fs_get) ~= "function" then
        return nil, "SM64CoopDX ModFS API is unavailable"
    end
    local ok, modfs = pcall(mod_fs_get)
    if ok and modfs == nil and type(mod_fs_create) == "function" then
        ok, modfs = pcall(mod_fs_create)
    end
    if not ok or not is_modfs(modfs) then
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

local function decode_base64(encoded)
    if type(encoded) ~= "string" then return nil, "base64 input is not a string" end
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local reverse = {}
    for index = 1, #alphabet do
        reverse[alphabet:sub(index, index)] = index - 1
    end
    local output = {}
    local length = #encoded
    local i = 1
    while i <= length do
        local a = reverse[encoded:sub(i, i)]
        local b = reverse[encoded:sub(i + 1, i + 1)]
        local c_char = encoded:sub(i + 2, i + 2)
        local d_char = encoded:sub(i + 3, i + 3)
        local c = c_char ~= "=" and reverse[c_char] or nil
        local d = d_char ~= "=" and reverse[d_char] or nil
        if a == nil or b == nil
            or (c_char ~= "=" and c == nil)
            or (d_char ~= "=" and d == nil)
            or (c_char == "=" and d_char ~= "=") then
            return nil, "invalid base64 quartet at byte " .. tostring(i)
        end
        if (c_char == "=" or d_char == "=") and i + 3 < length then
            return nil, "base64 padding is only valid at the end"
        end
        output[#output + 1] = string.char(a * 4 + math.floor(b / 16))
        if c ~= nil then
            output[#output + 1] = string.char((b % 16) * 16 + math.floor(c / 4))
            if d ~= nil then
                output[#output + 1] = string.char((c % 4) * 64 + d)
            end
        end
        i = i + 4
    end
    return table.concat(output)
end

M.decode_base64 = decode_base64

function M.install_embedded_resources(modfs, root)
    if not is_modfs(modfs) then return false, "missing ModFS" end
    local first_error
    local ok, manifest = pcall(require, "embedded_block_textures")
    if not ok or type(manifest) ~= "table" then
        first_error = manifest
        ok, manifest = pcall(require, "systems/embedded_block_textures")
    end
    if not ok or type(manifest) ~= "table" then
        local second_error = manifest
        -- Some mobile mod-file loaders index files differently from desktop.
        -- Load the root manifest by its exact mod directory as a final fallback.
        if type(dofile) == "function" and type(root) == "string" then
            local path = root .. "embedded_block_textures.lua"
            ok, manifest = pcall(dofile, path)
        end
        if not ok or type(manifest) ~= "table" then
            return false, "embedded resource manifest unavailable. root require: "
                .. tostring(first_error) .. "; systems require: "
                .. tostring(second_error) .. "; root file: " .. tostring(manifest)
        end
    end

    local installed, failures = 0, {}
    for relative, encoded in pairs(manifest) do
        if type(relative) ~= "string" or relative:find("..", 1, true)
            or relative:sub(1, 1) == "/" then
            failures[#failures + 1] = "invalid embedded resource path"
        else
            local data, decode_error = decode_base64(encoded)
            if data == nil then
                failures[#failures + 1] = relative .. ": " .. tostring(decode_error)
            else
                local path = "assets/" .. relative
                local file_ok, file = pcall(function()
                    return modfs:get_file(path) or modfs:create_file(path, false)
                end)
                if not file_ok or file == nil then
                    failures[#failures + 1] = path .. ": ModFS file creation failed"
                else
                    local write_ok, write_error = pcall(function()
                        file:set_text_mode(false)
                        local old_size = tonumber(file.size) or 0
                        if old_size > 0 then file:erase(old_size) end
                        file:rewind()
                        local result = file:write_bytes(data)
                        if result == false or tonumber(file.size) ~= #data then
                            error("ModFS write size mismatch")
                        end
                    end)
                    if write_ok then
                        installed = installed + 1
                    else
                        failures[#failures + 1] = path .. ": " .. tostring(write_error)
                    end
                end
            end
        end
    end

    if installed > 0 then
        local save_ok, save_result = pcall(function() return modfs:save() end)
        if not save_ok or save_result == false then
            failures[#failures + 1] = "ModFS save failed"
        end
    end

    return #failures == 0, {
        installed = installed,
        failures = failures,
    }
end

local block_texture_paths = {
    stone = "textures/block/stone.png",
    dirt = "textures/block/dirt.png",
    grass_top = "textures/block/grass_block_top.png",
    grass_side = "textures/block/grass_block_side.png",
    oak_planks = "textures/block/oak_planks.png",
    cobblestone = "textures/block/cobblestone.png",
    glass = "textures/block/glass.png",
    bricks = "textures/block/bricks.png",
    sand = "textures/block/sand.png",
    bedrock = "textures/block/bedrock.png",
}

function M.get_block_textures()
    local result = {}
    if type(get_texture_info) ~= "function" then
        print("[SteveCraft] WARNING: get_texture_info is unavailable; voxel blocks retain the vanilla display list.")
        return result
    end
    for key, relative in pairs(block_texture_paths) do
        local uri = M.get_uri(relative)
        if uri ~= nil then
            local ok, info = pcall(get_texture_info, uri)
            if ok and type(info) == "table" and info.texture ~= nil
                and type(info.width) == "number" and type(info.height) == "number" then
                result[key] = info
            else
                print("[SteveCraft] WARNING: could not load block texture " .. relative .. ": " .. tostring(info))
            end
        end
    end
    return result
end

function M.import_all(root)
    local modfs, err = resolve_modfs()
    if modfs == nil then
        print("[SteveCraft] WARNING: asset import skipped: " .. tostring(err))
        return false, err
    end

    local embedded_ok, embedded_result = M.install_embedded_resources(modfs, root)
    if not embedded_ok then
        local failures = type(embedded_result) == "table" and embedded_result.failures or nil
        print("[SteveCraft] WARNING: embedded resource import had failures: "
            .. tostring(failures and failures[1] or embedded_result))
    else
        print("[SteveCraft] Imported " .. tostring(embedded_result.installed or 0)
            .. " embedded textures/sounds into ModFS.")
    end

    -- Preserve the legacy installer for builds that explicitly expose Lua IO.
    -- Production builds can still load the embedded block textures/sounds without io.open.
    if type(io) == "table" and type(io.open) == "function" then
        local legacy_ok, legacy_result = M.install(root or "mods/stevecraft/", modfs)
        if not legacy_ok then
            local failures = type(legacy_result) == "table" and legacy_result.failures or nil
            print("[SteveCraft] WARNING: optional filesystem asset copy was incomplete: "
                .. tostring(failures and failures[1] or legacy_result))
        end
    end

    local loaded = 0
    for _ in pairs(M.get_block_textures()) do loaded = loaded + 1 end
    print("[SteveCraft] Block texture map ready: " .. tostring(loaded) .. "/10.")
    return embedded_ok, embedded_result
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
    if type(root) ~= "string" or not is_modfs(modfs) then
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
    if type(texture_getter) ~= "function" or not is_modfs(modfs) then return {} end
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
