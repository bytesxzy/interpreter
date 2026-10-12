-- usage: lua5.4 tools/run_longctx.lua [--lengths 10,100,500] [--seeds 3] [--kinds a,b] [--json path] [--mode full|no_coref|no_memory_select]
-- Long-conversation benchmark for the memory / coreference layer (needed information at the beginning, middle and end of N distractors).
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local U = require("asi.nlu.util")
local I = require("asi.nlu.interp")
local Memory = require("asi.nlu.memory")
local LC = require("asi.nlu.longctx")

local opts = { lengths = "10,100,500", seeds = "3", mode = "full", positions = "begin,middle,end" }
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end
  end
end
local flags = {}
if opts.templates then
  local t, digest = LC.load_templates(opts.templates)
  LC.use(t)
  print("external templates: " .. opts.templates .. "  sha256=" .. digest)
end
if opts.mode ~= "full" then for f in opts.mode:gmatch("[^,]+") do flags[f] = true end end
local interp = I.new({ flags = flags })
local kinds = LC.KINDS
if opts.kinds then kinds = {}; for k in opts.kinds:gmatch("[^,]+") do kinds[#kinds + 1] = k end end
local lengths, positions = {}, {}
for l in opts.lengths:gmatch("%d+") do lengths[#lengths + 1] = tonumber(l) end
for p in opts.positions:gmatch("[^,]+") do positions[#positions + 1] = p end
local seeds = tonumber(opts.seeds)

local rows = {}
local totals = { n = 0, ok = 0, rel_sel = 0, planted = 0, false_mem = 0, selected = 0 }
print(string.format("%-16s %6s %-7s %5s %7s %9s %9s %8s", "kind", "turns", "pos", "n", "success", "work/final", "wall(s)", "false_mem"))
for _, kind in ipairs(kinds) do
  for _, n in ipairs(lengths) do
    for _, pos in ipairs(positions) do
      local ok, cnt, wf, wall, fm, rs, pl, sel = 0, 0, 0, 0, 0, 0, 0, 0
      local pronoun_correct, pronoun_honest, pronoun_wrong = 0, 0, 0
      for s = 1, seeds do
        local rng = U.rng(1000 * s + n + #pos * 7 + #kind)
        local sc = LC.BUILD[kind](rng, n, pos)
        local score = LC.run(interp, Memory, sc)
        cnt = cnt + 1
        if score.ok then ok = ok + 1 end
        wf = wf + score.work_final; wall = wall + score.wall
        fm = fm + score.false_memory; rs = rs + score.relevant_selected; pl = pl + score.planted_total; sel = sel + score.n_selected
        if score.pronoun_status then
          if score.pronoun_correct then pronoun_correct = pronoun_correct + 1
          elseif not score.checks.no_false_resolution then pronoun_wrong = pronoun_wrong + 1
          else pronoun_honest = pronoun_honest + 1 end
        end
      end
      local lo, hi = U.wilson(ok, cnt)
      rows[#rows + 1] = { kind = kind, n = n, pos = pos, cnt = cnt, ok = ok, lo = lo, hi = hi, work_final = wf / cnt, wall = wall / cnt, false_memory = fm / cnt,
        recall = pl > 0 and rs / pl or nil, precision = sel > 0 and rs / sel or nil, pronoun = kind == "pronoun_gap" and { correct = pronoun_correct, honest = pronoun_honest, wrong = pronoun_wrong } or nil }
      totals.n = totals.n + cnt; totals.ok = totals.ok + ok; totals.rel_sel = totals.rel_sel + rs; totals.planted = totals.planted + pl
      totals.false_mem = totals.false_mem + fm; totals.selected = totals.selected + sel
      local r = rows[#rows]
      print(string.format("%-16s %6d %-7s %5d %7.2f %9.0f %9.2f %8.2f%s", kind, n, pos, cnt, ok / cnt, r.work_final, r.wall, r.false_memory,
        r.pronoun and string.format("  pronoun: right=%d honest-unresolved=%d WRONG=%d", pronoun_correct, pronoun_honest, pronoun_wrong) or ""))
    end
  end
end
local lo, hi = U.wilson(totals.ok, totals.n)
print(string.format("\nOVERALL scenarios=%d success=%.3f [%.3f,%.3f]  memory recall=%.3f precision=%.3f false-memory/request=%.2f",
  totals.n, totals.ok / totals.n, lo, hi, totals.rel_sel / math.max(1, totals.planted), totals.rel_sel / math.max(1, totals.selected), totals.false_mem / totals.n))
if opts.json then local f = io.open(opts.json, "w"); f:write(U.json_encode({ rows = rows, totals = totals, mode = opts.mode }, { pretty = true, nan_null = true })); f:close() end
