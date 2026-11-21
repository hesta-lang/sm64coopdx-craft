package.path = "mods/stevecraft/?.lua;" .. package.path

local Sounds = require("sounds")
assert(Sounds.is_mario_footstep_sound(0x06108080), "normal Mario step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x06178080), "terrain-addended step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x06208080), "tiptoe step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x06278080), "terrain-addended tiptoe step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x042A9080), "metal step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x042D8080), "hanging step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x042E0080), "quicksand step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x042F9080), "metal tiptoe step was not recognized")
assert(Sounds.is_mario_footstep_sound(0x04529080), "metal water step was not recognized")

assert(Sounds.filter_mario_sounds(0x06108080) == 0, "native step sound was not suppressed")
assert(Sounds.filter_mario_sounds(0x04008080) == 0, "Mario jump/action sound was not suppressed")
assert(Sounds.filter_mario_sounds(0x042A9080) == 0, "Mario acrobatic/action sound was not suppressed")
assert(Sounds.filter_mario_sounds(0x50000000) == 0, "Mario voice bank was not suppressed")
assert(Sounds.filter_mario_sounds(0x14108080) == nil, "non-action sound bank was incorrectly suppressed")
assert(Sounds.filter_mario_sounds(0xB4000000) == nil, "environmental sound bank was incorrectly suppressed")

local Blocks = require("blocks")
assert(Blocks.get_footstep_material("minecraft:grass_block") == "grass")
assert(Blocks.get_footstep_material("minecraft:dirt") == "dirt")
assert(Blocks.get_footstep_material("minecraft:oak_planks") == "wood")
assert(Blocks.get_footstep_material("minecraft:glass") == "glass")
assert(Blocks.get_footstep_material("minecraft:sand") == "sand")
assert(Blocks.get_footstep_material("minecraft:bedrock") == "stone")
print("PASS: native Mario footstep suppression and per-block Minecraft step material routing")


-- Validate ModAudio resource loading itself, including the retry path used
-- when the embedded ModFS files become available after the first hook call.
MOD_FS_URI_FORMAT = "modfs:/%s/%s"
gGlobalTimer = 1
function mod_fs_get() return { modPath = "SteveCraft" } end
local fail_one_sample_once = true
local pending_dirt_sample = nil
local loaded_samples = {}
local played_samples = {}
function audio_sample_load(uri)
    assert(uri:match("^modfs:/SteveCraft/assets/sounds/") ~= nil,
        "sample loader received a non-ModFS sound path: " .. tostring(uri))
    if fail_one_sample_once and uri:match("/stone_step%.ogg$") then
        fail_one_sample_once = false
        return nil
    end
    if uri:match("/dirt_step%.ogg$") then
        pending_dirt_sample = { filepath = uri, loaded = false }
        loaded_samples[uri] = pending_dirt_sample
        return pending_dirt_sample
    end
    local sample = { filepath = uri, loaded = true }
    loaded_samples[uri] = sample
    return sample
end
function audio_sample_play(sample, position, volume)
    played_samples[#played_samples + 1] = {
        sample = sample, position = position, volume = volume,
    }
    -- The host function returns void/nil on a successful queue operation.
end

assert(Sounds.load(true) == true, "partial ModAudio load should report available samples")
assert(loaded_samples["modfs:/SteveCraft/assets/sounds/stone_step.ogg"] == nil,
    "test's first missing-sample condition did not occur")
gGlobalTimer = 121
assert(Sounds.load() == true, "ModAudio retry did not load the missing sample")
local stone_sample = loaded_samples["modfs:/SteveCraft/assets/sounds/stone_step.ogg"]
assert(stone_sample ~= nil, "stone footstep sample was not retried")
assert(pending_dirt_sample ~= nil and pending_dirt_sample.loaded == false,
    "test did not simulate an asynchronously loading audio object")
pending_dirt_sample.loaded = true
gGlobalTimer = 241
assert(Sounds.load() == true, "ModAudio did not detect a previously pending sample becoming ready")
assert(stone_sample.channel == nil,
    "ModAudio sample must not receive the stream-only volume channel property")
assert(stone_sample.baseVolume == nil,
    "sample playback volume should be passed to audio_sample_play instead of mutating stream volume")
assert(Sounds.play_footstep("stone", { x = 1, y = 2, z = 3 }) == true,
    "audio_sample_play void return was incorrectly treated as failure")
assert(#played_samples == 1, "stone footstep did not queue exactly one sample")
assert(played_samples[1].sample == stone_sample, "wrong sample was played for stone")
assert(played_samples[1].volume >= 0.9, "Minecraft footstep output volume remains too low")
print("PASS: ModAudio sample loading/retry and direct SFX playback without stream-only properties")
