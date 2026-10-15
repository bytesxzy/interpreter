-- usage: lua5.4 tools/calibration_shift.lua FILE.cases [FILE.cases ...]
-- Evaluates the SAVED calibration model (data/calibration/interp_v1.json) on gold files it was not fitted on: how well does the stated confidence
-- predict that the primary reading is correct (every gold field except the ambiguity flags)?  Single-turn cases only.  Reports ECE, Brier, AUROC,
-- accuracy and the reliability table for the raw score and for the calibrated score, so a distribution shift shows up as a number, not as a claim.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local E = require("asi.nlu.eval")
local R = require("asi.nlu.resources")
local Cal = require("asi.nlu.calibration")

local model = assert(Cal.load_file(root .. "/data/calibration/interp_v1.json"))
local lex = R.core()
local runner = E.make_runner("full", lex)
for _, path in ipairs(arg) do
  local cases, errs = E.parse_cases(assert(E.read_file(path)), path)
  assert(#errs == 0, table.concat(errs, "\n"))
  local raw, cal = {}, {}
  for _, cs in ipairs(cases) do
    if not cs.turns and cs.gold.status == nil and not cs.gold.mm then
      local rep = E.run({ cs }, runner, lex)
      local r = rep.results[1]
      local m = r.interp
      local ok = true
      for k, f in pairs(r.fields) do if not f.ok and k ~= "amb" and k ~= "alts" then ok = false end end
      local f = m and Cal.features(m) or { no_interpretation = 1 }
      raw[#raw + 1] = { x = f.semantic_raw or 0, y = ok and 1 or 0 }
      cal[#cal + 1] = { x = Cal.apply_features(model, f), y = ok and 1 or 0 }
    end
  end
  local ev_raw, ev_cal = Cal.evaluate(raw, nil), Cal.evaluate(cal, nil)
  print(string.format("== %s  (single-turn cases: n=%d, primary-reading accuracy %.3f)", path, #raw, ev_raw.accuracy))
  print(string.format("   raw semantic score      : ECE %.3f  Brier %.3f  AUROC %.3f", ev_raw.ece, ev_raw.brier, Cal.auroc(raw)))
  print(string.format("   calibrated (saved model): ECE %.3f  Brier %.3f  AUROC %.3f", ev_cal.ece, ev_cal.brier, Cal.auroc(cal)))
  print("   reliability of the calibrated confidence:  bin  n  mean-confidence  accuracy")
  for i, b in ipairs(ev_cal.bins) do print(string.format("      %2d %4d   %.3f   %.3f", i, b.n, b.mean_confidence, b.accuracy)) end
end
