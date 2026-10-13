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
  -- "88 days", "4 million people": a counted unit noun is a quantity literal when the relation expects a quantity
  if np.count and expected and (expected == "number" or expected == "quantity" or expected == "money") and (np.head_kind == "unknown" or np.head_kind == "typenoun" or np.head_kind == "concept") then
    local lit = { kind = "number", value = np.count, unit = np.head and np.head.form, text = P.span_text(S, np) }
    return { literal = lit, text = lit.text, type = "number" }
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
  -- the descriptor text is the mention WITHOUT its leading determiner ("the quokka" -> "quokka"); the surface span stays recoverable from the offsets
  local text = P.span_text(S, np)
  if np.det and np.head_kind ~= "entity" then text = text:gsub("^%a+%s+", "", 1) end
  -- "the city of Grutuburn": the type noun only classifies; the descriptor names the entity itself
  if np.type_noun and np.head_kind == "entity" or (np.type_noun and np.head_kind == "unknown") then
    local u1 = np.type_noun.u2 + 2
    if u1 <= np.u2 then text = S.an.original:sub(S.units[u1].s, S.units[np.u2].e) end
  end
  local d = { text = text, type = b.type or (b.top and b.top.type), status = b.status, head_kind = np.head_kind }
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
  for _, k in ipairs(a.skipped or {}) do keep[k] = true end
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
  local event = rel_obj and (rel_obj.when ~= nil or rel_obj.event == true or rel_obj.open == true)
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
  return { nxt = j, neg = neg, past = past, used = used, form = f, skipped = skipped, former = former, hedged = c.hedged, onset = c.onset }
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

local LOCATIVE_PARTICIPLE = U.set({ "situated", "located", "based", "found", "housed", "headquartered", "centred", "centered", "sited", "positioned", "established", "stationed" })
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
            -- (2b) a location-valued noun takes a locative complement: "The headquarters of X is IN Oslo."
            local pk = cp.nxt
            do
              local pp = C(S, pk)
              if pp and pp.single and not pp.masked and LOCATIVE_PARTICIPLE[pp.unit.form] then pk = pk + 1 end
            end
            local pc = C(S, pk)
            if o.rel.locus and o.ask_role == "to" and pc and pc.single and not pc.masked and (pc.unit.form == "in" or pc.unit.form == "at") then
              for _, vnp in ipairs(P.parse_np(S, pk + 1)) do
                local a = { rel = o.rel.id, rel_obj = o.rel, pattern = "copular_locative", used_np = { snp, vnp }, neg = cp.neg, tense = cp.past and "past" or "present", copula = cp }
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
end

