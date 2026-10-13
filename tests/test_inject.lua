-- The bundle builder and the non-destructive injector, exercised against a synthetic host bundle in the package.preload style (the user's real bundle was
-- not available in this environment; see reports/00_audit.md).
package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
local root = T.setup_path()
local U = require("asi.nlu.util")

local lua = arg[-1] or "lua5.4"
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp)
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function run(cmd) local h = io.popen(cmd .. " 2>&1"); local o = h:read("a"); local ok = h:close(); return o, ok end

local HOST = [==[
#!/usr/bin/env lua
-- a host bundle in the same style: package.preload modules and a main chunk that returns the entry function
package.preload["host.util"] = function(...)
  local M = {}
  function M.shout(s) return s:upper() end
  return M
end
package.preload["host.main"] = function(...)
  local util = require("host.util")
  return function(text)
    local ok, Hook = pcall(require, "asi.nlu.hook")
    local rel = "none"
    if ok then rel = Hook.prepare(text).record.requested_relations.relation.id end
    return util.shout(text) .. "|" .. rel
  end
end
local main = require("host.main")
return main
]==]
local host_path = tmp .. "/host.lua"
write(host_path, HOST)
local bundle_path = tmp .. "/bundle.lua"

T.test("the bundle builds from the sources, every module compiles, and it runs with nothing on disk", function()
  local o = run(lua .. " " .. root .. "/tools/build_bundle.lua --out " .. bundle_path)
  T.ok(o:find("smoke test passed", 1, true), o)
  local b = read(bundle_path)
  T.ok(b:find('package.preload["asi.nlu.engine"]', 1, true) and b:find('package.preload["asi.nlu.hook"]', 1, true) and b:find('package.preload["asi.nlu.manifest"]', 1, true))
  T.ok(#b > 200000)
end)

T.test("injection is non-destructive: removing the region restores the host byte for byte, and the shebang stays first", function()
  local out_path = tmp .. "/host.asi.lua"
  local o = run(lua .. " " .. root .. "/tools/inject_bundle.lua --target " .. host_path .. " --module " .. bundle_path .. " --out " .. out_path .. " --selfcheck")
  T.ok(o:find("IDENTICAL to the original host", 1, true), o)
  T.ok(o:find("selfcheck: region runs alone", 1, true), o)
  local injected = read(out_path)
  T.ok(injected:sub(1, 2) == "#!", "shebang line preserved as the first line")
  T.ok(injected:find(">>> ASI-NLU BEGIN", 1, true) and injected:find("<<< ASI-NLU END", 1, true))
  local clean_path = tmp .. "/host.clean.lua"
  run(lua .. " " .. root .. "/tools/inject_bundle.lua --target " .. out_path .. " --remove --out " .. clean_path)
  T.eq(read(clean_path), HOST, "removal restores the original host exactly")
  T.eq(U.sha256(read(clean_path)), U.sha256(HOST))
end)

T.test("injection is idempotent", function()
  local out_path = tmp .. "/host.asi.lua"
  local before = read(out_path)
  local o = run(lua .. " " .. root .. "/tools/inject_bundle.lua --target " .. out_path .. " --module " .. bundle_path .. " --in-place")
  T.ok(o:find("already injected", 1, true), o)
  T.eq(read(out_path), before, "a second injection changes nothing")
end)

T.test("the injected host still works and can now interpret text without any language model", function()
  local out_path = tmp .. "/host.asi.lua"
  -- run it in a clean process: the host's own modules and the injected asi.nlu modules cooperate
  write(tmp .. "/run.lua", 'package.path = ""\nlocal main = dofile(' .. string.format("%q", out_path) .. ')\nprint(main("What is the capital of France?"))\n')
  local o = run(lua .. " " .. tmp .. "/run.lua")
  T.ok(o:find("WHAT IS THE CAPITAL OF FRANCE?|capital", 1, true), o)
end)

T.test("injection at an anchor line, and a host file that does not compile is reported rather than corrupted", function()
  local out_path = tmp .. "/host.anchor.lua"
  local o = run(lua .. " " .. root .. "/tools/inject_bundle.lua --target " .. host_path .. " --module " .. bundle_path .. " --out " .. out_path .. " --at 'before:local main = require'")
  T.ok(o:find("IDENTICAL to the original host", 1, true), o)
  local s = read(out_path)
  local a, b = s:find(">>> ASI-NLU BEGIN", 1, true), s:find("local main = require", 1, true)
  T.ok(a and b and a < b, "region sits before the anchor")
  write(tmp .. "/broken.lua", "local x = = 1\n")
  local o2, ok2 = run(lua .. " " .. root .. "/tools/inject_bundle.lua --target " .. tmp .. "/broken.lua --module " .. bundle_path .. " --out " .. tmp .. "/broken.out.lua")
  T.ok(not ok2 or o2:find("does not compile", 1, true), o2)
end)

os.execute("rm -rf " .. tmp)
os.exit(T.report("inject") and 0 or 1)
