-- asi.nlu.bundler: text generation for the two shapes the project ships in.
--   Bundler.library(files, opts)   the LIBRARY text: package.preload["asi.nlu.x"] = function(...) ... end for every engine module + the shipped lexicon data modules
--                                  + the calibration model, with a manifest header (module names, sizes, SHA-256).  Byte-identical to tools/build_bundle.lua
--                                  for the same sources (tests/test_single.lua checks that), so a host bundle injected from the one-file build equals one injected
--                                  from dist/asi_nlu_bundle.lua.
--   Bundler.single(files, opts)    the ONE-FILE build: every project file (engine sources, lexicon data, gold and held-out sets, tools, tests, reports) as a
--                                  string table + a loader that registers the modules lazily + the command-line entry point.
-- `files` is { [project-relative path] = source }.  Module names come from the path: nlu/asi/nlu/parse.lua -> asi.nlu.parse.
local U = require("asi.nlu.util")

local B = {}

-- modules that exist only for the one-file command line; they are not part of the library text injected into a host bundle
B.LIBRARY_EXCLUDE = U.set({ "main", "vfs", "injector", "bundler" })

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- a long bracket string that cannot be terminated early by its own content (level >= `min`)
function B.long_string(s, min)
  local level = min or 0
  while s:find("%]" .. string.rep("=", level) .. "%]", 1) do level = level + 1 end
  local eq = string.rep("=", level)
  return "[" .. eq .. "[\n" .. s .. "]" .. eq .. "]"
end

-- the project files of a checkout as { [relative path] = content }: engine sources, lexicon data, evaluation data, tests, tools, reports, README
-- (generated or machine-local files are not part of the project: dist/, backups, .git)
B.COLLECT_DIRS = { "nlu", "data", "tests", "tools", "reports" }
B.COLLECT_EXT = U.set({ "lua", "cases", "json", "jsonl", "csv", "md", "txt" })
function B.collect(root)
  local files = {}
  local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
  local function add(rel)
    local ext = rel:match("%.([%w]+)$")
    if not (ext and B.COLLECT_EXT[ext]) or rel:find("asi%-backup", 1) then return end
    local f = io.open(root .. "/" .. rel, "rb")
    if not f then return end
    files[rel] = f:read("a")
    f:close()
  end
  for _, d in ipairs(B.COLLECT_DIRS) do
    local p = io.popen("cd " .. sh_quote(root) .. " && find " .. d .. " -type f 2>/dev/null")
    if p then
      for line in p:lines() do add(line) end
      p:close()
    end
  end
  add("README.md")
  return files
end

