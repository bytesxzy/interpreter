-- asi.nlu.plan: interpretation -> retrieval plan.
-- Retrieval receives the STRUCTURED interpretation (relation, direction, typed entity readings, answer type, time, source and exclusions),
-- never just the raw string.  A plan says exactly what a record must establish to count as evidence.
local U = require("asi.nlu.util")

local Plan = {}

-- readings of one argument: [{key, text, type, p}] from the interpretation's own entity resolution (candidates keep their probabilities)
local function readings(ref, kb)
  local out = {}
  if not ref then return out, "missing" end
  local function canon(key)
    local e = kb and kb.lex:get_entity(key)
    return (e and e.alias_of) or key
  end
  if ref.antecedent and ref.antecedent.key and not ref.antecedent.group then
    out[1] = { key = canon(ref.antecedent.key), text = ref.antecedent.text or ref.text, type = ref.antecedent.type, p = 1.0, via = ref.antecedent.via or "antecedent" }
    return out, "resolved"
  end
  if (ref.status == "resolved" or ref.status == "unseen") and ref.resolved_id then
    local fuzzy
    for _, c in ipairs(ref.candidates or {}) do if c.id == ref.resolved_id and c.fuzzy then fuzzy = c.fuzzy end end
    out[1] = { key = canon(ref.resolved_id), text = ref.text, type = ref.type, p = 1.0, via = ref.status, fuzzy = fuzzy }
    return out, ref.status
  end
  if ref.status == "ambiguous" then
    for _, c in ipairs(ref.candidates or {}) do
      if (c.p or 0) >= 0.08 then out[#out + 1] = { key = canon(c.id), text = ref.text, matched_name = c.name, type = c.type, p = c.p, via = "candidate", fuzzy = c.fuzzy } end
    end
    return out, "ambiguous"
  end
  if ref.senses and #ref.senses > 0 then
    -- a concept: all lexicon senses are readings; the first is the interpreter's choice
    for i, sn in ipairs(ref.senses) do out[#out + 1] = { key = "sense:" .. sn.id, text = ref.text, type = sn.type, p = i == 1 and 0.8 or 0.2 / math.max(1, #ref.senses - 1), via = "sense" } end
    out[#out + 1] = { key = "term:" .. (ref.core or ref.text:lower()), text = ref.text, type = nil, p = 0.3, via = "term" }
    return out, "resolved"
  end
  if ref.kind == "unknown" or ref.kind == "typenoun" or ref.kind == "concept" then
    out[1] = { key = "term:" .. (ref.core or ref.text:lower()), text = ref.text, p = 1.0, via = "term" }
    return out, "term"
  end
  return out, ref.status or "unresolved"
end
Plan.readings = readings

local function time_request(m)
  local t = { mode = "current", lo = nil, hi = nil, text = nil, basis = "default (no time stated)" }
  local temporals = (m.constraints and m.constraints.temporal) or {}
  for _, c in ipairs(temporals) do
    if c.basis ~= "source_label" and c.role ~= "derived" then
      if c.op == "since" or c.op == "after" then t = { mode = "after", lo = c.eff_lo, hi = c.eff_hi, text = c.text, basis = "stated" }
      elseif c.op == "until" or c.op == "before" or c.op == "by" then t = { mode = "before", lo = c.eff_lo, hi = c.eff_hi, text = c.text, basis = "stated" }
      elseif c.op == "as_of" then t = { mode = "at", lo = c.eff_lo, hi = c.eff_hi, text = c.text, basis = "stated" }
      else t = { mode = "at", lo = c.eff_lo, hi = c.eff_hi, text = c.text, basis = "stated" } end
      break
    end
  end
  -- "former capital", "historical", "previous"
  for _, r in pairs(m.roles or {}) do
    for _, mod in ipairs(r.modifiers or {}) do
      local w = (mod.text or ""):lower()
      if w == "former" or w == "previous" or w == "historical" or w == "ex" or w == "old" then t = { mode = "former", text = w, basis = "modifier" } end
    end
  end
  if m.temporal_scope == "historical" or m.temporal_scope == "former" or m.temporal_scope == "past" then t.mode = "former"; t.basis = "temporal scope" end
  -- a bare past-tense question ("Who was the CEO of X?") leans historical but is often used loosely: both past and present facts qualify,
  -- the present ones with reduced weight and a flag
  if t.mode == "current" and t.basis:find("default") and m.tense == "past" then t.mode = "past_leaning"; t.basis = "past tense of the question" end
  return t
end

local function source_request(m)
  local out = {}
  for _, s in ipairs((m.constraints and m.constraints.source) or {}) do
    out[#out + 1] = { label = s.label, resource = s.resource, year = s.label_year, qualifiers = s.qualifiers, cue = s.cue }
  end
  return out
end

local function exclusions(m)
  local out = {}
  for _, n in ipairs((m.constraints and m.constraints.negative) or {}) do
    out[#out + 1] = { cue = n.cue, text = n.text, target = n.target, filters = n.filters, applies_to = n.applies_to }
  end
  return out
end

-- Build the plan.  m = the main sentence interpretation (Sem.render output with .context)
function Plan.build(m, kb, opts)
  opts = opts or {}
  local plan = { kind = "none", intent = m and m.intent, notes = {} }
  if not m or m.status ~= "ok" then plan.reason = "no semantic interpretation"; return plan end
  plan.time = time_request(m)
  plan.sources = source_request(m)
  plan.exclusions = exclusions(m)
  plan.ambiguity = m.ambiguity and m.ambiguity.state or "resolved"
  if m.intent == "factual_lookup" and m.relation and m.query then
    local q = m.query
    plan.kind = "lookup"
    plan.relation = m.relation.id
    plan.relation_info = { id = m.relation.id, label = m.relation.label, from_type = m.relation.from_type, to_type = m.relation.to_type, derived_from = m.relation.derived_from }
    plan.known_role, plan.ask = q.known_role, q.ask
    plan.answer_type = q.answer_type or q.relation_answer_type
    local ref = m.roles and m.roles[q.known_role]
    plan.subject_ref = ref and { text = ref.text, status = ref.status } or nil
    plan.subjects, plan.subject_status = readings(ref, kb)
    if q.steps and #q.steps > 0 then
      plan.chain = {}
      for i, st in ipairs(q.steps) do
        local r, status = readings(st.known, kb)
        plan.chain[#plan.chain + 1] = { index = i, relation = st.relation, known_role = st.known_role, ask_role = st.ask_role, known = r, known_status = status,
          var = st.known and st.known.status == "chain_variable", result_type = st.result_type }
      end
    end
  elseif m.intent == "verification" and m.query and m.query.verify then
    plan.kind = "verify"
    plan.relation = m.relation and m.relation.id
    plan.from_readings, plan.from_status = readings(m.query.verify.from, kb)
    plan.to_readings, plan.to_status = readings(m.query.verify.to, kb)
  elseif m.intent == "definition" or m.intent == "entity_description" then
    plan.kind = "define"
    local ref = m.concept or m.subject or m.target
    plan.term_ref = ref and { text = ref.text } or nil
    plan.subjects, plan.subject_status = readings(ref, kb)
  elseif m.intent == "search" then
    plan.kind = "search"
    local tgt = m.target
    plan.target = tgt and { text = tgt.text, type = tgt.type or (tgt.senses and tgt.senses[1] and tgt.senses[1].type) } or nil
    plan.filters = (m.constraints and m.constraints.positive) or {}
    plan.preferences = (m.constraints and m.constraints.preferences) or {}
  elseif m.intent == "comparison" then
    plan.kind = "compare"
    plan.items = {}
    for _, it in ipairs(m.items or {}) do
      local r = readings(it, kb)
      plan.items[#plan.items + 1] = { text = it.text, readings = r }
    end
    if #plan.items == 0 and m.context then
      for _, ref in ipairs(m.context.references or {}) do
        if ref.kind == "comparison_set" and ref.items then
          for _, it in ipairs(ref.items) do plan.items[#plan.items + 1] = { text = it.text, readings = { { key = it.key, text = it.text, type = it.type, p = 1.0 } } } end
        end
      end
    end
    plan.dimension, plan.degree = m.dimension, m.degree
  elseif m.intent == "conversation_recall" then
    plan.kind = "none"; plan.reason = "answered from conversation memory, not from the dataset"
  else
    plan.kind = "none"
    plan.reason = "intent '" .. tostring(m.intent) .. "' has no dataset retrieval plan"
  end
  plan.requires_evidence = m.requires_external_evidence
  return plan
end

return Plan
