-- usage: lua5.4 tools/run_retrieval_bench.lua [--vocab dev|heldout] [--seeds 1,2,3] [--facts 40] [--modes system,baseline,v_no_time,...] [--json path] [--failures N]
-- Retrieval / evidence benchmark: question -> verified evidence, with the traps a keyword retriever falls into (see asi.nlu.rbench).
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local U = require("asi.nlu.util")
local B = require("asi.nlu.rbench")
local opts = { vocab = "dev", seeds = "1,2,3", facts = "40", modes = "baseline,system", failures = "0" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end
if opts.templates then print("templates sha256: " .. B.load_templates(opts.vocab, opts.templates)) end
local seeds = {}
for s in opts.seeds:gmatch("%d+") do seeds[#seeds + 1] = tonumber(s) end
local out = {}
for mode in opts.modes:gmatch("[^,]+") do
  local agg
  for _, seed in ipairs(seeds) do
    local bench = B.generate({ vocab = opts.vocab, seed = seed, n_facts = tonumber(opts.facts) })
    local flags = {}
    local m
    if mode == "baseline" or mode == "baseline1" then m = B.evaluate(bench, { mode = mode })
    else
      if mode ~= "system" then for f in mode:gmatch("[^+]+") do flags[f] = true end end
      m = B.evaluate(bench, { flags = flags, mode = "system" })
    end
    if not agg then agg = m else
      for k, v in pairs(m) do if type(v) == "number" then agg[k] = (agg[k] or 0) + v end end
      for _, f in ipairs(m.failures) do if #agg.failures < 40 then agg.failures[#agg.failures + 1] = f end end
    end
  end
  agg.mode = mode
  out[#out + 1] = agg
  local lo, hi = U.wilson(agg.errors, agg.error_n)
  local function r(a, b) return b > 0 and a / b or 0 end
  print(string.format("%-26s n=%-4d  serious-error=%.3f [%.3f,%.3f]  %s", mode, agg.error_n, r(agg.errors, agg.error_n), lo, hi,
    (mode == "baseline" or mode == "baseline1")
      and string.format("top1-wrong-topic=%.3f  contaminated@3=%.3f  gold-in-top3=%.3f  (never abstains)", r(agg.top1_wrong, agg.top1_n), r(agg.contam3, agg.contam3_n), r(agg.gold_in_topk, agg.top1_n))
      or string.format("correct=%.3f wrong-answer=%.3f contaminated=%.3f abstained=%.3f | unsupported ok=%.3f insufficient ok=%.3f | injection leak=%d/%d conflict wrong=%d/%d retained=%d | answerable-with-unparsable-template=%d (abstained %d)",
        r(agg.correct, agg.answerable), r(agg.wrong_answer, agg.answerable), r(agg.contaminated, agg.answerable), r(agg.abstained, agg.answerable),
        r(agg.unsupported_ok, agg.unsupported_n), r(agg.insufficient_ok, agg.insufficient_n), agg.injection_leak, agg.injection_n, agg.conflict_wrong, agg.conflict_n, agg.conflict_retained, agg.unparsed, agg.unparsed_abstained)))
  if tonumber(opts.failures) > 0 and agg.failures then
    for i, f in ipairs(agg.failures) do
      if i > tonumber(opts.failures) then break end
      print(string.format("    [%s] %q status=%s answer=%s gold=%s selected=%s", f.kind, f.question, tostring(f.status), tostring(f.answer), tostring(f.gold), table.concat(f.selected or {}, ",")))
    end
  end
end
if opts.json then local f = io.open(opts.json, "w"); f:write(U.json_encode(out, { pretty = true, nan_null = true })); f:close() end
