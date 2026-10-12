-- asi.nlu.record: the versioned, schema-validated Interpretation Record.
-- Everything here is DERIVED from computed interpretation / memory / retrieval results.  Confidence components are reported separately and are
-- RAW unless a calibration table (fitted on labelled dev data, see asi.nlu.calibrate) is supplied; nothing is hand-set per question type.
local U = require("asi.nlu.util")

local R = {}
R.SCHEMA = "nlu.record/1"
R.ENGINE = "asi-nlu"
R.ENGINE_VERSION = "0.9.0"

local S = {
  str = { type = "string" }, num = { type = "number" }, bool = { type = "boolean" }, tab = { type = "table" }, any = { type = "any" },
}
local function obj(fields, req)
  local f = {}
  for k, v in pairs(fields) do f[k] = U.copy(v); if req and req[k] then f[k].required = true end end
  return { type = "object", fields = f }
end
local function arr(of) return { type = "array", of = of } end

-- the schema is intentionally permissive about the inside of evidence / interpretation blobs (they are validated structurally and by
-- Record.check_invariants) but strict about the envelope: every top-level section must be present with the right shape.
R.SPEC = {
  type = "object",
  fields = {
    schema_version = { type = "enum", values = { R.SCHEMA }, required = true },
    request_id = { type = "string", required = true, min = 8 },
    engine = { type = "object", required = true, fields = { name = S.str, version = S.str, flags = S.tab } },
    original_input = { type = "string", required = true },
    normalized_input = { type = "object", required = true, fields = { text = S.str, note = S.str } },
    lexical_analysis = { type = "object", required = true, fields = { status = S.str, utf8 = S.tab, n_tokens = S.num, sentences = arr(S.tab), temporal = arr(S.tab), numbers = arr(S.tab), notes = S.tab } },
    semantic_intent = { type = "object", required = true, fields = { speech_act = S.str, intent = S.str, op = S.any, frame = S.any, status = S.str } },
    entity_candidates = { type = "array", required = true, of = S.tab },
    resolved_entities = { type = "array", required = true, of = S.tab },
    requested_relations = { type = "table", required = true },
    requested_answer_type = { type = "any" },
    temporal_constraints = { type = "array", required = true, of = S.tab },
    geographic_constraints = { type = "array", required = true, of = S.tab },
    positive_constraints = { type = "array", required = true, of = S.tab },
    negative_constraints = { type = "array", required = true, of = S.tab },
    preferences = { type = "array", required = true, of = S.tab },
    source_constraints = { type = "array", required = true, of = S.tab },
    relevant_context = { type = "object", required = true, fields = { dependency = S.any, references = arr(S.tab), recent = arr(S.tab) } },
    relevant_memory = { type = "array", required = true, of = S.tab },
    active_constraints = { type = "array", required = true, of = S.tab },
    memory_provenance = { type = "object", required = true, fields = { namespace = S.any, revision = S.any, turn = S.any, n_selected = S.any, n_excluded = S.any, excluded = arr(S.tab) } },
    retrieval_candidates = { type = "object", required = true, fields = { plan_kind = S.str, topical = arr(S.tab), n_assertions_examined = S.any } },
    selected_evidence = { type = "array", required = true, of = S.tab },
    rejected_evidence = { type = "array", required = true, of = S.tab },
    conflicting_evidence = { type = "array", required = true, of = S.tab },
    ambiguity_state = { type = "object", required = true, fields = { state = S.str, points = arr(S.tab) } },
    evidence_sufficiency = { type = "object", required = true, fields = { status = { type = "enum", values = { "answerable", "potentially_answerable", "ambiguous", "contradictory", "insufficient", "unsupported", "not_applicable" }, required = true },
      reasons = arr(S.str), notes = arr(S.str), answer = S.any } },
    confidence = { type = "object", required = true, fields = { lexical_segmentation = S.tab, entity_identity = S.tab, semantic_interpretation = S.tab, memory_reference = S.tab, evidence_sufficiency = S.tab, interpretation_correct = S.tab, calibration = S.str } },
    decision_provenance = { type = "array", required = true, of = S.tab },
    unresolved_requirements = { type = "array", required = true, of = S.tab },
    execution_cost = { type = "object", required = true, fields = { interpretation_work = S.num, retrieval = S.tab, status = S.str } },
    integrity = { type = "object", required = true, fields = { sha256 = { type = "string", min = 64, max = 64, required = true }, covers = S.str } },
  },
}

