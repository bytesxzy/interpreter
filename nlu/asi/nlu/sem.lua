-- asi.nlu.sem: semantic interpretation of one sentence.
--   lattice covers (segmentation alternatives) x frames (constructions) -> competing hypotheses -> bounded selection.
-- Output is a plain, serialisable table (see Sem.render); every number in its provenance is a computed factor.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local Cons = require("asi.nlu.constraints")
local H = require("asi.nlu.hyp")
local F = require("asi.nlu.frames2")

local Sem = {}

local FRAME_FUNCS = { "wh_copular", "wh_verb", "wh_do", "wh_passive", "wh_adverbial", "yes_no", "wh_change", "compare_q",
  "request", "instruction", "focus", "statement", "np_only" }

local function sentence_unit_range(an, sid)
  local a, b
  for i, u in ipairs(an.units) do
    if u.sent == sid then a = a or i; b = i end
  end
  return a, b
end
Sem.sentence_unit_range = sentence_unit_range

---------------------------------------------------------------- rendering of arguments
local function ref(S, np, depth)
  depth = depth or 0
  if not np then return nil end
  local r = { text = P.span_text(S, np), kind = np.head_kind, span = { S.units[np.u1].s, S.units[np.u2].e }, chunk_range = { np.c1, np.c2 } }
  local b = np.bound
  if b then
    r.status = b.status
    if b.top then
      if b.status == "resolved" or b.status == "unseen" then r.resolved_id, r.type = b.top.id, b.top.type
      else r.leading_candidate = b.top.id end -- ambiguous: a leading candidate is NOT a resolution
    end
    r.type = r.type or b.type
    if b.cands and #b.cands > 0 then
      r.candidates = U.map(b.cands, function(c) return { id = c.id, type = c.type, name = c.name, p = c.p, score = c.score, reasons = c.reasons, unseen = c.unseen or nil, fuzzy = c.fuzzy } end)
    end
    if b.rejected and #b.rejected > 0 then
      r.rejected = U.map(b.rejected, function(c) return { id = c.id, type = c.type, reason = c.reasons[#c.reasons] } end)
    end
    if b.senses then r.senses = U.map(b.senses, function(s) return { id = s.id, type = s.type, gloss = s.gloss } end) end
  end
  if np.pron then r.pronoun = np.pron.form; r.needs_antecedent = true end
  if np.backref then r.backref = true; r.needs_context = true end
  if np.det then r.det = np.det end
  if np.plural then r.plural = true end
  if np.superlative then r.superlative = np.superlative end
  if np.ordinal then r.ordinal = np.ordinal end
  if np.count then r.count = np.count end
  if np.temporal_scope then r.temporal_scope = np.temporal_scope end
  if np.temporal_mod then r.temporal_mod = np.temporal_mod.text; r.temporal_mod_role = np.temporal_mod.role end
  if #np.mods > 0 then r.modifiers = U.map(np.mods, function(m) return { text = m.text, kind = m.kind } end) end
  if depth < 3 then
    if np.of_arg then r.of = ref(S, np.of_arg, depth + 1) end
    if np.possessor then r.possessor = ref(S, np.possessor, depth + 1) end
  end
  return r
end
Sem.ref = ref

---------------------------------------------------------------- run
function Sem.analyze_sentence(an, lat, lex, sent, ctx)
  ctx = ctx or {}
  local W = H.W
  local ua, ub = sentence_unit_range(an, sent.id)
  if not ua then return nil end
  local covers = lat:covers(ctx.max_covers or 3, ua, ub)
  local all, states = {}, {}
  local best_cover_score = covers[1] and covers[1].score or 0
  local meter = ctx.meter
  for ci, cover in ipairs(covers) do
    local S = P.new_state(an, lex, lat, cover, ctx)
    S.cover_index, S.cover_score = ci, cover.score
    S.sentence = sent
    states[ci] = S
    local _, wrapper = P.strip_wrapper(S)
    S.wrapper = wrapper
    local segs = Cons.find_segments(S)
    local seg_cons = Cons.parse_segments(S, segs)
    Cons.apply_masks(S, segs)
    S.segs, S.seg_cons = segs, seg_cons
    local hyps = {}
    for _, fname in ipairs(FRAME_FUNCS) do
      if meter and not meter:tick("frames", 1) then break end
      local fn = F[fname]
      if fn then fn(S, hyps) end
    end
    for _, h in ipairs(hyps) do
      h.cover_index = ci
      if ci > 1 then
        h.factors[#h.factors + 1] = { name = "segmentation", v = -1.1 * math.min(1, (best_cover_score - cover.score) / math.max(best_cover_score, 1)) - 0.1,
          note = string.format("alternative segmentation #%d (cover score %.2f vs best %.2f)", ci, cover.score, best_cover_score) }
      end
      if #seg_cons.unparsed > 0 then
        h.factors[#h.factors + 1] = { name = "unparsed_segment", v = -0.3 * #seg_cons.unparsed, note = "a negation/preference cue had no parsable target" }
      end
      H.finalize(S, ctx, h)
      if meter then meter:tick("hypotheses", 1) end
      all[#all + 1] = h
    end
  end
  if ctx.flags and ctx.flags.no_hypotheses then
    -- ablation: commit to the first hypothesis generated (no competition, no ambiguity retention)
    local first = all[1]
    all = first and { first } or {}
  end
  local sel = H.select(states[1] or {}, ctx, all)
  -- the state that owns the winning hypothesis (it carries chunks used for rendering)
  local top = sel.ranked[1]
  local S = top and states[top.cover_index] or states[1]
  if top then
    sel = H.select(S, ctx, all)
    top = sel.ranked[1]
  end
  local amb = top and H.ambiguity(S, ctx, sel) or { state = "unresolvable", points = {} }
  if ctx.flags and ctx.flags.no_hypotheses and top then amb = { state = "resolved", points = {} } end
  return { sentence = sent, S = S, states = states, covers = covers, sel = sel, ranked = sel.ranked, rejected = sel.rejected, top = top,
    ambiguity = amb, seg_cons = S and S.seg_cons or nil, n_hyps = #all }
end

---------------------------------------------------------------- rendering
local function factor_list(h)
  local out = {}
  for _, f in ipairs(h.factors) do out[#out + 1] = { factor = f.name, value = U.round(f.v, 3), note = f.note } end
  return out
end

local function relation_info(S, h)
  if not h.rel_obj then return nil end
  local r = h.rel_obj
  return { id = r.id, label = r.label, from_type = r.from, to_type = r.to, derived_from = r.derived, kind_modifier = h.kind_mod, lexicalization = r.source,
    attribute = r.attr or nil, derived_via = h.derived_via }
end

local function filter_to_constraint(S, f)
  if f.kind == "temporal_relation" then
    local ex = f.expr
    return { kind = "temporal", relation = f.rel, via = f.via, target_role = f.role, op = ex.op, eff_lo = ex.eff_lo, eff_hi = ex.eff_hi, text = ex.text, polarity = "positive" }
  elseif f.kind == "relation" then
    return { kind = "relation", relation = f.rel, target_role = f.target_role, value = ref(S, f.value), polarity = f.polarity or "positive", temporal_scope = f.adv }
  elseif f.kind == "geo" then
    return { kind = "geographic", prep = f.prep, value = ref(S, f.value), polarity = "positive" }
  elseif f.kind == "has" then
    return { kind = "has", value = ref(S, f.value), polarity = "positive" }
  end
  return { kind = f.kind }
end

local function describe_target(t)
  if not t then return nil end
  local out = { text = t.text, scope = t.scope, type = t.type, plural = t.plural, superlative = t.superlative, count = t.count, pronoun = t.pron }
  if t.cands then out.candidates = U.map(t.cands, function(c) return { id = c.id, type = c.type } end) end
  if t.of then out.of = describe_target(t.of) end
  if t.possessor then out.possessor = describe_target(t.possessor) end
  return out
end

function Sem.render(res, ctx)
  local top = res.top
  local S = res.S
  local interp = { schema = "nlu.sem/1" }
  local sent = res.sentence
  interp.sentence = { id = sent.id, text = S and S.an.original:sub(sent.s, sent.e) or "", s = sent.s, e = sent.e, terminal = sent.terminal }
  if not top then
    interp.status = "no_interpretation"
    interp.speech_act = (sent.question_mark and "question") or "unknown"
    interp.intent = "unknown"
    interp.ambiguity = { state = "unresolvable", points = {} }
    interp.hypotheses = {}
    interp.rejected_hypotheses = U.map(res.rejected or {}, function(h) return { summary = H.summarize(S, h), veto = h.veto, frame = h.frame } end)
    interp.unexplained = {}
    interp.constraints = { positive = {}, negative = {}, preferences = {}, restrictions = {}, temporal = {}, geographic = {}, source = {} }
    if S and S.seg_cons then
      for _, n in ipairs(S.seg_cons.negative) do interp.constraints.negative[#interp.constraints.negative + 1] = { cue = n.cue, text = n.scope_text, target = describe_target(n.target) } end
    end
    interp.requires_external_evidence = false
    interp.reasons = { "no construction matched the sentence" }
    return interp
  end
  interp.status = "ok"
  interp.speech_act = top.speech_act
  interp.intent, interp.op, interp.frame = top.intent, top.op, top.frame
  interp.wrapper = (S.wrapper and #S.wrapper.kinds > 0) and { kinds = S.wrapper.kinds, polite = S.wrapper.polite } or nil
  interp.relation = relation_info(S, top)
  interp.polarity = top.polarity
  interp.roles = {}
  for role, np in pairs(top.roles) do interp.roles[role] = ref(S, np) end
  if top.rel then
    interp.query = { known_role = top.known_role, ask = top.ask, answer_type = top.wh_type or top.ask_type, relation_answer_type = top.ask_type,
      answer_form = top.answer_form, dimension = top.dimension, count = top.count_target or nil }
    if top.wh then interp.query.wh = top.wh.wh end
    if top.qualifier then interp.query.qualifier = { relation = top.qualifier.rel, role = top.qualifier.role, arg = ref(S, top.qualifier.np) } end
    if top.verify then interp.query.verify = { from = ref(S, top.verify.from), to = ref(S, top.verify.to) } end
  end
  if top.concept then interp.concept = ref(S, top.concept) end
  if top.subject then interp.subject = ref(S, top.subject) end
  if top.target then interp.target = ref(S, top.target) end
  if top.focus then interp.focus = ref(S, top.focus) end
  if top.object then interp.object = ref(S, top.object); interp.task_verb = top.task_verb end
  if top.items then interp.items = U.map(top.items, function(np) return ref(S, np) end); interp.dimension = top.dimension; interp.degree = top.degree end
  if top.instruction then
    local ins = top.instruction
    interp.instruction = { verb = ins.verb, act = ins.act, slot = ins.slot, value = ins.value and { year = ins.value.year, label = ins.value.label, word = ins.value.word } or nil,
      object = ref(S, ins.np), correction = ins.correction or nil, persist = ins.persist or nil }
  end
  if top.clause then
    interp.clause = { subject = ref(S, top.clause.subj), lemma = top.clause.lemma, object = ref(S, top.clause.obj), negated = top.clause.neg or nil, voice = top.clause.voice }
  end
  if top.statement then
    local st = top.statement
    interp.statement = { subject = ref(S, st.subj), lemma = st.lemma, object = ref(S, st.obj), negated = st.neg or nil }
  end
  -- constraints -------------------------------------------------------------
  local cons = { positive = {}, negative = {}, preferences = {}, restrictions = {}, temporal = {}, geographic = {}, source = {} }
  for _, f in ipairs(top.filters or {}) do cons.positive[#cons.positive + 1] = filter_to_constraint(S, f) end
  for _, t in ipairs(top.constraints.temporal or {}) do cons.temporal[#cons.temporal + 1] = t end
  for _, g in ipairs(top.constraints.geographic or {}) do cons.geographic[#cons.geographic + 1] = { prep = g.prep, value = ref(S, g.value), text = g.text } end
  for _, s in ipairs(top.constraints.source or {}) do cons.source[#cons.source + 1] = s end
  local sc = S.seg_cons
  for _, n in ipairs(sc.negative) do
    local applies = "result_set"
    if top.op == "lookup" or top.op == "verify" then applies = "answer" end
    cons.negative[#cons.negative + 1] = { cue = n.cue, text = n.scope_text, target = describe_target(n.target), applies_to = applies,
      filters = U.map(n.target.filters or {}, function(f) return filter_to_constraint(S, f) end),
      inherits_scope = (top.op == "lookup" and n.target.scope == "description") and (top.roles[top.known_role] and ref(S, top.roles[top.known_role]).text) or nil }
  end
  for _, n in ipairs(sc.preferences) do
    cons.preferences[#cons.preferences + 1] = { cue = n.cue, text = n.scope_text, target = describe_target(n.target),
      filters = U.map(n.target.filters or {}, function(f) return filter_to_constraint(S, f) end), strength = "soft" }
  end
  for _, n in ipairs(sc.restrictions) do
    cons.restrictions[#cons.restrictions + 1] = { cue = n.cue, text = n.scope_text, resource = n.resource, label = n.label, qualifiers = n.qualifiers, mode = "only" }
  end
  -- a labelled source ("the 2020 dataset") also fixes the state of the world being asked about, softly and with provenance
  if #cons.temporal == 0 then
    for _, s in ipairs(cons.source) do
      if s.label_year then
        cons.temporal[#cons.temporal + 1] = { kind = "as_of", year = s.label_year, text = s.label, role = "derived", basis = "source_label", strength = "soft",
          eff_lo = s.label_year * 10000 + 101, eff_hi = s.label_year * 10000 + 1231 }
        top.temporal_scope = top.temporal_scope or "as_of_source"
        break
      end
    end
  end
  interp.constraints = cons
  if top.ordering then interp.ordering = top.ordering end
  interp.temporal_scope = top.temporal_scope or ((#cons.temporal == 0) and (top.op == "lookup" or top.op == "describe") and "current_unspecified") or nil
  interp.persist = top.persist or nil
  interp.unexplained = U.map(top.unexplained or {}, function(k) return S.chunks[k].text end)
  -- context dependencies -----------------------------------------------------
  local deps = {}
  local function scan_dep(np)
    if not np then return end
    if np.head_kind == "pronoun" then deps[#deps + 1] = { kind = "pronoun", text = P.span_text(S, np), pronoun = np.pron.form } end
    if np.backref then deps[#deps + 1] = { kind = "backref", text = P.span_text(S, np) } end
    if np.ordinal and np.head_kind ~= "temporal" then deps[#deps + 1] = { kind = "ordinal_reference", text = P.span_text(S, np), ordinal = np.ordinal } end
    if np.of_arg then scan_dep(np.of_arg) end
    if np.possessor then scan_dep(np.possessor) end
  end
  for _, np in pairs(top.roles) do scan_dep(np) end
  scan_dep(top.concept); scan_dep(top.subject); scan_dep(top.target); scan_dep(top.focus); scan_dep(top.object)
  for _, it in ipairs(top.items or {}) do scan_dep(it) end
  if top.statement then scan_dep(top.statement.subj); scan_dep(top.statement.obj) end
  if top.instruction then scan_dep(top.instruction.np) end
  interp.dependencies = deps
  interp.requires_external_evidence = top.requires_evidence == true
  interp.requires_context = top.requires_context or nil
  -- hypotheses with provenance -------------------------------------------------
  interp.hypotheses = {}
  for i, h in ipairs(res.ranked) do
    if i > 6 then break end
    interp.hypotheses[#interp.hypotheses + 1] = { rank = i, summary = H.summarize(S, h), p = U.round(h.p, 4), score = U.round(h.score, 3), frame = h.frame,
      coverage = U.round(h.coverage or 0, 3), factors = factor_list(h), agreeing_frames = h.agreeing_frames }
  end
  interp.rejected_hypotheses = {}
  for i, h in ipairs(res.rejected) do
    if i > 8 then break end
    interp.rejected_hypotheses[#interp.rejected_hypotheses + 1] = { summary = H.summarize(S, h), frame = h.frame, veto = h.veto }
  end
  interp.ambiguity = res.ambiguity
  interp.confidence = { semantic_raw = U.round(top.p, 4), coverage = U.round(top.coverage or 0, 3) }
  -- provenance: the computed factors of the winning hypothesis, plus explicit rejections
  local prov = {}
  for _, f in ipairs(top.factors) do prov[#prov + 1] = { step = f.name, detail = f.note, value = U.round(f.v, 3) } end
  for _, rj in ipairs(interp.rejected_hypotheses) do prov[#prov + 1] = { step = "rejected", detail = rj.summary .. " -- " .. tostring(rj.veto) } end
  interp.provenance = prov
  return interp
end

return Sem
