-- Camera basis and ray helpers shared by crosshair targeting and building.
local M = {}

function M.forward(yaw, pitch, sin_fn, cos_fn)
    local yaw_sin = sin_fn and sin_fn(yaw) or math.sin((yaw or 0) * math.pi / 32768)
    local yaw_cos = cos_fn and cos_fn(yaw) or math.cos((yaw or 0) * math.pi / 32768)
    local pitch_sin = sin_fn and sin_fn(pitch) or math.sin((pitch or 0) * math.pi / 32768)
    local pitch_cos = cos_fn and cos_fn(pitch) or math.cos((pitch or 0) * math.pi / 32768)
    return {
        x = -pitch_cos * yaw_sin,
        y = -pitch_sin,
        z = -pitch_cos * yaw_cos,
    }
end

return M
