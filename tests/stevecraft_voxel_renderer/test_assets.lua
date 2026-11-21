package.path = "mods/stevecraft/?.lua;" .. package.path

local Assets = require("systems/assets")
assert(Assets.decode_base64("AQID/w==") == string.char(1, 2, 3, 255), "base64 decoder mishandled binary bytes")
assert(Assets.decode_base64("SGVsbG8=") == "Hello", "base64 decoder mishandled padding")
local value, err = Assets.decode_base64("not-base64!")
assert(value == nil and type(err) == "string", "base64 decoder did not reject malformed data")
print("PASS: embedded binary resource base64 decoder")
