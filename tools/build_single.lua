-- usage: lua5.4 tools/build_single.lua [--out dist/asi_nlu.lua]
-- Builds the ONE-FILE distribution: the engine, its lexicon data, gold and held-out sets, calibration model, acceptance world, evaluation tools, unit tests, reports
-- and the command-line entry point in a single Lua file.  The file is then loaded from an EMPTY directory with package.path = "" and exercised
-- (version, verify, interpret, interpret-eval, bundle) so that a broken build can never be written silently.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")
local B = require("asi.nlu.bundler")
local Engine = require("asi.nlu.engine")

local opts = { out = root .. "/dist/asi_nlu.lua" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end

local files = B.collect(root)
local text, info = B.single(files, { version = Engine.VERSION })
os.execute("mkdir -p '" .. opts.out:match("^(.*)/[^/]*$") .. "'")
local f = assert(io.open(opts.out, "wb"))
f:write(text)
f:close()

-- the written file must reproduce every embedded file byte for byte when it is loaded
local chunk = assert(loadfile(opts.out))
local saved_pre, saved_loaded, saved_path = {}, {}, package.path
for k, v in pairs(package.preload) do saved_pre[k] = v end
for k, v in pairs(package.loaded) do saved_loaded[k] = v end
for k in pairs(package.preload) do if k:find("^asi%.nlu") then package.preload[k] = nil end end
for k in pairs(package.loaded) do if k:find("^asi%.nlu") then package.loaded[k] = nil end end
package.path = ""
local main = chunk()
local E = require("asi.nlu.embedded")
local n = 0
for p, src in pairs(files) do
  assert(E.files[p] == src, "embedded content differs from the source file: " .. p)
  n = n + 1
end
assert(main.version() == Engine.VERSION)
package.path = saved_path
print(string.format("wrote %s : %d files embedded, %d bytes, files digest %s", opts.out, n, #text, info.digest))
