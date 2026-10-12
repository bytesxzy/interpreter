-- Minimal deterministic test harness (no external dependencies).
local T = { passed = 0, failed = 0, failures = {}, current = nil }

local function show(v, d)
  d = d or 0
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if d > 3 then return "{...}" end
  local parts = {}
  local ks = {}
  for k in pairs(v) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(ks) do parts[#parts + 1] = tostring(k) .. "=" .. show(v[k], d + 1) end
  return "{" .. table.concat(parts, ", ") .. "}"
end
T.show = show

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- every test gets an instruction budget (default ~400M VM instructions) so an infinite loop fails fast and by name
T.budget_chunks = tonumber(os.getenv("NLU_TEST_BUDGET") or "") or 400

function T.test(name, fn)
  T.current = name
  local chunks = 0
  debug.sethook(function()
    chunks = chunks + 1
    if chunks > T.budget_chunks then error("TEST BUDGET EXCEEDED (possible infinite loop): " .. name, 0) end
  end, "", 1000000)
  local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
  debug.sethook()
  if ok then T.passed = T.passed + 1
  else
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = name .. "\n    " .. tostring(err):gsub("\n", "\n    ")
  end
end

function T.eq(a, b, msg)
  if not deep_eq(a, b) then
    error((msg or "values differ") .. "\n  got:      " .. show(a) .. "\n  expected: " .. show(b), 2)
  end
end
function T.ok(c, msg) if not c then error(msg or "assertion failed", 2) end end
function T.near(a, b, eps, msg)
  if math.abs(a - b) > (eps or 1e-9) then error((msg or "not near") .. ": " .. a .. " vs " .. b, 2) end
end

function T.report(title)
  print(string.format("[%s] passed=%d failed=%d", title or "tests", T.passed, T.failed))
  for _, f in ipairs(T.failures) do print("  FAIL " .. f) end
  return T.failed == 0
end

-- locate repo root from this file so tests run from any cwd
function T.setup_path()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local root = src:match("^(.*)/tests/[^/]*$") or "."
  package.path = root .. "/nlu/?.lua;" .. package.path
  return root
end

return T
