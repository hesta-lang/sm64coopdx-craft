-- Audio event router. Actual samples are registered separately in ModFS.
local M = {}
local samples = {}
local warned = {}

function M.register(name, uri)
    if type(audio_sample_load) ~= "function" then
        if not warned.api then
            print("[SteveCraft] Audio samples are unavailable on this engine build.")
            warned.api = true
        end
        return false
    end
    local ok, sample = pcall(audio_sample_load, uri)
    if not ok or sample == nil then
        if not warned[name] then
            print("[SteveCraft] Could not load sound sample: " .. tostring(name))
            warned[name] = true
        end
        return false
    end
    samples[name] = sample
    return true
end

function M.play(name, position, volume, pitch)
    local sample = samples[name]
    if sample == nil then return false end
    if type(audio_sample_play) ~= "function" then return false end
    local ok = pcall(audio_sample_play, sample, position, volume or 1.0, pitch or 1.0)
    return ok
end

function M.clear()
    samples = {}
end

return M
