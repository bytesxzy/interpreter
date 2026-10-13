-- usage: lua5.4 tools/inject_bundle.lua --target HOST.lua [--module dist/asi_nlu_bundle.lua] [--out OUT.lua | --in-place] [--at start|before:TEXT] [--remove] [--selfcheck]
-- Controlled, non-destructive injection of the asi-nlu modules into a package.preload-style host bundle.
--   * The host file is never modified in place unless --in-place is given, and then only after a byte-exact backup (.asi-backup) is written and verified.
--   * The injected region is delimited by BEGIN/END marker comments that carry the module bundle's version and SHA-256, so injection is IDEMPOTENT
--     (same bundle already present => no change; different version => the region is replaced) and REVERSIBLE (--remove).
--   * Proof of non-destruction: the output with the marked region cut out is compared byte-for-byte (SHA-256) with the original host file.
--   * The injected code only adds entries to package.preload; --selfcheck executes the region alone in a fresh environment and verifies that no global is
--     created or changed and that the engine interprets a sentence.  The host file itself is only COMPILED (never run) to check that it still parses.
local function read(path) local f, e = io.open(path, "rb"); if not f then return nil, e end local s = f:read("a"); f:close(); return s end
local function write(path, s) local f = assert(io.open(path, "wb")); f:write(s); f:close() end
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")

local opts = { module = root .. "/dist/asi_nlu_bundle.lua", at = "start" }
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--in-place" or a == "--remove" or a == "--selfcheck" then opts[a:sub(3):gsub("%-", "_")] = true; i = i + 1
    elseif a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2
    else i = i + 1 end
  end
end
if not opts.target then io.stderr:write("--target is required\n"); os.exit(2) end

local host, herr = read(opts.target)
if not host then io.stderr:write(herr .. "\n"); os.exit(2) end
local BEGIN_PAT = "%-%-  >>> ASI%-NLU BEGIN [^\n]*\n"
local END_TXT = "\n%-%-  <<< ASI%-NLU END[^\n]*\n"

-- locate an existing region
local function find_region(text)
  local bs, be = text:find(BEGIN_PAT)
  if not bs then return nil end
  local es, ee = text:find(END_TXT, be)
  if not es then error("found an ASI-NLU BEGIN marker without an END marker: refusing to touch the file") end
  return bs, ee
end

local function strip_region(text)
  local bs, ee = find_region(text)
  if not bs then return text, false end
  return text:sub(1, bs - 1) .. text:sub(ee + 1), true
end

local original_host, had_region = strip_region(host)
local sha_original = U.sha256(original_host)

local function report(lines) for _, l in ipairs(lines) do print(l) end end

