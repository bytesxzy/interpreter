package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
local root = T.setup_path()
local U = require("asi.nlu.util")
local I = require("asi.nlu.interp")
local Memory = require("asi.nlu.memory")

local interp = I.new({})
local function session(conv)
  local mem = Memory.new({ ns = { user = "u1", project = "p", conversation = conv or "c" } })
  return mem, function(text, speaker)
    local r = interp:interpret(text, { memory = mem, speaker = speaker or "user", light = (speaker == "assistant") })
    return r.main, r
  end
end

local function find_ref(m, mention)
  for _, r in ipairs(m.context and m.context.references or {}) do if r.mention:lower() == mention:lower() then return r end end
end

T.test("pronoun resolves to the focus entity of the previous turn", function()
  local _, say = session()
  say("I'm researching Company A.")
  local m = say("Who founded it?")
  T.eq(m.relation.id, "founder")
  local r = find_ref(m, "it")
  T.eq(r.status, "resolved"); T.eq(r.antecedent.text, "Company A")
  T.eq(m.roles.from.antecedent.text, "Company A")
  T.eq(m.context.dependency.primary, "recent_message")
end)

T.test("a pronoun with no available antecedent stays unresolved and is reported, never guessed", function()
  local _, say = session()
  local m = say("Who founded it?")
  local r = find_ref(m, "it")
  T.eq(r.status, "unresolved")
  T.ok(r.requirement and r.requirement:find("no antecedent"), "requirement text")
  T.eq(m.context.dependency.primary, "ambiguous_missing_context")
  T.eq(#m.context.unresolved, 1)
end)

T.test("animacy and role type constrain the antecedent (it != person, he != organisation)", function()
  local _, say = session()
  say("Alice Smith founded Acme Robotics.")
  say("Tell me about Acme Robotics.")
  local m = say("Who is the CEO of it?")
  local r = find_ref(m, "it")
  T.eq(r.status, "resolved"); T.eq(r.antecedent.text, "Acme Robotics")
end)

T.test("two equally salient organisations leave 'it' ambiguous with both candidates listed", function()
  local _, say = session()
  say("Compare Company A and Company B.")
  local m = say("Who founded it?")
  local r = find_ref(m, "it")
  T.ok(r.status == "ambiguous" or r.status == "unresolved", "must not silently pick one: " .. tostring(r.status))
  if r.status == "ambiguous" then T.ok(#r.candidates >= 2) end
end)

T.test("a co-argument of the same predicate is excluded from pronoun binding", function()
  local _, say = session()
  say("Tell me about Acme Robotics.")
  local m = say("Which company acquired it?")
  local r = find_ref(m, "it")
  T.ok(r ~= nil)
  -- 'Acme Robotics' is the only candidate and 'which company' is the asked role: binding must still be explicit
  T.ok(r.status == "resolved" or r.status == "ambiguous")
end)

T.test("superseded instruction is not active; the correction is (message 1 vs 120 vs 300)", function()
  local mem, say = session()
  say("Use the 2023 dataset.")
  for i = 1, 120 do say("Filler turn number " .. i .. " about weather in Springfield.") end
  say("Actually, use the 2025 dataset from now on.")
  for i = 1, 150 do say("More filler " .. i .. " discussing lunch menus.") end
  local m = say("Analyze the figures.")
  local act = {}
  for _, c in ipairs(m.context.active_constraints) do if c.slot then act[c.slot] = c.value end end
  T.eq(tostring(act.dataset), "2025")
  local sel_text = {}
  for _, it in ipairs(m.context.memory.selected) do sel_text[#sel_text + 1] = it.text end
  local joined = table.concat(sel_text, "\n")
  T.ok(joined:find("2025 dataset", 1, true), "correction retrieved")
  T.ok(not joined:find("2023 dataset", 1, true), "superseded instruction must not be selected")
end)

T.test("revocation removes the standing instruction without replacing it", function()
  local mem, say = session()
  say("Use the 2023 dataset from now on.")
  say("Never mind the dataset instruction.")
  local m = say("Who founded Example Labs?")
  for _, c in ipairs(m.context.active_constraints or {}) do T.ok(c.slot ~= "dataset", "dataset slot must be revoked") end
end)

T.test("exclusions persist as standing prohibitions and are selected for later requests", function()
  local mem, say = session()
  say("Do not include universities.")
  for i = 1, 20 do say("Unrelated chatter " .. i .. " about hiking trails.") end
  local m = say("Find companies in Germany.")
  local found = false
  for _, c in ipairs(m.context.active_constraints) do if c.kind == "prohibition" then found = true end end
  T.ok(found, "prohibition must remain active")
end)

T.test("irrelevant earlier discussion is not injected (context pollution)", function()
  local mem, say = session()
  say("We are planning venture capital financing and bank loans for the startup.")
  say("Working capital and equity financing matter for the budget.")
  local m = say("What is the capital of France?")
  T.eq(m.relation.id, "capital")
  T.eq(m.roles.from.resolved_id, "country.france")
  for _, it in ipairs(m.context.memory.selected) do
    T.ok(not it.text:lower():find("financing"), "finance chatter must not be selected for a geography question: " .. it.text)
  end
end)

T.test("namespaces: another conversation's memory is invisible; owners only", function()
  local store = Memory.store()
  local a = assert(store:open({ user = "alice", project = "p", conversation = "c1" }, { user = "alice" }))
  local b = assert(store:open({ user = "bob", project = "p", conversation = "c1" }, { user = "bob" }))
  a:begin_turn("user"); a:note_utterance("secret plan alpha", "user")
  T.eq(#b:active_items(), 0)
  local denied, err = store:open({ user = "alice", project = "p", conversation = "c1" }, { user = "bob" })
  T.eq(denied, nil); T.ok(err:find("access denied"))
  T.eq(select(1, store:open({ user = "alice", project = "p", conversation = "c1" }, { user = "alice" })), a)
end)

T.test("persistence round trip, tamper detection, cross-user load refusal", function()
  local mem, say = session("persist")
  say("Use the 2023 dataset.")
  say("Actually, use the 2025 dataset from now on.")
  local blob = mem:serialize()
  local back = assert(Memory.deserialize(blob, { ns = { user = "u1" } }))
  T.eq(back.turn, mem.turn)
  T.eq(#back:active_items("correction"), #mem:active_items("correction"))
  local tampered = blob:gsub("2025", "2026", 1)
  local bad, err = Memory.deserialize(tampered, { ns = { user = "u1" } })
  T.eq(bad, nil); T.ok(err:find("checksum"), err)
  local other, err2 = Memory.deserialize(blob, { ns = { user = "mallory" } })
  T.eq(other, nil); T.ok(err2:find("namespace"), err2)
end)

T.test("summaries keep exclusions, corrections and hedges; speculation never becomes fact", function()
  local mem, say = session("sum")
  say("Do not include universities.")
  say("Actually, use the 2025 dataset from now on.")
  say("Maybe Acme Robotics acquired Beta Systems.")
  say("Acme Robotics acquired Gamma Corp.")
  local d = mem:summarize(1, mem.turn)
  T.ok(#d.exclusions >= 1, "exclusion kept verbatim")
  T.ok(#d.corrections + #d.instructions >= 1, "correction kept")
  T.eq(#mem:loss_audit(d), 0, "summary loses nothing protected")
  for _, f in ipairs(d.facts) do T.ok(f.status ~= "speculative", "speculation must not be listed as fact") end
  local text = mem:expand(d.exclusions[1].ref)
  T.ok(text:find("universities"), "original wording retrievable")
end)

T.test("capacity pressure evicts ordinary items but never protected ones", function()
  local mem = Memory.new({ max_items = 50 })
  mem:begin_turn("user")
  local keep = mem:add({ layer = "task", kind = "prohibition", text = "never include universities", standing = true })
  for i = 1, 200 do mem:begin_turn("user"); mem:note_utterance("chatter " .. i, "user") end
  T.ok(mem.items[keep.id] ~= nil, "protected item survives eviction")
  T.ok(#mem.evictions > 0)
  T.ok(mem.index.n <= 51)
end)

T.test("ordinal artifact reference resolves to the numbered item, and is reported missing when absent", function()
  local _, say = session()
  say("Here are two approaches:\n1. Cache the results.\n2. Rewrite the parser.", "assistant")
  local m = say("Explain why the second solution failed.")
  local r = find_ref(m, "the second solution")
  T.ok(r ~= nil)
  T.eq(r.status, "resolved")
  T.ok(r.antecedent.excerpt:find("Rewrite the parser"), r.antecedent.excerpt)
  local _, say2 = session()
  local m2 = say2("Explain why the second solution failed, considering the correction I made earlier.")
  T.eq(find_ref(m2, "the second solution").status, "unresolved")
  local c = find_ref(m2, "the correction I made earlier")
  T.eq(c.status, "unresolved")
  T.ok(c.requirement:find("none is invented"), c.requirement)
end)

T.test("revised version resolves to the latest enumerated version", function()
  local _, say = session()
  say("Version 1: initial design.\nVersion 2: revised design with caching.", "assistant")
  local m = say("What changed between the first version and the revised version?")
  T.eq(m.intent, "comparison")
  local a, b = find_ref(m, "the first version"), find_ref(m, "the revised version")
  T.ok(a and b)
  T.eq(a.status, "resolved"); T.eq(b.status, "resolved")
  T.ok(a.antecedent.excerpt:find("initial design")); T.ok(b.antecedent.excerpt:find("revised design"))
end)

T.test("a back-reference resolves only to an entity introduced earlier, with type compatibility", function()
  local _, say = session()
  say("I'm looking at Beta Systems, a robotics business.")
  say("Weather is nice today.")
  local m = say("Which company acquired the business I mentioned earlier?")
  local r = find_ref(m, "the business I mentioned earlier")
  T.eq(r.status, "resolved"); T.eq(r.antecedent.text, "Beta Systems")
end)

T.test("memory selection is index-driven: work does not grow with history length", function()
  local small, say1 = session("s")
  for i = 1, 30 do say1("Filler " .. i .. " about weather.") end
  local big, say2 = session("b")
  for i = 1, 1500 do say2("Filler " .. i .. " about weather.") end
  local m1 = say1("What is the capital of France?")
  local m2 = say2("What is the capital of France?")
  T.eq(m1.relation.id, m2.relation.id)
  local r1 = small:select(m1, {})
  local r2 = big:select(m2, {})
  T.ok(r2.n_candidates <= r1.n_candidates + 60, "candidates considered: " .. r1.n_candidates .. " vs " .. r2.n_candidates)
  T.ok(r2.n_items > 1000)
end)

os.exit(T.report("memory") and 0 or 1)
