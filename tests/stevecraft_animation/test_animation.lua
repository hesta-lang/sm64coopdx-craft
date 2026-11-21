local harness = {}
_G.__STEVECRAFT_TEST = harness
dofile("mods/stevecraft/main.lua")

assert(type(harness.build_animation) == "function", "main.lua did not expose the pure animation builder")
assert(type(harness.animation_value) == "function", "main.lua did not expose the formula evaluator")
local frames = harness.constants.frames
local parts = harness.constants.parts
assert(frames == 24, "unexpected frame count")
assert(parts == 20, "unexpected animated-part count")

local function test_animation(kind)
    local values, index = harness.build_animation(kind)
    assert(#values == parts * 3 * frames, kind .. ": invalid values length")
    assert(#index == 6 + parts * 3 * 2, kind .. ": invalid index length")

    -- The first three index pairs are skipped root-translation channels for ANIM_FLAG_6.
    for pair = 0, 2 do
        local pos = pair * 2 + 1
        assert(index[pos] == frames, kind .. ": root placeholder frame count mismatch")
        assert(index[pos + 1] == 0, kind .. ": root placeholder offset mismatch")
    end

    for channel = 0, parts * 3 - 1 do
        local indexPos = 7 + channel * 2
        local count = index[indexPos]
        local offset = index[indexPos + 1]
        assert(count == frames, kind .. ": channel frame count mismatch")
        assert(offset >= 0 and offset + count <= #values, kind .. ": channel offset out of bounds")
        for frame = 0, frames - 1 do
            local value = values[offset + frame + 1]
            assert(value >= -32768 and value <= 32767, kind .. ": value outside signed 16-bit range")
            assert(value == math.floor(value), kind .. ": non-integer animation value")
        end
    end
    return values, index
end

local function sample(values, index, part, axis, frame)
    -- Three reserved translation pairs precede the 20*3 rotation channels.
    local channel = part * 3 + axis
    local indexPos = 7 + channel * 2
    local offset = index[indexPos + 1]
    return values[offset + frame + 1]
end

local idleValues, idleIndex = test_animation("idle")
local walkValues, walkIndex = test_animation("walk")

-- Part indices are zero-based MarioAnimPart order: torso=2, head=3,
-- left arm=5, left forearm=6, right arm=9, right forearm=10,
-- left thigh=13, right thigh=17.
assert(sample(idleValues, idleIndex, 2, 0, 6) == 96, "idle torso breathing amplitude is incorrect")
assert(sample(idleValues, idleIndex, 3, 0, 6) == -32, "idle head counter-motion is incorrect")

local quarter = 6
assert(sample(walkValues, walkIndex, 5, 0, quarter) == 5461, "left arm walk swing incorrect")
assert(sample(walkValues, walkIndex, 9, 0, quarter) == -5461, "right arm must oppose left arm")
assert(sample(walkValues, walkIndex, 13, 0, quarter) == -5461, "left thigh must oppose left arm")
assert(sample(walkValues, walkIndex, 17, 0, quarter) == 5461, "right thigh must oppose left thigh")
assert(sample(walkValues, walkIndex, 5, 0, 18) == -5461, "walk cycle opposite phase incorrect")
assert(sample(walkValues, walkIndex, 5, 0, 0) == 0, "walk cycle must start at neutral pose")
assert(sample(walkValues, walkIndex, 5, 1, quarter) == 0, "walk must not rotate arms around the wrong axis")

print("SteveCraft animation validation passed: 2 animations, 24 frames, 20 parts, 63 channels each.")
