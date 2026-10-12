-- Runs every tests/test_*.lua as an isolated subprocess and prints one summary line per suite.
-- usage: lua5.4 tests/run_all.lua   (exit code 0 only if all suites pass)
local root = (arg[0]:match("^(.*)/tests/[^/]*$") or ".")
local lua = arg[-1] or "lua5.4"
local p = io.popen("ls " .. root .. "/tests/test_*.lua 2>/dev/null")
local files = {}
for l in p:lines() do files[#files + 1] = l end
p:close()
table.sort(files)
local all_ok = true
local total_pass, total_fail = 0, 0
for _, f in ipairs(files) do
  local h = io.popen(lua .. " " .. f .. " 2>&1")
  local out = h:read("*a")
  local ok = h:close()
  local pass, fail = out:match("passed=(%d+) failed=(%d+)")
  total_pass = total_pass + (tonumber(pass) or 0)
  total_fail = total_fail + (tonumber(fail) or 0)
  print(string.format("%-34s %s", f:match("[^/]+$"), (out:match("%[[^\n]*") or out:sub(1, 80))))
  if not ok or (tonumber(fail) or 1) > 0 then
    all_ok = false
    print(out)
  end
end
print(string.format("TOTAL passed=%d failed=%d suites=%d", total_pass, total_fail, #files))
os.exit(all_ok and 0 or 1)
