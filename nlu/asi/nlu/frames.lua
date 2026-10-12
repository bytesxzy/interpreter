-- asi.nlu.frames: construction-level semantics. Every frame turns parsed chunks into zero or more competing
-- hypotheses.  Roles are never guessed from word proximity: they come from (1) voice and wh-gap position,
-- (2) the relation lexicon's subj=to|from direction, and (3) type compatibility with the relation signature.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")

local F = {}

local cat = P.cat
local function C(S, k) return S.chunks[k] end
local function barrier(c) return c ~= nil and c.pre ~= nil end
local function other(role) return role == "to" and "from" or "to" end

---------------------------------------------------------------- hypothesis helpers
local function newh(S, frame, speech_act, intent, op)
  return { frame = frame, speech_act = speech_act, intent = intent, op = op, roles = {}, used = {}, factors = {}, notes = {}, constraints = {},
    polarity = "positive", S = S }
end
local function addf(h, name, v, note) h.factors[#h.factors + 1] = { name = name, v = v, note = note } end
local function use(h, a, b) for i = a, b or a do h.used[i] = true end end
local function use_np(h, np)
  if not np then return end
  for i = np.c1, np.c2 do h.used[i] = true end
  if np.of_arg then use_np(h, np.of_arg) end
  if np.possessor then use_np(h, np.possessor) end
  for _, m in ipairs(np.mods or {}) do if m.chunk then h.used[m.chunk.idx] = true end end
end
local function use_wh(h, wh) if wh then for i = wh.c1, wh.c2 do h.used[i] = true end end end
local function use_vp(h, vp)
  for i = vp.c1, vp.c2 do h.used[i] = true end
end
F.newh, F.addf, F.use_np = newh, addf, use_np

local function is_be(c) return c and c.single and (cat(c, "aux_be") or cat(c, "clitic_s")) and not c.masked end
local function is_do(c) return c and c.single and cat(c, "aux_do") and not c.masked end
local function is_prep(c, form) return c and c.single and not c.masked and cat(c, "prep") and (form == nil or c.unit.form == form) end

-- a relational NP exposes (relation entry, argument NP, role of the known argument, role asked for)
local function relnp_options(S, np)
  local out = {}
  if np.head_kind ~= "relnoun" then return out end
  local arg = np.of_arg or np.possessor
  local compound = false
  if not arg then
    local last = np.mods[#np.mods]
    if last and last.kind == "entity_mod" and last.chunk.idx + 1 == np.hchunk_idx then
      arg = { head_kind = "entity", cands = last.cands, head = last.chunk, u1 = last.chunk.u1, u2 = last.chunk.u2, c1 = last.chunk.idx, c2 = last.chunk.idx,
        mods = {}, score = 0.2, compound = true, nxt = np.hchunk_idx, notes = {} }
      compound = true
    end
  end
  for _, e in ipairs(np.relnouns) do
    local rel = S.lex:get_rel(e.rel)
    if rel then
      local known_role = (e.role == "to") and "from" or "to"
      local base = { rel = rel, arg = arg, known_role = known_role, ask_role = e.role, compound = compound, entry = e, comma = np.comma_arg, fuzzy = e.fuzzy }
      -- kind modifiers ("financial capital of X": either a separate word or a lexicalised prefix) re-target the relation
      local kinds = {}
      if e.kind_prefix then kinds[#kinds + 1] = { form = e.kind_prefix } end
      for _, m in ipairs(np.mods) do kinds[#kinds + 1] = m end
      local derived_found = false
      for _, m in ipairs(kinds) do
        local derived = rel.kinds and rel.kinds[m.form]
        if derived and derived ~= rel.id and S.lex:get_rel(derived) then
          out[#out + 1] = { rel = S.lex:get_rel(derived), arg = arg, known_role = known_role, ask_role = e.role, kind_mod = m, compound = compound, entry = e,
            comma = np.comma_arg, fuzzy = e.fuzzy }
          derived_found = true
        elseif derived == rel.id then base.political_mod = m end
      end
      base.kind_ignored = derived_found -- the base relation silently ignores a kind word: strongly disfavoured
      out[#out + 1] = base
    end
  end
  return out
end
F.relnp_options = relnp_options

-- factors shared by every consumer of a relational-NP option
local function option_factors(h, o)
  if o.kind_mod then
    h.kind_mod = o.kind_mod.form
    if o.kind_mod.chunk then use(h, o.kind_mod.chunk.idx) end
    addf(h, "kind_modifier", 0.2, "kind modifier '" .. tostring(o.kind_mod.form) .. "' selects " .. o.rel.id)
  end
  if o.political_mod and o.political_mod.chunk then use(h, o.political_mod.chunk.idx) end
  if o.kind_ignored then addf(h, "kind_modifier_ignored", -0.9, "a kind word is present but this relation ignores it") end
  if o.comma then addf(h, "comma_apposition", -0.3, "argument attached across a comma") end
  if o.compound then addf(h, "compound_arg", -0.25, "entity+noun compound instead of 'of'/'s'") end
end
F.option_factors = option_factors

local function span_end_ok(S, k)
  -- true when nothing but sentence-final constraints can follow chunk k (used only for scoring, not as a hard gate)
  return k > S.last
end

-- record how a relation hypothesis binds its arguments (type fit is computed in hyp.lua)
local function set_lookup(h, rel, known_role, known_np, ask_role, wh)
  h.rel, h.rel_obj = rel.id, rel
  h.roles[known_role] = known_np
  h.known_role, h.ask = known_role, ask_role
  h.ask_type = rel[ask_role]
  if wh and wh.type then h.wh_type = wh.type end
  h.wh = wh
  h.op = "lookup"
  h.intent = "factual_lookup"
  h.requires_evidence = true
end

local function mark_unresolved_pron(h, np)
  if np and np.head_kind == "pronoun" then h.pronouns = h.pronouns or {}; h.pronouns[#h.pronouns + 1] = np end
  if np and np.of_arg then mark_unresolved_pron(h, np.of_arg) end
  if np and np.possessor then mark_unresolved_pron(h, np.possessor) end
end
F.mark_pron = mark_unresolved_pron

---------------------------------------------------------------- frame: wh + be + NP
function F.wh_copular(S, out)
  local k0 = S.first
  for _, wh in ipairs(P.parse_wh(S, k0)) do
    if not wh.adverbial and wh.wh ~= "how_many" and wh.wh ~= "how_much" and wh.wh ~= "how_adj" then
      local bk = wh.nxt
      local be = C(S, bk)
      if is_be(be) and not barrier(be) then
        for _, np in ipairs(P.parse_np(S, bk + 1)) do
          local base = function(frame)
            local h = newh(S, frame, "question", nil, nil)
            use_wh(h, wh); use(h, bk); use_np(h, np)
            h.wh = wh; h.last_chunk = np.c2
            mark_unresolved_pron(h, np)
            return h
          end
          if np.head_kind == "relnoun" then
            local opts = relnp_options(S, np)
            for _, o in ipairs(opts) do
              local h = base("wh_copular:relnp")
              if o.arg then
                set_lookup(h, o.rel, o.known_role, o.arg, o.ask_role, wh)
                addf(h, "relnp_arg", 0.7, "relational noun with explicit argument")
                option_factors(h, o)
                mark_unresolved_pron(h, o.arg)
              else
                h.op, h.intent, h.rel, h.rel_obj = "define", "definition", o.rel.id, o.rel
                h.concept = np
                addf(h, "relnoun_no_arg", -1.0, "relational noun without its argument")
              end
              if np.temporal_scope then h.temporal_scope = np.temporal_scope end
              if np.superlative then h.ordering = { superlative = np.superlative } end
              out[#out + 1] = h
            end
          elseif np.head_kind == "entity" then
            local h = base("wh_copular:entity")
            h.op, h.intent = "describe", "entity_description"
            h.subject = np
            h.roles.subject = np
            h.requires_evidence = true
            if wh.wh == "who" then h.expect_type = "agent"; addf(h, "wh_who_expects_agent", 0.0, "who expects an agent") end
            if wh.type then h.expect_type = wh.type end
            out[#out + 1] = h
          elseif np.head_kind == "typenoun" or np.head_kind == "concept" or np.head_kind == "unknown" then
            local h = base("wh_copular:concept")
            h.op, h.intent = "define", "definition"
            h.concept = np
            h.requires_evidence = true
            if np.head_kind == "unknown" then addf(h, "unknown_term", -0.15, "term not in the lexicon: dataset-specific meaning must be learned from evidence") end
            if np.of_arg then addf(h, "concept_of_arg", -0.4, "a non-relational concept noun with an 'of' argument is a weaker structure than a relational noun") end
            out[#out + 1] = h
          elseif np.head_kind == "pronoun" then
            local h = base("wh_copular:pronoun")
            h.op, h.intent = "describe", "entity_description"
            h.subject = np
            out[#out + 1] = h
          elseif np.head_kind == "temporal" or np.head_kind == "number" or np.head_kind == "quote" or np.head_kind == "literal" then
            local h = base("wh_copular:literal")
            h.op, h.intent = "describe", "entity_description"
            h.subject = np
            out[#out + 1] = h
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- frame: wh + VERB(active) + NP    ("Who founded X?")
-- also "Which company is based in Germany?" (stative prep verbs) and "Which claims are not supported by the documents?" (passive)
function F.wh_verb(S, out)
  local k0 = S.first
  for _, wh in ipairs(P.parse_wh(S, k0)) do
    if not wh.adverbial and wh.wh ~= "how_adj" and wh.wh ~= "how_many" and wh.wh ~= "how_much" then
      local vk = wh.nxt
      for _, vp in ipairs(P.parse_vp(S, vk)) do
        for _, e in ipairs(vp.analysis.entries) do
          local rel = S.lex:get_rel(e.rel)
          if rel then
            local function finish(h, known_np, known_role, ask_role)
              set_lookup(h, rel, known_role, known_np, ask_role, wh)
              h.wh = wh
              use_wh(h, wh); use_vp(h, vp); use_np(h, known_np)
              if vp.neg then h.polarity = "negative"; use(h, vp.neg_chunk.idx) end
              addf(h, "direction_explicit", 0.35, "role direction fixed by voice/lexicon (" .. vp.voice .. ", subj=" .. e.subj .. ")")
              if vp.analysis.guessed then addf(h, "guessed_verb", -0.3, "verb form guessed") end
              mark_unresolved_pron(h, known_np)
              out[#out + 1] = h
            end
            if vp.voice == "active" then
              if e.prep then
                -- "Which company invested in B?": prep object fills the other role
                local pk = vp.nxt
                if is_prep(C(S, pk), e.prep) then
                  for _, np in ipairs(P.parse_np(S, pk + 1)) do
                    local h = newh(S, "wh_verb:active_prep", "question")
                    use(h, pk)
                    finish(h, np, other(e.subj), e.subj)
                  end
                end
              else
                for _, np in ipairs(P.parse_np(S, vp.nxt)) do
                  local h = newh(S, "wh_verb:active", "question")
                  finish(h, np, other(e.subj), e.subj)
                end
              end
            else -- passive / stative:  wh is the grammatical subject
              if e.prep then
                -- "Which company is based in Germany?": subject keeps e.subj role, PP object the other
                local pk = vp.nxt
                if is_prep(C(S, pk), e.prep) then
                  for _, np in ipairs(P.parse_np(S, pk + 1)) do
                    local h = newh(S, "wh_verb:stative", "question")
                    use(h, pk)
                    finish(h, np, other(e.subj), e.subj)
                  end
                end
              else
                -- "Which claims are not supported by the documents?"  by-agent fills e.subj; wh is the other role
                local pk = vp.nxt
                if is_prep(C(S, pk), "by") then
                  for _, np in ipairs(P.parse_np(S, pk + 1)) do
                    local h = newh(S, "wh_verb:passive_by", "question")
                    use(h, pk)
                    finish(h, np, e.subj, other(e.subj))
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

---------------------------------------------------------------- frame: wh + do + NP(subject) + VERB(base)   ("Which company did P found?")
function F.wh_do(S, out)
  local k0 = S.first
  for _, wh in ipairs(P.parse_wh(S, k0)) do
    if not wh.adverbial and wh.wh ~= "how_adj" then
      local dk = wh.nxt
      if is_do(C(S, dk)) then
        local nk = dk + 1
        local neg_chunk
        if P.is_neg(C(S, nk)) then neg_chunk = C(S, nk); nk = nk + 1 end
        for _, snp in ipairs(P.parse_np(S, nk, { no_of = false })) do
          for _, vp in ipairs(P.parse_vp(S, snp.nxt, { aux_hint = "do" })) do
            for _, e in ipairs(vp.analysis.entries) do
              local rel = S.lex:get_rel(e.rel)
              if rel then
                -- subject NP fills e.subj; the wh-gap is the object (other role). Stranded or absent preposition is fine.
                local h = newh(S, "wh_do:object_gap", "question")
                set_lookup(h, rel, e.subj, snp, other(e.subj), wh)
                use_wh(h, wh); use(h, dk); use_np(h, snp); use_vp(h, vp)
                if neg_chunk then h.polarity = "negative"; use(h, neg_chunk.idx) end
                local pk = vp.nxt
                if e.prep then
                  if is_prep(C(S, pk), e.prep) then use(h, pk) else addf(h, "prep_missing", -0.5, "expected stranded preposition '" .. e.prep .. "'") end
                end
                addf(h, "direction_explicit", 0.35, "role direction fixed by do-support gap (subject=" .. e.subj .. ")")
                mark_unresolved_pron(h, snp)
                out[#out + 1] = h
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- frame: wh + be + NP + VERB-ed (+ by)   ("Who was X founded by?")
function F.wh_passive(S, out)
  local k0 = S.first
  for _, wh in ipairs(P.parse_wh(S, k0)) do
    if not wh.adverbial then
      local bk = wh.nxt
      if is_be(C(S, bk)) then
        for _, snp in ipairs(P.parse_np(S, bk + 1)) do
          for _, vp in ipairs(P.parse_vp(S, snp.nxt, { aux_hint = "be" })) do
            if vp.voice == "passive" then
              for _, e in ipairs(vp.analysis.entries) do
                local rel = S.lex:get_rel(e.rel)
                if rel and not e.prep then
                  local h = newh(S, "wh_passive:stranded_by", "question")
                  -- X (grammatical subject) is the logical object; the wh-gap is the agent (e.subj role)
                  set_lookup(h, rel, other(e.subj), snp, e.subj, wh)
                  use_wh(h, wh); use(h, bk); use_np(h, snp); use_vp(h, vp)
                  local pk = vp.nxt
                  if is_prep(C(S, pk), "by") then use(h, pk) else addf(h, "by_missing", -0.4, "passive without by-phrase") end
                  addf(h, "direction_explicit", 0.35, "agent gap of a passive")
                  mark_unresolved_pron(h, snp)
                  out[#out + 1] = h
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- frame: when / where / how-many / how-old questions
function F.wh_adverbial(S, out)
  local k0 = S.first
  for _, wh in ipairs(P.parse_wh(S, k0)) do
    local f = wh.wh
    if f == "where" or f == "when" then
      local bk = wh.nxt
      -- "Where is X?"  /  "When was X founded?"  /  "When did X acquire Y?"
      if is_be(C(S, bk)) then
        for _, np in ipairs(P.parse_np(S, bk + 1)) do
          -- X followed by a participle:  "Where is X located?"  "When was X founded/born?"
          local vps = P.parse_vp(S, np.nxt, { aux_hint = "be" })
          for _, vp in ipairs(vps) do
            if vp.voice == "passive" then
              for _, e in ipairs(vp.analysis.entries) do
                local rel = S.lex:get_rel(e.rel)
                if rel then
                  local target_rel, known_role, ask_role
                  if f == "where" then
                    -- stative-prep verbs map directly ("located in", "based in", "born in"); others use rel.where
                    if e.prep then target_rel, known_role, ask_role = rel, e.subj, other(e.subj)
                    elseif rel.where and S.lex:get_rel(rel.where) then target_rel = S.lex:get_rel(rel.where); known_role, ask_role = "from", "to" end
                  else
                    if rel.when and S.lex:get_rel(rel.when) then target_rel = S.lex:get_rel(rel.when); known_role, ask_role = "from", "to" end
                  end
                  if target_rel then
                    local h = newh(S, "wh_adv:" .. f .. ":passive", "question")
                    set_lookup(h, target_rel, known_role, np, ask_role, wh)
                    h.derived_via = rel.id
                    use_wh(h, wh); use(h, bk); use_np(h, np); use_vp(h, vp)
                    addf(h, "direction_explicit", 0.3, f .. "-question on passive participle")
                    mark_unresolved_pron(h, np)
                    out[#out + 1] = h
                  end
                end
              end
            end
          end
          if f == "where" then
            local lrel = S.lex:get_rel("located_in")
            if lrel then
              local h = newh(S, "wh_adv:where:copula", "question")
              set_lookup(h, lrel, "from", np, "to", wh)
              use_wh(h, wh); use(h, bk); use_np(h, np)
              mark_unresolved_pron(h, np)
              out[#out + 1] = h
            end
          end
        end
      elseif is_do(C(S, bk)) then
        -- "When did X acquire Y?"  /  "When did X die?"
        for _, snp in ipairs(P.parse_np(S, bk + 1)) do
          for _, vp in ipairs(P.parse_vp(S, snp.nxt, { aux_hint = "do" })) do
            for _, e in ipairs(vp.analysis.entries) do
              local rel = S.lex:get_rel(e.rel)
              local trel_id = rel and ((f == "when") and rel.when or rel.where)
              local trel = trel_id and S.lex:get_rel(trel_id)
              if trel then
                local obj_nps = P.parse_np(S, vp.nxt)
                local function build(onp)
                  local h = newh(S, "wh_adv:" .. f .. ":do", "question")
                  local known, kr
                  if onp then known, kr = onp, "from"; h.qualifier = { rel = rel.id, role = e.subj, np = snp }
                  else known, kr = snp, "from" end
                  set_lookup(h, trel, kr, known, "to", wh)
                  h.derived_via = rel.id
                  use_wh(h, wh); use(h, bk); use_np(h, snp); use_vp(h, vp)
                  if onp then use_np(h, onp) end
                  mark_unresolved_pron(h, snp); mark_unresolved_pron(h, onp)
                  addf(h, "direction_explicit", 0.3, f .. "-question on active verb")
                  out[#out + 1] = h
                end
                if e.subj == "from" then build(nil) end -- intransitive-like: "When did X die?"
                for _, onp in ipairs(obj_nps) do build(onp) end
                if e.subj == "to" and #obj_nps == 0 then build(nil) end
              end
            end
          end
        end
      end
    elseif f == "how_many" or f == "how_much" then
      -- "How many employees does X have?"  "How much revenue does X generate?"
      local np = wh.np
      local dk = wh.nxt
      if np and np.head_kind == "relnoun" and is_do(C(S, dk)) then
        for _, snp in ipairs(P.parse_np(S, dk + 1)) do
          local vk = snp.nxt
          local vc = C(S, vk)
          local consumed_verb = false
          if vc and vc.single and (cat(vc, "aux_have") or (vc.verbs or vc.relverbs[1])) and not barrier(vc) then consumed_verb = true end
          for _, e in ipairs(np.relnouns) do
            local rel = S.lex:get_rel(e.rel)
            if rel then
              local h = newh(S, "wh_adv:" .. f, "question")
              set_lookup(h, rel, other(e.role), snp, e.role, wh)
              h.answer_form = "number"
              use_wh(h, wh); use_np(h, np); use(h, dk); use_np(h, snp)
              if consumed_verb then use(h, vk) end
              addf(h, "relnp_arg", 0.6, "how-many over a relational noun")
              mark_unresolved_pron(h, snp)
              out[#out + 1] = h
            end
          end
        end
      elseif np and (np.head_kind == "typenoun" or np.head_kind == "unknown") then
        -- "How many cities are there in France?" -> count query over a type
        local h = newh(S, "wh_adv:count", "question", "count", "count")
        h.target = np
        h.wh = wh
        h.requires_evidence = true
        use_wh(h, wh); use_np(h, np)
        local k = wh.nxt
        while C(S, k) and is_be(C(S, k)) or (C(S, k) and C(S, k).single and (C(S, k).unit.form == "there")) do use(h, k); k = k + 1 end
        h.count_target = true
        addf(h, "count_query", 0.3, "how many <type>")
        out[#out + 1] = h
      end
    elseif f == "how_adj" then
      -- "How old is X?"  "How tall is Y?"
      local bk = wh.nxt
      if is_be(C(S, bk)) then
        for _, np in ipairs(P.parse_np(S, bk + 1)) do
          local dim = wh.dim and S.lex:dim(wh.dim)
          for _, rid in ipairs(dim and dim.rels or {}) do
            local rel = S.lex:get_rel(rid)
            if rel then
              local h = newh(S, "wh_adv:how_adj", "question")
              set_lookup(h, rel, "from", np, "to", wh)
              h.answer_form = "number"
              h.dimension = wh.dim
              use_wh(h, wh); use(h, bk); use_np(h, np)
              mark_unresolved_pron(h, np)
              addf(h, "dimension_relation", 0.2, "how-" .. tostring(wh.adj) .. " via dimension " .. tostring(wh.dim))
              out[#out + 1] = h
            end
          end
        end
      end
    elseif f == "why" or f == "how" then
      local k = wh.nxt
      local h = newh(S, "wh_adv:" .. f, "question", f == "why" and "causal_explanation" or "explanation", "explain")
      h.wh = wh
      h.requires_evidence = true
      use_wh(h, wh)
      -- clause = [aux] NP VERB ...  captured generically
      local cl = F.parse_clause(S, k)
      if cl then
        h.clause = cl
        for i = k, cl.last do h.used[i] = true end
        addf(h, "clause_parsed", 0.4, "explanatory clause identified")
      else
        addf(h, "clause_missing", -0.6, "no clause to explain")
      end
      out[#out + 1] = h
    end
  end
end

-- generic clause: [aux]* [NP-subject] [aux]* [not] VERB [NP-object] -> {subj, verb, obj, neg, last}
function F.parse_clause(S, k)
  local best
  for _, snp in ipairs(P.parse_np(S, k)) do
    for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
      local cl = { subj = snp, vp = vp, lemma = vp.lemma, neg = vp.neg, voice = vp.voice, last = vp.c2 }
      local objs = P.parse_np(S, vp.nxt)
      if objs[1] then cl.obj = objs[1]; cl.last = objs[1].c2 end
      best = best or cl
    end
  end
  if not best then
    -- inverted: aux NP VERB  ("did X fail", "does X work")
    local c = C(S, k)
    if c and c.single and (cat(c, "aux_do") or cat(c, "aux_be") or cat(c, "aux_have") or cat(c, "modal")) then
      for _, snp in ipairs(P.parse_np(S, k + 1)) do
        local neg
        local vk = snp.nxt
        if P.is_neg(C(S, vk)) then neg = true; vk = vk + 1 end
        for _, vp in ipairs(P.parse_vp(S, vk, { aux_hint = (cat(c, "aux_do") and "do") or (cat(c, "aux_be") and "be") or "have" })) do
          local cl = { subj = snp, vp = vp, lemma = vp.lemma, neg = neg or vp.neg, voice = vp.voice, last = vp.c2 }
          local objs = P.parse_np(S, vp.nxt)
          if objs[1] then cl.obj = objs[1]; cl.last = objs[1].c2 end
          best = best or cl
        end
      end
    end
  end
  return best
end

---------------------------------------------------------------- frame: yes/no verification
function F.yes_no(S, out)
  local k0 = S.first
  local c0 = C(S, k0)
  if not (c0 and c0.single and (cat(c0, "aux_be") or cat(c0, "aux_do") or cat(c0, "aux_have") or cat(c0, "modal")) and not cat(c0, "wh")) then return end
  local akind = P.aux_kind(c0)
  for _, np1 in ipairs(P.parse_np(S, k0 + 1)) do
    local function base(frame)
      local h = newh(S, frame, "question", "verification", "verify")
      use(h, k0); use_np(h, np1)
      h.requires_evidence = true
      mark_unresolved_pron(h, np1)
      return h
    end
    if akind == "be" then
      local nk = np1.nxt
      -- "Is Paris the capital of France?"  /  "Is the capital of France Paris?"
      for _, np2 in ipairs(P.parse_np(S, nk)) do
        for _, pair in ipairs({ { np1, np2 }, { np2, np1 } }) do
          local value, relnp = pair[1], pair[2]
          if relnp.head_kind == "relnoun" and value.head_kind ~= "relnoun" then
            for _, o in ipairs(relnp_options(S, relnp)) do
              if o.arg then
                local h = base("yes_no:be_rel")
                use_np(h, np2)
                h.rel, h.rel_obj = o.rel.id, o.rel
                h.roles[o.known_role] = o.arg
                h.roles[o.ask_role] = value
                h.verify = { rel = o.rel.id, from = h.roles.from, to = h.roles.to }
                h.known_role, h.ask = o.known_role, nil
                addf(h, "relnp_arg", 0.6, "verification of a relational statement")
                mark_unresolved_pron(h, o.arg); mark_unresolved_pron(h, value)
                out[#out + 1] = h
              end
            end
          end
        end
        if np2.head_kind == "typenoun" and np1.head_kind == "entity" then
          local h = base("yes_no:be_type")
          use_np(h, np2)
          h.verify = { type_assertion = np2.senses and np2.senses[1] and np2.senses[1].type, subject = np1 }
          h.roles.subject = np1
          out[#out + 1] = h
        end
      end
      -- "Is Paris in France?"  "Is X located in Y?"
      local pk = nk
      local vps = P.parse_vp(S, nk, { aux_hint = "be" })
      for _, vp in ipairs(vps) do
        if vp.voice == "passive" then
          for _, e in ipairs(vp.analysis.entries) do
            local rel = S.lex:get_rel(e.rel)
            if rel then
              if e.prep and is_prep(C(S, vp.nxt), e.prep) then
                for _, np2 in ipairs(P.parse_np(S, vp.nxt + 1)) do
                  local h = base("yes_no:be_stative")
                  use_vp(h, vp); use(h, vp.nxt); use_np(h, np2)
                  h.rel, h.rel_obj = rel.id, rel
                  h.roles[e.subj] = np1; h.roles[other(e.subj)] = np2
                  h.verify = { rel = rel.id, from = h.roles.from, to = h.roles.to }
                  out[#out + 1] = h
                end
              elseif not e.prep and is_prep(C(S, vp.nxt), "by") then
                for _, np2 in ipairs(P.parse_np(S, vp.nxt + 1)) do
                  local h = base("yes_no:be_passive")
                  use_vp(h, vp); use(h, vp.nxt); use_np(h, np2)
                  h.rel, h.rel_obj = rel.id, rel
                  h.roles[other(e.subj)] = np1; h.roles[e.subj] = np2
                  h.verify = { rel = rel.id, from = h.roles.from, to = h.roles.to }
                  if vp.neg then h.polarity = "negative" end
                  out[#out + 1] = h
                end
              end
            end
          end
        end
      end
      if is_prep(C(S, pk), "in") then
        local lrel = S.lex:get_rel("located_in")
        for _, np2 in ipairs(P.parse_np(S, pk + 1)) do
          local h = base("yes_no:be_in")
          use(h, pk); use_np(h, np2)
          h.rel, h.rel_obj = "located_in", lrel
          h.roles.from, h.roles.to = np1, np2
          h.verify = { rel = "located_in", from = np1, to = np2 }
          out[#out + 1] = h
        end
      end
    elseif akind == "do" or akind == "have" or akind == "modal" then
      for _, vp in ipairs(P.parse_vp(S, np1.nxt, { aux_hint = (akind == "do" and "do") or (akind == "have" and "have") or "modal" })) do
        for _, e in ipairs(vp.analysis.entries) do
          local rel = S.lex:get_rel(e.rel)
          if rel then
            local pk = vp.nxt
            local has_prep = e.prep and is_prep(C(S, pk), e.prep)
            local ok_start = has_prep and pk + 1 or (not e.prep and pk)
            if ok_start then
              for _, np2 in ipairs(P.parse_np(S, ok_start)) do
                local h = base("yes_no:aux_verb")
                use_vp(h, vp); use_np(h, np2)
                if has_prep then use(h, pk) end
                h.rel, h.rel_obj = rel.id, rel
                h.roles[e.subj] = np1; h.roles[other(e.subj)] = np2
                h.verify = { rel = rel.id, from = h.roles.from, to = h.roles.to }
                if vp.neg then h.polarity = "negative" end
                addf(h, "direction_explicit", 0.3, "role direction fixed by active verb")
                mark_unresolved_pron(h, np2)
                out[#out + 1] = h
              end
            end
          end
        end
      end
    end
  end
end

return F
