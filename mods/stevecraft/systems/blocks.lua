-- SteveCraft block lifecycle and idempotent placement guard.
local M = {}

function M.new_placement_guard()
    local last_frame, last_key
    return function(frame, x, y, z)
        local key = table.concat({ tostring(x), tostring(y), tostring(z) }, ",")
        if frame == last_frame and key == last_key then
            return false, "duplicate_same_frame"
        end
        last_frame, last_key = frame, key
        return true
    end
end

function M.new_object_registry()
    local objects = {}
    return {
        get = function(key) return objects[key] end,
        claim = function(key, object)
            if objects[key] ~= nil and objects[key] ~= object then
                return false
            end
            objects[key] = object
            return true
        end,
        release = function(key, object)
            if object == nil or objects[key] == object then
                objects[key] = nil
                return true
            end
            return false
        end,
        clear = function() objects = {} end,
    }
end

function M.is_live_object(object)
    if object == nil then return false end
    if type(object.activeFlags) ~= "number" then return true end
    return object.activeFlags ~= 0 and (ACTIVE_FLAG_DEACTIVATED == nil or object.activeFlags ~= ACTIVE_FLAG_DEACTIVATED)
end

return M