-- "was founded IN 1998 by P", "was started in Oslo by P": a temporal expression, an adverb or one prepositional phrase may sit between the participle
-- and its by-phrase.  Returns the chunk index of "by" and the chunks skipped (they still qualify the assertion), or nil.
local function skip_adjuncts_to_by(S, k)
  local skipped = {}
  for _ = 1, 3 do
    local c = C(S, k)
    if not c or c.masked then return nil end
    if c.single and c.unit.form == "by" then return k, skipped end
    if c.temporal and c.temporal.kind ~= "marker" then skipped[#skipped + 1] = k; k = k + 1
    elseif c.single and cat(c, "adv") and not barrier(c) then skipped[#skipped + 1] = k; k = k + 1
    elseif c.single and cat(c, "prep") and not barrier(c) then
      local hit
      for _, np in ipairs(P.parse_np(S, k + 1)) do
        local nc = C(S, np.nxt)
        if nc and nc.single and not nc.masked and nc.unit.form == "by" then hit = np; break end
      end
      if not hit then return nil end
      for i = k, hit.nxt - 1 do skipped[#skipped + 1] = i end
      k = hit.nxt
    else return nil end
  end
  return nil
end

-- Subject VERB Object  (active / passive-by / verb+prep), via the lexicon's role-directed relation verbs
local function verb_relational(self, S, ctx, out)
  local lex = S.lex
  for _, snp in ipairs(P.parse_np(S, S.first)) do
   for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
    for _, vp in ipairs(P.parse_vp(S, pos)) do
      for _, e in ipairs(vp.analysis.entries) do
        local rel = lex:get_rel(e.rel)
        if rel and not e.as_only then
          local k = vp.nxt
          local patient_first = vp.voice == "passive" and not e.prep
          local skipped
          if e.prep then
            local pc = C(S, k)
            if pc and pc.single and pc.unit.form == e.prep and not pc.masked then k = k + 1 else k = nil end
          elseif vp.voice == "passive" then
            local kb
            kb, skipped = skip_adjuncts_to_by(S, k)
            if kb then k = kb + 1 else k = nil end
          end
          if k then
            for _, onp in ipairs(P.parse_np(S, k)) do
              local a = { rel = rel.id, rel_obj = rel, pattern = vp.voice == "passive" and "passive_by" or "svo", used_np = { snp, onp }, neg = vp.neg,
                tense = (vp.vform == "past" or vp.perfect) and "past" or "present", vp = vp, skipped = skipped }
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

-- "Financial capital refers to money used to fund businesses."  /  "X is defined as ..."  /  "X means ..."
local function definition(self, S, ctx, out)
  local lex = S.lex
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if snp.head_kind ~= "relnoun" and snp.head_kind ~= "pronoun" then
      local c = S.chunks[snp.nxt]
      if c and not c.masked and lex:cue_at("definition_verb", S.units, c.u1) then
        local n = lex:cue_at("definition_verb", S.units, c.u1)
        local k = snp.nxt
        local consumed = 0
        local used = {}
        while S.chunks[k] and consumed < n do consumed = consumed + (S.chunks[k].u2 - S.chunks[k].u1 + 1); used[k] = true; k = k + 1 end
        if S.chunks[k] and k <= S.last then
          local a = { rel = "defined_as", pattern = "definition", used_np = { snp }, tense = "present", copula = { used = used }, is_class = true, definitional = true }
          a.roles = { from = snp, to = nil }
          a.def_start = k
          a.end_chunk = S.last + 1
          out[#out + 1] = a
        end
      end
    end
  end
end

-- "Mercury is a chemical element with atomic number 80."  /  "Zorbland is a country with a population of 4 million."
local function with_attribute(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
      local cp = copula_at(S, pos)
      if cp then
        for _, tnp in ipairs(P.parse_np(S, cp.nxt)) do
          local wc = S.chunks[tnp.nxt]
          if wc and wc.single and wc.unit.form == "with" and not wc.masked then
            for _, rnp in ipairs(P.parse_np(S, tnp.nxt + 1)) do
              if rnp.head_kind == "relnoun" then
                for _, o in ipairs(F.relnp_options(S, rnp)) do
                  local rel = o.rel
                  if o.ask_role == "to" then
                    local value_np, nxt
                    if o.arg then value_np, nxt = o.arg, rnp.nxt   -- "with a population of 4 million"
                    else
                      for _, vnp in ipairs(P.parse_np(S, rnp.nxt)) do value_np, nxt = vnp, vnp.nxt break end   -- "with atomic number 80"
                    end
                    if value_np and (value_np.head_kind == "number" or value_np.head_kind == "temporal" or value_np.head_kind == "literal" or value_np.head_kind == "entity") then
                      local a = { rel = rel.id, rel_obj = rel, pattern = "with_attribute", used_np = { snp, rnp, value_np }, neg = cp.neg, tense = cp.past and "past" or "present", copula = cp }
                      a.roles = { from = snp, to = value_np }
                      a.end_chunk = nxt
                      out[#out + 1] = a
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Support-verb statements.  The holder is the subject; the verb ("has", "keeps", "maintains", "uses") only carries the relation named by the noun:
--   X HAS|KEEPS|MAINTAINS its RELNOUN (in|at|of) VALUE      "Acme maintains its headquarters in Oslo."
--   X HAS|USES VALUE as its RELNOUN                          "Sweden uses the krona as its currency."  "France has Paris as its capital."
local SUPPORT_PREP = U.set({ "in", "at", "of", "as" })
local function supports(vp, rel)
  if vp.lemma == "have" then return rel.support_have == true end
  for _, e in ipairs(vp.analysis.entries or {}) do if e.support and e.rel == rel.id then return true end end
  return false
end
local function possessed_relnoun(S, onp)
  local dc = C(S, onp.c1)
  return onp.head_kind == "relnoun" and not onp.of_arg and dc and dc.single and (cat(dc, "poss_det") or cat(dc, "det")) and onp.c1 < onp.nxt - 1
end
local function support_statement(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
   for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
    for _, vp in ipairs(P.parse_vp(S, pos)) do
      if vp.voice == "active" then
        local tense = (vp.vform == "past") and "past" or "present"
        -- (1) verb [from|at|out of] + possessed relational noun + (preposition +) value        "operates from its headquarters in Oslo", "calls its currency the krona"
        local starts = { vp.nxt }
        do
          local fc = C(S, vp.nxt)
          if fc and fc.single and not fc.masked and (fc.unit.form == "from" or fc.unit.form == "at" or fc.unit.form == "out") then
            local k2 = vp.nxt + 1
            if fc.unit.form == "out" and C(S, k2) and C(S, k2).unit.form == "of" then k2 = k2 + 1 end
            starts[#starts + 1] = k2
          end
        end
        for _, k0 in ipairs(starts) do
          for _, onp in ipairs(P.parse_np(S, k0)) do
            if possessed_relnoun(S, onp) then
              local pc = C(S, onp.nxt)
              local vstart
              if pc and pc.single and not pc.masked and SUPPORT_PREP[pc.unit.form] and pc.unit.form ~= "as" then vstart = onp.nxt + 1
              elseif k0 == vp.nxt and vp.lemma == "call" then vstart = onp.nxt end      -- "calls its currency THE KRONA": no preposition
              if vstart then
                for _, vnp in ipairs(P.parse_np(S, vstart)) do
                  for _, o in ipairs(F.relnp_options(S, onp)) do
                    if o.rel and o.ask_role == "to" and supports(vp, o.rel) then
                      local a = { rel = o.rel.id, rel_obj = o.rel, pattern = "support_have", used_np = { snp, onp, vnp }, neg = vp.neg, tense = tense, vp = vp }
                      a.roles = { from = snp, to = vnp }
                      a.end_chunk = vnp.nxt
                      out[#out + 1] = a
                    end
                  end
                end
              end
            end
          end
        end
        -- (2) verb + value + "as" + relational noun:  "France has Paris as its capital", "Acme appointed Jane Doe as CEO" (bare), "... as the CEO"
        for _, vnp in ipairs(P.parse_np(S, vp.nxt)) do
          local ac = C(S, vnp.nxt)
          if ac and ac.single and not ac.masked and ac.unit.form == "as" then
            for _, onp in ipairs(P.parse_np(S, vnp.nxt + 1)) do
              if onp.head_kind == "relnoun" and not onp.possessor and not (onp.of_arg and vp.lemma == "have") then
                local pc2 = C(S, onp.nxt)
                local dangling_of = pc2 and pc2.single and not pc2.masked and pc2.unit.form == "of"
                for _, o in ipairs(F.relnp_options(S, onp)) do
                  if o.rel and o.ask_role == "to" and supports(vp, o.rel) and not dangling_of then
                    local a = { rel = o.rel.id, rel_obj = o.rel, pattern = "support_as", used_np = { snp, vnp, onp }, neg = vp.neg, tense = tense, vp = vp }
                    -- "the board appointed Jane Doe as CEO OF Acme": the holder is the argument of the noun, the subject is only the agent of the appointment
                    if o.arg and not onp.topic_arg then a.roles = { from = o.arg, to = vnp }
                    else a.roles = { from = snp, to = vnp } end
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
   end
  end
end

-- "P is the person who founded O."  /  "P is the one that started O."  The head noun is generic; the relative clause carries the relation, and
-- the copular subject fills the gap.
local function relative_identity(self, S, ctx, out)
  local lex = S.lex
  for _, snp in ipairs(P.parse_np(S, S.first)) do
   if snp.head_kind ~= "relnoun" then
    for _, pos in ipairs(predicate_positions(S, snp.nxt)) do
      local cp = copula_at(S, pos)
      if cp then
        for _, tnp in ipairs(P.parse_np(S, cp.nxt, { no_of = true })) do
          local rc = C(S, tnp.nxt)
          if tnp.head_kind ~= "entity" and tnp.head_kind ~= "relnoun" and rc and rc.single and not rc.masked
            and (rc.unit.form == "who" or rc.unit.form == "that" or rc.unit.form == "which") then
            for _, vp in ipairs(P.parse_vp(S, tnp.nxt + 1)) do
              if vp.voice == "active" then
                for _, e in ipairs(vp.analysis.entries or {}) do
                  local rel = lex:get_rel(e.rel)
                  if rel and not e.prep and not rel.open and not e.support then
                    for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
                      local a = { rel = rel.id, rel_obj = rel, pattern = "relative_identity", used_np = { snp, tnp, onp }, neg = cp.neg or vp.neg,
                        tense = (cp.past or vp.vform == "past") and "past" or "present", copula = cp, vp = vp }
                      a.roles = { [e.subj] = snp, [other(e.subj)] = onp }
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
    end
   end
  end
end

-- "The person who started O is P."  /  "The city where O is headquartered is C."  /  "The city that functions as the capital of K is C."
-- A definite singular description with ONE relative clause names the value of the relation the clause expresses.
local function description_identity(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if snp.head_kind == "typenoun" and not snp.plural and snp.det == "the" then
      local filters, kf = F.parse_filters(S, snp.nxt, snp)
      -- the relative clause ends where the copula begins
      for cut = #filters, 1, -1 do
        local f = filters[cut]
        if cut == 1 and f.kind == "relation" and f.value and f.rel then
          local rel = S.lex:get_rel(f.rel)
          local cp = copula_at(S, f.span.last + 1)
          if rel and not rel.open and cp then
            for _, vnp in ipairs(P.parse_np(S, cp.nxt)) do
              local a = { rel = rel.id, rel_obj = rel, pattern = "description_identity", used_np = { snp, f.value, vnp }, neg = cp.neg or f.polarity == "negative",
                tense = cp.past and "past" or "present", copula = cp }
              a.roles = { [f.target_role] = vnp, [other(f.target_role)] = f.value }
              for i = f.span.first, f.span.last do a.copula.used[i] = true end
              a.end_chunk = vnp.nxt
              out[#out + 1] = a
            end
          end
        end
      end
    end
  end
end

local function comma_before(S, k) local c = C(S, k); return c ~= nil and c.pre ~= nil and c.pre:find("comma") ~= nil end

-- A comma-delimited relational noun phrase next to a name states the relation between its argument and the name:
--   "Brelmont, the capital of Tavoria, is a coastal city."     "The founder of Brennick Dynamics, Odalys Feurmann, spoke yesterday."
--   "Tavoria's capital, Brelmont, hosts the parliament."       "Jane Doe, CEO of Acme Corp, said ..."
local function apposition_relational(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if comma_before(S, snp.nxt) then
      for _, np2 in ipairs(P.parse_np(S, snp.nxt)) do
        local nc = C(S, np2.nxt)
        local closed = np2.nxt > S.last or (nc ~= nil and nc.pre ~= nil and (nc.pre:find("comma") ~= nil or nc.pre:find("dash") ~= nil))
        if closed then
          local function mk(o, valnp, argnp, pattern)
            local a = { rel = o.rel.id, rel_obj = o.rel, pattern = pattern, used_np = { snp, np2 }, neg = false, tense = "present" }
            a.roles = { [o.known_role] = o.arg, [o.ask_role] = valnp }
            a.end_chunk = np2.nxt
            out[#out + 1] = a
          end
          -- NAME , RELNP-of-X ,
          if np2.head_kind == "relnoun" and (snp.head_kind == "entity" or (snp.head_kind == "unknown" and snp.head and snp.head.cap)) and not snp.det and not snp.poss_det then
            for _, o in ipairs(F.relnp_options(S, np2)) do if o.arg and o.rel and not o.rel.open then mk(o, snp, o.arg, "apposition") end end
          end
          -- RELNP-of-X , NAME ,
          if snp.head_kind == "relnoun" and (np2.head_kind == "entity" or (np2.head_kind == "unknown" and np2.head and np2.head.cap)) and not np2.det and not np2.poss_det then
            for _, o in ipairs(F.relnp_options(S, snp)) do if o.arg and o.rel and not o.rel.open then mk(o, np2, o.arg, "apposition") end end
          end
        end
      end
    end
  end
end

-- A non-restrictive relative clause on the subject names the relation too:
--   "Odalys Feurmann, who founded Brennick Dynamics, lives in Oslo."       "Brennick Dynamics, which was founded by Odalys Feurmann, is based in Oslo."
local function relative_apposition(self, S, ctx, out)
  local lex = S.lex
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    local rc = C(S, snp.nxt)
    if rc and rc.single and not rc.masked and comma_before(S, snp.nxt) and (rc.unit.form == "who" or rc.unit.form == "which")
      and (snp.head_kind == "entity" or (snp.head_kind == "unknown" and snp.head and snp.head.cap)) then
      for _, vp in ipairs(P.parse_vp(S, snp.nxt + 1)) do
        for _, e in ipairs(vp.analysis.entries or {}) do
          local rel = lex:get_rel(e.rel)
          if rel and not rel.open and not e.support and not e.as_only then
            local tense = (vp.vform == "past" or vp.perfect) and "past" or "present"
            if vp.voice == "active" and not e.prep then
              for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
                local a = { rel = rel.id, rel_obj = rel, pattern = "relative_apposition", used_np = { snp, onp }, neg = vp.neg, tense = tense, vp = vp }
                a.roles = { [e.subj] = snp, [other(e.subj)] = onp }
                a.end_chunk = onp.nxt
                out[#out + 1] = a
              end
            elseif vp.voice == "passive" and not e.prep then
              local bc = C(S, vp.nxt)
              if bc and bc.single and not bc.masked and bc.unit.form == "by" then
                for _, onp in ipairs(P.parse_np(S, vp.nxt + 1)) do
                  local a = { rel = rel.id, rel_obj = rel, pattern = "relative_apposition", used_np = { snp, onp }, neg = vp.neg, tense = tense, vp = vp }
                  a.roles = { [other(e.subj)] = snp, [e.subj] = onp }
                  a.end_chunk = onp.nxt
                  out[#out + 1] = a
                end
              end
            elseif e.prep then
              local pc = C(S, vp.nxt)
              if pc and pc.single and not pc.masked and pc.unit.form == e.prep then
                for _, onp in ipairs(P.parse_np(S, vp.nxt + 1)) do
                  local a = { rel = rel.id, rel_obj = rel, pattern = "relative_apposition", used_np = { snp, onp }, neg = vp.neg, tense = tense, vp = vp }
                  a.roles = { [e.subj] = snp, [other(e.subj)] = onp }
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
end

local PATTERNS = { copular_relational, verb_relational, have_attribute, support_statement, relative_identity, description_identity, classification, with_attribute, definition,
  apposition_relational, relative_apposition }

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
          P.take_topic(S)
          P.take_attribution(S)
          P.take_reported(S, true)
          P.normalize_cleft(S)
          P.normalize_inversion(S)
          for _, pat in ipairs(PATTERNS) do pat(self, S, ctx, cands) end
          -- "Officials confirmed that X is Y.": a reporting clause is tried only when the sentence as written yields nothing
          if #cands == 0 and P.take_reported(S) then
            P.normalize_cleft(S)
            P.normalize_inversion(S)
            for _, pat in ipairs(PATTERNS) do pat(self, S, ctx, cands) end
          end
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
            if a.copula and a.copula.hedged then q.modality = "hedged" end          -- "is said to be", "is believed to be"
            if S.attribution then q.attribution = S.attribution.text end
            local rel_obj = a.rel_obj
            local rec = { rel = a.rel, pattern = a.pattern, polarity = q.polarity, modality = q.modality, tense = q.tense, sent = sent.id,
              s = sent.s, e = sent.e, text = stext, cover = ci, coverage = a.coverage }
            if a.definitional then
              rec.is_class = true
              rec.definition = true
              rec.from = describe_np(S, ctx, a.roles.from, nil, "from")
              local ua = S.chunks[a.def_start]
              rec.class_text = text:sub(S.units[ua.u1].s, sent.e):gsub("[%.%s]+$", "")
            elseif a.is_class then
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
            rec.attribution = q.attribution
            -- "Brelmont became the capital in 1950": the time marks the START of the state
            if a.copula and a.copula.onset and rec.valid_at then rec.valid_from = rec.valid_at.lo; rec.valid_at = nil end
            -- a clash between the entity's known type and the relation signature means the pattern misfired (e.g. a city as a "founder")
            local clash = (rec.from and rec.from.type_clash) or (rec.to and rec.to.type_clash)
            if rel_obj and rel_obj.open then
              rec.open_relation = true
              -- an inferred relation is only trusted between two proper participants (entities or literals), never between generic nouns
              local function proper(d) return d and (d.literal or (d.key and (d.key:sub(1, 8) == "mention:" or not d.key:find("^term:") and not d.key:find("^sense:")))) end
              -- verb-based open relations connect proper participants only; "the X of Y is Z" (explicit relational noun) may have any value
              if (a.pattern == "svo" or a.pattern == "passive_by") and not (proper(rec.from) and proper(rec.to)) then clash = true end
            end
            local dedupe_key
            do
              local function dk(d) return d and (d.key or (d.literal and d.literal.text) or d.text) or "-" end
              dedupe_key = table.concat({ rec.rel, dk(rec.from), rec.is_class and (rec.definition and "def" or "class") or dk(rec.to), rec.polarity, tostring(sent.id) }, "|")
            end
            res._seen = res._seen or {}
            local valid = rec.from and rec.from.status ~= "pronoun" and (rec.is_class or (rec.to and rec.to.status ~= "pronoun")) and not clash
            -- one reading of the sentence per (relation, subject): among VALID candidates the one explaining most of the sentence wins over
            -- truncated parses ("88" vs "88 days"); an invalid (type-clashing) candidate never shadows a valid one
            local skip = false
            if valid then
              local gk = table.concat({ rec.rel, (rec.from.key or rec.from.text), rec.polarity, tostring(sent.id), rec.is_class and "c" or "r" }, "|")
              res._best = res._best or {}
              local prev = res._best[gk]
              if prev and (prev.coverage or 0) >= (rec.coverage or 0) then skip = true
              elseif prev then
                for i, x in ipairs(res.assertions) do if x == prev then table.remove(res.assertions, i) break end end
              end
              if not skip then res._best[gk] = rec end
            end
            if valid and not skip and not res._seen[dedupe_key] then
              res._seen[dedupe_key] = true
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
  res._seen, res._best = nil, nil
  return res
end

return A
