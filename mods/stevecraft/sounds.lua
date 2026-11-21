-- SteveCraft original audio samples.
-- These OGG files are generated for SteveCraft and are not extracted from
-- Minecraft. The engine plays them positionally through ModAudio samples.

local Sounds = {}
local samples = {}
local attempted = false
local SAMPLE_COUNT = 2
local Assets = require("assets")

local sample_files = {
    footstep = "sounds/footstep.ogg",
    block = "sounds/block.ogg",
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
        local uri = Assets.get_uri(path)
        local ok, sample = false, nil
        if uri ~= nil then
            ok, sample = pcall(audio_sample_load, uri)
        end
        if ok and sample ~= nil then
            samples[name] = sample
            loaded = loaded + 1
        else
            print("[SteveCraft] WARNING: couldn't load sound " .. path .. ": " .. tostring(sample))
        end
    end
    print("[SteveCraft] Loaded " .. tostring(loaded) .. "/" .. tostring(SAMPLE_COUNT) .. " original sound samples.")
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
    local volume = block_id == "minecraft:glass" and 0.42 or 0.62
    return Sounds.play("block", position, volume)
end

function Sounds.play_break(block_id, position)
    local volume = block_id == "minecraft:glass" and 0.82 or 0.92
    return Sounds.play("block", position, volume)
end

function Sounds.play_footstep(material, position, volume)
    local material_gain = {
        stone = 0.52,
        dirt = 0.43,
        grass = 0.38,
        wood = 0.49,
    }
    return Sounds.play("footstep", position, volume or material_gain[material or "stone"] or 0.48)
end

return Sounds