---------------------------------------------------------------- helpers
local function first_main(result)
  return result.main
end

local function ref_list(m)
  -- every entity-bearing argument of the interpretation, with its resolution state
  local out = {}
  local seen = {}
  local function add(role, ref)
    if not ref or ref.asked or seen[ref] then return end
    seen[ref] = true
    out[#out + 1] = { role = role, ref = ref }
  end
  for role, ref in pairs(m.roles or {}) do add("arg:" .. role, ref) end
  for _, k in ipairs({ "subject", "concept", "target", "focus", "object", "basis" }) do add(k, m[k]) end
  for i, it in ipairs(m.items or {}) do add("item" .. i, it) end
  if m.statement then add("stmt_subject", m.statement.subject); add("stmt_object", m.statement.object) end
  if m.clause then add("clause_subject", m.clause.subject); add("clause_object", m.clause.object) end
  for _, st in ipairs((m.query and m.query.steps) or {}) do add("chain" .. st.index, st.known) end
  table.sort(out, function(a, b) return a.role < b.role end)
  return out
end

local function entity_sections(m)
  local cands, resolved = {}, {}
  for _, e in ipairs(ref_list(m)) do
    local r = e.ref
    if r.candidates or r.status or r.senses then
      cands[#cands + 1] = { role = e.role, mention = r.text, span = r.span, status = r.status, candidates = r.candidates, rejected = r.rejected, senses = r.senses,
        pronoun = r.pronoun, backref = r.backref, ordinal = r.ordinal, head = r.head }
    end
    local key = (r.antecedent and r.antecedent.key) or r.resolved_id
    resolved[#resolved + 1] = { role = e.role, mention = r.text, key = key, type = r.type, status = r.status or "n/a", antecedent = r.antecedent,
      via = r.antecedent and (r.antecedent.via or "antecedent") or (r.status == "unseen" and "open-set mention") or (r.status == "resolved" and "lexicon") or nil,
      weak_name = r.weak_name, non_anaphoric = r.non_anaphoric, deictic = r.deictic }
  end
  return cands, resolved
end

---------------------------------------------------------------- confidence components (raw, each from a computed quantity)
local function confidence(result, m, evidence, calibration)
  local conf = {}
  -- (1) lexical segmentation: margin of the best cover over the runner-up
  local seg = 1.0
  if result.lattice and result.lattice.segmentation_margin then
    local margin = result.lattice:segmentation_margin()
    seg = margin
  end
  conf.lexical_segmentation = { raw = U.round(seg, 4), basis = "relative score margin between the best and the runner-up phrase segmentation" }
  -- (2) entity identity: weakest resolved-or-ambiguous entity mention
  local ent, n = 1.0, 0
  for _, e in ipairs(ref_list(m)) do
    local r = e.ref
    if r.candidates and #r.candidates > 0 and not r.pronoun then
      local top = r.candidates[1].p or 1
      if r.status == "ambiguous" then top = math.min(top, 0.5) end
      if r.status == "unseen" then top = math.min(top, 0.85) end   -- an open-set name is identified as a mention, not as a known individual
      ent = math.min(ent, top); n = n + 1
    elseif r.status == "unresolved" or r.status == "unknown_term" then ent = math.min(ent, 0.2); n = n + 1 end
  end
  conf.entity_identity = { raw = U.round(ent, 4), basis = "lowest top-candidate posterior over the entity mentions of the request", n_mentions = n }
  -- (3) semantic interpretation: posterior of the winning hypothesis among competing ones
  conf.semantic_interpretation = { raw = U.round((m.confidence and m.confidence.semantic_raw) or 0, 4), coverage = m.confidence and m.confidence.coverage,
    basis = "posterior probability of the winning semantic hypothesis (softmax over named-factor scores)" }
  -- (4) memory reference resolution
  local mem, nref = 1.0, 0
  for _, ref in ipairs((m.context and m.context.references) or {}) do
    nref = nref + 1
    if ref.status ~= "resolved" then mem = 0.0
    else mem = math.min(mem, (ref.antecedent and ref.antecedent.p) or 0.9) end
  end
  conf.memory_reference = { raw = U.round(mem, 4), n_references = nref, basis = "weakest posterior among resolved context references (0 if any is unresolved)" }
  -- (5) evidence sufficiency: ordinal, not a probability that the answer is right
  local ev = { raw = 0.0, status = evidence and evidence.status or "not_applicable", basis = "strength (noisy-OR of independent record reliabilities) of the best supported answer; 0 unless answerable" }
  if evidence and evidence.status == "answerable" and evidence.answers and evidence.answers[1] then ev.raw = U.round(evidence.answers[1].strength or 0, 4)
  elseif evidence and evidence.status == "answerable" and evidence.matches then ev.raw = 0.5 end
  conf.evidence_sufficiency = ev
  -- optional calibration: maps a raw value to the empirical accuracy of that value on labelled data
  if calibration then
    conf.calibration = "calibrated with " .. tostring(calibration.method) .. " on " .. tostring(calibration.n) .. " labelled dev examples (" .. tostring(calibration.source) .. ")"
    local function apply(c, which)
      local f = calibration.maps and calibration.maps[which]
      if f and c then c.calibrated = f(c.raw) end
    end
    if calibration.model then
      -- whole-interpretation calibration: P(primary reading correct) from interpretation-derived features, fitted and cross-validated offline
      local Cal = require("asi.nlu.calibration")
      local p = Cal.apply_features(calibration.model, Cal.features(m))
      conf.interpretation_correct = { calibrated = U.round(p, 4), method = calibration.model.method, basis = calibration.model.fit and calibration.model.fit.target,
        valid_for = calibration.model.fit and calibration.model.fit.valid_for, cross_fit_ece = calibration.model.fit and calibration.model.fit.cross_fit_ece_calibrated }
      conf.calibration = "interpretation_correct is calibrated (" .. tostring(calibration.model.method) .. " over interpretation features, " .. tostring(calibration.n) ..
        " labelled noisy examples; " .. tostring(calibration.source) .. "); the other components remain RAW scores, not probabilities"
    end
    apply(conf.semantic_interpretation, "semantic_interpretation")
    apply(conf.entity_identity, "entity_identity")
    apply(conf.lexical_segmentation, "lexical_segmentation")
  else
    conf.calibration = "uncalibrated: values are raw model scores, NOT probabilities of being correct"
  end
  return conf
end

---------------------------------------------------------------- build
function R.build(ctx)
  local result, evidence, plan = ctx.result, ctx.evidence, ctx.plan
  local an = result.analysis
  local m = first_main(result) or { status = "no_interpretation", speech_act = "unknown", intent = "unknown", roles = {}, constraints = {} }
  local cons = m.constraints or {}
  local cands, resolved = entity_sections(m)
  local toks = {}
  for i, u in ipairs(an and an.units or {}) do
    if i > 400 then break end
    toks[#toks + 1] = { form = u.form, raw = u.raw, s = u.s, e = u.e, kind = u.kind }
  end
  local sentences = {}
  for _, s in ipairs(an and an.sentences or {}) do sentences[#sentences + 1] = { id = s.id, s = s.s, e = s.e, terminal = s.terminal, question_mark = s.question_mark or nil } end
  local mem = m.context and m.context.memory
  local rec = {
    schema_version = R.SCHEMA,
    engine = { name = R.ENGINE, version = R.ENGINE_VERSION, flags = ctx.flags or {}, lexicon_revision = ctx.lexicon_revision, interpreter_version = ctx.interpreter_version },
    original_input = result.original or "",
    normalized_input = { text = (result.original or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""),
      note = "whitespace-collapsed only; the original request is preserved verbatim in original_input and is what the interpretation refers to" },
    lexical_analysis = { status = result.status or "ok", utf8 = an and an.utf8 or {}, n_tokens = an and #an.units or 0, tokens = toks, sentences = sentences,
      temporal = U.map(an and an.temporal or {}, function(t) return { kind = t.kind, op = t.op, text = t.text, year = t.year, lo = t.eff_lo or t.lo, hi = t.eff_hi or t.hi, s = t.s, e = t.e } end),
      numbers = U.map(an and an.numbers or {}, function(n) return { kind = n.kind, value = n.value, text = n.text } end), notes = an and an.notes or {} },
    semantic_intent = { speech_act = m.speech_act or "unknown", intent = m.intent or "unknown", op = m.op, frame = m.frame, status = m.status or "no_interpretation",
      wrapper = m.wrapper, polarity = m.polarity, tense = m.tense, task_verb = m.task_verb, recall = m.recall, instruction = m.instruction, persist = m.persist },
    entity_candidates = cands,
    resolved_entities = resolved,
    requested_relations = m.relation and { relation = m.relation, query = m.query } or {},
    requested_answer_type = m.query and (m.query.answer_type or m.query.relation_answer_type) or nil,
    temporal_constraints = cons.temporal or {},
    geographic_constraints = cons.geographic or {},
    positive_constraints = cons.positive or {},
    negative_constraints = cons.negative or {},
    preferences = cons.preferences or {},
    source_constraints = cons.source or {},
    restrictions = cons.restrictions or {},
    temporal_scope = m.temporal_scope,
    relevant_context = { dependency = m.context and m.context.dependency, references = m.context and m.context.references or {}, recent = ctx.recent or {} },
    relevant_memory = mem and mem.selected or {},
    active_constraints = m.context and m.context.active_constraints or {},
    memory_provenance = { namespace = mem and mem.namespace, revision = mem and mem.revision, turn = mem and mem.turn, n_selected = mem and mem.n_selected, n_excluded = mem and mem.n_excluded,
      excluded = mem and mem.excluded or {}, n_candidates = mem and mem.n_candidates, n_items = mem and mem.n_items },
    retrieval_candidates = { plan_kind = plan and plan.kind or "none", plan = plan and U.shallow(plan) or nil, topical = evidence and evidence.topical or {},
      n_assertions_examined = evidence and evidence.assertion_count or 0, knowledge_digest = evidence and evidence.knowledge_digest },
    selected_evidence = evidence and evidence.selected or {},
    rejected_evidence = evidence and evidence.rejected or {},
    conflicting_evidence = evidence and evidence.conflicting_evidence or {},
    partial_evidence = evidence and evidence.partial_evidence or {},
    refuting_evidence = evidence and evidence.refuting or {},
    ambiguity_state = m.ambiguity or { state = "unresolvable", points = {} },
    evidence_sufficiency = evidence and { status = evidence.status, reasons = evidence.reasons, notes = evidence.notes, answer = evidence.answer, answers = evidence.answers,
      alternative_answers = evidence.alternative_answers, answers_by_reading = evidence.answers_by_reading,
      conflicts = evidence.conflicts, claim_verdict = evidence.verdict, interpretation_incomplete = evidence.interpretation_incomplete }
      or { status = "not_applicable", reasons = { "no dataset was supplied" }, notes = {} },
    confidence = confidence(result, m, evidence, ctx.calibration),
    decision_provenance = m.provenance or {},
    hypotheses = m.hypotheses, rejected_hypotheses = m.rejected_hypotheses,
    unresolved_requirements = {},
    execution_cost = { interpretation_work = result.work and result.work.total or 0, work_by_stage = result.work and result.work.by_stage, status = result.status or "ok",
      retrieval = { assertions_examined = evidence and evidence.assertion_count or 0, selected = evidence and #evidence.selected or 0, rejected = evidence and #evidence.rejected or 0 } },
  }
  -- unresolved requirements: what is MISSING, stated explicitly
  local ur = rec.unresolved_requirements
  for _, u in ipairs(m.context and m.context.unresolved or {}) do ur[#ur + 1] = { kind = "context_reference", reference = u.reference, mention = u.mention, requirement = u.requirement } end
  for _, p in ipairs((m.ambiguity and m.ambiguity.points) or {}) do
    if p.material and not p.resolved then ur[#ur + 1] = { kind = "ambiguity", point = p.id, requirement = "choose between: " .. table.concat(U.map(p.candidates or {}, function(c) return tostring(c.id or c.summary) end), " | ") } end
  end
  for _, un in ipairs(m.unexplained or {}) do ur[#ur + 1] = { kind = "unexplained_text", text = un, requirement = "this part of the request was not understood and is not reflected in the interpretation" } end
  if evidence and evidence.interpretation_incomplete then ur[#ur + 1] = { kind = "entity_unidentified", requirement = "the entity the question is about could not be identified" } end
  if result.status == "limited" then ur[#ur + 1] = { kind = "resource_limit", requirement = "the work budget was exhausted; the interpretation is incomplete and was not completed by guessing" } end
  if evidence and (evidence.status == "insufficient" or evidence.status == "unsupported" or evidence.status == "potentially_answerable") then
    ur[#ur + 1] = { kind = "evidence", status = evidence.status, requirement = table.concat(evidence.reasons or {}, "; ") }
  end
  -- deterministic request id + integrity hash (hash covers every section except the integrity block itself)
  local body = U.json_encode(rec, { nan_null = true })
  rec.request_id = U.sha256(table.concat({ rec.original_input, tostring(rec.retrieval_candidates.knowledge_digest), tostring(rec.memory_provenance.namespace), tostring(rec.memory_provenance.revision),
    R.SCHEMA, R.ENGINE_VERSION }, "\0")):sub(1, 24)
  rec.integrity = { sha256 = U.sha256(body), covers = "canonical JSON of all other fields (before request_id was assigned)" }
  return rec
end

---------------------------------------------------------------- validation
function R.validate(rec)
  local ok, errs = U.validate(R.SPEC, rec)
  local extra = R.check_invariants(rec)
  for _, e in ipairs(extra) do errs[#errs + 1] = e end
  return #errs == 0, errs
end

-- semantic invariants the envelope schema cannot express
function R.check_invariants(rec)
  local errs = {}
  local function bad(m) errs[#errs + 1] = "invariant: " .. m end
  if type(rec) ~= "table" then return { "invariant: record is not a table" } end
  local st = rec.evidence_sufficiency and rec.evidence_sufficiency.status
  if st == "answerable" and #(rec.selected_evidence or {}) == 0 then bad("status answerable without selected evidence") end
  if st ~= "answerable" and st ~= "ambiguous" and rec.evidence_sufficiency and rec.evidence_sufficiency.answer and st ~= "contradictory" then
    if st == "insufficient" or st == "unsupported" then bad("an answer is attached to status " .. st) end
  end
  for i, ev in ipairs(rec.selected_evidence or {}) do
    if not ev.record or not ev.quote then bad("selected_evidence[" .. i .. "] lacks record/quote provenance") end
    if ev.role == "rejected" then bad("selected_evidence[" .. i .. "] has role rejected") end
  end
  local C = rec.confidence or {}
  for k, c in pairs(C) do
    if type(c) == "table" and c.raw ~= nil and (c.raw < 0 or c.raw > 1) then bad("confidence." .. k .. " outside [0,1]") end
    if type(c) == "table" and c.calibrated ~= nil and (c.calibrated < 0 or c.calibrated > 1) then bad("confidence." .. k .. " calibrated outside [0,1]") end
  end
  if rec.original_input == nil or rec.original_input == "" and rec.lexical_analysis and rec.lexical_analysis.n_tokens > 0 then bad("original input lost") end
  if rec.execution_cost and rec.execution_cost.status == "limited" then
    local found = false
    for _, u in ipairs(rec.unresolved_requirements or {}) do if u.kind == "resource_limit" then found = true end end
    if not found then bad("limited run without an explicit resource_limit requirement") end
  end
  return errs
end

function R.verify_integrity(rec)
  local copy = U.shallow(rec)
  local sha = rec.integrity and rec.integrity.sha256
  copy.integrity = nil
  copy.request_id = nil
  return sha == U.sha256(U.json_encode(copy, { nan_null = true }))
end

return R
