-- usage: lua5.4 tools/run_noise.lua [--split dev|val|test] [--modes full,no_repair,baseline] [--reps 3] [--seed 5] [--json path]
-- Robustness to surface noise: every single-turn gold case is perturbed by ONE operator at a time (typo in a non-entity word, filler word, lower-casing,
-- dropped punctuation, dropped determiner) and re-interpreted.  A variant is correct when every gold field except the ambiguity flags still holds.
-- The same perturbed texts are used for every mode, so modes are compared on identical inputs.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")
local E = require("asi.nlu.eval")
local R = require("asi.nlu.resources")
local X = require("asi.nlu.perturb")

local opts = { split = "val", modes = "full,no_repair,baseline", reps = "3", seed = "5" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end
local lex = R.core()
local cases = E.parse_cases(E.read_file(root .. "/data/eval/" .. opts.split .. ".cases"), opts.split)

-- one fixed set of perturbed inputs shared by all modes
local rng = U.rng(tonumber(opts.seed))
local inputs = {}
for _, cs in ipairs(cases) do
  if not cs.turns and cs.gold.status == nil and not cs.gold.mm then
    local protect = X.protect_list(cs.gold, cs.text)
    for _, op in ipairs(X.OPS) do
      for _ = 1, tonumber(opts.reps) do
        local t = X.apply_op(cs.text, op, protect, rng)
        if t ~= cs.text then inputs[#inputs + 1] = { op = op, case = { id = cs.id, category = cs.category, text = t, gold = cs.gold } } end
      end
    end
    -- the unperturbed case, as the reference point
    inputs[#inputs + 1] = { op = "none", case = { id = cs.id, category = cs.category, text = cs.text, gold = cs.gold } }
  end
end

local result = { split = opts.split, n_inputs = #inputs, modes = {} }
for mode in opts.modes:gmatch("[^,]+") do
  local runner = E.make_runner(mode, lex)
  local by_op = {}
  for _, inp in ipairs(inputs) do
    local rep = E.run({ inp.case }, runner, lex)
    local r = rep.results[1]
    local primary = true
    for k, f in pairs(r.fields) do if not f.ok and k ~= "amb" and k ~= "alts" then primary = false end end
    local b = by_op[inp.op]
    if not b then b = { n = 0, ok = 0 }; by_op[inp.op] = b end
    b.n = b.n + 1
    if primary then b.ok = b.ok + 1 end
  end
  result.modes[mode] = by_op
end

local ops = { "none" }
for _, o in ipairs(X.OPS) do ops[#ops + 1] = o end
local lines = { string.format("noise robustness on the %s split (%d perturbed inputs, seed %s); primary reading correct, Wilson 95%% CI", opts.split, #inputs, opts.seed) }
local header = string.format("%-12s", "operator")
for mode in opts.modes:gmatch("[^,]+") do header = header .. string.format(" | %-24s", mode) end
lines[#lines + 1] = header
for _, op in ipairs(ops) do
  local row = string.format("%-12s", op)
  for mode in opts.modes:gmatch("[^,]+") do
    local b = result.modes[mode][op] or { n = 0, ok = 0 }
    local lo, hi = U.wilson(b.ok, b.n)
    row = row .. string.format(" | %.3f [%.3f,%.3f] n=%-4d", b.n > 0 and b.ok / b.n or 0, lo, hi, b.n)
  end
  lines[#lines + 1] = row
end
local tot_row = string.format("%-12s", "ALL noisy")
for mode in opts.modes:gmatch("[^,]+") do
  local n, ok = 0, 0
  for op, b in pairs(result.modes[mode]) do if op ~= "none" then n = n + b.n; ok = ok + b.ok end end
  local lo, hi = U.wilson(ok, n)
  tot_row = tot_row .. string.format(" | %.3f [%.3f,%.3f] n=%-4d", n > 0 and ok / n or 0, lo, hi, n)
end
lines[#lines + 1] = tot_row
print(table.concat(lines, "\n"))
if opts.json then local f = io.open(opts.json, "w"); f:write(U.json_encode(result, { pretty = true, nan_null = true })); f:close() end
