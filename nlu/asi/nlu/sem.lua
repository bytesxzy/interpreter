-- asi.nlu.sem: semantic interpretation of one sentence.
--   lattice covers (segmentation alternatives) x frames (constructions) -> competing hypotheses -> bounded selection.
-- Output is a plain, serialisable table (see Sem.render); every number in its provenance is a computed factor.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local Cons = require("asi.nlu.constraints")
local H = require("asi.nlu.hyp")
local F = require("asi.nlu.frames2")
require("asi.nlu.frames3")   -- registers the stranded-preposition, quantity, list and support-verb yes/no frames on the same table
require("asi.nlu.frames4")   -- attribution idioms, locus hosts, "where can I find", generic-subject holders

local Sem = {}

local FRAME_FUNCS = { "wh_copular", "wh_verb", "wh_do", "wh_passive", "wh_adverbial", "where_support", "wh_support_as", "wh_support_subject", "wh_role_holder", "wh_relnoun_stranded", "wh_pred_stranded", "wh_relnoun_same_pred", "wh_identity_person", "wh_credit", "wh_locus_host", "where_find", "wh_adj_predicate", "ellipsis", "compare_differences", "compare_which_of_two", "wh_impersonal", "wh_origin", "what_does_do", "quantity_q", "how_adj_relnoun", "list_relative", "yes_no_support", "existential_search", "style_instruction", "resource_directive", "yes_no", "wh_change", "compare_q",
  "request", "instruction", "exclusion_clause", "focus", "statement", "np_only", "segment_only", "recall", "what_means", "generic_holder" }

local function sentence_unit_range(an, sid)
  local r = an._ranges
  if not r then
    r = {}
    for i, u in ipairs(an.units) do
      local e = r[u.sent]
      if not e then r[u.sent] = { i, i } else e[2] = i end
    end
    an._ranges = r
  end
  local e = r[sid]
  if e then return e[1], e[2] end
end
Sem.sentence_unit_range = sentence_unit_range

