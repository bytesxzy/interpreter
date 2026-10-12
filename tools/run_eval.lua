-- usage: lua5.4 tools/run_eval.lua [--split dev|val|test] [--mode full|baseline|lexical_only|no_types|no_domain|no_hypotheses|...]
--                                [--failures N] [--json path] [--file path]
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")
local E = require("asi.nlu.eval")
local R = require("asi.nlu.resources")

local opts = { split = "dev", mode = "full", failures = 25 }
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end
  end
end
opts.failures = tonumber(opts.failures) or 25

local path = opts.file or (root .. "/data/eval/" .. opts.split .. ".cases")
local text = E.read_file(path)
if not text then io.stderr:write("cannot read " .. path .. "\n"); os.exit(2) end
local cases, errs = E.parse_cases(text, path)
if #errs > 0 then for _, e in ipairs(errs) do io.stderr:write(e .. "\n") end; os.exit(2) end

local lex = R.core()
local runner = E.make_runner(opts.mode, lex)

local rep = E.run(cases, runner, lex)
print(E.summary(rep, opts.mode .. "/" .. opts.split))
if opts.failures > 0 then
  local f = E.failures(rep, opts.failures)
  if f ~= "" then print("\nFAILURES:\n" .. f) end
  if rep.metamorphic and #rep.metamorphic.failures > 0 then
    print("\nMETAMORPHIC FAILURES:")
    for i, mf in ipairs(rep.metamorphic.failures) do
      if i > opts.failures then break end
      print(string.format("  %s group=%s %s vs %s\n     %s\n     %s", mf.kind, mf.group, mf.a, tostring(mf.b or mf.other), mf.sig_a or mf.sig or "", mf.sig_b or ""))
    end
  end
end
print(string.format("work=%d wall=%.2fs", rep.work, rep.wall))
if opts.json then
  local slim = { n = rep.n, any_fail = rep.any_fail, serious_fail = rep.serious_fail, by_cat = rep.by_cat, field_fail = rep.field_fail, metamorphic = rep.metamorphic }
  local f = io.open(opts.json, "w"); f:write(U.json_encode(slim, { pretty = true, nan_null = true })); f:close()
end
