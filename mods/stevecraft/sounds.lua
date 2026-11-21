-- SteveCraft original audio samples.
-- These OGG files are generated for SteveCraft and are not extracted from
-- Minecraft. The engine plays them positionally through ModAudio samples.

local Sounds = {}
local samples = {}
local attempted = false

local sample_files = {
    stone_step = "sounds/stone_step.ogg",
    dirt_step = "sounds/dirt_step.ogg",
    grass_step = "sounds/grass_step.ogg",
    wood_step = "sounds/wood_step.ogg",
    block_place = "sounds/block_place.ogg",
    block_break = "sounds/block_break.ogg",
}

local material_sounds = {
    stone = "stone_step",
    dirt = "dirt_step",
    grass = "grass_step",
    wood = "wood_step",
}

local function current_position(position)
    if position ~= nil then return position end
    local mario = gMarioStates and gMarioStates[0] or nil
    return mario and mario.pos or { x = 0, y = 0, z = 0 }
end

function Sounds.load()
    if attempted then return true end
    attempted = true

    if type(audio_sample_load) ~= "function" then
        print("[SteveCraft] WARNING: ModAudio sample loading is unavailable; custom sounds are disabled.")
        return false
    end

    local loaded = 0
    for name, path in pairs(sample_files) do
        local ok, sample = pcall(audio_sample_load, path)
        if ok and sample ~= nil then
            samples[name] = sample
            loaded = loaded + 1
        else
            print("[SteveCraft] WARNING: couldn't load sound " .. path .. ": " .. tostring(sample))
        end
    end
    print("[SteveCraft] Loaded " .. tostring(loaded) .. "/" .. tostring(#sample_files) .. " original sound samples.")
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
    local definition = block_id and require("blocks").catalog[block_id] or nil
    local material = definition and definition.place_sound or "stone"
    return Sounds.play("block_place", position, material == "glass" and 0.45 or 0.7)
end

function Sounds.play_break(block_id, position)
    local definition = block_id and require("blocks").catalog[block_id] or nil
    local material = definition and definition.break_sound or "stone"
    return Sounds.play("block_break", position, material == "glass" and 0.8 or 0.9)
end

function Sounds.play_footstep(material, position, volume)
    local sound_name = material_sounds[material or "stone"] or "stone_step"
    return Sounds.play(sound_name, position, volume or 0.48)
end

return Sounds
