-- asi.nlu.assertions: record text -> typed assertions.
-- The extractor reuses the interpreter's lexicon and parse primitives, so a paraphrase in the data ("X founded Y", "Y was started by X", "the founder of
-- Y is X") lands on the SAME relation id and role direction as the question that will be asked about it.  Output per assertion:
--   rel, from, to (entity {key,type,status} or literal), polarity, modality, tense, former/current markers, validity interval or event time,
--   provenance (record, sentence, byte span).  Sentences that address the reader (imperatives, injection cues) are NEVER mined for facts.
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Lattice = require("asi.nlu.lattice")
local P = require("asi.nlu.parse")
local H = require("asi.nlu.hyp")
local F = require("asi.nlu.frames2")
local Sem = require("asi.nlu.sem")

local A = {}
A.__index = A

local function C(S, k) return S.chunks[k] end
local function barrier(c) return c ~= nil and c.pre ~= nil end
local function other(role) return role == "to" and "from" or "to" end
local cat = P.cat

function A.new(lex, opts)
  opts = opts or {}
  return setmetatable({ lex = lex, meter = opts.meter, max_sentence_units = opts.max_sentence_units or 160 }, A)
end

---------------------------------------------------------------- binding a parsed NP to an entity / literal descriptor
local LITERAL_KINDS = { number = true, temporal = true, quote = true, literal = true }

local function describe_np(S, ctx, np, expected, role)
  if not np then return nil end
  if LITERAL_KINDS[np.head_kind] then
    local c = np.head
    local lit = { kind = np.head_kind, text = P.span_text(S, np) }
    if np.head_kind == "number" and c.number then lit.value = c.number.value; lit.unit = c.number.unit end
    if np.head_kind == "temporal" and c.temporal then lit.lo, lit.hi, lit.year = c.temporal.eff_lo or c.temporal.lo, c.temporal.eff_hi or c.temporal.hi, c.temporal.year end
    local d = { literal = lit, text = lit.text, type = np.head_kind == "number" and "number" or (np.head_kind == "temporal" and "date" or "text") }
    if expected and S.lex:compat(d.type, expected) == -1.0 then d.type_clash = true end
    return d
  end
  if np.head_kind == "pronoun" then
    -- inside a record, a subject pronoun refers to the record topic (title entity) or the previous sentence's subject, if it agrees in animacy
    local t = ctx.topic
    local feats = np.pron and np.pron.feats or {}
    if t and t.key and not (feats.person == "1" or feats.person == "2") then
      local person_like = t.type and S.lex:isa(t.type, "person")
      local an = tostring(feats.animate or "any")
      local ok = not ((an == "1" and t.type and not person_like) or (an == "0" and person_like))
      if ok then return { key = t.key, text = t.text, type = t.type, status = "resolved_by_topic", via_pronoun = np.pron.form } end
    end
    return { text = P.span_text(S, np), status = "pronoun", head_kind = "pronoun" }
  end
  local b = H.bind_np(S, ctx, np, expected, nil, role)
  local d = { text = P.span_text(S, np), type = b.type or (b.top and b.top.type), status = b.status, head_kind = np.head_kind }
  if b.top and (b.status == "resolved" or b.status == "unseen") then d.key = b.top.id
  elseif b.status == "ambiguous" then
    d.cands = U.map(b.cands or {}, function(c) return { id = c.id, type = c.type, p = c.p } end)
    d.key = nil
  elseif (np.head_kind == "typenoun" or np.head_kind == "concept") and b.senses and b.senses[1] then
    -- concepts are keyed by their lexicon sense, so "capital punishment" in a record and in a question meet at the same key
    d.key = "sense:" .. b.senses[1].id
    d.status = "concept"
    d.type = b.senses[1].type
    d.term = P.core_text(S, np)
  elseif np.head_kind == "typenoun" or np.head_kind == "concept" or np.head_kind == "unknown" then
    d.key = "term:" .. P.core_text(S, np)
    d.status = "term"
  end
  if np.head_kind == "entity" and b.fit == -1.0 then d.type_clash = true end
  return d
end

A.describe_np = describe_np

