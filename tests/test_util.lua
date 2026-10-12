package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
local root = T.setup_path()
local U = require("asi.nlu.util")

T.test("sha256 known vectors", function()
  T.eq(U.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  T.eq(U.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  T.eq(U.sha256(string.rep("a", 1000000)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  -- padding boundaries
  T.eq(U.sha256(string.rep("x", 55)), U.sha256(string.rep("x", 55)))
  T.ok(U.sha256(string.rep("x", 55)) ~= U.sha256(string.rep("x", 56)))
end)

T.test("sha256 matches system sha256sum on pseudo-random data", function()
  local rng = U.rng(99)
  for _, n in ipairs({ 0, 1, 55, 56, 63, 64, 65, 119, 120, 1000 }) do
    local bytes = {}
    for i = 1, n do bytes[i] = string.char(rng:int(0, 255)) end
    local data = table.concat(bytes)
    local f = assert(io.open("/tmp/_sha_test.bin", "wb")); f:write(data); f:close()
    local p = io.popen("sha256sum /tmp/_sha_test.bin")
    local ref = p:read("*l"):match("^(%x+)"); p:close()
    T.eq(U.sha256(data), ref, "len " .. n)
  end
  os.remove("/tmp/_sha_test.bin")
end)

T.test("json round trip is canonical and strict", function()
  local v = { b = 1, a = { 1, 2, { z = true, y = "é\n\"" } }, c = 1.5, d = "ok" }
  local s = U.json_encode(v)
  T.eq(s, '{"a":[1,2,{"y":"é\\n\\"","z":true}],"b":1,"c":1.5,"d":"ok"}')
  T.eq(U.json_decode(s), v)
  T.eq(U.json_decode('"\\ud83d\\ude00"'), "😀")
  T.eq(select(2, U.json_decode('{"a":1,"a":2}')) ~= nil, true, "duplicate keys rejected")
  T.ok(select(2, U.json_decode("[1,2,]")), "trailing comma rejected")
  T.ok(select(2, U.json_decode("{'a':1}")), "single quotes rejected")
  T.ok(select(2, U.json_decode("01")), "leading zero rejected")
  T.ok(select(2, U.json_decode('"\\ud800"')), "lone surrogate rejected")
  T.ok(select(2, U.json_decode('"a\nb"')), "raw control char rejected")
  T.ok(select(2, U.json_decode("\255\254")), "invalid utf8 rejected")
  T.ok(select(2, U.json_decode(string.rep("[", 200) .. string.rep("]", 200))), "depth limit")
  T.eq(U.json_decode("[]"), {})
  T.eq(getmetatable(U.json_decode("{}")), U.OBJ)
  T.eq(U.json_encode(U.json_decode("{}")), "{}")
  local ok = pcall(U.json_encode, { x = 0 / 0 })
  T.ok(not ok, "NaN rejected")
end)

T.test("rng is deterministic and well-spread", function()
  local a, b = U.rng(5), U.rng(5)
  for _ = 1, 20 do T.eq(a:u64(), b:u64()) end
  local r, seen = U.rng(1), {}
  for _ = 1, 1000 do seen[r:int(1, 10)] = true end
  T.eq(U.count(seen), 10)
end)

T.test("osa distance", function()
  T.eq(U.osa("capital", "captial", 2), 1) -- transposition
  T.eq(U.osa("france", "frnace", 2), 1)
  T.eq(U.osa("kitten", "sitting", 5), 3)
  T.eq(U.osa("abc", "xyz", 1), 2) -- capped at maxd+1
  T.eq(U.osa("é", "e", 1), 1)
end)

T.test("wilson interval brackets the point estimate", function()
  local lo, hi = U.wilson(90, 100)
  T.ok(lo < 0.9 and hi > 0.9 and lo > 0.8 and hi < 0.96)
  local l0, h0 = U.wilson(0, 50)
  T.ok(l0 == 0 and h0 > 0 and h0 < 0.1)
end)

T.test("meter enforces budget", function()
  local m = U.meter(5)
  T.ok(m:tick("a", 3))
  T.ok(not m:tick("b", 3))
  T.ok(m:snapshot().exceeded)
end)

T.test("schema validator", function()
  local spec = { type = "object", fields = { n = { type = "integer", required = true, min = 0 }, s = { type = "string" } }, extra = false }
  T.ok(U.validate(spec, { n = 1, s = "x" }))
  T.ok(not U.validate(spec, { s = "x" }))
  T.ok(not U.validate(spec, { n = -1 }))
  T.ok(not U.validate(spec, { n = 1, zz = 1 }))
end)

os.exit(T.report("util") and 0 or 1)
