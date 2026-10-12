-- usage: lua5.4 tools/manifest.lua [write|check]
-- Writes / verifies data/eval/MANIFEST.json: SHA-256 and case counts of every evaluation split, so a silently edited split is detected.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")
local E = require("asi.nlu.eval")
local mode = arg[1] or "check"
local path = root .. "/data/eval/MANIFEST.json"
local splits = {}
for _, name in ipairs({ "dev", "val", "test" }) do
  local f = root .. "/data/eval/" .. name .. ".cases"
  local text = E.read_file(f)
  if text then
    local cases = E.parse_cases(text, f)
    splits[#splits + 1] = { name = name, file = "data/eval/" .. name .. ".cases", sha256 = U.sha256(text), cases = #cases, bytes = #text }
  end
end
if mode == "write" then
  local old = E.read_file(path)
  local prev = old and U.json_decode(old)
  local doc = { schema = "nlu.eval.manifest/1", note = "splits are frozen by hash; the test split is run once for the official held-out figure (reports/heldout_log.md)", splits = splits,
    frozen = prev and prev.frozen or {} }
  local f = io.open(path, "w"); f:write(U.json_encode(doc, { pretty = true })); f:close()
  print("manifest written")
else
  local doc = U.json_decode(E.read_file(path) or "{}")
  local ok = true
  for _, s in ipairs(splits) do
    local want
    for _, w in ipairs(doc.splits or {}) do if w.name == s.name then want = w end end
    local frozen = doc.frozen and doc.frozen[s.name]
    if frozen and (not want or want.sha256 ~= s.sha256) then ok = false; print("MODIFIED after freeze: " .. s.name) end
    print(string.format("%-5s cases=%-4d sha256=%s%s", s.name, s.cases, s.sha256:sub(1, 16), frozen and "  [frozen]" or ""))
  end
  os.exit(ok and 0 or 1)
end
