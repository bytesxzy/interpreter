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

-- Wordings of every planted / final turn live in a template table so that an INDEPENDENTLY authored set can be swapped in (LC.use).  The defaults below are
-- the development wordings.  Placeholders: %ORG% %THING% %DB% %WHAT% %NEW% %OLD% %SIM1% %SIM2%.
local DEFAULT_T = {
  plant_entity = { "I'm looking at %ORG%, a small robotics business." },
  final_acquirer = { "Which company acquired the business I mentioned earlier?" },
  final_ceo = { "Who is the CEO of the company I mentioned earlier?" },
  plant_old_dataset = { "Use the %OLD% dataset." },
  plant_correction = { "Actually, use the %NEW% dataset from now on." },
  final_analyze = { "Analyze the figures." },
  plant_exclusion = { "Do not include %WHAT%." },
  plant_exclusion_embedded = { "Please do not include %WHAT%." },
  final_search = { "Find organizations in Germany." },
  plant_similar = { "I'm looking at %ORG%, a small robotics business." },
  assistant_similar = { "Related names include %SIM1% and %SIM2%." },
  final_ceo_similar = { "Who is the CEO of the company I mentioned earlier?" },
  plant_decision = { "We decided to use %DB% for the %THING% service." },
  final_decision = { "What did we decide about the %THING% service?" },
  plant_research = { "I'm researching %ORG%." },
  plant_other = { "Tell me about %ORG%." },
  final_pronoun = { "Who founded it?" },
  orgs = ORGS, things = { "inventory", "billing", "telemetry" }, dbs = { "PostgreSQL", "SQLite", "MariaDB" },
  whats = { "universities", "reposts", "retailers", "agencies" }, years_old = { "2019", "2020", "2021" }, years_new = { "2024", "2025", "2026" },
}
local T = DEFAULT_T
local EXTERNAL   -- set by LC.use: external distractor / look-alike pools

-- swap in an externally authored template set (same keys; missing keys fall back to the defaults); returns the previous set
function LC.use(t)
  local prev = { T = T, EXTERNAL = EXTERNAL }
  if not t then T, EXTERNAL = DEFAULT_T, nil; return prev end
  local merged = {}
  for k, v in pairs(DEFAULT_T) do merged[k] = v end
  for k, v in pairs(t) do merged[k] = v end
  if t.years then merged.years_old, merged.years_new = t.years, t.years end
  T = merged
  EXTERNAL = (t.distractors and #t.distractors > 0) and { distractors = t.distractors, lookalikes = t.lookalikes or {} } or nil
  return prev
end

local function fill(tmpl, vars)
  return (tmpl:gsub("%%(%u+%d?)%%", function(k) return vars[k] or ("%" .. k .. "%") end))
end

function LC.load_templates(path)
  local f = assert(io.open(path, "rb"))
  local raw = f:read("a")
  f:close()
  local obj = assert(U.json_decode(raw))
  return obj, U.sha256(raw)
end

function LC.distractor(rng)
  if EXTERNAL then
    local lookalike = #EXTERNAL.lookalikes > 0 and rng:int(1, 6) == 1
    local pool = lookalike and EXTERNAL.lookalikes or EXTERNAL.distractors
    return rng:pick(pool), lookalike and "lookalike" or "chatter"
  end
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
  local org = rng:pick(T.orgs)
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_entity), { ORG = org }), planted = "entity" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = rng:pick(T.final_acquirer), planted = planted,
    expect = { ref = T == DEFAULT_T and "the business I mentioned earlier" or nil, ref_any = true, antecedent = org, relation = "acquirer" } }
end

-- instruction early, correction later; the superseded value must not be active or retrieved
function B.correction(rng, n, pos)
  local a, b = rng:pick(T.years_old), rng:pick(T.years_new)
  while b == a do b = rng:pick(T.years_new) end
  local turns, planted = {}, {}
  local first = slot(pos, n) // 2
  local second = slot(pos, n)
  if second <= first then second = first + 1 end
  for i = 0, n do
    if i == first then turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_old_dataset), { OLD = a }), planted = "old" } end
    if i == second then
      turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_correction), { NEW = b }), planted = "correction" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = rng:pick(T.final_analyze), planted = planted, expect = { slot = "dataset", value = b, stale = a } }
end

-- standing exclusion given once
function B.exclusion(rng, n, pos)
  local what = rng:pick(T.whats)
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_exclusion), { WHAT = what }), planted = "exclusion" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = rng:pick(T.final_search), planted = planted, expect = { prohibition = what } }
end