-- the module list of the library: { {name=, source=}, ... } in the order tools/build_bundle.lua uses (file names in byte order, data modules last)
function B.library_modules(files, opts)
  opts = opts or {}
  local top, data = {}, {}
  for _, path in ipairs(sorted_keys(files)) do
    local dir, base = path:match("^nlu/asi/nlu/(.-)([^/]+)%.lua$")
    if base then
      if dir == "" and not B.LIBRARY_EXCLUDE[base] then top[#top + 1] = { name = "asi.nlu." .. base, source = files[path], path = path }
      elseif dir == "data/" then data[#data + 1] = { name = "asi.nlu.data." .. base, source = files[path], path = path } end
    end
  end
  local mods = {}
  for _, m in ipairs(top) do mods[#mods + 1] = m end
  for _, m in ipairs(data) do mods[#mods + 1] = m end
  local cal = files["data/calibration/interp_v1.json"]
  if cal then mods[#mods + 1] = { name = "asi.nlu.data.cal_interp_v1", source = "return " .. B.long_string(cal), path = "data/calibration/interp_v1.json" } end
  return mods
end

local function module_block(name, source) return string.format('package.preload[%q] = function(...)\n%s\nend\n', name, source) end

-- returns text, info   (info = { version =, body_sha256 =, modules = { {name=, bytes=, sha256=} } })
function B.library(files, opts)
  opts = opts or {}
  local version = opts.version or "0.0.0"
  local parts, manifest = {}, {}
  for _, m in ipairs(B.library_modules(files, opts)) do
    local chunk, err = load(m.source, "=" .. m.name)
    if not chunk then error("module " .. m.name .. " does not compile: " .. tostring(err)) end
    manifest[#manifest + 1] = { name = m.name, bytes = #m.source, sha256 = U.sha256(m.source) }
    parts[#parts + 1] = module_block(m.name, m.source)
  end
  local total = U.sha256(table.concat(parts, "\n"))
  local mlines = {}
  for _, m in ipairs(manifest) do mlines[#mlines + 1] = string.format("--   %-34s %7d  %s", m.name, m.bytes, m.sha256) end
  local manifest_module = "return { version = " .. string.format("%q", version) .. ", body_sha256 = " .. string.format("%q", total) .. ", modules = {\n"
  for _, m in ipairs(manifest) do manifest_module = manifest_module .. string.format("  { name = %q, bytes = %d, sha256 = %q },\n", m.name, m.bytes, m.sha256) end
  manifest_module = manifest_module .. "} }"
  parts[#parts + 1] = module_block("asi.nlu.manifest", manifest_module)
  local body = table.concat(parts, "\n")
  local header = table.concat({
    "-- asi-nlu bundle " .. version .. " : LM-independent natural-language interpretation engine (package.preload modules, no external dependencies).",
    "-- body sha256 (all module blocks, excluding this header): " .. total,
    "-- modules:", table.concat(mlines, "\n"), "",
  }, "\n")
  return header .. "\n" .. body, { version = version, body_sha256 = total, modules = manifest }
end

---------------------------------------------------------------- the one-file build
-- a Lua string literal for arbitrary bytes: a long bracket string when the content survives the lexer's newline normalisation, an escaped literal otherwise
local function literal(s)
  if s:find("\r", 1, true) or s:find("\0", 1, true) then return (string.format("%q", s):gsub("\\\n", "\\n")) end
  return B.long_string(s, 2)
end
B.literal = literal

-- sha256 over the embedded files in canonical order ("path\0sha256\n" per file): the identity of one build
function B.files_digest(files)
  local lines = {}
  for _, p in ipairs(sorted_keys(files)) do lines[#lines + 1] = p .. "\0" .. U.sha256(files[p]) .. "\n" end
  return U.sha256(table.concat(lines))
end

local LOADER = [=[
local E = { version = %q, digest = %q, sha256 = SHA, files = FILES }
for path, src in pairs(E.files) do
  local mod = path:match("^nlu/(asi/.+)%%.lua$")
  if mod then
    mod = mod:gsub("/", ".")
    package.preload[mod] = function(...) return assert(load(src, "=" .. mod))(...) end
  end
end
package.preload["asi.nlu.embedded"] = function() return E end
package.preload["asi.nlu.data.cal_interp_v1"] = function() return E.files["data/calibration/interp_v1.json"] end
]=]

-- returns the text of the one-file build.  opts = { version =, header = extra header lines }
function B.single(files, opts)
  opts = opts or {}
  local version = opts.version or "0.0.0"
  local digest = B.files_digest(files)
  local entries = {}
  for _, p in ipairs(sorted_keys(files)) do
    local src = files[p]
    if p:match("%.lua$") then
      local chunk, err = load(src, "=" .. p)
      if not chunk then error("file " .. p .. " does not compile: " .. tostring(err)) end
    end
    entries[#entries + 1] = string.format("[%q] = %s,", p, literal(src))
  end
  local head = {
    "-- asi-nlu " .. version .. " -- ONE FILE: LM-independent natural-language interpretation engine, its data, evaluation tools, tests and reports.",
    "-- Run it:      lua5.4 asi_nlu.lua help        (commands: interpret, interpret-eval, interpret-report, interpret-trace, interpret-memory,",
    "--                                                interpret-replay, selftest, tool, inject, bundle, extract, verify, report)",
    "-- Use it as a library:   local asi = dofile('asi_nlu.lua')   -- registers the modules lazily (package.preload) and returns the entry module",
    "-- No network, no external model, no dependency beyond Lua 5.4.  Deterministic.",
    "-- files digest (sha256 over the embedded files in path order): " .. digest,
    "-- embedded files:",
  }
  for _, p in ipairs(sorted_keys(files)) do head[#head + 1] = string.format("--   %-44s %8d  %s", p, #files[p], U.sha256(files[p])) end
  head[#head + 1] = ""
  local out = { table.concat(head, "\n") }
  out[#out + 1] = "local FILES = {\n" .. table.concat(entries, "\n") .. "\n}"
  local shas = {}
  for _, p in ipairs(sorted_keys(files)) do shas[#shas + 1] = string.format("[%q] = %q,", p, U.sha256(files[p])) end
  out[#out + 1] = "local SHA = {\n" .. table.concat(shas, "\n") .. "\n}"
  out[#out + 1] = string.format(LOADER, version, digest)
  out[#out + 1] = [=[
local main = require("asi.nlu.main")
local me = debug.getinfo(1, "S").source:gsub("^@", "")
if arg and arg[0] == me then os.exit(main.run(arg)) end
return main
]=]
  return table.concat(out, "\n"), { digest = digest, version = version }
end

return B
