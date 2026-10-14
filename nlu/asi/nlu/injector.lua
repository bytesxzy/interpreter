-- asi.nlu.injector: controlled, non-destructive injection of the engine's package.preload modules into a host Lua bundle (the same behaviour as
-- tools/inject_bundle.lua, as a library so the ONE-FILE build can inject itself).
--   * Nothing is modified in place unless the caller writes the result over the host (the CLI does so only with --in-place, after a verified byte-exact backup).
--   * The injected region is delimited by BEGIN/END marker comments that carry the library's version and SHA-256: injection is IDEMPOTENT (the same region already
--     present => no change; another version => the region is replaced) and REVERSIBLE (remove => the host's original bytes come back).
--   * Proof of non-destruction: the output with the marked region cut out is compared byte for byte (SHA-256) with the original host.
--   * The injected text only adds entries to package.preload; selfcheck executes it in a SANDBOX environment (its own `package`/`require`), verifies that it creates
--     no global and that the engine interprets a sentence.  The host is only COMPILED here, never run.
local U = require("asi.nlu.util")

local I = {}

I.BEGIN_PAT = "%-%-  >>> ASI%-NLU BEGIN [^\n]*\n"
I.END_PAT = "\n%-%-  <<< ASI%-NLU END[^\n]*\n"

-- load() does not skip a shebang line (the lua executable does)
local function compile_text(t) return (t:gsub("^#[^\n]*", "--")) end

function I.find_region(text)
  local bs, be = text:find(I.BEGIN_PAT)
  if not bs then return nil end
  local es, ee = text:find(I.END_PAT, be)
  if not es then error("found an ASI-NLU BEGIN marker without an END marker: refusing to touch the file") end
  return bs, ee
end

function I.strip_region(text)
  local bs, ee = I.find_region(text)
  if not bs then return text, false end
  return text:sub(1, bs - 1) .. text:sub(ee + 1), true
end

-- the marked region for a library text
function I.region(lib)
  local sha = U.sha256(lib)
  local version = lib:match("asi%-nlu bundle ([%d%.]+)") or "?"
  local begin_marker = string.format("--  >>> ASI-NLU BEGIN %s sha256=%s bytes=%d (package.preload modules only; remove with the injector's --remove)\n", version, sha, #lib)
  local end_marker = string.format("\n--  <<< ASI-NLU END %s\n", version)
  return begin_marker .. lib .. (lib:sub(-1) == "\n" and "" or "\n") .. "do local _ = nil end" .. end_marker, version, sha
end

-- run the region in a sandbox: it must only add package.preload entries (no global) and the engine must interpret a sentence from it alone
function I.selfcheck(region)
  local new_globals = {}
  local fake = { preload = {}, loaded = {}, path = "", cpath = "", config = package.config }
  local env = setmetatable({}, { __index = _G, __newindex = function(t, k, v) new_globals[#new_globals + 1] = tostring(k); rawset(t, k, v) end })
  rawset(env, "package", fake)
  rawset(env, "require", function(name)
    local m = fake.loaded[name]
    if m ~= nil then return m end
    local loader = fake.preload[name]
    if not loader then error("module '" .. tostring(name) .. "' is not provided by the injected region") end
    local r = loader(name)
    if r == nil then r = true end
    fake.loaded[name] = r
    return r
  end)
  local chunk, err = load(region, "=asi-nlu-region", "t", env)
  if not chunk then return false, "region does not compile: " .. tostring(err) end
  local ok, rerr = pcall(chunk)
  if not ok then return false, "region failed to run: " .. tostring(rerr) end
  local n_modules = 0
  for _ in pairs(fake.preload) do n_modules = n_modules + 1 end
  local ok2, o = pcall(function() return env.require("asi.nlu.hook").prepare("What is the capital of France?") end)
  if not ok2 then return false, "the engine failed inside the sandbox: " .. tostring(o) end
  if not (o.valid and o.record.requested_relations and o.record.requested_relations.relation and o.record.requested_relations.relation.id == "capital") then
    return false, "selfcheck: interpretation failed inside the sandbox"
  end
  if #new_globals > 0 then return false, "selfcheck: the region created globals: " .. table.concat(new_globals, ",") end
  return true, string.format("region runs alone in a sandbox (%d package.preload entries), creates no global, interprets a sentence", n_modules)
end

-- opts = { at = "start" | "before:TEXT", selfcheck = bool, target = "name for messages" }
-- returns { ok =, output =, unchanged =, report = { lines }, error = }
function I.inject(host, lib, opts)
  opts = opts or {}
  local at = opts.at or "start"
  local original, had_region = I.strip_region(host)
  local sha_original = U.sha256(original)
  local region, version, sha = I.region(lib)
  if had_region and host:find(region, 1, true) then
    return { ok = true, unchanged = true, output = host, report = { string.format("already injected (version %s, sha256 %s): no change", version, sha) } }
  end
  local pos
  if at == "start" then
    pos = 1
    if original:sub(1, 2) == "#!" then pos = (original:find("\n", 1, true) or #original) + 1 end   -- keep a shebang line first
  elseif at:sub(1, 7) == "before:" then
    local needle = at:sub(8)
    local last, from = nil, 1
    while true do
      local s = original:find(needle, from, true)
      if not s then break end
      last = s; from = s + 1
    end
    if not last then return { ok = false, error = "anchor text not found: " .. needle } end
    while last > 1 and original:sub(last - 1, last - 1) ~= "\n" do last = last - 1 end
    pos = last
  else
    return { ok = false, error = "at must be 'start' or 'before:TEXT'" }
  end
  local output = original:sub(1, pos - 1) .. region .. original:sub(pos)
  local restored, cut = I.strip_region(output)
  if not (cut and restored == original) then return { ok = false, error = "internal error: the injected output does not restore to the original host" } end
  local chunk, cerr = load(compile_text(output), "=" .. (opts.target or "host"))
  if not chunk then return { ok = false, error = "the injected file does not compile: " .. tostring(cerr) } end
  local host_alone = load(compile_text(original), "=host")
  local report = {
    string.format("host            : %s (%d bytes)", opts.target or "?", #host),
    string.format("host sha256     : %s%s", sha_original, had_region and " (after removing an earlier ASI-NLU region)" or ""),
    string.format("host compiles   : %s", tostring(host_alone ~= nil)),
    string.format("injected at     : byte %d (%s)", pos, at),
    string.format("library         : version %s sha256 %s (%d bytes)", version, sha, #lib),
    string.format("output sha256   : %s (%d bytes)", U.sha256(output), #output),
    string.format("restore check   : cutting the region out gives sha256 %s -> %s", U.sha256(restored), U.sha256(restored) == sha_original and "IDENTICAL to the original host" or "DIFFERENT (!)"),
    "output compiles : true",
  }
  if opts.selfcheck then
    local ok, msg = I.selfcheck(region)
    if not ok then return { ok = false, error = msg } end
    report[#report + 1] = "selfcheck       : " .. msg
  end
  return { ok = true, output = output, report = report, sha_original = sha_original }
end

-- removes the region: returns { ok =, output =, had_region =, sha256 = }
function I.remove(host)
  local original, had = I.strip_region(host)
  return { ok = true, output = original, had_region = had, sha256 = U.sha256(original) }
end

return I