---------------------------------------------------------------- qualifiers
local function qualifier_range(S, a)
  -- chunks that qualify THIS assertion: a fronted adverbial before the subject, and what follows the object up to the next comma-delimited clause
  local keep = {}
  local first_used = a.used_np[1].c1
  for _, np in ipairs(a.used_np) do if np.c1 < first_used then first_used = np.c1 end end
  for k = S.first, first_used - 1 do keep[k] = true end
  local start = a.end_chunk or (S.last + 1)
  for k = start, S.last do
    local c = C(S, k)
    if c and c.pre and c.pre:find("comma") and not c.temporal then break end
    keep[k] = true
  end
  for k = S.lead_first or S.first, S.first - 1 do keep[k] = true end
  -- the predicate (copula / verb / negation) sits between the NPs
  for k = S.first, S.last do
    if a.copula and a.copula.used[k] then keep[k] = true end
    if a.vp and k >= a.vp.c1 and k <= a.vp.c2 then keep[k] = true end
  end
  for _, k in ipairs(a.copula and a.copula.skipped or {}) do keep[k] = true end
  return keep
end

local function qualifiers(self, S, used, info)
  local q = { polarity = info.neg and "negative" or "positive", modality = "asserted", tense = info.tense or "present", former = info.former }
  local lex = S.lex
  for k = S.lead_first or S.first, S.last do
    local c = C(S, k)
    if c and not c.masked and info.range[k] then
      if not used[k] then
        if P.is_neg(c) or (c.single and (c.unit.form == "never")) then q.polarity = "negative"
        elseif c.temporal then
          local t = c.temporal
          if t.kind == "marker" then
            local w = (t.text or c.form or ""):lower()
            if w == "formerly" or w == "previously" or w == "once" or w == "originally" or w == "historically" or w == "recently" and false then q.former = true end
            if w == "currently" or w == "now" or w == "today" or w == "presently" or w == "still" then q.current = true end
          else
            local lo, hi = t.eff_lo or t.lo, t.eff_hi or t.hi
            local op = t.op
            q.temporal = q.temporal or {}
            q.temporal[#q.temporal + 1] = { op = op or "in", lo = lo, hi = hi, year = t.year, text = t.text or c.form, kind = t.kind }
          end
          used[k] = true
        elseif lex:cue_at("hedge", S.units, c.u1) then q.modality = "hedged"
        elseif lex:cue_at("conditional", S.units, c.u1) then q.modality = "hypothetical" end
      end
    end
  end
  -- "no longer" marks an ended state
  for i = 1, #S.units - 1 do
    if S.units[i].form == "no" and S.units[i + 1].form == "longer" and S.units[i].sent == S.sentence.id then q.former = true; q.polarity = "positive" end
  end
  return q
end

-- turn raw temporal qualifiers into a validity interval (state relations) or an event time (event relations)
local function apply_time(a, q, rel_obj, lex)
  a.former, a.current, a.tense = q.former, q.current, q.tense
  local event = rel_obj and rel_obj.when ~= nil
  for _, t in ipairs(q.temporal or {}) do
    local op = t.op
    if event then
      -- "founded in 1999": the relation (founder) is not limited to 1999, the EVENT happened then
      a.event_time = a.event_time or { lo = t.lo, hi = t.hi, year = t.year, text = t.text, op = op }
    elseif op == "since" or op == "from" then a.valid_from = a.valid_from or t.lo
    elseif op == "until" or op == "till" or op == "to" then a.valid_to = a.valid_to or t.hi
    elseif op == "from_to" or op == "between" then a.valid_from, a.valid_to = t.lo, t.hi
    elseif op == "by" then a.valid_to = a.valid_to or t.hi
    elseif op == "after" then a.valid_from = a.valid_from or t.lo
    elseif op == "before" then a.valid_to = a.valid_to or (t.lo and t.lo - 1) or t.hi
    elseif op == "as_of" then a.as_of = { lo = t.lo, hi = t.hi, year = t.year, text = t.text }
    else a.valid_at = { lo = t.lo, hi = t.hi, year = t.year, text = t.text } end
  end
  if a.former and not a.valid_to and not a.valid_at then a.ended = true end
end

---------------------------------------------------------------- patterns
local COPULA = U.set({ "is", "are", "was", "were", "be", "been", "being" })
local function copula_at(S, k)
  local c = C(S, k)
  if not (c and c.single and not c.masked) then return nil end
  local f = c.unit.form
  local past = (f == "was" or f == "were" or f == "had")
  local nxt, neg, used = k + 1, false, { [k] = true }
  local j = k + 1
  if cat(c, "aux_have") and (f == "has" or f == "have" or f == "had") then
    -- "has been" / "had been": a perfect copula
    local b = C(S, k + 1)
    if b and b.single and b.unit.form == "been" and not barrier(b) then used[k + 1] = true; j = k + 2 else return nil end
  elseif not (cat(c, "aux_be") or cat(c, "clitic_s")) then return nil end
  local skipped, former = {}, false
  while C(S, j) and C(S, j).single and not barrier(C(S, j)) and (P.is_neg(C(S, j)) or cat(C(S, j), "adv") or (C(S, j).temporal and C(S, j).temporal.kind == "marker")
    or (C(S, j).unit.form == "no" and C(S, j + 1) and C(S, j + 1).unit.form == "longer")) do
    if C(S, j).unit.form == "no" then former = true; used[j] = true; used[j + 1] = true; j = j + 1
    elseif P.is_neg(C(S, j)) then neg = true; used[j] = true
    elseif C(S, j).temporal then skipped[#skipped + 1] = j
    else used[j] = true end
    j = j + 1
  end
  return { nxt = j, neg = neg, past = past, used = used, form = f, skipped = skipped, former = former }
end

-- positions where the predicate may start after a subject NP ending at chunk `nxt`: directly, or after a comma-delimited appositive
-- ("France, officially the French Republic, is ...")
local function predicate_positions(S, nxt)
  local out = { nxt }
  local c = C(S, nxt)
  if c and c.pre and c.pre:find("comma") then
    for j = nxt + 1, math.min(#S.chunks, nxt + 10) do
      local cj = C(S, j)
      if cj and cj.pre and cj.pre:find("comma") then out[#out + 1] = j break end
    end
  end
  return out
end

-- X BE (the|a)? RELNP-of-Y        |    RELNP-of-Y BE X       |    Y's RELNOUN BE X
local function copular_relational(self, S, ctx, out)
  local k = S.first
  for _, snp in ipairs(P.parse_np(S, k)) do
   for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
    local cp = copula_at(S, pos)
    if cp then
      -- (1) subject is the value, complement is the relational NP
      for _, rnp in ipairs(P.parse_np(S, cp.nxt)) do
        if rnp.head_kind == "relnoun" then
          for _, o in ipairs(F.relnp_options(S, rnp)) do
            if o.arg and o.rel then
              local a = { rel = o.rel.id, rel_obj = o.rel, pattern = "copular_relnp", used_np = { snp, rnp }, neg = cp.neg, tense = cp.past and "past" or "present", copula = cp }
              a.roles = { [o.ask_role] = snp, [o.known_role] = o.arg }
              a.end_chunk = rnp.nxt
              out[#out + 1] = a
            end
          end
        end
      end
      -- (2) subject is the relational NP, complement is the value
      if snp.head_kind == "relnoun" then
        for _, o in ipairs(F.relnp_options(S, snp)) do
          if o.arg and o.rel then
            for _, vnp in ipairs(P.parse_np(S, cp.nxt)) do
              local a = { rel = o.rel.id, rel_obj = o.rel, pattern = "copular_value", used_np = { snp, vnp }, neg = cp.neg, tense = cp.past and "past" or "present", copula = cp }
              a.roles = { [o.known_role] = o.arg, [o.ask_role] = vnp }
              a.end_chunk = vnp.nxt
              out[#out + 1] = a
            end
          end
        end
      end
    end
   end
  end
end

-- Subject VERB Object  (active / passive-by / verb+prep), via the lexicon's role-directed relation verbs
local function verb_relational(self, S, ctx, out)
  local lex = S.lex
  for _, snp in ipairs(P.parse_np(S, S.first)) do
   for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
    for _, vp in ipairs(P.parse_vp(S, pos)) do
      for _, e in ipairs(vp.analysis.entries) do
        local rel = lex:get_rel(e.rel)
        if rel then
          local k = vp.nxt
          local patient_first = vp.voice == "passive" and not e.prep
          if e.prep then
            local pc = C(S, k)
            if pc and pc.single and pc.unit.form == e.prep and not pc.masked then k = k + 1 else k = nil end
          elseif vp.voice == "passive" then
            local bc = C(S, k)
            if bc and bc.single and bc.unit.form == "by" and not bc.masked then k = k + 1 else k = nil end
          end
          if k then
            for _, onp in ipairs(P.parse_np(S, k)) do
              local a = { rel = rel.id, rel_obj = rel, pattern = vp.voice == "passive" and "passive_by" or "svo", used_np = { snp, onp }, neg = vp.neg,
                tense = (vp.vform == "past" or vp.perfect) and "past" or "present", vp = vp }
              if patient_first or (e.prep == nil and vp.voice == "passive") then
                a.roles = { [other(e.subj)] = snp, [e.subj] = onp }
              else
                a.roles = { [e.subj] = snp, [other(e.subj)] = onp }
              end
              a.end_chunk = onp.nxt
              out[#out + 1] = a
            end
          end
        end
      end
    end
   end
  end
end

-- X has/had a RELNOUN of VALUE   ("France has a population of 68 million")
local function have_attribute(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    local hc = C(S, snp.nxt)
    if hc and hc.single and not hc.masked and cat(hc, "aux_have") and (hc.unit.form == "has" or hc.unit.form == "have" or hc.unit.form == "had") then
      local k = snp.nxt + 1
      local neg = false
      while C(S, k) and C(S, k).single and not barrier(C(S, k)) and (P.is_neg(C(S, k)) or cat(C(S, k), "adv")) do
        if P.is_neg(C(S, k)) then neg = true end
        k = k + 1
      end
      for _, onp in ipairs(P.parse_np(S, k)) do
        if onp.head_kind == "relnoun" and onp.of_arg then
          for _, o in ipairs(F.relnp_options(S, onp)) do
            local rel = o.rel
            local to_t = rel.to
            if o.ask_role == "to" and (to_t == "number" or to_t == "money" or to_t == "date" or to_t == "quantity") then
              local a = { rel = rel.id, rel_obj = rel, pattern = "has_attribute", used_np = { snp, onp }, neg = neg, tense = (hc.unit.form == "had") and "past" or "present",
                copula = { used = { [snp.nxt] = true } } }
              a.roles = { from = snp, to = o.arg }
              a.end_chunk = onp.nxt
              out[#out + 1] = a
            end
          end
        end
      end
    end
  end
end

-- X is a/an N  -> classification (feeds terminology and entity typing, never relational answers)
local function classification(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if snp.head_kind ~= "relnoun" then
     for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
      local cp = copula_at(S, pos)
      if cp then
        local dc = C(S, cp.nxt)
        if dc and dc.single and cat(dc, "det") and (dc.unit.form == "a" or dc.unit.form == "an") then
          for _, tnp in ipairs(P.parse_np(S, cp.nxt)) do
            if (tnp.head_kind == "typenoun" or tnp.head_kind == "unknown" or tnp.head_kind == "concept") and not tnp.of_arg then
              local a = { rel = "instance_of", pattern = "classification", used_np = { snp, tnp }, neg = cp.neg, tense = cp.past and "past" or "present", copula = cp, is_class = true }
              a.roles = { from = snp, to = tnp }
              a.end_chunk = tnp.nxt
              out[#out + 1] = a
            end
          end
        end
      end
     end
    end
  end
end

local PATTERNS = { copular_relational, verb_relational, have_attribute, classification }

---------------------------------------------------------------- reader-directed content
-- Data that addresses the reader is evidence ABOUT the data, never a command: such sentences are flagged and excluded from fact extraction.
local function reader_directed(self, S, sent_text)
  local lex = S.lex
  local reasons = {}
  local c = C(S, S.first)
  if c and not sent_text:match("%?%s*$") then
    local ana = (c.single or c.kind == "mwe") and P.verb_analyses(S, c) or {}
    for _, a in ipairs(ana) do
      if a.form == "base" and a.act and (a.act == "retrieve" or a.act == "inform" or a.act == "task" or a.act == "constraint" or a.act == "exclude"
        or a.act == "include" or a.act == "compare" or a.act == "focus") and not cat(c, "wh") then
        -- an imperative must have a verb-initial sentence; "Paris" etc. never reach here
        if c.cap == nil or c.cap then reasons[#reasons + 1] = "imperative: " .. a.lemma end
        break
      end
    end
  end
  for i, u in ipairs(S.units) do
    if u.sent == S.sentence.id then
      if lex:cue_at("injection", S.units, i) then reasons[#reasons + 1] = "injection cue: " .. u.form; break end
    end
  end
  local addresses, ai = false, false
  for _, u in ipairs(S.units) do
    if u.sent == S.sentence.id then
      if u.form == "you" or u.form == "your" or u.form == "yourself" then addresses = true end
      if u.form == "assistant" or u.form == "chatbot" or u.form == "ai" or u.form == "llm" or u.form == "model" or u.form == "system" then ai = true end
    end
  end
  if addresses and ai then reasons[#reasons + 1] = "addresses the reader/assistant" end
  return reasons
end

---------------------------------------------------------------- mentions + aliases
local function mentions_of(S, cover_spans)
  local out, aliases = {}, {}
  for k, c in ipairs(S.chunks) do
    if c.kind == "entity" or c.kind == "name" or #c.entities > 0 or #c.names > 0 then
      local keys = {}
      for _, r in ipairs(c.entities) do if not r.fuzzy then keys[#keys + 1] = { key = r.entry.id, type = r.entry.etype } end end
      if #keys == 0 then for _, r in ipairs(c.names) do keys[#keys + 1] = { key = "mention:" .. c.form, type = r.type_guess, weak = r.weak } end end
      for _, kk in ipairs(keys) do
        out[#out + 1] = { key = kk.key, type = kk.type, weak = kk.weak, text = c.text or c.form, s = S.units[c.u1].s, e = S.units[c.u2].e, chunk = k, ambiguous = #keys > 1 or nil }
      end
      -- alias apposition: "France, officially the French Republic," / "X, also known as Y"
      local n1 = C(S, k + 1)
      if n1 and n1.pre and n1.pre:find("comma") and #keys == 1 then
        local j = k + 1
        local cue = S.lex:cue_at("alias_intro", S.units, n1.u1)
        if cue then
          local consumed = 0
          while C(S, j) and consumed < cue do consumed = consumed + (C(S, j).u2 - C(S, j).u1 + 1); j = j + 1 end
          local dc = C(S, j)
          if dc and dc.single and cat(dc, "det") then j = j + 1 end
          for _, np in ipairs(P.parse_np(S, j)) do
            if np.head_kind == "entity" or np.head_kind == "unknown" or np.head_kind == "typenoun" then
              aliases[#aliases + 1] = { key = keys[1].key, alias = P.core_text(S, np), text = P.span_text(S, np) }
              break
            end
          end
        end
      end
    end
  end
  return out, aliases
end

---------------------------------------------------------------- main
-- returns { assertions, mentions, aliases, reader_directed = {{text, reasons, s, e}}, sentences = n, limited = bool }
function A:extract(text, meta)
  meta = meta or {}
  local lex = self.lex
  local an = Lex.analyze(text, { spell = nil, meter = self.meter, max_bytes = meta.max_bytes })
  local res = { assertions = {}, mentions = {}, aliases = {}, reader_directed = {}, sentences = 0, status = an.status }
  if an.status == "rejected" then return res end
  local lat = Lattice.build(an, lex, { meter = self.meter })
  local ctx = { flags = {}, meter = self.meter, max_covers = 2, topic = meta.topic }
  for _, sent in ipairs(an.sentences) do
    local ua, ub = Sem.sentence_unit_range(an, sent.id)
    if ua and ub - ua < self.max_sentence_units then
      res.sentences = res.sentences + 1
      local stext = text:sub(sent.s, sent.e)
      local covers = lat:covers(2, ua, ub)
      local found_in
      local next_topic
      for ci, cover in ipairs(covers) do
        local S = P.new_state(an, lex, lat, cover, ctx)
        S.sentence = sent
        S.cover_index = ci
        if ci == 1 then
          local ms, als = mentions_of(S)
          for _, m in ipairs(ms) do m.sent = sent.id; m.s = m.s; res.mentions[#res.mentions + 1] = m end
          for _, al in ipairs(als) do al.sent = sent.id; res.aliases[#res.aliases + 1] = al end
          local rd = reader_directed(self, S, stext)
          if #rd > 0 then
            res.reader_directed[#res.reader_directed + 1] = { text = stext, reasons = rd, s = sent.s, e = sent.e, sent = sent.id }
            found_in = "reader_directed"
          end
        end
        if found_in == "reader_directed" then break end
        if not stext:match("%?%s*$") then
          local cands = {}
          -- fronted adverbials ("In 1999, Alice founded ...", "Formerly, ...") qualify the clause that follows the comma
          S.lead_first = S.first
          do
            local k = S.first
            while C(S, k) and C(S, k).temporal and C(S, k + 1) and C(S, k + 1).pre and C(S, k + 1).pre:find("comma") do k = k + 1 end
            S.first = k
          end
          for _, pat in ipairs(PATTERNS) do pat(self, S, ctx, cands) end
          -- keep candidates that explain the most of the sentence; ties broken by pattern order (copular relational first)
          local best, best_cov = {}, -1
          for _, a in ipairs(cands) do
            local used = {}
            for _, np in ipairs(a.used_np) do for i = np.c1, np.c2 do used[i] = true end end
            local cov = 0
            for i in pairs(used) do cov = cov + 1 end
            a.coverage = cov
            if cov > best_cov then best_cov = cov end
          end
          for _, a in ipairs(cands) do if a.coverage >= best_cov - 1 then best[#best + 1] = a end end
          for _, a in ipairs(best) do
            local used = {}
            for _, np in ipairs(a.used_np) do for i = np.c1, np.c2 do used[i] = true end end
            if a.copula then for i in pairs(a.copula.used) do used[i] = true end end
            if a.vp then
              for i = a.vp.c1, a.vp.c2 do
                local ci = C(S, i)
                if not (ci and ci.temporal) then used[i] = true end
              end
            end
            local q = qualifiers(self, S, used, { neg = a.neg, tense = a.tense, range = qualifier_range(S, a), former = a.copula and a.copula.former })
            if a.neg then q.polarity = "negative" end
            local rel_obj = a.rel_obj
            local rec = { rel = a.rel, pattern = a.pattern, polarity = q.polarity, modality = q.modality, tense = q.tense, sent = sent.id,
              s = sent.s, e = sent.e, text = stext, cover = ci, coverage = a.coverage }
            if a.is_class then
              rec.is_class = true
              rec.from = describe_np(S, ctx, a.roles.from, nil, "from")
              rec.class_text = P.core_text(S, a.roles.to)
              rec.class_type = a.roles.to.senses and a.roles.to.senses[1] and a.roles.to.senses[1].type or nil
              -- "Mercury is a planet": the class selects among the subject's candidate senses
              if rec.from and rec.from.cands and rec.class_type then
                local keep = {}
                for _, c in ipairs(rec.from.cands) do if c.type and lex:compat(c.type, rec.class_type) >= 0.9 then keep[#keep + 1] = c end end
                if #keep == 1 then rec.from.key, rec.from.status, rec.from.type, rec.from.resolved_by = keep[1].id, "resolved", keep[1].type, "classification" end
              end
            else
              rec.from = describe_np(S, ctx, a.roles.from, rel_obj and rel_obj.from, "from")
              rec.to = describe_np(S, ctx, a.roles.to, rel_obj and rel_obj.to, "to")
            end
            apply_time(rec, q, rel_obj, lex)
            -- a clash between the entity's known type and the relation signature means the pattern misfired (e.g. a city as a "founder")
            local clash = (rec.from and rec.from.type_clash) or (rec.to and rec.to.type_clash)
            if rec.from and rec.from.status ~= "pronoun" and (rec.is_class or (rec.to and rec.to.status ~= "pronoun")) and not clash then
              res.assertions[#res.assertions + 1] = rec
              found_in = found_in or "assertion"
              local sd = a.used_np[1].head_kind == "entity" and describe_np(S, ctx, a.used_np[1], nil, "subject") or nil
              if sd and sd.key and not sd.literal and not next_topic then next_topic = sd end
            end
          end
        end
        if found_in == "assertion" then break end
      end
      if next_topic and not meta.topic_fixed then ctx.topic = next_topic end
    end
  end
  res.limited = self.meter and self.meter.over or false
  return res
end

return A
