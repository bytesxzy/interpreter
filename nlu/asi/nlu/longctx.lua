-- asi.nlu.longctx: deterministic long-conversation generator + scorer for the memory / coreference layer.
-- Every scenario plants the information the final request needs at the beginning, middle or end of N distractor turns and records exactly
-- which planted items are relevant, so memory precision / recall / false-memory rate are measured against ground truth, not impressions.
-- The distractor vocabulary is deliberately disjoint from the wording of the dev/val/test case files.
local U = require("asi.nlu.util")

local LC = {}

local TOPIC_SENTENCES = {
  weather = { "The weather in %s was grey and windy all week.", "It rained on the %s ferry again yesterday.", "A cold front is crossing %s tonight." },
  food = { "I tried a new %s recipe over the weekend.", "The %s at the corner cafe sold out by noon.", "We ordered far too much %s for the party." },
  travel = { "Our train to %s was delayed by forty minutes.", "I booked a hostel near the %s station.", "The flight to %s leaves before sunrise." },
  hobby = { "I finally repaired my %s after months of procrastinating.", "The %s club meets on Thursdays.", "My neighbour lent me a %s for the weekend." },
  chatter = { "Anyway, that was a long day.", "Thanks, that makes sense.", "Okay, noted.", "Let me think about that for a moment.", "Interesting, I did not know that.",
    "Never mind the noise outside.", "The meeting ran over again." },
  -- adversarial distractors: they contain instruction-looking or dataset-looking words but are not instructions to the system
  lookalike = { "My friend said to use the %s dataset in her statistics class.", "The %s report was lovely but I lost the file.",
    "Someone asked whether universities should be excluded from the survey.", "She told me to switch to the %s edition of the textbook." },
}
local FILL = {
  weather = { "Springfield", "Dunmore", "Larchford", "Pellham", "Ostrava" },
  food = { "lentil", "mushroom", "quince", "barley", "sesame" },
  travel = { "Lisbon", "Bergen", "Tallinn", "Kraków", "Valencia" },
  hobby = { "bicycle", "telescope", "kayak", "accordion", "loom" },
  lookalike = { "2019", "2021", "2022", "revised", "third" },
}
local TOPICS = { "weather", "food", "travel", "hobby", "chatter", "lookalike" }

local ORGS = { "Zenvo Dynamics", "Quillon Labs", "Marrow Systems", "Tessaly Robotics", "Brindle Analytics", "Oakhaven Partners", "Pyrrhic Software", "Lumora Networks" }
local SIMILAR = { { "Zenvo Dynamics", "Zenvo Dynamix", "Zenvo Dynamics Labs" }, { "Quillon Labs", "Quillion Labs", "Quillon Labs Europe" } }

function LC.distractor(rng)
  local topic = rng:pick(TOPICS)
  local pool = TOPIC_SENTENCES[topic]
  local t = rng:pick(pool)
  if t:find("%%s") then t = t:format(rng:pick(FILL[topic])) end
  return t, topic
end

-- position p in {"begin","middle","end"} -> index among N distractor slots (needed turn is inserted AFTER that many distractors)
local function slot(p, n)
  if p == "begin" then return 0 elseif p == "middle" then return n // 2 end
  return n
end

-- ---------------------------------------------------------------------------------------------------------------- scenario builders
local B = {}

-- an entity introduced by the user is referred to much later by a definite description with a discourse-linked relative clause
function B.backref_entity(rng, n, pos)
  local org = rng:pick(ORGS)
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = "I'm looking at " .. org .. ", a small robotics business.", planted = "entity" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = "Which company acquired the business I mentioned earlier?", planted = planted,
    expect = { ref = "the business I mentioned earlier", antecedent = org, relation = "acquirer" } }
end

