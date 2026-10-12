-- usage: lua5.4 tools/calibrate.lua [--variants 6] [--seed 11] [--out data/calibration/interp_v1.json] [--report reports/calibration.md]
-- Calibrates the interpreter's raw semantic confidence (posterior of the winning hypothesis) against CORRECTNESS on noisy variants of the gold cases.
--   fit set  : dev + its perturbed variants       eval set : val + its perturbed variants   (and the reverse direction)
-- The frozen test split is never read.  The saved model is fitted on dev+val variants; the accuracy numbers in the report come from the cross-fits.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")
local E = require("asi.nlu.eval")
local R = require("asi.nlu.resources")
local Cal = require("asi.nlu.calibration")
local X = require("asi.nlu.perturb")

local opts = { variants = "6", seed = "11", out = root .. "/data/calibration/interp_v1.json", report = root .. "/reports/calibration.md" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end
local NV, SEED = tonumber(opts.variants), tonumber(opts.seed)

local lex = R.core()
local runner = E.make_runner("full", lex)

local function load(split)
  local cases, errs = E.parse_cases(E.read_file(root .. "/data/eval/" .. split .. ".cases"), split)
  assert(#errs == 0, table.concat(errs, "\n"))
  return cases
end

-- samples for one split: the original case plus NV perturbed variants of every single-turn case
local function collect(split)
  local rng = U.rng(SEED + (split == "val" and 1000 or 0))
  local samples, by_variant = {}, { original = { n = 0, ok = 0 }, perturbed = { n = 0, ok = 0 } }
  for _, cs in ipairs(load(split)) do
    if not cs.turns and cs.gold.status == nil and not cs.gold.mm then
      local protect = X.protect_list(cs.gold)
      local variants = { { text = cs.text, kind = "original" } }
      for v = 1, NV do
        local t, ops = X.perturb(cs.text, protect, rng, rng:int(1, 3))
        if t ~= cs.text then variants[#variants + 1] = { text = t, kind = "perturbed", ops = ops } end
      end
      for _, v in ipairs(variants) do
        local one = { id = cs.id, category = cs.category, text = v.text, gold = cs.gold }
        local rep = E.run({ one }, runner, lex)
        local r = rep.results[1]
        local m = r.interp
        local x = (m and m.confidence and m.confidence.semantic_raw) or 0
        local y = r.ok and 1 or 0
        samples[#samples + 1] = { x = x, y = y, id = cs.id, kind = v.kind }
        local b = by_variant[v.kind]
        b.n = b.n + 1; b.ok = b.ok + y
      end
    end
  end
  return samples, by_variant
end

local dev, dev_v = collect("dev")
local val, val_v = collect("val")

local function fmt_bins(ev)
  local lines = { "| bin | n | mean confidence | accuracy | range |", "|---|---|---|---|---|" }
  for i, b in ipairs(ev.bins) do
    lines[#lines + 1] = string.format("| %d | %d | %.3f | %.3f | %.3f-%.3f |", i, b.n, b.mean_confidence, b.accuracy, b.lo, b.hi)
  end
  return table.concat(lines, "\n")
end

local function line(name, ev, auc)
  return string.format("| %s | %d | %.3f | %.4f | %.4f | %.4f | %s |", name, ev.n, ev.accuracy, ev.ece, ev.brier, ev.logloss, auc and string.format("%.3f", auc) or "n/a")
end

local out = { "# Confidence calibration (interpretation correctness)", "",
  "Target: P(all gold fields of a case are satisfied) given the raw `semantic_raw` score (posterior of the winning hypothesis).",
  string.format("Data: gold cases of the dev and val splits (single-turn, %d perturbed variants per case plus the original; deterministic seed %d).", NV, SEED),
  "Perturbations (see `asi.nlu.perturb`): typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.",
  "The frozen test split is NOT used. Dev gold was used to tune the interpreter, so dev/original accuracy is optimistic by construction; the perturbed",
  "variants are what give the calibration data its errors. The calibration is valid only for this distribution of inputs.", "" }

local function summarize(label, fit, eval_set)
  local iso = Cal.fit_isotonic(fit)
  local platt = Cal.fit_platt(fit)
  local raw = Cal.evaluate(eval_set, nil)
  local ev_iso, ev_pl = Cal.evaluate(eval_set, iso), Cal.evaluate(eval_set, platt)
  local auc = Cal.auroc(eval_set)
  out[#out + 1] = "## " .. label
  out[#out + 1] = ""
  out[#out + 1] = "| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |"
  out[#out + 1] = "|---|---|---|---|---|---|---|"
  out[#out + 1] = line("raw (uncalibrated)", raw, auc)
  out[#out + 1] = line("temperature/Platt", ev_pl, auc)
  out[#out + 1] = line("isotonic", ev_iso, auc)
  out[#out + 1] = ""
  out[#out + 1] = "Reliability of the RAW score on the evaluation set:"
  out[#out + 1] = ""
  out[#out + 1] = fmt_bins(raw)
  out[#out + 1] = ""
  out[#out + 1] = "Reliability after isotonic calibration (evaluation set, not used for fitting):"
  out[#out + 1] = ""
  out[#out + 1] = fmt_bins(ev_iso)
  out[#out + 1] = ""
  return iso, platt, raw, ev_iso, ev_pl
end

local _, _, raw_a, iso_a = summarize("Fit on dev variants, evaluate on val variants", dev, val)
local _, _, raw_b, iso_b = summarize("Fit on val variants, evaluate on dev variants", val, dev)

-- final model: all data; chosen method = the one with the lower cross-fit ECE
local all = {}
for _, s in ipairs(dev) do all[#all + 1] = s end
for _, s in ipairs(val) do all[#all + 1] = s end
local model = Cal.fit_isotonic(all)
model.fit = { splits = { "dev", "val" }, variants_per_case = NV, seed = SEED, n = #all, digest = Cal.digest(all), target = "all gold fields satisfied",
  predictor = "interpretation.confidence.semantic_raw", perturbations = X.OPS,
  cross_fit_ece_raw = { U.round(raw_a.ece, 4), U.round(raw_b.ece, 4) }, cross_fit_ece_calibrated = { U.round(iso_a.ece, 4), U.round(iso_b.ece, 4) },
  valid_for = "noisy variants of the development/validation case distribution; NOT validated on other distributions" }
local f = assert(io.open(opts.out, "w"))
f:write(U.json_encode(model, { pretty = true, nan_null = true }))
f:close()

out[#out + 1] = "## Original vs perturbed accuracy"
out[#out + 1] = ""
out[#out + 1] = "| split | original | perturbed |"
out[#out + 1] = "|---|---|---|"
for _, p in ipairs({ { "dev", dev_v }, { "val", val_v } }) do
  local o, q = p[2].original, p[2].perturbed
  out[#out + 1] = string.format("| %s | %d/%d = %.3f | %d/%d = %.3f |", p[1], o.ok, o.n, o.n > 0 and o.ok / o.n or 0, q.ok, q.n, q.n > 0 and q.ok / q.n or 0)
end
out[#out + 1] = ""
out[#out + 1] = string.format("Saved model: `%s` (isotonic, %d samples, %d steps, digest %s).", opts.out:gsub("^" .. root:gsub("%p", "%%%0") .. "/", ""), model.n, #model.steps, model.fit.digest:sub(1, 16))
local rf = assert(io.open(opts.report, "w"))
rf:write(table.concat(out, "\n") .. "\n")
rf:close()
print(table.concat(out, "\n"))
