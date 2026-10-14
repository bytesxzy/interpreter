-- usage: lua5.4 tools/build_bundle.lua [--out dist/asi_nlu_bundle.lua]
-- Builds ONE Lua file in the same style as the host bundle (package.preload["module.name"] = function(...) ... end) that contains every asi.nlu module, the
-- shipped lexicon DSL data and the calibration model.  Each module is syntax-checked on its own before it is embedded, and the whole file is loaded and smoke-
-- tested after it is written.  The file carries a manifest (module names + SHA-256) in a header comment and as the module asi.nlu.manifest.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")

local opts = { out = root .. "/dist/asi_nlu_bundle.lua" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end

local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local function ls(dir)
  local p = io.popen("ls " .. dir .. " 2>/dev/null")
  local t = {}
  for l in p:lines() do t[#t + 1] = l end
  p:close()
  table.sort(t)
  return t
end

local modules = {}
local EXCLUDE = require("asi.nlu.bundler").LIBRARY_EXCLUDE   -- modules that exist only for the one-file command line
for _, f in ipairs(ls(root .. "/nlu/asi/nlu")) do
  local n = f:match("^(.+)%.lua$")
  if n and not EXCLUDE[n] then modules[#modules + 1] = { name = "asi.nlu." .. n, path = root .. "/nlu/asi/nlu/" .. f } end
end
for _, f in ipairs(ls(root .. "/nlu/asi/nlu/data")) do
  local n = f:match("^(.+)%.lua$")
  if n then modules[#modules + 1] = { name = "asi.nlu.data." .. n, path = root .. "/nlu/asi/nlu/data/" .. f } end
end

-- the calibration model is data, embedded as a JSON string module
local cal_path = root .. "/data/calibration/interp_v1.json"
local cal_json
do local f = io.open(cal_path, "rb"); if f then cal_json = f:read("a"); f:close() end end

local function long_string(s)
  local level = 0
  while s:find("%]" .. string.rep("=", level) .. "%]", 1) do level = level + 1 end
  local eq = string.rep("=", level)
  return "[" .. eq .. "[\n" .. s .. "]" .. eq .. "]"
end

local parts, manifest = {}, {}
local function add_module(name, source)
  local chunk, err = load(source, "=" .. name)
  if not chunk then error("module " .. name .. " does not compile: " .. tostring(err)) end
  manifest[#manifest + 1] = { name = name, bytes = #source, sha256 = U.sha256(source) }
  parts[#parts + 1] = string.format('package.preload[%q] = function(...)\n%s\nend\n', name, source)
end

for _, m in ipairs(modules) do add_module(m.name, read(m.path)) end
if cal_json then add_module("asi.nlu.data.cal_interp_v1", "return " .. long_string(cal_json)) end

local version = "0.9.0"
do
  local ok, Engine = pcall(require, "asi.nlu.engine")
  if ok then version = Engine.VERSION end
end
local body = table.concat(parts, "\n")
local total = U.sha256(body)
local mlines = {}
for _, m in ipairs(manifest) do mlines[#mlines + 1] = string.format("--   %-34s %7d  %s", m.name, m.bytes, m.sha256) end
local manifest_module = "return { version = " .. string.format("%q", version) .. ", body_sha256 = " .. string.format("%q", total) .. ", modules = {\n"
for _, m in ipairs(manifest) do manifest_module = manifest_module .. string.format("  { name = %q, bytes = %d, sha256 = %q },\n", m.name, m.bytes, m.sha256) end
manifest_module = manifest_module .. "} }"
parts[#parts + 1] = string.format('package.preload[%q] = function(...)\n%s\nend\n', "asi.nlu.manifest", manifest_module)
body = table.concat(parts, "\n")

local header = table.concat({
  "-- asi-nlu bundle " .. version .. " : LM-independent natural-language interpretation engine (package.preload modules, no external dependencies).",
  "-- body sha256 (all module blocks, excluding this header): " .. total,
  "-- modules:", table.concat(mlines, "\n"), "",
}, "\n")
local out_text = header .. "\n" .. body

os.execute("mkdir -p " .. opts.out:match("^(.*)/[^/]*$"))
local f = assert(io.open(opts.out, "wb"))
f:write(out_text)
f:close()

-- smoke test in a clean environment: load the file, require the engine, interpret a sentence
local env_loader = assert(loadfile(opts.out))
local saved = {}
for k, v in pairs(package.preload) do saved[k] = v end
for k in pairs(package.loaded) do if k:find("^asi%.nlu") then package.loaded[k] = nil end end
for k in pairs(package.preload) do if k:find("^asi%.nlu") then package.preload[k] = nil end end
local saved_path = package.path
package.path = ""      -- nothing may be found on disk: everything must come from the bundle
env_loader()
local Hook = require("asi.nlu.hook")
local o = Hook.prepare("What is the capital of France?")
assert(o.valid and o.record.requested_relations.relation.id == "capital", "bundle smoke test failed")
package.path = saved_path
print(string.format("wrote %s : %d modules, %d bytes, body sha256 %s", opts.out, #manifest, #out_text, total))
print("smoke test passed (interpreted a sentence using only the bundle)")