-- a negation buried inside ONE long message
function B.buried_negation(rng, n, pos)
  local what = rng:pick(T.whats)
  local parts = {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then parts[#parts + 1] = fill(rng:pick(T.plant_exclusion_embedded), { WHAT = what }) end
    if i < n then local t = LC.distractor(rng); parts[#parts + 1] = t end
  end
  local text = table.concat(parts, " ")
  return { turns = { { speaker = "user", text = text, planted = "exclusion" } }, final = rng:pick(T.final_search), planted = { 1 },
    expect = { prohibition = what } }
end

-- several look-alike names: the one the USER introduced is the referent of "the company I mentioned earlier"
function B.similar_names(rng, n, pos)
  local set
  if T == DEFAULT_T then set = rng:pick(SIMILAR)
  else local org = rng:pick(T.orgs); set = { org, (org:gsub(".$", "x")), org .. " Europe" } end
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_similar), { ORG = set[1] }), planted = "entity" }
      planted[#planted + 1] = #turns
      turns[#turns + 1] = { speaker = "assistant", text = fill(rng:pick(T.assistant_similar), { SIM1 = set[2], SIM2 = set[3] }), planted = "similar" }
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  local final = rng:pick(T.final_ceo_similar)
  return { turns = turns, final = final, planted = planted,
    expect = { ref = T == DEFAULT_T and "the company I mentioned earlier" or nil, ref_any = true, antecedent = set[1], relation = "ceo" } }
end

-- a decision referred to later without repeating its wording
function B.decision(rng, n, pos)
  local db = rng:pick(T.dbs)
  local thing = rng:pick(T.things)
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_decision), { DB = db, THING = thing }), planted = "decision" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  return { turns = turns, final = fill(rng:pick(T.final_decision), { THING = thing }), planted = planted, expect = { fragment = db } }
end

-- the pronoun case: after distractors the antecedent has decayed; the system must either resolve correctly or say it cannot -- never resolve wrongly
function B.pronoun_gap(rng, n, pos)
  local org = rng:pick(T.orgs)
  local other = rng:pick(T.orgs)
  while other == org do other = rng:pick(T.orgs) end
  local turns, planted = {}, {}
  local at = slot(pos, n)
  for i = 0, n do
    if i == at then
      turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_research), { ORG = org }), planted = "entity" }
      planted[#planted + 1] = #turns
    end
    if i < n then local t, tp = LC.distractor(rng); turns[#turns + 1] = { speaker = "user", text = t, topic = tp } end
  end
  turns[#turns + 1] = { speaker = "user", text = fill(rng:pick(T.plant_other), { ORG = other }), planted = "other" }
  -- "it" now most plausibly refers to the most recent organisation (other); referring to the old one would be WRONG
  return { turns = turns, final = rng:pick(T.final_pronoun), planted = planted, expect = { pronoun = "it", wrong = org, right = other, relation = "founder" } }
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
function LC.score(sc, m, lex)
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
  if ex.ref or ex.ref_any then
    local found
    local refs = m.context and m.context.references or {}
    if ex.ref then
      for _, ref in ipairs(refs) do if norm(ref.mention) == norm(ex.ref) then found = ref end end
    else
      -- externally authored final wording: the back-reference is whichever reference the interpreter resolved to the planted entity (or, failing that, any reference)
      for _, ref in ipairs(refs) do
        if ref.status == "resolved" and ref.antecedent and norm(ref.antecedent.text) == norm(ex.antecedent) then found = ref end
      end
      found = found or refs[1]
    end
    chk("reference_found", found ~= nil)
    chk("entity_recovered", found ~= nil and found.status == "resolved" and found.antecedent and norm(found.antecedent.text) == norm(ex.antecedent))
    -- "Who LEADS / is the HEAD of the company I mentioned?" asks for the leader, of which the CEO is a kind (ceo isa leader): when the wording does not say CEO,
    -- the parent relation is the correct reading of the question.  A wording that names the CEO must produce ceo.
    local rel_ok = m.relation and m.relation.id == ex.relation
    if not rel_ok and m.relation and lex and not (sc.final or ""):lower():find("ceo", 1, true) and not (sc.final or ""):lower():find("chief executive", 1, true) then
      local want = lex:get_rel(ex.relation)
      rel_ok = want ~= nil and want.isa == m.relation.id
    end
    chk("relation", rel_ok)
  elseif ex.slot then
    local act = {}
    for _, c in ipairs(m.context and m.context.active_constraints or {}) do if c.slot then act[c.slot] = tostring(c.value) end end
    chk("correction_active", act[ex.slot] == ex.value)
    -- the corrected value must be among the retrieved memory items of the slot and the superseded one must not be (the wording around the value is the
    -- user's own: "the 2021 dataset", "dataset 2021", "dataset named 2021", ...; the item records slot and value, so the check does not depend on wording)
    local got_new, got_stale = false, false
    for _, it in ipairs(m.context and m.context.memory and m.context.memory.selected or {}) do
      if it.slot == ex.slot and tostring(it.value) == tostring(ex.value) then got_new = true end
      if it.slot == ex.slot and tostring(it.value) == tostring(ex.stale) then got_stale = true end
    end
    chk("correction_retrieved", got_new)
    chk("stale_not_retrieved", not got_stale)
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
    -- externally authored final wordings refer to the company in other ways ("them", "they", "that company", "this company"): any anaphoric reference counts
    if not found and T ~= DEFAULT_T then
      for _, ref in ipairs(m.context and m.context.references or {}) do
        if ref.kind == "pronoun" or ref.kind == "entity_backref" then found = found or ref end
      end
    end
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
  local score = LC.score(sc, last, interp.lex)
  score.work_final = fin.work and fin.work.total or 0
  score.work_total = work + score.work_final
  score.wall = os.clock() - t0
  score.items = mem.index.n
  score.n_candidates = (last and last.context and last.context.memory) and last.context.memory.n_selected or 0
  return score, mem, last
end

return LC