---------------------------------------------------------------- rendering of arguments
local function ref(S, np, depth)
  depth = depth or 0
  if not np then return nil end
  local r = { text = P.span_text(S, np), kind = np.head_kind, span = { S.units[np.u1].s, S.units[np.u2].e }, chunk_range = { np.c1, np.c2 } }
  -- "the company Apple", "CEO Dana Whitcombe": type nouns and titles in front of a name classify it; the mention is the name itself
  if np.head_kind == "entity" and np.head and np.head.u1 > np.u1 and #(np.mods or {}) > 0 then
    local all_cls = true
    for _, md in ipairs(np.mods) do
      local mc = md.chunk
      if not (md.kind == "mod" and mc and ((mc.senses and #mc.senses > 0) or (mc.relnouns and #mc.relnouns > 0))) then all_cls = false end
    end
    if all_cls then
      local first_mod = np.mods[1].chunk
      r.classifier = S.an.original:sub(S.units[first_mod.u1].s, S.units[np.head.u1 - 1].e)
      r.text = S.an.original:sub(S.units[np.head.u1].s, S.units[np.u2].e)
    end
  end
  -- "the country called Tavoria", "the city of Paris": the type noun classifies the name; the mention is the name itself
  if np.type_noun and np.head and np.head.u1 > np.u1 and not r.classifier then
    r.classifier = S.an.original:sub(S.units[np.u1].s, S.units[np.head.u1 - 1].e)
    r.text = S.an.original:sub(S.units[np.head.u1].s, S.units[np.u2].e)
  end
  if np.head then r.head = np.head.form end
  r.core = P.core_text(S, np)
  -- a multiword capitalised name without organisation / place cues is probably a person's name (weak evidence for animate pronouns)
  if np.head_kind == "entity" and np.head and np.head.names and np.head.names[1] then
    local nm = np.head.names[1]
    if nm.multiword and not nm.head_cue and not nm.type_guess then r.pname = true end
  end
  local b = np.bound
  if b and b.deictic then r.deictic = b.deictic end
  if b and (b.expletive or b.indefinite) then r.non_anaphoric = b.expletive and "expletive" or "indefinite" end
  if b and b.antecedent then r.antecedent = b.antecedent end
  if b then
    r.status = b.status
    if b.top then
      if b.top.weak then r.weak_name = true end
      if b.status == "resolved" or b.status == "unseen" then r.resolved_id, r.type = b.top.id, b.top.type
      else r.leading_candidate = b.top.id end -- ambiguous: a leading candidate is NOT a resolution
    end
    r.type = r.type or b.type
    if b.itype and not r.type then r.itype = b.itype end
    if b.cands and #b.cands > 0 then
      r.candidates = U.map(b.cands, function(c) return { id = c.id, type = c.type, name = c.name, p = c.p, score = c.score, reasons = c.reasons, unseen = c.unseen or nil, weak = c.weak or nil, fuzzy = c.fuzzy } end)
    end
    if b.rejected and #b.rejected > 0 then
      r.rejected = U.map(b.rejected, function(c) return { id = c.id, type = c.type, reason = c.reasons[#c.reasons] } end)
    end
    if b.senses then r.senses = U.map(b.senses, function(s) return { id = s.id, type = s.type, gloss = s.gloss } end) end
  end
  if np.head_kind == "var" then r.status, r.type, r.result_of_step = "chain_variable", np.type, np.step; r.var = np.var end
  if np.pron then
    r.pronoun = np.pron.form
    r.needs_antecedent = not (b and (b.deictic or b.expletive or b.indefinite or b.status == "resolved"))
    if b and b.topic_bound then r.topic_bound = true end
    if b and b.discourse and b.status ~= "resolved" and not b.deictic then r.antecedent_reason = b.none_reason end
  end
  if np.backref then r.backref = true; r.needs_context = true; r.backref_who = np.backref_who end
  if np.head_kind == "ordinal_ref" then r.ordinal_ref = true; r.needs_context = true end
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
Sem.SUFFIX_TRIGGER = 1.0
Sem.REPORT_WORDS = U.set({ "she", "he", "they", "someone", "somebody", "people", "told", "asked", "said", "says", "wants", "wanted", "suggested", "recommended", "thinks", "thought",
  "claims", "claimed", "insists", "insisted", "advised", "reminded", "mentioned" })
Sem.WEAK_INTENTS = { definition = true, entity_description = true, statement = true, unknown = true, explanation = true }
local SUFFIX_JOINERS = U.set({ "but", "so", "and", "then", "because", "that", "whether", "while", "though", "although" })
-- chunk indices (after the sentence's first chunk) where a new clause may start: after a comma / colon / dash / semicolon, after a joiner, or after "to" before a verb
function Sem.clause_starts(S)
  local out = {}
  for k = S.first + 1, S.last - 1 do
    local c, pc = S.chunks[k], S.chunks[k - 1]
    if c and not c.masked then
      local boundary = c.pre and (c.pre:find("comma") or c.pre:find("colon") or c.pre:find("dash") or c.pre:find("semi"))
      if not boundary and pc and pc.single and not pc.masked and SUFFIX_JOINERS[pc.unit.form] then boundary = true end
      if not boundary and pc and pc.single and not pc.masked and pc.unit.form == "to" and c.verbs then boundary = true end
      if boundary then out[#out + 1] = k end
    end
  end
  -- the later clauses are the likelier request; keep at most three
  while #out > 3 do table.remove(out, 1) end
  return out
end

function Sem.analyze_sentence(an, lat, lex, sent, ctx)
  ctx = ctx or {}
  local W = H.W
  local ua, ub = sentence_unit_range(an, sent.id)
  if not ua then return nil end
  local covers = lat:covers(ctx.max_covers or 3, ua, ub)
  local all, states = {}, {}
  local best_cover_score = covers[1] and covers[1].score or 0
  local meter = ctx.meter
  -- the repair variant of the best cover (misspelled function words, filler words) competes as one more reading, at an explicit cost
  local run_covers = {}
  for ci, cover in ipairs(covers) do run_covers[ci] = cover end
  if covers[1] and not (ctx.flags and ctx.flags.no_repair) then
    local rc = P.repair_cover(lex, an.units, covers[1], an.original)
    if rc then run_covers[#run_covers + 1] = rc end
  end
  for ci, cover in ipairs(run_covers) do
    local an_s = an
    if cover.units then an_s = setmetatable({ units = cover.units }, { __index = an }) end   -- repaired reading: corrected unit forms
    local S = P.new_state(an_s, lex, lat, cover, ctx)
    S.cover_index, S.cover_score = ci, cover.score
    S.repairs = cover.repairs
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
    -- a clause asked for confirmation ("..., right?", "Is it true that ...") whose reading is a relational statement is the verification of that statement
    if S.polar then
      for _, h in ipairs(hyps) do
        if h.speech_act == "statement" and h.rel and h.rel_obj and h.roles and h.roles.from and h.roles.to and not h.verify then
          h.speech_act, h.intent, h.op = "question", "verification", "verify"
          h.requires_evidence = true
          h.verify = { rel = h.rel, from = h.roles.from, to = h.roles.to }
          h.items = (h.roles.from.u1 or 0) < (h.roles.to.u1 or 0) and { h.roles.from, h.roles.to } or { h.roles.to, h.roles.from }
          h.factors[#h.factors + 1] = { name = "polar_confirmation", v = 0.3, note = "the clause is asked for confirmation (wrapper or tag question)" }
        end
      end
    end
    for _, h in ipairs(hyps) do
      h.cover_index = ci
      if cover.repair then
        local cost = 0
        for _, r in ipairs(cover.repairs) do
          -- an explicit, bounded price per repair: lower for a near-certain closed-class correction, higher for a doubtful content-word guess
          local base = (r.kind == "ignored" and 0.15) or (r.kind == "function_word" and 0.08) or 0.18
          cost = cost + base + 0.5 * (1 - (r.conf or 0.6))
        end
        h.factors[#h.factors + 1] = { name = "repair", v = -cost, note = "reading after repairs: " .. table.concat(U.map(cover.repairs, function(r)
          return r.kind ~= "ignored" and string.format("'%s' read as '%s'", r.from, r.to) or string.format("'%s' ignored", r.word) end), "; ") }
      elseif ci > 1 then
        h.factors[#h.factors + 1] = { name = "segmentation", v = -1.1 * math.min(1, (best_cover_score - cover.score) / math.max(best_cover_score, 1)) - 0.1,
          note = string.format("alternative segmentation #%d (cover score %.2f vs best %.2f)", ci, cover.score, best_cover_score) }
      end
      if sent.question_mark and h.speech_act == "statement" then
        h.factors[#h.factors + 1] = { name = "question_mark_vs_statement", v = -0.9, note = "the sentence ends with '?' but this reading is a declarative statement" }
      end
      if #seg_cons.unparsed > 0 then
        h.factors[#h.factors + 1] = { name = "unparsed_segment", v = -0.3 * #seg_cons.unparsed, note = "a negation/preference cue had no parsable target" }
      end
      H.finalize(S, ctx, h)
      if meter then meter:tick("hypotheses", 1) end
      all[#all + 1] = h
    end
  end
  -- Clause-suffix readings.  When no reading of the whole sentence is good, a clause that starts after a comma / "but" / "so" / "to" may be the request or
  -- question proper ("Sorry to loop back, but who is the CEO of ...?", "Time to find some organisations ...").  Everything before it is then explicitly
  -- unexplained (it counts against the reading like any other unexplained content), so a suffix reading wins only when the whole-sentence readings are poor.
  if not (ctx.flags and ctx.flags.no_suffix) and covers[1] and states[1] then
    local best, best_h = -math.huge, nil
    for _, h in ipairs(all) do if h.score > best then best, best_h = h.score, h end end
    -- only when the best whole-sentence reading is a fallback kind of reading (a bare definition / description / statement) or a poor one
    if best_h == nil or Sem.WEAK_INTENTS[best_h.intent or "?"] or best < Sem.SUFFIX_TRIGGER then
      local cover = covers[1]
      local an_s = an
      local S1 = states[1]
      for si, p in ipairs(Sem.clause_starts(S1)) do
        if meter and not meter:tick("frames", 1) then break end
        local S2 = P.new_state(an_s, lex, lat, cover, ctx)
        S2.cover_index, S2.cover_score, S2.sentence = 1, cover.score, sent
        S2.first = p
        S2.prefix_chunks = {}
        for k = S1.first, p - 1 do
          local ck = S2.chunks[k]
          if ck and not P.is_function_chunk(S2, ck) then S2.prefix_chunks[#S2.prefix_chunks + 1] = ck end
        end
        -- "She told me to switch to the 2021 edition": an instruction reported from a third party is not an instruction to the system
        local reported_prefix = false
        for k = S1.first, p - 1 do
          local ck = S2.chunks[k]
          local f = ck and ck.single and ck.unit and ck.unit.form
          if f and Sem.REPORT_WORDS[f] then reported_prefix = true end
        end
        local key = 100 + si
        states[key] = S2
        local _, wrapper = P.strip_wrapper(S2)
        S2.wrapper = wrapper
        local segs = Cons.find_segments(S2)
        local seg_cons = Cons.parse_segments(S2, segs)
        Cons.apply_masks(S2, segs)
        S2.segs, S2.seg_cons = segs, seg_cons
        local hyps = {}
        for _, fname in ipairs(FRAME_FUNCS) do
          local fn = F[fname]
          if fn then fn(S2, hyps) end
        end
        for hi = #hyps, 1, -1 do
          local hh = hyps[hi]
          if reported_prefix and (hh.intent == "instruction_update" or hh.instruction) then table.remove(hyps, hi) end
        end
        for _, h in ipairs(hyps) do
          h.cover_index = key
          h.factors[#h.factors + 1] = { name = "clause_suffix", v = -0.15, note = "reading of the clause that starts at '" .. tostring(S2.chunks[p] and S2.chunks[p].text) .. "'; the words before it are not explained" }
          if #seg_cons.unparsed > 0 then
            h.factors[#h.factors + 1] = { name = "unparsed_segment", v = -0.3 * #seg_cons.unparsed, note = "a negation/preference cue had no parsable target" }
          end
          H.finalize(S2, ctx, h)
          -- a clause reading is only justified when it explains clearly MORE of the sentence than the whole-sentence reading did
          if best_h and (h.coverage or 0) < (best_h.coverage or 0) + 0.15 then
            h.factors[#h.factors + 1] = { name = "suffix_explains_no_more", v = -1.0, note = "the clause reading does not explain more of the sentence than the whole-sentence reading" }
            h.score = h.score - 1.0
          end
          if meter then meter:tick("hypotheses", 1) end
          all[#all + 1] = h
        end
      end
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
    H.rebind(S, ctx, top)   -- NP bindings are shared between hypotheses: restore the winner's own before rendering / auditing
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
  -- a question put politely ("Could you tell me who ...", "I want to know ...") is a request for the answer
  if interp.speech_act == "question" and S.wrapper then
    for _, k in ipairs(S.wrapper.kinds) do if k == "polite_question" or k == "request_open" then interp.speech_act = "request" end end
  end
  interp.intent, interp.op, interp.frame = top.intent, top.op, top.frame
  interp.wrapper = (S.wrapper and #S.wrapper.kinds > 0) and { kinds = S.wrapper.kinds, polite = S.wrapper.polite } or nil
  interp.relation = relation_info(S, top)
  if S.topic then
    H.bind_np(S, ctx or {}, S.topic, nil, nil, "topic")
    interp.topic = ref(S, S.topic)
  end
  interp.polarity = top.polarity
  interp.roles = {}
  for role, np in pairs(top.roles) do interp.roles[role] = ref(S, np) end
  -- the asked role carries the wh-noun when there is one ("Which claims ..."): it constrains the answer, it is not a known argument
  if top.wh and top.wh.np and not top.wh.relnoun and top.ask and not interp.roles[top.ask] then
    interp.roles[top.ask] = ref(S, top.wh.np)
    interp.roles[top.ask].asked = true
  end
  if top.rel then
    -- the answer type is the narrower of the wh-type ("who" -> agent) and the relation's range type (person)
    local answer_type = top.wh_type or top.ask_type
    if top.wh_type and top.ask_type and S.lex:compat(top.ask_type, top.wh_type) >= 0.9 then answer_type = top.ask_type end
    -- "How many moons does Neptune have?" asks for a NUMBER of moons, not for moons
    if top.answer_form == "number" then answer_type = "number" end
    interp.query = { known_role = top.known_role, ask = top.ask, answer_type = answer_type, relation_answer_type = top.ask_type,
      answer_form = top.answer_form, dimension = top.dimension, count = top.count_target or nil }
    if top.wh then interp.query.wh = top.wh.wh end
    if top.chain then
      interp.query.chain, interp.query.steps = {}, {}
      for i, st in ipairs(top.chain) do
        interp.query.chain[#interp.query.chain + 1] = st.rel
        interp.query.steps[#interp.query.steps + 1] = { index = i, relation = st.rel, known_role = st.known_role, known = ref(S, st.known), ask_role = st.ask_role,
          result_var = "?" .. i, result_type = st.result_type }
      end
      interp.query.chain[#interp.query.chain + 1] = top.rel
    end
    if top.qualifier then interp.query.qualifier = { relation = top.qualifier.rel, role = top.qualifier.role, arg = ref(S, top.qualifier.np) } end
    if top.verify then interp.query.verify = { from = ref(S, top.verify.from), to = ref(S, top.verify.to) } end
  end
  if top.basis then interp.basis = ref(S, top.basis.np); interp.basis_cue = top.basis.cue end
  if top.recall then
    interp.recall = { verb = top.recall.verb, wh = top.recall.wh, participant = top.recall.participant, topic = ref(S, top.recall.topic) }
    interp.subject = interp.subject or ref(S, top.recall.topic)
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
  -- a future copula chunk ("Who WILL BE the CEO ...?") marks the question as about the future when no explicit time expression says so
  if not top.temporal_scope and #cons.temporal == 0 then
    for k in pairs(top.used or {}) do
      local ck = S.chunks[k]
      if ck and ck.future then top.temporal_scope = "future"; break end
    end
  end
  interp.temporal_scope = top.temporal_scope or ((#cons.temporal == 0) and (top.op == "lookup" or top.op == "describe") and "current_unspecified") or nil
  -- grammatical tense of the question's own predicate ("was the capital" -> past); "did" is neutral
  do
    local past = false
    for k in pairs(top.used) do
      local c = S.chunks[k]
      if c and c.single then
        local f = c.unit.form
        if f == "was" or f == "were" or f == "had" then past = true end
      end
    end
    interp.tense = past and "past" or "present"
  end
  interp.persist = top.persist or nil
  interp.unexplained = U.map(top.unexplained or {}, function(k) return S.chunks[k].text end)
  -- context dependencies -----------------------------------------------------
  local deps = {}
  local function scan_dep(np)
    if not np then return end
    local person = np.pron and tostring(np.pron.feats and np.pron.feats.person or "3")
    if np.head_kind == "pronoun" and person ~= "1" and person ~= "2" and not (np.bound and (np.bound.deictic or np.bound.expletive or np.bound.indefinite)) then deps[#deps + 1] = { kind = "pronoun", text = P.span_text(S, np), pronoun = np.pron.form } end
    if np.backref then deps[#deps + 1] = { kind = "backref", text = P.span_text(S, np) } end
    if np.ordinal and np.head_kind ~= "temporal" then deps[#deps + 1] = { kind = "ordinal_reference", text = P.span_text(S, np), ordinal = np.ordinal } end
    if np.of_arg then scan_dep(np.of_arg) end
    if np.possessor then scan_dep(np.possessor) end
  end
  for _, np in pairs(top.roles) do scan_dep(np) end
  scan_dep(top.concept); scan_dep(top.subject); scan_dep(top.target); scan_dep(top.focus); scan_dep(top.object)
  if top.recall then deps[#deps + 1] = { kind = "conversation_history", text = interp.sentence.text } end
  if top.ellipsis then deps[#deps + 1] = { kind = "previous_question", text = interp.sentence.text, turn = top.ellipsis.turn } end
  if top.basis then scan_dep(top.basis.np) end
  if top.intent == "comparison" and (not top.items or #top.items < 2) then deps[#deps + 1] = { kind = "comparison_set", text = interp.sentence.text } end
  for _, it in ipairs(top.items or {}) do scan_dep(it) end
  if top.statement then scan_dep(top.statement.subj); scan_dep(top.statement.obj) end
  if top.instruction then scan_dep(top.instruction.np) end
  if top.clause then scan_dep(top.clause.subj); scan_dep(top.clause.obj) end
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
  do
    -- lexical evidence about the surface: words the lexicon does not know (lower-case ones are the usual symptom of a misspelling)
    local ua, ub = sentence_unit_range(S.an, res.sentence.id)
    local unk_lower, unk_cap = 0, 0
    if ua then
      for k = ua, ub do
        local u = S.an.units[k]
        if u.unknown then if u.cap then unk_cap = unk_cap + 1 else unk_lower = unk_lower + 1 end end
      end
    end
    interp.lexical = { unknown_lowercase = unk_lower, unknown_capitalised = unk_cap }
  end
  if S.repairs then interp.repairs = U.map(S.repairs, function(r) return { kind = r.kind, from = r.from, to = r.to, word = r.word, dist = r.dist } end) end
  -- provenance: the computed factors of the winning hypothesis, plus explicit rejections
  local prov = {}
  for _, f in ipairs(top.factors) do prov[#prov + 1] = { step = f.name, detail = f.note, value = U.round(f.v, 3) } end
  for _, rj in ipairs(interp.rejected_hypotheses) do prov[#prov + 1] = { step = "rejected", detail = rj.summary .. " -- " .. tostring(rj.veto) } end
  interp.provenance = prov
  return interp
end

return Sem
