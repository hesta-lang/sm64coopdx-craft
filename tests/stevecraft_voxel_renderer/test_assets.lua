package.path = "mods/stevecraft/?.lua;" .. package.path

local Assets = require("systems/assets")
assert(Assets.decode_base64("AQID/w==") == string.char(1, 2, 3, 255), "base64 decoder mishandled binary bytes")
assert(Assets.decode_base64("SGVsbG8=") == "Hello", "base64 decoder mishandled padding")
local value, err = Assets.decode_base64("not-base64!")
assert(value == nil and type(err) == "string", "base64 decoder did not reject malformed data")
print("PASS: embedded binary resource base64 decoder")


-- SM64CoopDX CObject wrappers (including ModFs) are Lua userdata, not tables.
-- Exercise the same runtime type with a closed file handle and a test metatable.
local dummy = assert(io.tmpfile())
dummy:close()
local stored = {}
local save_calls = 0
local fake_file = {
    size = 0,
}
function fake_file:set_text_mode(value) self.text_mode = value; return true end
function fake_file:erase() self.bytes = ""; self.size = 0; return true end
function fake_file:rewind() return true end
function fake_file:write_bytes(bytes)
    self.bytes = bytes
    self.size = #bytes
    return true
end
debug.setmetatable(dummy, {
    __index = function(_, key)
        if key == "modPath" then return "stevecraft" end
        if key == "get_file" then
            return function(_, path) return stored[path] end
        end
        if key == "create_file" then
            return function(_, path, is_text)
                assert(is_text == false)
                stored[path] = fake_file
                return fake_file
            end
        end
        if key == "save" then
            return function()
                save_calls = save_calls + 1
                return true
            end
        end
    end,
})
MOD_FS_URI_FORMAT = "modfs:/%s/%s"
function mod_fs_get() return dummy end
package.loaded["embedded_block_textures"] = {
    ["textures/block/stone.png"] = "AQID",
}
assert(type(dummy) == "userdata", "test did not create an SM64CoopDX-like userdata")
assert(Assets.get_uri("textures/block/stone.png") == "modfs:/stevecraft/assets/textures/block/stone.png",
    "ModFS URI resolver rejected a CObject userdata wrapper")
local imported, report = Assets.install_embedded_resources(dummy)
assert(imported == true, "embedded resource importer rejected ModFs userdata")
assert(report.installed == 1, "userdata ModFS did not report one imported file")
assert(stored["assets/textures/block/stone.png"] == fake_file, "userdata ModFS did not create the texture file")
assert(fake_file.bytes == string.char(1, 2, 3), "userdata ModFS did not write decoded PNG bytes")
assert(save_calls == 1, "userdata ModFS did not persist imported assets")
print("PASS: ModFs userdata compatibility and embedded ModFS resource import")
