-- The ONE-FILE build: it is built from the checkout, then every claim made about it is checked from an EMPTY directory with nothing but the file itself.
package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
local root = T.setup_path()
local U = require("asi.nlu.util")
local lua = arg[-1] or "lua5.4"

local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/asi_single_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
os.execute("mkdir -p " .. tmp .. "/empty")
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function run(cmd) local h = io.popen(cmd .. " 2>&1"); local o = h:read("a"); local ok, how, code = h:close(); return o, ok and 0 or (code or 1) end

local single = tmp .. "/asi_nlu.lua"
local function asi(args) return run("cd " .. tmp .. "/empty && " .. lua .. " ../asi_nlu.lua " .. args) end

T.test("the builder writes one file and proves it reproduces every embedded file", function()
  local o, code = run(lua .. " " .. root .. "/tools/build_single.lua --out " .. single)
  T.ok(code == 0, o)
  T.ok(o:find("files embedded", 1, true), o)
  T.ok(#read(single) > 1000000, "the file should embed the engine and its data")
end)

T.test("verify: every embedded file hashes to the recorded value; a tampered copy is refused", function()
  local o, code = asi("verify")
  T.ok(code == 0 and o:find("0 mismatched", 1, true), o)
  local text = read(single)
  local at = text:find("class det: the a an this", 1, true)
  T.ok(at, "lexicon text should be embedded")
  write(tmp .. "/tampered.lua", text:sub(1, at - 1) .. "class det: thx a an this" .. text:sub(at + #"class det: the a an this"))
  local o2, code2 = run("cd " .. tmp .. "/empty && " .. lua .. " ../tampered.lua verify")
  T.ok(code2 ~= 0 and o2:find("MISMATCH", 1, true), "a modified embedded file must be detected: " .. o2)
end)

T.test("interpret from an empty directory (no source tree, no data directory, package.path untouched)", function()
  local o, code = asi('interpret "What is the capital of France?"')
  T.ok(code == 0 and o:find("relation   : capital", 1, true) and o:find("France", 1, true), o)
  local j, jc = asi('interpret --json "Which company acquired the business I mentioned earlier?"')
  T.ok(jc == 0, j)
  local rec = U.json_decode(j)
  T.ok(rec and rec.requested_relations.relation.id == "acquirer" and rec.integrity and rec.integrity.sha256, "record should validate: " .. j:sub(1, 200))
  local p, pc = asi('interpret --prompt "Do not include universities in the results."')
  T.ok(pc == 0 and #p > 100, p)
end)

T.test("interpret-eval runs the embedded gold sets (dev, val, regression A-J) and the CLI gives the same numbers as the checkout", function()
  local o, code = asi("interpret-eval --split dev --failures 3")
  T.ok(code == 0 and o:find("all-fields accuracy=1.000", 1, true), o)
  local v, vc = asi("interpret-eval --split val --failures 3")
  T.ok(vc == 0 and v:find("n=100", 1, true), v)
  local a, ac = asi("interpret-eval --file data/eval/regression_AJ.cases --failures 3")
  T.ok(ac == 0 and a:find("n=38", 1, true), a)
  local co = run(lua .. " " .. root .. "/tools/run_eval.lua --split dev --failures 0")
  T.eq(o:match("accuracy=%S+"), co:match("accuracy=%S+"))
end)

T.test("selftest --quick passes inside the single file", function()
  local o, code = asi("selftest --quick")
  T.ok(code == 0 and o:find("SELFTEST PASSED", 1, true), o)
end)

T.test("tool: an embedded evaluation tool runs from the file (manifest check of the frozen split)", function()
  local o, code = asi("tool manifest check")
  T.ok(code == 0 and o:find("test  cases=140", 1, true) and o:find("[frozen]", 1, true), o)
end)

T.test("bundle: the library text equals the one produced by tools/build_bundle.lua", function()
  local o, code = asi("bundle --out " .. tmp .. "/lib_from_single.lua")
  T.ok(code == 0, o)
  local o2, code2 = run(lua .. " " .. root .. "/tools/build_bundle.lua --out " .. tmp .. "/lib_from_tool.lua")
  T.ok(code2 == 0, o2)
  T.ok(read(tmp .. "/lib_from_single.lua") == read(tmp .. "/lib_from_tool.lua"), "the two library texts must be byte-identical")
end)

T.test("inject into a host bundle, run it, inject again (no change), remove (byte-exact)", function()
  local host = "-- host\npackage.preload['host.m'] = function() return { n = 41 } end\nprint(require('host.m').n + 1)\n"
  write(tmp .. "/empty/host.lua", host)
  local o, code = asi("inject --target host.lua --out host.asi.lua --selfcheck")
  T.ok(code == 0 and o:find("IDENTICAL to the original host", 1, true) and o:find("selfcheck", 1, true), o)
  local r, rc = run("cd " .. tmp .. "/empty && " .. lua .. " -e 'package.path=\"\"' host.asi.lua")
  T.ok(rc == 0 and r:find("42", 1, true), r)
  write(tmp .. "/empty/use.lua", 'package.path = ""\nassert(loadfile("host.asi.lua"))()\nlocal o = require("asi.nlu.hook").prepare("Who founded Acme?")\nprint(o.valid, o.record.requested_relations.relation.id)\n')
  local u, uc = run("cd " .. tmp .. "/empty && " .. lua .. " use.lua")
  T.ok(uc == 0 and u:find("42", 1, true) and u:find("true\tfounder", 1, true), u)
  local again = asi("inject --target host.asi.lua --out host.asi2.lua")
  T.ok(again:find("no change", 1, true), again)
  local _, rmc = asi("inject --target host.asi.lua --remove --out host.restored.lua")
  T.ok(rmc == 0)
  T.ok(read(tmp .. "/empty/host.restored.lua") == host, "removal must restore the host byte for byte")
end)

T.test("extract rebuilds the project tree byte for byte", function()
  local o, code = asi("extract ../tree")
  T.ok(code == 0 and o:find("extracted", 1, true), o)
  for _, rel in ipairs({ "nlu/asi/nlu/parse.lua", "nlu/asi/nlu/data/lex_core.lua", "data/eval/dev.cases", "tests/t.lua", "tools/run_eval.lua", "data/calibration/interp_v1.json" }) do
    T.ok(read(tmp .. "/tree/" .. rel) == read(root .. "/" .. rel), "differs: " .. rel)
  end
end)

T.test("library use: dofile registers modules lazily, prints nothing, creates no global", function()
  write(tmp .. "/empty/lib.lua", [[
package.path = ""
local before = {}
for k in pairs(_G) do before[k] = true end
local asi = dofile("../asi_nlu.lua")
local added = {}
for k in pairs(_G) do if not before[k] then added[#added + 1] = k end end
assert(#added == 0, "globals created: " .. table.concat(added, ","))
local o = asi.prepare("What is the capital of France?")
print(o.valid, o.record.requested_relations.relation.id, asi.version())
]])
  local o, code = run("cd " .. tmp .. "/empty && " .. lua .. " lib.lua")
  T.ok(code == 0 and o:find("true\tcapital\t", 1, true), o)
end)

os.execute("rm -rf " .. tmp)
os.exit(T.report("single") and 0 or 1)