if opts.remove then
  if not had_region then print("nothing to remove: no ASI-NLU region present"); os.exit(0) end
  local dest = opts.out or (opts.in_place and opts.target) or (opts.target .. ".clean.lua")
  if opts.in_place then write(opts.target .. ".asi-backup", host) end
  write(dest, original_host)
  print(string.format("removed the ASI-NLU region -> %s (%d bytes, sha256 %s)", dest, #original_host, sha_original))
  os.exit(0)
end

local mod, merr = read(opts.module)
if not mod then io.stderr:write("cannot read module bundle: " .. tostring(merr) .. "\n"); os.exit(2) end
local mod_sha = U.sha256(mod)
local version = mod:match("asi%-nlu bundle ([%d%.]+)") or "?"
local begin_marker = string.format("--  >>> ASI-NLU BEGIN %s sha256=%s bytes=%d (package.preload modules only; remove with tools/inject_bundle.lua --remove)\n", version, mod_sha, #mod)
local end_marker = string.format("\n--  <<< ASI-NLU END %s\n", version)
local region = begin_marker .. mod .. (mod:sub(-1) == "\n" and "" or "\n") .. "do local _ = nil end" .. end_marker

-- idempotency: same region already present
if had_region and host:find(region, 1, true) then
  print(string.format("already injected (version %s, sha256 %s): no change", version, mod_sha))
  os.exit(0)
end

-- insertion point
local base = original_host
local pos
if opts.at == "start" then
  pos = 1
  if base:sub(1, 2) == "#!" then pos = (base:find("\n", 1, true) or #base) + 1 end   -- keep a shebang line first
elseif opts.at:sub(1, 7) == "before:" then
  local needle = opts.at:sub(8)
  local last
  local from = 1
  while true do
    local s = base:find(needle, from, true)
    if not s then break end
    last = s; from = s + 1
  end
  if not last then io.stderr:write("anchor text not found: " .. needle .. "\n"); os.exit(2) end
  -- back up to the start of that line
  while last > 1 and base:sub(last - 1, last - 1) ~= "\n" do last = last - 1 end
  pos = last
else
  io.stderr:write("--at must be 'start' or 'before:TEXT'\n"); os.exit(2)
end
local output = base:sub(1, pos - 1) .. region .. base:sub(pos)

-- verification 1: cutting the region out restores the original exactly
local restored, cut = strip_region(output)
local sha_restored = U.sha256(restored)
assert(cut and restored == base, "internal error: the injected output does not restore to the original host")
-- verification 2: the output still compiles (syntax only); the host is never executed
local function compile_text(t) return t:gsub("^#[^\n]*", "--") end      -- load() does not skip a shebang line; the lua executable does
local chunk, cerr = load(compile_text(output), "=" .. (opts.target:match("[^/]+$") or "host"))
if not chunk then io.stderr:write("the injected file does not compile: " .. tostring(cerr) .. "\n"); os.exit(3) end
local host_alone, herr2 = load(compile_text(base), "=host")
local host_compiles = host_alone ~= nil
-- verification 3 (optional): run the injected region alone
if opts.selfcheck then
  local before = {}
  for k, v in pairs(_G) do before[k] = v end
  local saved_pre, saved_loaded = {}, {}
  for k, v in pairs(package.preload) do saved_pre[k] = v end
  for k, v in pairs(package.loaded) do saved_loaded[k] = v end
  for k in pairs(package.preload) do if k:find("^asi%.nlu") then package.preload[k] = nil end end
  for k in pairs(package.loaded) do if k:find("^asi%.nlu") then package.loaded[k] = nil end end
  local saved_path = package.path
  package.path = ""
  local reg = assert(load(region, "=asi-nlu-region"))
  reg()
  local Hook = require("asi.nlu.hook")
  local o = Hook.prepare("What is the capital of France?")
  assert(o.valid and o.record.requested_relations.relation.id == "capital", "selfcheck: interpretation failed")
  local changed = {}
  for k, v in pairs(_G) do if before[k] ~= v then changed[#changed + 1] = tostring(k) end end
  for k in pairs(before) do if _G[k] == nil then changed[#changed + 1] = tostring(k) .. "(removed)" end end
  assert(#changed == 0, "selfcheck: the injected region changed globals: " .. table.concat(changed, ","))
  package.path = saved_path
  print("selfcheck: region runs alone, adds only package.preload entries, interprets a sentence")
end

local dest = opts.out or (opts.in_place and opts.target) or (opts.target:gsub("%.lua$", "") .. ".asi.lua")
if opts.in_place then
  write(opts.target .. ".asi-backup", host)
  assert(read(opts.target .. ".asi-backup") == host, "backup verification failed")
end
write(dest, output)
report({
  string.format("host            : %s (%d bytes, %d lines)", opts.target, #host, select(2, host:gsub("\n", "\n")) + 1),
  string.format("host sha256     : %s%s", sha_original, had_region and " (after removing an earlier ASI-NLU region)" or ""),
  string.format("host compiles   : %s", tostring(host_compiles)),
  string.format("injected at     : byte %d (%s)", pos, opts.at),
  string.format("module bundle   : %s version %s sha256 %s (%d bytes)", opts.module, version, mod_sha, #mod),
  string.format("output          : %s (%d bytes)", dest, #output),
  string.format("output sha256   : %s", U.sha256(output)),
  string.format("restore check   : cutting the region out gives sha256 %s -> %s", sha_restored, sha_restored == sha_original and "IDENTICAL to the original host" or "DIFFERENT (!)"),
  string.format("output compiles : %s", tostring(chunk ~= nil)),
})
