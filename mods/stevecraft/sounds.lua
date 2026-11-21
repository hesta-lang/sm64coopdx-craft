-- SteveCraft routes the official Java 26.3 block samples through ModAudio.
-- The binary OGG files are copied into the mod's ModFS by systems/assets.lua.

local Sounds = {}
local samples = {}
local attempted = false

local sample_files = {
    stone_step = "sounds/stone_step.ogg",
    stone_place = "sounds/stone_place.ogg",
    stone_break = "sounds/stone_break.ogg",
    dirt_step = "sounds/dirt_step.ogg",
    dirt_place = "sounds/dirt_place.ogg",
    dirt_break = "sounds/dirt_break.ogg",
    grass_step = "sounds/grass_step.ogg",
    grass_place = "sounds/grass_place.ogg",
    grass_break = "sounds/grass_break.ogg",
    wood_step = "sounds/wood_step.ogg",
    wood_place = "sounds/wood_place.ogg",
    wood_break = "sounds/wood_break.ogg",
    glass_step = "sounds/glass_step.ogg",
    glass_place = "sounds/glass_place.ogg",
    glass_break = "sounds/glass_break.ogg",
    sand_step = "sounds/sand_step.ogg",
    sand_place = "sounds/sand_place.ogg",
    sand_break = "sounds/sand_break.ogg",
}
local SAMPLE_COUNT = 18
local Assets = require("assets")

local function current_position(position)
    if position ~= nil then return position end
    local mario = gMarioStates and gMarioStates[0] or nil
    return mario and mario.pos or { x = 0, y = 0, z = 0 }
end

local function material_for_block(block_id)
    local id = type(block_id) == "string" and block_id:lower() or ""
    if id:find("glass", 1, true) then return "glass" end
    if id:find("sand", 1, true) then return "sand" end
    if id:find("grass", 1, true) then return "grass" end
    if id:find("dirt", 1, true) or id:find("gravel", 1, true) then return "dirt" end
    if id:find("wood", 1, true) or id:find("planks", 1, true)
        or id:find("log", 1, true) then return "wood" end
    return "stone"
end

function Sounds.load()
    if attempted then return next(samples) ~= nil end
    attempted = true

    if type(audio_sample_load) ~= "function" then
        print("[SteveCraft] WARNING: ModAudio sample loading is unavailable; block sounds are disabled.")
        return false
    end

    local loaded = 0
    for name, path in pairs(sample_files) do
        local uri = Assets.get_uri(path)
        local ok, sample = false, nil
        if uri ~= nil then
            ok, sample = pcall(audio_sample_load, uri)
        end
        if ok and sample ~= nil then
            samples[name] = sample
            loaded = loaded + 1
        else
            print("[SteveCraft] WARNING: could not load Java sound " .. path .. ": " .. tostring(sample))
        end
    end
    print("[SteveCraft] Loaded " .. tostring(loaded) .. "/" .. tostring(SAMPLE_COUNT) .. " Java block sound samples.")
    return loaded > 0
end

function Sounds.play(name, position, volume)
    if not attempted then Sounds.load() end
    local sample = samples[name]
    if sample == nil or type(audio_sample_play) ~= "function" then return false end
    local ok, result = pcall(audio_sample_play, sample, current_position(position), volume or 0.75)
    return ok and result ~= false
end

function Sounds.play_place(block_id, position)
    local material = material_for_block(block_id)
    local volume = material == "glass" and 0.42 or 0.62
    return Sounds.play(material .. "_place", position, volume)
end

function Sounds.play_break(block_id, position)
    local material = material_for_block(block_id)
    local volume = material == "glass" and 0.82 or 0.92
    return Sounds.play(material .. "_break", position, volume)
end

function Sounds.play_footstep(material, position, volume)
    material = type(material) == "string" and material:lower() or "stone"
    if material == "oak" or material == "planks" then material = "wood" end
    if samples[material .. "_step"] == nil then material = "stone" end
    local gains = {
        stone = 0.52, dirt = 0.43, grass = 0.38,
        wood = 0.49, glass = 0.45, sand = 0.40,
    }
    return Sounds.play(material .. "_step", position, volume or gains[material] or 0.48)
end

return Sounds