-- instruction early, correction later; the superseded value must not be active or retrieved
function B.correction(rng, n, pos)
  local a, b = rng:pick({ "2019", "2020", "2021" }), rng:pick({ "2024", "2025", "2026" })
  local turns, planted = {}, {}
  local first = slot(pos, n) // 2
  local second = slot(pos, n)
  if second <= first then second = first + 1 end
  for i = 0, n do
    if i == first then turns[#turns + 1] = { speaker = "user", text = "Use the " .. a .. " dataset.", planted = "old" } end
    if i == second then
      turns[#turns + 1] = { speaker = "user", text = "Actually, use the " .. b .. " dataset from now on.", planted = "correction" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = "Analyze the figures.", planted = planted, expect = { slot = "dataset", value = b, stale = a } }
end

-- standing exclusion given once
function B.exclusion(rng, n, pos)
  local what = rng:pick({ "universities", "reposts", "retailers", "agencies" })
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = "Do not include " .. what .. ".", planted = "exclusion" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = "Find organizations in Germany.", planted = planted, expect = { prohibition = what } }
end

-- a negation buried inside ONE long message
function B.buried_negation(rng, n, pos)
  local what = rng:pick({ "universities", "reposts", "retailers", "agencies" })
  local parts = {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then parts[#parts + 1] = "Please do not include " .. what .. "." end
    if i < n then local t = LC.distractor(rng); parts[#parts + 1] = t end
  end
  local text = table.concat(parts, " ")
  return { turns = { { speaker = "user", text = text, planted = "exclusion" } }, final = "Find organizations in Germany.", planted = { 1 },
    expect = { prohibition = what } }
end

-- several look-alike names: the one the USER introduced is the referent of "the company I mentioned earlier"
function B.similar_names(rng, n, pos)
  local set = rng:pick(SIMILAR)
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = "I'm looking at " .. set[1] .. ", a small robotics business.", planted = "entity" }
      planted[#planted + 1] = #turns
      turns[#turns + 1] = { speaker = "assistant", text = "Related names include " .. set[2] .. " and " .. set[3] .. ".", planted = "similar" }
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = "Who is the CEO of the company I mentioned earlier?", planted = planted,
    expect = { ref = "the company I mentioned earlier", antecedent = set[1], relation = "ceo" } }
end

-- a decision referred to later without repeating its wording
function B.decision(rng, n, pos)
  local db = rng:pick({ "PostgreSQL", "SQLite", "MariaDB" })
  local thing = rng:pick({ "inventory", "billing", "telemetry" })
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = "We decided to use " .. db .. " for the " .. thing .. " service.", planted = "decision" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = "What did we decide about the " .. thing .. " service?", planted = planted, expect = { fragment = db } }
end

-- the pronoun case: after distractors the antecedent has decayed; the system must either resolve correctly or say it cannot -- never resolve wrongly
function B.pronoun_gap(rng, n, pos)
  local org = rng:pick(ORGS)
  local other = rng:pick(ORGS)
  while other == org do other = rng:pick(ORGS) end
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = "I'm researching " .. org .. ".", planted = "entity" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  turns[#turns + 1] = { speaker = "user", text = "Tell me about " .. other .. ".", planted = "other" }
  -- "it" now most plausibly refers to the most recent organisation (other); referring to the old one would be WRONG
  return { turns = turns, final = "Who founded it?", planted = planted, expect = { pronoun = "it", wrong = org, right = other, relation = "founder" } }
end

LC.KINDS = { "backref_entity", "correction", "exclusion", "buried_negation", "similar_names", "decision", "pronoun_gap" }
LC.BUILD = B

-- ---------------------------------------------------------------------------------------------------------------- scoring
local function norm(s) return (s or ""):lower():gsub("%s+", " ") end

local function selected_text(m)
  local out = {}
  for _, it in ipairs(m.context and m.context.memory and m.context.memory.selected or {}) do out[#out + 1] = it.text or "" end
  return out
end

-- returns { ok = bool, checks = { name = bool }, selected = {...}, false_memory = n, relevant_selected = n }
function LC.score(sc, m)
  local r = { ok = true, checks = {} }
  local function chk(name, ok) r.checks[name] = ok and true or false; if not ok then r.ok = false end end
  local ex = sc.expect
  if not m then chk("interpretation", false); return r end
  local texts = selected_text(m)
  local planted_text = {}
  for _, idx in ipairs(sc.planted) do planted_text[#planted_text + 1] = norm(sc.turns[idx].text) end
  -- memory precision / recall against planted items
  local rel_sel, false_sel, recent = 0, 0, 0
  for _, it in ipairs(m.context and m.context.memory and m.context.memory.selected or {}) do
    local t = it.text or ""
    local hit = false
    for _, p in ipairs(planted_text) do if norm(t):find(p:sub(1, 40), 1, true) or p:find(norm(t):sub(1, 40), 1, true) then hit = true end end
    if hit then rel_sel = rel_sel + 1
    elseif it.factors and it.factors.recent_window then recent = recent + 1 -- "essential recent conversation" by policy for pronoun requests: not a false memory
    else false_sel = false_sel + 1 end
  end
  r.relevant_selected, r.false_memory, r.n_selected, r.recent_window = rel_sel, false_sel, #texts, recent
  r.planted_total = #planted_text
  if ex.ref then
    local found
    for _, ref in ipairs(m.context and m.context.references or {}) do if norm(ref.mention) == norm(ex.ref) then found = ref end end
    chk("reference_found", found ~= nil)
    chk("entity_recovered", found ~= nil and found.status == "resolved" and found.antecedent and norm(found.antecedent.text) == norm(ex.antecedent))
    chk("relation", m.relation and m.relation.id == ex.relation)
  elseif ex.slot then
    local act = {}
    for _, c in ipairs(m.context and m.context.active_constraints or {}) do if c.slot then act[c.slot] = tostring(c.value) end end
    chk("correction_active", act[ex.slot] == ex.value)
    local joined = table.concat(texts, "\n")
    chk("correction_retrieved", joined:find(ex.value .. " dataset", 1, true) ~= nil)
    chk("stale_not_retrieved", joined:find(ex.stale .. " dataset", 1, true) == nil)
  elseif ex.prohibition then
    local found = false
    for _, c in ipairs(m.context and m.context.active_constraints or {}) do
      if c.kind == "prohibition" and norm(c.text):find(ex.prohibition, 1, true) then found = true end
    end
    chk("constraint_retained", found)
  elseif ex.fragment then
    local joined = table.concat(texts, "\n")
    chk("decision_retrieved", joined:find(ex.fragment, 1, true) ~= nil)
  elseif ex.pronoun then
    local found
    for _, ref in ipairs(m.context and m.context.references or {}) do if norm(ref.mention) == ex.pronoun then found = ref end end
    chk("pronoun_found", found ~= nil)
    -- correct = resolves to the right entity, or honestly reports ambiguity / no antecedent.  WRONG = resolves to the stale one.
    local wrong = found and found.status == "resolved" and found.antecedent and norm(found.antecedent.text) == norm(ex.wrong)
    chk("no_false_resolution", not wrong)
    r.pronoun_status = found and found.status or "none"
    r.pronoun_correct = found and found.status == "resolved" and found.antecedent and norm(found.antecedent.text) == norm(ex.right) or false
  end
  return r
end

-- run one scenario through an interpreter facade; returns score table plus cost counters
function LC.run(interp, Memory, sc, opts)
  opts = opts or {}
  local mem = Memory.new({ ns = { user = "lc", project = "lc", conversation = "lc" } })
  local work, t0 = 0, os.clock()
  local last
  for _, t in ipairs(sc.turns) do
    local r = interp:interpret(t.text, { memory = mem, speaker = t.speaker, light = (t.speaker ~= "user") })
    work = work + (r.work and r.work.total or 0)
  end
  local fin = interp:interpret(sc.final, { memory = mem, speaker = "user" })
  last = fin.main
  local score = LC.score(sc, last)
  score.work_final = fin.work and fin.work.total or 0
  score.work_total = work + score.work_final
  score.wall = os.clock() - t0
  score.items = mem.index.n
  score.n_candidates = (last and last.context and last.context.memory) and last.context.memory.n_selected or 0
  return score, mem, last
end

return LC
