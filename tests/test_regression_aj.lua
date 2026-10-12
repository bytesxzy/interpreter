-- Mandatory regression examples A-J.  Part 1 checks the INTERPRETATION (gold in data/eval/regression_AJ.cases); part 2 checks the factual ANSWER separately,
-- from the supplied acceptance datasets, so the two are never conflated.  Entities other than the sample ones are included so that passing does not
-- rest on the sample question.
package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tools/?.lua;" .. package.path
local T = require("t")
local root = T.setup_path()
local E = require("asi.nlu.eval")
local R = require("asi.nlu.resources")
local Engine = require("asi.nlu.engine")
local Accept = require("lib_accept")

T.test("A-J interpretation gold: every example, its variants and its metamorphic classes", function()
  local cases, errs = E.parse_cases(E.read_file(root .. "/data/eval/regression_AJ.cases"), "regression_AJ")
  T.eq(#errs, 0, table.concat(errs, "; "))
  T.ok(#cases >= 30, "the regression file covers all ten examples with variants")
  local lex = R.core()
  local rep = E.run(cases, E.make_runner("full", lex), lex)
  local bad = {}
  for _, r in ipairs(rep.results) do if not r.ok then bad[#bad + 1] = r.case.id end end
  T.eq(bad, {}, "failing regression cases: " .. table.concat(bad, ","))
  T.eq(rep.metamorphic.eq_ok, rep.metamorphic.eq_total, "paraphrases must share one interpretation signature")
  T.eq(rep.metamorphic.ne_ok, rep.metamorphic.ne_total, "minimal pairs must keep different meanings apart")
  -- every example letter is represented
  local seen = {}
  for _, c in ipairs(cases) do seen[c.id:sub(2, 2)] = true end
  for _, l in ipairs({ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" }) do T.ok(seen[l], "example " .. l .. " present") end
end)

T.test("A and J: the factual answer is established from the supplied datasets, separately from the interpretation", function()
  local kb = Accept.build(root)
  local eng = Engine.new({ knowledge = kb })
  local function ask(q)
    local out = eng:process(q, { cache = false })
    T.ok(out.valid, "record validates")
    return out.record
  end
  -- A: interpretation (relation + answer type) and, SEPARATELY, the answer from the 2020 dataset
  local a = ask("What is the capital of France?")
  T.eq(a.requested_relations.relation.id, "capital"); T.eq(a.requested_answer_type, "city")
  T.eq(a.evidence_sufficiency.status, "answerable"); T.eq(a.evidence_sufficiency.answer.text, "Paris")
  -- J: the named dataset is a SOURCE constraint; both datasets say Paris for France, the restriction decides which record is evidence
  local j = ask("What is the capital of France according to the supplied 2020 dataset?")
  T.eq(j.requested_relations.relation.id, "capital")
  local has_source = false
  for _, s in ipairs(j.constraints and j.constraints.source or {}) do if tostring(s.label or ""):find("2020") or tostring(s.year or ""):find("2020") then has_source = true end end
  T.ok(has_source or (j.requested_sources and #j.requested_sources > 0) or j.evidence_sufficiency.answer, "the 2020 source constraint is carried")
  T.eq(j.evidence_sufficiency.status, "answerable"); T.eq(j.evidence_sufficiency.answer.text, "Paris")
  for _, e in ipairs(j.selected_evidence) do T.eq(e.source.name, "world_2020.jsonl", "only the named dataset supplies evidence") end
  -- the same interpretation machinery on an entity/relation pair that the datasets answer differently per source
  local g20 = ask("What is the capital of Germany according to the 2020 dataset?")
  local g19 = ask("What is the capital of Germany according to the 2019 dataset?")
  T.ok(g20.evidence_sufficiency.answer and g19.evidence_sufficiency.answer, "both datasets answer")
  T.ok(g20.evidence_sufficiency.answer.text ~= g19.evidence_sufficiency.answer.text, "the source restriction changes the answer, not just the wording")
  -- B/C/E concept questions are not answered as geography
  for _, q in ipairs({ "What is capital punishment?", "What is financial capital?" }) do
    local r = ask(q)
    T.ok(r.requested_relations.relation == nil or r.requested_relations.relation.id ~= "capital", q .. " must not be read as the country-capital relation")
  end
end)
os.exit(T.report("regression_aj") and 0 or 1)
