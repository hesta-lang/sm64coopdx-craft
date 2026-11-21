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
local retry_after_frame = -1
local last_load_count = -1

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

function Sounds.load(force)
    local current_frame = tonumber(gGlobalTimer) or 0
    if attempted then return true end
    if not force and current_frame < retry_after_frame then
        return next(samples) ~= nil
    end
    retry_after_frame = current_frame + 120

    if type(audio_sample_load) ~= "function" then
        if last_load_count ~= 0 then
            print("[SteveCraft] ERROR: ModAudio audio_sample_load is unavailable.")
            last_load_count = 0
        end
        return false
    end

    local loaded = 0
    local failed = 0
    for name, path in pairs(sample_files) do
        if samples[name] == nil then
            local uri = Assets.get_uri(path)
            local ok, sample = false, nil
            if uri ~= nil then
                ok, sample = pcall(audio_sample_load, uri)
            end
            local is_loaded = false
            if ok and sample ~= nil then
                local read_ok, state = pcall(function() return sample.loaded end)
                is_loaded = not read_ok or state ~= false
            end
            if ok and sample ~= nil and is_loaded then
                samples[name] = sample
                loaded = loaded + 1
                if type(MOD_AUDIO_CHANNEL_SFX) == "number" then
                    pcall(function() sample.channel = MOD_AUDIO_CHANNEL_SFX end)
                end
                pcall(function() sample.baseVolume = 1.0 end)
            else
                failed = failed + 1
                if failed <= 2 then
                    print("[SteveCraft] WARNING: failed to load " .. path .. " from "
                        .. tostring(uri) .. ": " .. tostring(sample))
                end
            end
        else
            loaded = loaded + 1
        end
    end
    if loaded == SAMPLE_COUNT then
        attempted = true
        print("[SteveCraft] Loaded all " .. tostring(loaded) .. " Minecraft block audio samples.")
    elseif last_load_count ~= loaded then
        print("[SteveCraft] Minecraft block audio loaded " .. tostring(loaded)
            .. "/" .. tostring(SAMPLE_COUNT) .. "; retrying after resource check.")
    end
    last_load_count = loaded
    return loaded > 0
end

function Sounds.play(name, position, volume)
    if not attempted then Sounds.load() end
    local sample = samples[name]
    if sample == nil or type(audio_sample_play) ~= "function" then return false end
    local ok, result = pcall(audio_sample_play, sample, current_position(position), volume or 0.9)
    if not ok then
        print("[SteveCraft] ERROR: audio_sample_play failed for " .. tostring(name) .. ": " .. tostring(result))
        return false
    end
    return result ~= false
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

function Sounds.reset_audio_cache()
    samples = {}
    attempted = false
    retry_after_frame = -1
    last_load_count = -1
end

function Sounds.play_footstep(material, position, volume)
    material = type(material) == "string" and material:lower() or "stone"
    if material == "oak" or material == "planks" or material == "log" then material = "wood" end
    if samples[material .. "_step"] == nil then material = "stone" end
    local gains = {
        stone = 0.92, dirt = 0.82, grass = 0.78,
        wood = 0.88, glass = 0.84, sand = 0.82,
    }
    return Sounds.play(material .. "_step", position, volume or gains[material] or 0.86)
end

-- HOOK_ON_PLAY_SOUND is called before a native sound is queued.
-- Suppress the complete action bank (Mario jumps, landings and acrobatics) and
-- Mario's voice bank. SteveCraft's own Minecraft samples use audio_sample_play
-- and are not routed through this hook.
local function sound_bank(sound_bits)
    if type(sound_bits) ~= "number" then return -1 end
    return (sound_bits >> 28) & 0x0F
end

function Sounds.is_mario_footstep_sound(sound_bits)
    if sound_bank(sound_bits) ~= 0 then return false end
    local sound_id = (sound_bits >> 16) & 0xFF
    return (sound_id >= 0x10 and sound_id <= 0x17)
        or (sound_id >= 0x20 and sound_id <= 0x27)
        or sound_id == 0x2A or sound_id == 0x2D
        or sound_id == 0x2E or sound_id == 0x2F
        or sound_id == 0x52
end

function Sounds.filter_mario_sounds(sound_bits, _position)
    local bank = sound_bank(sound_bits)
    local voice_bank = 5
    if type(SOUND_BANK_MARIO_VOICE) == "number" then
        local configured = SOUND_BANK_MARIO_VOICE
        if configured > 0x0F then
            configured = (configured >> 28) & 0x0F
        end
        voice_bank = configured
    end
    if bank == 0 or bank == voice_bank then
        return type(NO_SOUND) == "number" and NO_SOUND or 0
    end
    return nil
end

-- Backwards-compatible test/API alias.
function Sounds.filter_mario_footstep(sound_bits, position)
    return Sounds.filter_mario_sounds(sound_bits, position)
end

return Sounds
