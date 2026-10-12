package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tools/?.lua;" .. package.path
local T = require("t")
local root = T.setup_path()
local U = require("asi.nlu.util")
local Engine = require("asi.nlu.engine")
local Record = require("asi.nlu.record")
local Package = require("asi.nlu.package")
local Accept = require("lib_accept")

local kb = Accept.build(root)
local eng = Engine.new({ knowledge = kb })

local function ask(q, call)
  local out = eng:process(q, call or {})
  T.ok(out.valid, "record must validate: " .. table.concat(out.validation_errors or {}, "; "))
  T.ok(Record.verify_integrity(out.record), "record integrity hash")
  local ok, errs = Package.check(out.package)
  T.ok(ok, table.concat(errs, ";"))
  return out
end

local function selected_records(out)
  local s = {}
  for _, e in ipairs(out.record.selected_evidence) do s[e.record] = true end
  return s
end

T.test("ACCEPTANCE 1-13: 'What is the capital of France?' end to end", function()
  local q = "What is the capital of France?"
  local out = ask(q)
  local rec = out.record
  -- 1. original preserved
  T.eq(rec.original_input, q)
  -- 2. words and phrase boundaries
  local forms = {}
  for _, t in ipairs(rec.lexical_analysis.tokens) do forms[#forms + 1] = t.form end
  T.eq(forms, { "what", "is", "the", "capital", "of", "france" })
  T.eq(rec.lexical_analysis.sentences[1].terminal, "?")
  T.eq(rec.lexical_analysis.tokens[6].s, 24); T.eq(rec.lexical_analysis.tokens[6].e, 29)
  -- 3. France as the country entity
  local france
  for _, e in ipairs(rec.resolved_entities) do if e.mention == "France" then france = e end end
  T.ok(france and france.key == "country.france" and france.type == "country")
  -- 4. national-capital relationship, direction
  T.eq(rec.requested_relations.relation.id, "capital")
  T.eq(rec.requested_relations.query.known_role, "from"); T.eq(rec.requested_relations.query.ask, "to")
  -- 5. answer type
  T.eq(rec.requested_answer_type, "city")
  -- 6. unrelated senses of "capital" are not what was interpreted
  for _, c in ipairs(rec.entity_candidates) do
    for _, s in ipairs(c.senses or {}) do T.ok(not s.id:find("financial") and not s.id:find("punishment"), "no financial/legal sense chosen") end
  end
  -- 7-9. the supporting record is retrieved and VERIFIED; shared-keyword records are not evidence
  local sel = selected_records(out)
  T.ok(sel["w2020:fr1"], "the verified record is selected")
  for _, bad in ipairs({ "w2020:fr3", "w2020:fr4", "w2020:fr5", "w2020:fr6", "w2020:fr7", "w2020:fr8", "w2020:fr10", "w2020:fr12", "w2020:z1" }) do
    T.ok(not sel[bad], bad .. " must not be selected as evidence")
  end
  local ev = rec.selected_evidence[1]
  T.eq(ev.checks.entity, "exact"); T.eq(ev.checks.relation, true); T.eq(ev.checks.answer_type, "ok")
  -- 10. structured record
  T.eq(rec.schema_version, "nlu.record/1")
  -- 11. package carries the right evidence and only that as verified evidence
  local pkg = out.package
  T.ok(pkg.prompt:find("Paris is the capital of France.", 1, true))
  local verified = pkg.prompt:match("=== VERIFIED EVIDENCE.-\n\n=== ") or ""
  T.ok(verified ~= "", "verified block present")
  T.ok(not verified:find("punishment") and not verified:find("Lyon"), "no contamination in the verified block")
  -- 12. provenance and sufficiency
  T.eq(rec.evidence_sufficiency.status, "answerable")
  T.eq(rec.evidence_sufficiency.answer.text, "Paris")
  T.ok(ev.source and ev.source.name == "world_2020.jsonl" and ev.record == "w2020:fr1")
  T.ok(ev.reliability >= 0.9)
  -- 13. nothing invented: the only factual answer is Paris, and every quoted line comes from a record
  T.eq(#rec.evidence_sufficiency.answers, 1)
  for _, e in ipairs(rec.selected_evidence) do T.ok(kb:record(e.record).text:find(e.quote:gsub("%.%.%.$", ""), 1, true), "quote must be verbatim from the record") end
end)

T.test("duplicates do not corroborate; a low-reliability contradicting blog is kept SEPARATELY as conflicting evidence", function()
  local out = ask("What is the capital of France?")
  local rec = out.record
  local recs = {}
  for _, e in ipairs(rec.selected_evidence) do recs[e.record] = true end
  T.ok(not recs["w2020:fr11"], "exact duplicate is not independent support")
  local conflicting = {}
  for _, e in ipairs(rec.conflicting_evidence) do conflicting[e.record] = true end
  T.ok(conflicting["w2020:fr9"], "the Lyon blog post is retained as conflicting evidence, not mixed into the verified set")
  T.ok(#rec.evidence_sufficiency.conflicts >= 1 and rec.evidence_sufficiency.conflicts[1].resolution:find("outweighs"), "the resolution rule is explicit")
end)

T.test("paraphrases and punctuation variants produce the same verified answer", function()
  local variants = { "What's France's capital?", "Which city is France's capital?", "Could you tell me the capital city of France?", "france capital?", "Capital of France", "WHAT IS THE CAPITAL OF FRANCE???", "what is the capital of  France ?", "Name the capital of France." }
  for _, q in ipairs(variants) do
    local out = ask(q)
    T.eq(out.record.evidence_sufficiency.status, "answerable", q)
    T.eq(out.record.evidence_sufficiency.answer.text, "Paris", q)
    T.eq(out.record.requested_relations.relation.id, "capital", q)
  end
end)

T.test("minimal pairs keep different meanings apart", function()
  local fin = ask("What is the financial capital of France?")
  T.ok(fin.record.requested_relations.relation.id ~= "capital", "financial capital is a different relation: " .. tostring(fin.record.requested_relations.relation.id))
  T.ok(fin.record.evidence_sufficiency.status ~= "answerable" or fin.record.evidence_sufficiency.answer.text ~= "Paris", "Paris must not answer the financial-capital question")
  local pun = ask("What is capital punishment?")
  T.eq(pun.record.semantic_intent.intent, "definition")
  T.ok(pun.record.requested_relations.relation == nil)
  T.ok(pun.record.evidence_sufficiency.status ~= "answerable" or not tostring(pun.record.evidence_sufficiency.answer.text):find("Paris"))
  local fp = ask("Capital punishment in France")
  T.ok(fp.record.requested_relations.relation == nil, "capital punishment in France is not the capital relation")
end)

T.test("historical constraint: the present answer does not satisfy 'former', and the past answer is not presented as current", function()
  local former = ask("What is the former capital of France?")
  T.ok(former.record.evidence_sufficiency.status ~= "answerable", "no historical capital of France exists in the data")
  for _, e in ipairs(former.record.selected_evidence) do T.ok(e.to.text ~= "Paris", "Paris is the current capital, not a former one") end
  local gaul = ask("What was the capital of Gaul?")
  T.eq(gaul.record.evidence_sufficiency.status, "answerable")
  T.eq(gaul.record.evidence_sufficiency.answer.text, "Lyon")
  local gaul_now = ask("What is the capital of Gaul?")
  T.ok(gaul_now.record.evidence_sufficiency.status == "potentially_answerable", "a past-tense-only fact is not silently current: " .. gaul_now.record.evidence_sufficiency.status)
end)

T.test("negative evidence: a record denying Marseille never becomes an answer, and the source restriction is honoured", function()
  local out = ask("What is the capital of France?")
  T.ok(out.record.evidence_sufficiency.answer.text ~= "Marseille")
  local y19 = ask("What is the capital of Germany according to the 2019 dataset?")
  T.eq(y19.record.evidence_sufficiency.answer.text, "Bonn")
  local y20 = ask("What is the capital of Germany according to the supplied 2020 dataset?")
  T.eq(y20.record.evidence_sufficiency.answer.text, "Berlin")
  local none = ask("What is the capital of Germany?")
  T.eq(none.record.evidence_sufficiency.answer.text, "Berlin")
  T.ok(#none.record.conflicting_evidence >= 1, "the 2019 value stays visible as conflicting evidence")
end)

T.test("prompt injection inside a dataset record is data: not obeyed, not mined, not shown as text", function()
  local out = ask("What is the capital of France?")
  T.eq(out.record.evidence_sufficiency.answer.text, "Paris")
  T.ok(not out.package.prompt:find("pirate", 1, true) and not out.package.prompt:find("Ignore all previous", 1, true), "instruction-like text is withheld from the package")
  T.ok(kb.reader_directed["w2020:fr10"], "the record is flagged")
  -- and a question that retrieves the poisoned record cannot be steered by it
  local out2 = ask("What is the capital of Germany?")
  T.eq(out2.record.evidence_sufficiency.answer.text, "Berlin")
end)

T.test("unsupported and insufficient are distinguished from answerable, and nothing nearby is substituted", function()
  local atl = ask("What is the capital of Atlantis?")
  T.eq(atl.record.evidence_sufficiency.status, "unsupported")
  T.eq(#atl.record.selected_evidence, 0)
  T.ok(atl.package.prompt:find("MUST NOT INFER", 1, true))
  local pun = ask("What is the founder of France?")
  T.ok(pun.record.evidence_sufficiency.status ~= "answerable", pun.record.evidence_sufficiency.status)
  local sweden = ask("What is the capital of Sweden?")
  T.eq(sweden.record.evidence_sufficiency.status, "unsupported")
end)

T.test("GENERALISATION: entities and relations that appear nowhere in the implementation", function()
  local cases = {
    { "What is the capital of Zorbland?", "Quillbert" },
    { "Who founded Quillon Labs?", "Mira Voss" },
    { "Who is the CEO of Quillon Labs?", "Mira Voss" },
    { "What is the currency of Zorbland?", "glim" },
    { "What is the population of Zorbland?", "4 million" },
    { "What is the mascot of Zorbland?", "quokka" },          -- relation induced from a column name
    { "Where is Brindle Analytics headquartered?", "Quillbert" },  -- from a structured triple
    { "Who acquired Acme Robotics?", "Beta Systems" },
    { "What is the atomic number of Mercury?", "80" },
  }
  for _, c in ipairs(cases) do
    local out = ask(c[1])
    T.eq(out.record.evidence_sufficiency.status, "answerable", c[1] .. " -> " .. out.record.evidence_sufficiency.status)
    T.eq(out.record.evidence_sufficiency.answer.text, c[2], c[1])
  end
end)

T.test("ambiguous terminology stays ambiguous until context or evidence decides", function()
  local out = ask("Tell me about Mercury.")
  T.eq(out.record.evidence_sufficiency.status, "ambiguous")
  T.eq(out.record.evidence_sufficiency.answer, nil, "an ambiguous term has no single answer")
  local el = ask("What is the atomic number of Mercury?")
  T.eq(el.record.evidence_sufficiency.status, "answerable")
  local pl = ask("What is the orbital period of Mercury?")
  T.eq(pl.record.evidence_sufficiency.status, "answerable")
  T.eq(pl.record.evidence_sufficiency.answer.text, "88 days")
end)

T.test("definition questions use definitional evidence, not the nearest topical record", function()
  local fc = ask("What is financial capital?")
  T.eq(fc.record.evidence_sufficiency.status, "answerable")
  T.ok(fc.record.evidence_sufficiency.answer.text:find("money and assets"))
  local pc = ask("What is capital punishment?")
  T.ok(pc.record.evidence_sufficiency.status ~= "answerable", "the data mentions capital punishment but never defines it")
end)

T.test("a changed dataset invalidates cached results (cache key includes the dataset digest)", function()
  local e = Engine.new({ knowledge = kb })
  local o1, hit1 = e:process("What is the capital of Spain?", {})
  local o2, hit2 = e:process("What is the capital of Spain?", {})
  T.ok(not hit1 and hit2, "second identical stateless call is a cache hit")
  kb:ingest('{"id":"es2","title":"Spain","body":"Madrid has been the capital of Spain since 1561.","reliability":0.9}\n', { name = "more.jsonl", dataset = "w2020" })
  local o3, hit3 = e:process("What is the capital of Spain?", {})
  T.ok(not hit3, "dataset changed: the cached result must not be reused")
  T.eq(#o3.record.selected_evidence, 2)
end)

T.test("work budget exhaustion is explicit: limited status plus a requirement, never a confident guess", function()
  local out = eng:process("What is the capital of France?", { budget = 40, cache = false })
  T.eq(out.record.execution_cost.status, "limited")
  local found = false
  for _, u in ipairs(out.record.unresolved_requirements) do if u.kind == "resource_limit" then found = true end end
  T.ok(found)
  T.ok(out.valid)
end)

os.exit(T.report("acceptance") and 0 or 1)
