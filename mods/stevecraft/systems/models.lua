-- Custom actor registry helpers. The Steve binary importer is owned by main.lua.
local M = {}

function M.modfs_uri(format_string, modfs, filepath)
    if type(format_string) ~= "string" or type(modfs) ~= "table"
        or type(modfs.modPath) ~= "string" then
        return nil
    end
    return string.format(format_string, modfs.modPath, filepath)
end

function M.resolve(uri, resolver)
    if type(uri) ~= "string" or type(resolver) ~= "function" then return nil end
    local ok, result = pcall(resolver, uri)
    if not ok or type(result) ~= "number" then return nil end
    return result
end

return M
