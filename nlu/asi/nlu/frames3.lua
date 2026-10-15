-- asi.nlu.frames3: question constructions beyond the wh-first core frames (extends asi.nlu.frames / frames2; every function adds competing hypotheses).
--   wh_relnoun_stranded  "Which continent is Kenya IN?"  "What industry does X operate in?"  "In which industry does X operate?"    the wh-noun names the relation
--   wh_pred_stranded     "What is France a member OF?"  "Which company is Jane the CEO OF?"  "What is Normandy part OF?"            a predicate noun names the relation
--   wh_adj_predicate     "Which language is OFFICIAL in Brazil?"                                                                 adjective + wh-noun is a relational noun phrase
--   quantity_q           "How many people live in X?"  "How much does X cost?"  "How much is X?"  "How many people work at X?"   counted nouns / quantity verbs
--   how_adj_relnoun      "How large is the workforce of X?"                                                                     degree adjective over a relational noun
--   list_relative        "Name the startups X has invested in."  "List the countries that use the euro."                         imperative + noun phrase with a relative clause
--   yes_no_support       "Does X have its headquarters in Y?"                                                                    support verb + possessed relational noun, yes/no
-- Roles are never guessed from proximity: they come from the relation lexicon (the role a noun denotes, the subject role of a verb) and from type fit.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local F = require("asi.nlu.frames2")

local cat = P.cat
local newh, addf, use_np = F.newh, F.addf, F.use_np
local set_lookup, use_wh, use_vp = F.set_lookup, F.use_wh, F.use_vp
local is_be, is_do, is_prep = F.is_be, F.is_do, F.is_prep
local relnp_options, wh_relnoun_agreement, mark_unresolved_pron = F.relnp_options, F.wh_relnoun_agreement, F.mark_pron

local function C(S, k) return S.chunks[k] end
local function barrier(c) return c ~= nil and c.pre ~= nil end
local function other(role) return role == "to" and "from" or "to" end
local function use(h, a, b) for i = a, b or a do h.used[i] = true end end

-- words that may stand between the subject and a stranded preposition without adding a relation ("What sector is X ACTIVE in?", "Which industry does X OPERATE in?")
local FILLERS = U.set({ "active", "based", "located", "situated", "found", "operating", "working", "present", "listed", "registered", "classified", "categorised",
  "categorized", "placed", "positioned", "specialised", "specialized", "operate", "operates", "work", "works", "lie", "lies", "sit", "sits", "exist", "exists",
  "compete", "competes", "trade", "trades", "belong", "belongs", "fall", "falls", "rank", "ranks", "reside", "resides" })

-- relation noun phrases ("official language", "workforce", "chief executive officer") -> { {rel=, role=}, ... }
local function phrase_index(lex)
  if lex._phrase_index and lex._phrase_rev == lex.revision then return lex._phrase_index end
  local idx = {}
  for _, rel in ipairs(lex:all_rels()) do
    if not rel.open then
      for _, n in ipairs(rel.nouns_to or {}) do local k = n:lower(); idx[k] = idx[k] or {}; idx[k][#idx[k] + 1] = { rel = rel, role = "to" } end
      for _, n in ipairs(rel.nouns_from or {}) do local k = n:lower(); idx[k] = idx[k] or {}; idx[k][#idx[k] + 1] = { rel = rel, role = "from" } end
    end
  end
  lex._phrase_index, lex._phrase_rev = idx, lex.revision
  return idx
end

local PARTICIPLES = U.set({ "spoken", "used", "recognised", "recognized", "adopted", "designated", "declared", "accepted", "established", "named" })

local function wh_ok(wh)
  return not wh.adverbial and wh.wh ~= "how_adj" and wh.wh ~= "how_many" and wh.wh ~= "how_much"
end

---------------------------------------------------------------- the wh-noun names the relation; the preposition is stranded or fronted
function F.wh_relnoun_stranded(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh.relnoun and wh.np and wh_ok(wh) then
      local ac = C(S, wh.nxt)
      local mode = ac and not barrier(ac) and ((is_be(ac) and "be") or (is_do(ac) and "do")) or nil
      if mode then
        for _, snp in ipairs(P.parse_np(S, wh.nxt + 1)) do
          local pk, filler = snp.nxt, nil
          local fc = C(S, pk)
          if fc and fc.single and not fc.masked and not barrier(fc) and FILLERS[fc.unit.form] then filler = pk; pk = pk + 1 end
          local pc = C(S, pk)
          local stranded = pc and pc.single and not pc.masked and not barrier(pc) and cat(pc, "prep") and pk == S.last
          local fronted = wh.pied and pk > S.last
          if (stranded or fronted) and (mode == "be" or filler) then
            for _, e in ipairs(wh.np.relnouns) do
              local rel = S.lex:get_rel(e.rel)
              if rel then
                local h = newh(S, "wh_relnoun_stranded", "question")
                set_lookup(h, rel, other(e.role), snp, e.role, wh)
                use_wh(h, wh); use(h, wh.nxt); use_np(h, snp)
                if filler then use(h, filler) end
                if stranded then use(h, pk) elseif wh.pied then h.pied_consumed = true end
                addf(h, "stranded_relnoun", 0.7, "the wh-noun '" .. tostring(wh.np.head and wh.np.head.form) .. "' names " .. rel.id .. "; the preposition is stranded or fronted")
                wh_relnoun_agreement(h, wh, rel)
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

---------------------------------------------------------------- a predicate noun names the relation: "What is France a member of?"
function F.wh_pred_stranded(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh_ok(wh) and not wh.relnoun then
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        for _, snp in ipairs(P.parse_np(S, wh.nxt + 1)) do
          for _, rnp in ipairs(P.parse_np(S, snp.nxt)) do
            if rnp.head_kind == "relnoun" and not rnp.of_arg and not rnp.possessor then
              local pc = C(S, rnp.nxt)
              -- the preposition is stranded ("Which country is Bamako the capital OF?") or fronted with the wh-phrase ("OF which country is Bamako the capital?")
              local stranded = pc and pc.single and not pc.masked and not barrier(pc) and cat(pc, "prep") and rnp.nxt == S.last
              local fronted = wh.pied and rnp.nxt > S.last
              if stranded or fronted then
                for _, e in ipairs(rnp.relnouns) do
                  local rel = S.lex:get_rel(e.rel)
                  -- the predicate noun denotes role e.role of the SUBJECT ("France is a member of ..." / "Jane is the CEO of ..."); the preposition's object is the other role
                  local ask = other(e.role)
                  if rel and ((not wh.type) or S.lex:compat(rel[ask], wh.type) >= 0.5) then
                    local h = newh(S, "wh_pred_stranded", "question")
                    set_lookup(h, rel, e.role, snp, ask, wh)
                    use_wh(h, wh); use(h, wh.nxt); use_np(h, snp); use_np(h, rnp)
                    if stranded then use(h, rnp.nxt) else h.pied_consumed = true end
                    addf(h, "pred_noun_relation", 0.7, "the predicate noun '" .. tostring(rnp.head and rnp.head.form) .. "' names " .. rel.id .. " for the subject")
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
end

---------------------------------------------------------------- adjective + wh-noun is a relational noun phrase: "Which language is official in Brazil?"
function F.wh_adj_predicate(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh_ok(wh) and wh.np and not wh.relnoun and wh.np.head and wh.np.head.single and (wh.np.head_kind == "typenoun" or wh.np.head_kind == "concept") then
      local bc = C(S, wh.nxt)
      local ac = C(S, wh.nxt + 1)
      if is_be(bc) and not barrier(bc) and ac and ac.single and not ac.masked and not barrier(ac) then
        local adj, shift = ac.unit.form, 0
        -- "officially spoken" / "nationally recognised": the adverb stands for the adjective of the relational noun phrase
        local vc = C(S, wh.nxt + 2)
        if adj:match("ly$") and #adj > 4 and vc and vc.single and not vc.masked and not barrier(vc) and PARTICIPLES[vc.unit.form] then adj = adj:gsub("ly$", ""); shift = 1 end
        local phrase = adj .. " " .. wh.np.head.unit.form
        local pc = C(S, wh.nxt + 2 + shift)
        if pc and pc.single and not pc.masked and not barrier(pc) and cat(pc, "prep") then
          for _, ent in ipairs(phrase_index(S.lex)[phrase] or {}) do
            for _, np in ipairs(P.parse_np(S, wh.nxt + 3 + shift)) do
              local h = newh(S, "wh_adj_predicate", "question")
              set_lookup(h, ent.rel, other(ent.role), np, ent.role, wh)
              use_wh(h, wh); use(h, wh.nxt, wh.nxt + 2 + shift); use_np(h, np)
              addf(h, "adjective_noun_relation", 0.7, "'" .. phrase .. "' is a relational noun phrase of " .. ent.rel.id)
              mark_unresolved_pron(h, np)
              out[#out + 1] = h
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- impersonal subject: "What currency do THEY use in Zembrova?"  "Which currency do people use in Peru?"
local IMPERSONAL = U.set({ "they", "people", "folks", "locals", "residents", "citizens", "everyone", "you" })
function F.wh_impersonal(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh_ok(wh) and (wh.wh == "what" or wh.wh == "which") then
      local ac = C(S, wh.nxt)
      if is_do(ac) and not barrier(ac) then
        local pc = C(S, wh.nxt + 1)
        if pc and pc.single and not pc.masked and not barrier(pc) and IMPERSONAL[pc.unit.form] then
          for _, vp in ipairs(P.parse_vp(S, wh.nxt + 2, { aux_hint = "do" })) do
            local lp = C(S, vp.nxt)
            if lp and lp.single and not lp.masked and not barrier(lp) and cat(lp, "prep") and (lp.unit.form == "in" or lp.unit.form == "at" or lp.unit.form == "across" or lp.unit.form == "throughout") then
              for _, np in ipairs(P.parse_np(S, vp.nxt + 1)) do
                for _, e in ipairs(vp.analysis.entries or {}) do
                  local rel = S.lex:get_rel(e.rel)
                  -- the place is the holder of the relation the support verb carries ("use ... in Zembrova" = Zembrova's currency)
                  if rel and e.support and e.subj == "from" and F.support_licensed(S, e, rel, wh, "to") then
                    local h = newh(S, "wh_impersonal", "question")
                    set_lookup(h, rel, "from", np, "to", wh)
                    use_wh(h, wh); use(h, wh.nxt, wh.nxt + 1); use_vp(h, vp); use(h, vp.nxt); use_np(h, np)
                    addf(h, "impersonal_subject", 0.8, "'" .. pc.unit.form .. " " .. tostring(vp.lemma) .. " in X' is the generic 'what X uses'")
                    wh_relnoun_agreement(h, wh, rel)
                    mark_unresolved_pron(h, np)
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
end

---------------------------------------------------------------- "Which country is Elena Vasquez from?" / "What does Ithari Foundry do?"
function F.wh_origin(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh_ok(wh) and wh.np and not wh.relnoun and wh.type and (wh.np.head_kind == "typenoun") then
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        for _, snp in ipairs(P.parse_np(S, wh.nxt + 1)) do
          local pc = C(S, snp.nxt)
          if pc and pc.single and not pc.masked and not barrier(pc) and pc.unit.form == "from" and snp.nxt == S.last then
            local rid = S.lex:isa(wh.type, "country") and "nationality" or ((S.lex:isa(wh.type, "city") or wh.type == "place") and "birth_place" or nil)
            local rel = rid and S.lex:get_rel(rid)
            if rel then
              local h = newh(S, "wh_origin", "question")
              set_lookup(h, rel, "from", snp, "to", wh)
              use_wh(h, wh); use(h, wh.nxt); use_np(h, snp); use(h, snp.nxt)
              addf(h, "origin_from", 0.7, "'" .. tostring(wh.np.head and wh.np.head.form) .. " ... from' asks for the origin (" .. rel.id .. ") of a person")
              mark_unresolved_pron(h, snp)
              out[#out + 1] = h
            end
          end
        end
      end
    end
  end
end

function F.what_does_do(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh.wh == "what" and not wh.np and not wh.adverbial then
      local ac, k = C(S, wh.nxt), wh.nxt
      if is_do(ac) and not barrier(ac) then
        for _, snp in ipairs(P.parse_np(S, k + 1)) do
          local vc = C(S, snp.nxt)
          if vc and vc.single and not vc.masked and not barrier(vc) and vc.unit.form == "do" and snp.nxt == S.last and (snp.head_kind == "entity" or snp.head_kind == "unknown") then
            local rel = S.lex:get_rel("industry")
            if rel then
              local h = newh(S, "what_does_do", "question")
              set_lookup(h, rel, "from", snp, "to", wh)
              use_wh(h, wh); use(h, k); use_np(h, snp); use(h, snp.nxt)
              addf(h, "what_does_x_do", 0.6, "'What does X do?' asks for the business X is in")
              mark_unresolved_pron(h, snp)
              out[#out + 1] = h
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- quantities: counted nouns, "how much", degree adjectives over relational nouns
local function count_rels(lex, noun)
  local out = {}
  for _, rel in ipairs(lex:all_rels()) do
    for _, n in ipairs(rel.count_nouns or {}) do if n == noun then out[#out + 1] = rel end end
  end
  return out
end

-- the lemmas a chunk can be a form of (the lexicon's verbs, the inflection guesser, and the surface form itself as a base form)
local Morph = require("asi.nlu.morph")
local function lemma_set(S, c)
  local set = {}
  if not c or not c.single or c.masked then return set end
  for _, a in ipairs(P.verb_analyses(S, c)) do set[a.lemma] = true end
  for _, g in ipairs(Morph.guess(c.unit.form)) do if g.pos == "verb" then set[g.lemma] = true end end
  set[c.unit.form] = true
  return set
end

local function verb_entry(rel, lemma)
  local out = {}
  for _, cv in ipairs(rel.count_verbs or {}) do if cv.lemma == lemma then out[#out + 1] = cv end end
  return out
end

function F.quantity_q(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    -- "How many PEOPLE live in X?" / "How many residents are there in X?" / "How many people does X employ?"
    if wh.wh == "how_many" and wh.np and wh.np.head and wh.np.head.single and wh.np.head_kind ~= "relnoun" then
      local noun = wh.np.head.unit.form
      for _, rel in ipairs(count_rels(S.lex, noun)) do
        local function emit(frame, known, vp_or_k, extra)
          local h = newh(S, frame, "question")
          set_lookup(h, rel, "from", known, "to", wh)
          h.answer_form = "number"
          use_wh(h, wh); use_np(h, known)
          if extra then extra(h) end
          addf(h, "counted_noun", 0.7, "'how many " .. noun .. "' counts the value of " .. rel.id)
          mark_unresolved_pron(h, known)
          out[#out + 1] = h
        end
        local nk = wh.nxt
        local c1 = C(S, nk)
        -- (a) subject = the counted people:  live in X / work at X / are living in X
        do
          local vk = nk
          local progressive = false
          if is_be(c1) and not barrier(c1) and not (C(S, nk + 1) and C(S, nk + 1).single and C(S, nk + 1).unit.form == "there") then vk = nk + 1; progressive = true end
          local vc = C(S, vk)
          if vc and vc.single and not vc.masked and not barrier(vc) then
            for lemma in pairs(lemma_set(S, vc)) do
              for _, ce in ipairs(verb_entry(rel, lemma)) do
                local function mark(h) if progressive then use(h, nk) end; use(h, vk) end
                if ce.prep then
                  local pk = vk + 1
                  if is_prep(C(S, pk), ce.prep) then
                    for _, np in ipairs(P.parse_np(S, pk + 1)) do emit("quantity:count_verb", np, nil, function(h) mark(h); use(h, pk) end) end
                  else
                    -- "How many people live THERE?": the locative pro-form carries the preposition and the place
                    for _, np in ipairs(P.parse_np(S, pk)) do
                      if np.head_kind == "pronoun" and np.pron and np.pron.cats and np.pron.cats.pron_loc then emit("quantity:count_verb", np, nil, mark) end
                    end
                  end
                elseif ce.lemma ~= "have" then
                  for _, np in ipairs(P.parse_np(S, vk + 1)) do emit("quantity:count_verb", np, nil, mark) end
                end
              end
            end
          end
        end
        for _, vp in ipairs(P.parse_vp(S, nk)) do
          -- passive:  "How many people are employed by X?"
          if vp.voice == "passive" and (vp.lemma == "employ") and rel.id == "employees" then
            local pk = vp.nxt
            if is_prep(C(S, pk), "by") or is_prep(C(S, pk), "at") then
              for _, np in ipairs(P.parse_np(S, pk + 1)) do emit("quantity:count_passive", np, nil, function(h) use_vp(h, vp); use(h, pk) end) end
            end
          end
        end
        -- (b) "are there in X" / "are there at X"
        if is_be(c1) and not barrier(c1) then
          local c2, c3 = C(S, nk + 1), C(S, nk + 2)
          if c2 and c2.single and c2.unit.form == "there" and c3 and c3.single and cat(c3, "prep") and not barrier(c3) and (c3.unit.form == "in" or c3.unit.form == "at") then
            for _, np in ipairs(P.parse_np(S, nk + 3)) do emit("quantity:there_are", np, nil, function(h) use(h, nk, nk + 2) end) end
          end
        end
        -- (c) do-support:  "How many people does X have / employ?"
        if is_do(c1) and not barrier(c1) then
          for _, snp in ipairs(P.parse_np(S, nk + 1)) do
            for _, vp in ipairs(P.parse_vp(S, snp.nxt, { aux_hint = "do" })) do
              for _, ce in ipairs(verb_entry(rel, vp.lemma)) do
                if not ce.prep then emit("quantity:do_count", snp, nil, function(h) use(h, nk); use_vp(h, vp) end) end
              end
            end
          end
        end
      end
    end
    -- bare "How much does X cost?" / "How much is X?"
    if (wh.wh == "how_much" or wh.wh == "how_many") and wh.bare then
      local ac = C(S, wh.nxt)
      if is_do(ac) then
        for _, snp in ipairs(P.parse_np(S, wh.nxt + 1)) do
          for _, vp in ipairs(P.parse_vp(S, snp.nxt, { aux_hint = "do" })) do
            for _, e in ipairs(vp.analysis.entries or {}) do
              local rel = S.lex:get_rel(e.rel)
              if rel and not e.support and not e.prep and S.lex:compat(rel.to, "number") >= 0.9 then
                local h = newh(S, "quantity:how_much_verb", "question")
                set_lookup(h, rel, e.subj, snp, other(e.subj), wh)
                h.answer_form = "number"
                use_wh(h, wh); use(h, wh.nxt); use_np(h, snp); use_vp(h, vp)
                addf(h, "quantity_verb", 0.7, "'how much' asks for the numeric value of " .. rel.id .. " (verb '" .. tostring(vp.lemma) .. "')")
                mark_unresolved_pron(h, snp)
                out[#out + 1] = h
              end
            end
          end
        end
      elseif is_be(ac) and wh.wh == "how_much" then
        for _, np in ipairs(P.parse_np(S, wh.nxt + 1)) do
          for _, rel in ipairs(S.lex:all_rels()) do
            if rel.howmuch and (np.head_kind == "entity" or np.head_kind == "typenoun" or np.head_kind == "unknown") then
              local h = newh(S, "quantity:how_much_is", "question")
              set_lookup(h, rel, "from", np, "to", wh)
              h.answer_form = "number"
              use_wh(h, wh); use(h, wh.nxt); use_np(h, np)
              addf(h, "how_much_default", 0.4, "'how much is X' asks for the " .. rel.id .. " of a product-like thing")
              mark_unresolved_pron(h, np)
              out[#out + 1] = h
            end
          end
        end
      end
    end
  end
end

-- "How large is the workforce of X?"  "How big is the population of Chad?"  "How high is the revenue of X?"
function F.how_adj_relnoun(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh.wh == "how_adj" then
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        for _, np in ipairs(P.parse_np(S, wh.nxt + 1)) do
          if np.head_kind == "relnoun" and (np.of_arg or np.possessor) then
            for _, o in ipairs(relnp_options(S, np)) do
              if o.arg and S.lex:compat(o.rel.to, "number") >= 0.9 then
                local h = newh(S, "how_adj_relnoun", "question")
                set_lookup(h, o.rel, o.known_role, o.arg, o.ask_role, wh)
                h.answer_form = "number"
                use_wh(h, wh); use(h, wh.nxt); use_np(h, np)
                addf(h, "relnp_arg", 0.7, "relational noun with explicit argument")
                addf(h, "degree_over_relnoun", 0.2, "'how " .. tostring(wh.adj) .. "' over a numeric relational noun")
                F.option_factors(h, o)
                mark_unresolved_pron(h, o.arg)
                out[#out + 1] = h
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- elliptical follow-ups: "What about Jupiter?"  "Same question for Sundrel Energy."  "Sorry, I meant Nokian Tyres."
-- The previous relational question of the conversation is re-asked about the new argument (the memory keeps it as `last_query`).
function F.ellipsis(S, out)
  local view = S.ctx and S.ctx.discourse
  local mem = view and view.mem
  if not mem then return end
  local lq, cmp = mem.last_query, mem.comparison
  if lq and lq.turn >= (mem.turn or 0) then lq = nil end
  if cmp and cmp.turn >= (mem.turn or 0) then cmp = nil end
  if not lq and not cmp then return end
  -- the more recent of the two earlier requests is the one that is continued ("And what about Tanzania?" after a comparison adds an item to it)
  local continue_cmp = cmp ~= nil and (lq == nil or cmp.turn > lq.turn)
  local c0 = C(S, S.first)
  local n = c0 and not c0.masked and S.lex:cue_at("ellipsis_open", S.units, c0.u1)
  if not n then
    -- "And Bosch?", "Also of Bosch?": the sentence-initial conjunction was stripped as a lead-in; it is the whole cue
    local lc = S.wrapper and S.wrapper.lead_in and S.first > 1 and C(S, S.first - 1)
    if lc and lc.single and (lc.unit.form == "and" or lc.unit.form == "also") then n = 0 else return end
  end
  local k, consumed = S.first, 0
  while k <= S.last and consumed < n do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); k = k + 1 end
  if consumed ~= n or k > S.last then return end
  -- "And of Bosch?": the preposition that introduces the new argument of a relational noun belongs to the cue
  local pc = C(S, k)
  if pc and pc.single and not pc.masked and not barrier(pc) and pc.unit.form == "of" and k < S.last then k = k + 1 end
  local rel = S.lex:get_rel(continue_cmp and cmp.rel or (lq and lq.rel))
  if not rel and not continue_cmp then return end
  for _, np in ipairs(P.parse_np(S, k)) do
    -- the whole remainder is the new argument (a name, an unknown noun phrase or a pronoun)
    if np.nxt > S.last and (np.head_kind == "entity" or np.head_kind == "unknown" or np.head_kind == "typenoun" or np.head_kind == "pronoun") and not np.of_arg then
      local h
      if continue_cmp then
        h = newh(S, "ellipsis:comparison", "question", "comparison", "compare")
        h.items = { np }
        if rel then h.rel, h.rel_obj = rel.id, rel end
        h.dimension = cmp.dimension
        h.requires_evidence = true
        h.ellipsis = { turn = cmp.turn, text = "" }
        addf(h, "elliptical_comparison", 0.9, "adds an item to the comparison of the previous request (turn " .. tostring(cmp.turn) .. ")")
      else
        h = newh(S, "ellipsis:requery", "question")
        set_lookup(h, rel, lq.known_role, np, lq.ask, nil)
        h.ellipsis = { turn = lq.turn, text = lq.text }
        addf(h, "elliptical_requery", 0.9, "re-asks the previous question (" .. rel.id .. ", turn " .. tostring(lq.turn) .. ") about a new argument")
      end
      use(h, S.first, k - 1); use_np(h, np)
      mark_unresolved_pron(h, np)
      out[#out + 1] = h
    end
  end
end

---------------------------------------------------------------- comparisons
local DIFF_NOUNS = U.set({ "difference", "differences", "similarity", "similarities", "contrast", "contrasts", "distinction", "distinctions", "comparison" })

-- "What are the main differences between X and Y?"  "How do X and Y differ?"  "How does X compare to Y?"
function F.compare_differences(S, out)
  local function between(k, wh, base_used)
    for _, np1 in ipairs(P.parse_np(S, k)) do
      local jc = C(S, np1.nxt)
      if jc and jc.single and not jc.masked and not barrier(jc) and jc.unit.form == "and" then
        for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
          if np2.nxt > S.last then
            local h = newh(S, "compare_differences", "question", "comparison", "diff")
            use_wh(h, wh); use(h, np1.nxt); use_np(h, np1); use_np(h, np2)
            for i = base_used, np1.c1 - 1 do h.used[i] = true end
            h.items = { np1, np2 }
            h.requires_evidence = true
            mark_unresolved_pron(h, np1); mark_unresolved_pron(h, np2)
            addf(h, "differences_between_two", 0.8, "a request for the differences between two items")
            out[#out + 1] = h
          end
        end
      end
    end
  end
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh.wh == "what" and not wh.adverbial and not wh.np then
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        for _, dnp in ipairs(P.parse_np(S, wh.nxt + 1)) do
          if dnp.head and dnp.head.single and DIFF_NOUNS[dnp.head.unit.form] then
            local pc = C(S, dnp.nxt)
            if pc and pc.single and not pc.masked and not barrier(pc) and pc.unit.form == "between" then between(dnp.nxt + 1, wh, wh.nxt) end
          end
        end
      end
    elseif wh.wh == "how" and wh.adverbial then
      local ac = C(S, wh.nxt)
      if ac and ac.single and not ac.masked and not barrier(ac) and (cat(ac, "aux_do") or cat(ac, "aux_be")) then
        -- "How do X and Y differ?" / "How are X and Y different?"
        for _, np1 in ipairs(P.parse_np(S, wh.nxt + 1)) do
          local jc = C(S, np1.nxt)
          if jc and jc.single and not jc.masked and not barrier(jc) and jc.unit.form == "and" then
            for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
              local vc = C(S, np2.nxt)
              if vc and vc.single and not vc.masked and not barrier(vc) and np2.nxt == S.last and (vc.unit.form == "differ" or vc.unit.form == "different" or vc.unit.form == "similar" or vc.unit.form == "compare" or vc.unit.form == "alike") then
                local h = newh(S, "compare_differences:how_differ", "question", "comparison", "diff")
                use_wh(h, wh); use(h, wh.nxt); use_np(h, np1); use(h, np1.nxt); use_np(h, np2); use(h, np2.nxt)
                h.items = { np1, np2 }
                h.requires_evidence = true
                mark_unresolved_pron(h, np1); mark_unresolved_pron(h, np2)
                addf(h, "differences_between_two", 0.8, "how two items differ")
                out[#out + 1] = h
              end
            end
          end
          -- "How does X differ from Y?" / "How does X compare to Y?"
          local vc = C(S, np1.nxt)
          if vc and vc.single and not vc.masked and not barrier(vc) and (vc.unit.form == "differ" or vc.unit.form == "compare" or vc.unit.form == "stack") then
            local pc = C(S, np1.nxt + 1)
            if pc and pc.single and not pc.masked and not barrier(pc) and (pc.unit.form == "from" or pc.unit.form == "to" or pc.unit.form == "with" or pc.unit.form == "against" or pc.unit.form == "up") then
              local qk = np1.nxt + 2
              local q = C(S, qk)
              if q and q.single and q.unit.form == "to" and pc.unit.form == "up" then qk = qk + 1 end
              for _, np2 in ipairs(P.parse_np(S, qk)) do
                if np2.nxt > S.last then
                  local h = newh(S, "compare_differences:how_compare", "question", "comparison", "diff")
                  use_wh(h, wh); use(h, wh.nxt); use_np(h, np1); use(h, np1.nxt, qk - 1); use_np(h, np2)
                  h.items = { np1, np2 }
                  h.requires_evidence = true
                  mark_unresolved_pron(h, np1); mark_unresolved_pron(h, np2)
                  addf(h, "differences_between_two", 0.8, "how one item differs from / compares with another")
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

-- "Which of the two firms, A or B, has more employees?"  "Which has more employees, A or B?"  "Which of the two has more employees?"
local MORE_WORDS = { more = "more", greater = "more", larger = "more", bigger = "more", fewer = "fewer", less = "fewer", smaller = "fewer" }
function F.compare_which_of_two(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if (wh.wh == "which" or wh.wh == "who") and not wh.adverbial and not wh.np then
      local k = wh.nxt
      local items = {}
      local oc = C(S, k)
      -- "of the two firms," / "of the two," / "of A and B"
      if oc and oc.single and not oc.masked and not barrier(oc) and oc.unit.form == "of" then
        k = k + 1
        local dc, tc = C(S, k), C(S, k + 1)
        if dc and tc and dc.single and tc.single and dc.unit.form == "the" and (tc.unit.form == "two" or tc.unit.form == "both") then
          k = k + 2
          local nn = C(S, k)
          if nn and not barrier(nn) and not nn.pre and (nn.senses and #nn.senses > 0) then k = k + 1 end   -- "the two FIRMS"
        elseif dc and dc.single and (dc.unit.form == "them" or dc.unit.form == "these" or dc.unit.form == "those") then k = k + 1 end
        -- optional listed items:  ", A or B,"
        local lc = C(S, k)
        if lc and lc.pre and lc.pre:find("comma") then
          for _, np1 in ipairs(P.parse_np(S, k)) do
            local jc = C(S, np1.nxt)
            if jc and jc.single and (jc.unit.form == "or" or jc.unit.form == "and") then
              for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
                items = { np1, np2 }
                k = np2.nxt
                break
              end
            end
            break
          end
        end
      end
      -- verb: has / have + more|fewer N
      local hv = C(S, k)
      if hv and hv.single and not hv.masked and cat(hv, "aux_have") then
        local mw = C(S, k + 1)
        local deg = mw and mw.single and MORE_WORDS[mw.unit.form]
        if deg then
          for _, np in ipairs(P.parse_np(S, k + 2)) do
            if np.head_kind == "relnoun" and (np.nxt > S.last or true) then
              for _, e in ipairs(np.relnouns) do
                local rel = S.lex:get_rel(e.rel)
                if rel and S.lex:compat(rel.to, "number") >= 0.9 then
                  -- items may also follow:  "..., A or B"
                  local its = items
                  local nk = np.nxt
                  if #its == 0 then
                    local lc = C(S, nk)
                    if lc and lc.pre and lc.pre:find("comma") then
                      for _, n1 in ipairs(P.parse_np(S, nk)) do
                        local jc = C(S, n1.nxt)
                        if jc and jc.single and (jc.unit.form == "or" or jc.unit.form == "and") then
                          for _, n2 in ipairs(P.parse_np(S, n1.nxt + 1)) do if n2.nxt > S.last then its = { n1, n2 } end; break end
                        end
                        break
                      end
                    end
                  end
                  if #its == 0 and S.vs_items then its = S.vs_items end      -- "Siemens vs Bosch: who has more employees?"
                  local h = newh(S, "compare_which_of_two", "question", "comparison", "rank_attribute")
                  h.wh = wh
                  h.rel, h.rel_obj = rel.id, rel
                  use_wh(h, wh); use(h, wh.nxt, k + 1); use_np(h, np)
                  for _, it in ipairs(its) do use_np(h, it) end
                  if #its == 2 then h.items = its; use(h, its[1].nxt) end
                  h.degree = deg == "more" and "comp_more" or "comp_less"
                  h.dimension = "size"
                  h.requires_evidence = true
                  addf(h, "comparison_over_attribute", 0.9, "'" .. tostring(mw.unit.form) .. " " .. tostring(np.head and np.head.form) .. "' ranks two items on " .. rel.id)
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

---------------------------------------------------------------- imperative + noun phrase with a relative clause
local LIST_VERBS = U.set({ "name", "list", "enumerate", "give", "show", "tell", "find", "get", "provide", "identify", "mention", "state", "fetch", "retrieve", "display", "cite" })

function F.list_relative(S, out)
  local k = S.first
  local vc = C(S, k)
  local head
  if vc and vc.single and not vc.masked and LIST_VERBS[vc.unit.form] and not barrier(vc) then
    head = k
    k = k + 1
    local mc = C(S, k)
    if mc and mc.single and not mc.masked and (mc.unit.form == "me" or mc.unit.form == "us") and not barrier(mc) then k = k + 1 end
  else
    -- "Give me the firms ...": the request wrapper already took the verb and "me"
    local w = S.wrapper
    local wk = w and w.chunks and w.chunks[1]
    local wc = wk and C(S, wk)
    if not (wc and wc.single and LIST_VERBS[wc.unit.form]) then return end
    head = wk
  end
  for _, nnp in ipairs(P.parse_np(S, k, { no_of = true })) do
    local t = nnp.senses and nnp.senses[1] and nnp.senses[1].type
    if (nnp.head_kind == "typenoun" or nnp.head_kind == "unknown") and nnp.head and not nnp.of_arg then
      local rk = nnp.nxt
      local rc = C(S, rk)
      local relativizer = rc and rc.single and not rc.masked and not barrier(rc) and (rc.unit.form == "that" or rc.unit.form == "which" or rc.unit.form == "who")
      if relativizer then rk = rk + 1 end
      local wh = { wh = "which", type = t, np = nnp, nxt = rk, c1 = nnp.c1, c2 = nnp.c2, u1 = nnp.u1, u2 = nnp.u2, plural = true, synthetic = true }
      -- the known side of a LOOKUP is a named thing ("Sequoia Capital", "the euro"); a descriptive phrase ("Series A funding") makes the clause a FILTER of a search
      local function named(np)
        return np.head_kind == "entity" or (np.head_kind == "unknown" and np.head and np.head.cap)
          or ((np.head_kind == "typenoun" or np.head_kind == "unknown") and not np.plural and np.det == "the")   -- "the euro": one definite thing
      end
      local function finish(h, rel, known_role, known_np, ask_role, vp, prep_k)
        if not named(known_np) then return end
        set_lookup(h, rel, known_role, known_np, ask_role, wh)
        use(h, head, k - 1); use_np(h, nnp); use_np(h, known_np); use_vp(h, vp)
        if relativizer then use(h, nnp.nxt) end
        if prep_k then use(h, prep_k) end
        mark_unresolved_pron(h, known_np)
        out[#out + 1] = h
      end
      -- (a) object gap:  the startups [that] SEQUOIA CAPITAL HAS INVESTED IN        subject NP, then a verb group, a stranded preposition is allowed
      for _, snp in ipairs(P.parse_np(S, rk)) do
        for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
          for _, e in ipairs(vp.analysis.entries or {}) do
            local rel = S.lex:get_rel(e.rel)
            if rel and vp.voice == "active" and F.support_licensed(S, e, rel, wh, other(e.subj)) then
              local pk = vp.nxt
              local prep_ok = (not e.prep and pk > S.last) or (e.prep and is_prep(C(S, pk), e.prep) and pk == S.last)
              if prep_ok then
                local h = newh(S, "list_relative:object_gap", "request")
                finish(h, rel, e.subj, snp, other(e.subj), vp, e.prep and pk or nil)
                addf(h, "direction_explicit", 0.35, "role direction fixed by the relative clause's object gap (subject=" .. e.subj .. ")")
                addf(h, "list_request", 0.3, "imperative + noun phrase + relative clause")
              end
            end
          end
        end
      end
      -- (c) agent phrase:  all books BY Imelda Strand
      do
        local bc = C(S, nnp.nxt)
        if bc and bc.single and not bc.masked and not barrier(bc) and bc.unit.form == "by" and t then
          for _, anp in ipairs(P.parse_np(S, nnp.nxt + 1)) do
            if anp.nxt > S.last then
              for _, rel in ipairs(S.lex:all_rels()) do
                if not rel.open and (rel.id == "author" or rel.id == "creator" or rel.id == "developer") and S.lex:compat(t, rel.from) >= 0.9 then
                  local h = newh(S, "list_relative:by_agent", "request")
                  set_lookup(h, rel, "to", anp, "from", wh)
                  use(h, head, k - 1); use_np(h, nnp); use(h, nnp.nxt); use_np(h, anp)
                  addf(h, "by_agent", 0.6, "'" .. tostring(nnp.head and nnp.head.form) .. " by X' lists works whose " .. rel.id .. " is X")
                  if rel.id == "author" and S.lex:isa(t, "publication") then addf(h, "literary_work", 0.15, "a book/article has an author") end
                  mark_unresolved_pron(h, anp)
                  out[#out + 1] = h
                end
              end
            end
          end
        end
      end
      -- (b) subject gap:  the countries [that] USE THE EURO
      if relativizer or true then
        for _, vp in ipairs(P.parse_vp(S, rk)) do
          if vp.voice == "active" then
            for _, e in ipairs(vp.analysis.entries or {}) do
              local rel = S.lex:get_rel(e.rel)
              if rel and F.support_licensed(S, e, rel, wh, e.subj) then
                local pk = vp.nxt
                local ok_prep = (not e.prep) or is_prep(C(S, pk), e.prep)
                if ok_prep then
                  local ok = pk + (e.prep and 1 or 0)
                  for _, onp in ipairs(P.parse_np(S, ok)) do
                    if onp.nxt > S.last then
                      local h = newh(S, "list_relative:subject_gap", "request")
                      finish(h, rel, other(e.subj), onp, e.subj, vp, e.prep and pk or nil)
                      addf(h, "direction_explicit", 0.35, "role direction fixed by voice/lexicon (subject gap, subj=" .. e.subj .. ")")
                      addf(h, "list_request", 0.3, "imperative + noun phrase + relative clause")
                      if not relativizer then addf(h, "no_relativizer", -0.25, "a reduced relative clause without 'that'") end
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

---------------------------------------------------------------- a resource named with a value in a directive sentence: "the analysis should now run on dataset 2025 rather than the one I mentioned before"
-- "Scrap the earlier dataset, I want dataset 2026 used from here on."  "Whenever you run the analysis, pull from the 2020 dataset and nothing else."
-- Any sentence that frames a resource phrase WITH A VALUE (the 2021 dataset, dataset 2019, the dataset named 2026, version 3.2, the file a.csv) as what to use is an instruction
-- about that resource's slot -- whatever the verb ("lean on", "run on", "pull from", "built on", "carried out on", "go with").  Questions and reported speech are not.
local DIR_WORDS = U.set({ "use", "using", "run", "running", "pull", "pulling", "build", "built", "base", "based", "carry", "carried", "lean", "rely", "relying", "work", "working",
  "analyse", "analyze", "analysed", "analyzed", "go", "going", "switch", "switching", "stick", "sticking", "draw", "drawing", "take", "taking", "apply", "applied", "operate",
  "compute", "computed", "calculate", "calculated", "process", "load", "read", "query", "select", "choose", "pick", "prefer", "adopt", "default", "point", "restrict", "limit",
  "stay", "remain", "keep", "set", "need", "want", "wish", "should", "must", "ensure", "replace", "replaces", "swap", "change", "update", "upgrade", "move", "refer", "consult", "feed", "fall" })
local REPORT_MARKERS = U.set({ "she", "he", "they", "someone", "somebody", "friend", "colleague", "teacher", "professor", "boss", "manager", "said", "says", "told", "tells", "asked", "asks",
  "suggested", "suggests", "recommended", "recommends", "mentioned", "claimed", "thinks", "thought", "reckons", "reckoned", "heard", "read" })
local FIRST_PERSON_DIRECTIVE = U.set({ "i", "we", "let's", "lets", "please", "kindly" })
local NAMING = U.set({ "named", "called", "titled", "labelled", "labeled", "dubbed", "number", "no", "id", "version" })
local REPLACE_VERBS = U.set({ "use", "switch", "go", "pick", "choose", "take", "try", "prefer", "adopt", "select", "rely", "stick", "move" })
function F.resource_directive(S, out)
  if S.sentence and S.sentence.question_mark then return end
  if #P.parse_wh(S, S.first) > 0 then return end
  local lex = S.lex
  local has_dir, reported, first_person = false, false, false
  for i = S.first, S.last do
    local c = C(S, i)
    local f = c and not c.masked and ((c.single and c.unit.form) or (c.form and c.form:match("^(%S+)")))   -- a multiword verb ("set up") counts by its first word
    if f then
      if DIR_WORDS[f] then has_dir = true end
      -- "On second thought, ...": the idiom is not a report of someone's thinking
      local prevc = C(S, i - 1)
      local idiom = f == "thought" and prevc and prevc.single and (prevc.unit.form == "second" or prevc.unit.form == "first" or prevc.unit.form == "after")
      if REPORT_MARKERS[f] and not idiom then reported = true end
      if FIRST_PERSON_DIRECTIVE[f] then first_person = true end
      if f == "let" then
        local nx = C(S, i + 1)
        if nx and nx.single and (nx.unit.form == "us" or nx.unit.form == "'s" or cat(nx, "clitic_s")) then first_person = true end
      end
    end
  end
  if not has_dir then return end
  -- "My friend said to use the 2021 dataset in her statistics class.": reported, no directive of the speaker's own
  if reported and not first_person then return end
  local function emit(c, slot, value)
    -- a retraction or replacement marker anywhere makes it a correction; a standing marker makes it persist
    local correction, persist = false, false
    for k = S.first, S.last do
      local ck = C(S, k)
      if ck and not ck.masked then
        if lex:cue_at("correction", S.units, ck.u1) or lex:cue_at("revoke", S.units, ck.u1) then correction = true end
        if ck.temporal and (ck.temporal.kind == "persist" or ck.temporal.persist) then persist = true end
        if ck.single and (ck.unit.form == "instead" or ck.unit.form == "replace" or ck.unit.form == "replaces" or ck.unit.form == "scrap" or ck.unit.form == "disregard") then correction = true end
        if ck.single and (ck.unit.form == "whenever" or ck.unit.form == "always" or ck.unit.form == "everytime") then persist = true end
      end
    end
    local h = newh(S, "instruction:resource_directive", "instruction", "instruction_update", "instruct")
    for k = S.first, S.last do if C(S, k) and not C(S, k).masked then h.used[k] = true end end
    h.instruction = { verb = "use", act = "constraint", np = { head = c, head_kind = "concept", mods = {}, u1 = c.u1, u2 = c.u2, c1 = c.idx, c2 = c.idx, nxt = c.idx + 1, notes = {}, score = 0 },
      slot = slot, value = value, correction = correction, persist = persist }
    h.correction, h.persist = correction, persist
    addf(h, "resource_slot", 0.5, "the sentence names a '" .. slot .. "' with a value as what to use")
    addf(h, "directive_framing", 0.4, "directive wording around the resource phrase")
    if correction then addf(h, "correction_cue", 0.4, "explicit correction / replacement marker") end
    if persist then addf(h, "persist_cue", 0.3, "applies to every later request") end
    out[#out + 1] = h
  end
  local retracted    -- { chunk, slot } of a resource phrase that an exclusion verb retracts ("Forget the 2022 dataset ...")
  -- a value written at chunk k: a year, a number or an identifier ("2021", "v3.2", "a.csv"); "the ONE" is a pronoun, not the number one
  local function value_at(k)
    local vc = C(S, k)
    if not vc or vc.masked or barrier(vc) and false then return nil end
    if vc.temporal and vc.temporal.year then return { year = vc.temporal.year, label = vc.text, expr = vc.temporal } end
    if vc.single and (vc.literal or vc.unit.kind == "ident" or (vc.unit.kind == "number" and vc.unit.numval and not vc.unit.ordinal)) then
      local prev = C(S, k - 1)
      if vc.unit.form == "one" and prev and prev.single and (cat(prev, "det") or prev.unit.form == "which") then return nil end
      return { word = vc.text, label = vc.text }
    end
  end
  local COPULA_FORMS = U.set({ "is", "was", "are", "be", "'s", "will", "should", "must" })
  -- words that may stand between a resource noun and its value: "dataset WITH THE ONE FROM 2026", "dataset FOR THE YEAR 2020", "dataset NAMED 2021"
  local VALUE_FILL = U.set({ "one", "ones", "year", "version", "number", "no", "id", "named", "called", "titled", "labelled", "labeled", "dubbed", "edition", "release", "from", "for", "of",
    "with", "to", "by", "using", "as", "in", "at", "covering", "dated", "marked", "tagged" })
  for i = S.first, S.last do
    local c = C(S, i)
    local slot = c and not c.masked and lex:resource(c.single and c.unit.form or c.form)
    if slot and not (slot == "solution") then
      local value
      local pc = C(S, i - 1)
      if pc and not pc.masked and not barrier(c) then value = value_at(i - 1) end
      if value and pc.single and pc.unit.kind == "number" and pc.unit.form == "one" then value = nil end
      if not value then
        -- a value after the noun, over at most six function words
        local k = i + 1
        for _ = 1, 6 do
          local cn = C(S, k)
          if not cn or cn.masked or (barrier(cn) and k > i + 1) then break end
          value = value_at(k)
          if value then break end
          if cn.single and (cat(cn, "det") or cat(cn, "prep") or VALUE_FILL[cn.unit.form]) then k = k + 1 else break end
        end
        -- predicate value: "the dataset I need IS the one for 2026", "the right dataset should be 2026"
        if not value then
          for jk = i + 1, math.min(S.last, i + 9) do
            local cj = C(S, jk)
            if cj and cj.single and not cj.masked and COPULA_FORMS[cj.unit.form] then
              local vk = jk + 1
              for _ = 1, 6 do
                local cn = C(S, vk)
                if not cn then break end
                value = value_at(vk)
                if value then break end
                if cn.single and (cat(cn, "det") or cat(cn, "prep") or cn.unit.form == "be" or VALUE_FILL[cn.unit.form]) then vk = vk + 1 else break end
              end
              break
            end
          end
        end
      end
      if value then
        -- the object of an exclusion verb ("Forget / Ignore / Drop the 2022 dataset") is retracted, not adopted
        local excluded = false
        for b = i - 1, math.max(S.first, i - 5), -1 do
          local bc = C(S, b)
          if bc and not bc.masked then
            for _, v in ipairs(bc.verbs or {}) do if v.act == "exclude" then excluded = true end end
            if excluded or (b < i - 1 and barrier(bc)) then break end
          end
        end
        if excluded then retracted = retracted or { chunk = c, slot = slot }
        else emit(c, slot, value); return end
      end
    end
  end
  -- "Forget the 2022 dataset and use 2024 instead.": the retracted phrase names the slot, the replacement is a bare value after a choosing verb
  if retracted then
    for k = S.first, S.last do
      local ck = C(S, k)
      if ck and ck.single and not ck.masked and REPLACE_VERBS[ck.unit.form] then
        local nk = k + 1
        local tc = C(S, nk)
        if tc and tc.single and not tc.masked and (tc.unit.form == "to" or tc.unit.form == "with") then nk = nk + 1 end
        local vc = C(S, nk)
        if vc and not vc.masked and not barrier(vc) then
          local value
          if vc.temporal and vc.temporal.year then value = { year = vc.temporal.year, label = vc.text, expr = vc.temporal }
          elseif vc.single and (vc.unit.kind == "ident" or (vc.unit.kind == "number" and vc.unit.numval and not vc.unit.ordinal)) then value = { word = vc.text, label = vc.text } end
          if value then emit(retracted.chunk, retracted.slot, value); return end
        end
      end
    end
  end
end

---------------------------------------------------------------- standing style / format instructions: "Always answer in metric units from now on."  "Reply in formal English."
-- A persistence marker (always, never, from now on, going forward) with a verb of communication and a manner phrase is a standing instruction about HOW to answer.
local STYLE_VERBS = U.set({ "answer", "respond", "reply", "write", "format", "present", "explain", "speak", "talk", "summarize", "summarise", "keep", "report", "express", "phrase", "address" })
local PERSIST_WORDS = U.set({ "always", "never", "henceforth", "hereafter" })
function F.style_instruction(S, out)
  local persist = false
  for _, ch in ipairs(S.chunks) do
    if ch.temporal and (ch.temporal.kind == "persist" or ch.temporal.persist) then persist = true end
    if ch.single and PERSIST_WORDS[ch.unit.form] then persist = true end
  end
  if not persist then return end
  for k = S.first, S.last do
    local c = C(S, k)
    if c and c.single and not c.masked and STYLE_VERBS[c.unit.form] then
      local pk = k + 1
      local ac = C(S, pk)
      -- "answer ONLY in French": a restricting adverb carries no content of its own here
      if ac and ac.single and not ac.masked and not barrier(ac) and (ac.unit.form == "only" or ac.unit.form == "just" or ac.unit.form == "exclusively" or ac.unit.form == "strictly" or ac.unit.form == "solely") then pk = pk + 1 end
      local pc = C(S, pk)
      -- the manner phrase:  in / with / using / as  X
      if pc and pc.single and not pc.masked and not barrier(pc) and (pc.unit.form == "in" or pc.unit.form == "with" or pc.unit.form == "using" or pc.unit.form == "as" or pc.unit.form == "like") then
        for _, np in ipairs(P.parse_np(S, pk + 1)) do
          local h = newh(S, "instruction:style", "instruction", "instruction_update", "instruct")
          for i = S.first, np.nxt - 1 do
            local ci = C(S, i)
            if ci and not ci.masked and (i >= k or (ci.single and (PERSIST_WORDS[ci.unit.form] or ci.temporal or cat(ci, "polite") or cat(ci, "adv") or cat(ci, "discourse")))) then h.used[i] = true end
          end
          -- trailing persistence marker ("... from now on")
          for i = np.nxt, S.last do local ci = C(S, i); if ci and ci.temporal and (ci.temporal.kind == "persist" or ci.temporal.persist) then h.used[i] = true end end
          h.instruction = { verb = c.unit.form, act = "constraint", np = np, slot = "style", value = { word = np.head and np.head.form or "", label = P.span_text(S, np) }, persist = true }
          h.persist = true
          addf(h, "style_instruction", 0.9, "a standing instruction about how to answer ('" .. c.unit.form .. " " .. pc.unit.form .. " ...')")
          addf(h, "persist_cue", 0.3, "applies from now on")
          out[#out + 1] = h
        end
      end
    end
  end
end

---------------------------------------------------------------- existential questions: "Is there a bakery in Wexmoor?"  "Are there any hospitals in Finland?"  -> a search for such things
local EXIST_FILLERS = U.set({ "anywhere", "somewhere", "around", "nearby", "locally" })
function F.existential_search(S, out)
  local c0, c1 = C(S, S.first), C(S, S.first + 1)
  if not (c0 and c1 and c0.single and c1.single and not c0.masked and not c1.masked and cat(c0, "aux_be") and c1.unit.form == "there" and not barrier(c1)) then return end
  local k = S.first + 2
  local qc = C(S, k)
  local lead = { S.first, S.first + 1 }
  if qc and qc.single and not qc.masked and not barrier(qc) and (qc.unit.form == "any" or qc.unit.form == "a" or qc.unit.form == "an" or qc.unit.form == "some") then
    lead[#lead + 1] = k; k = k + 1
  end
  for _, np in ipairs(P.parse_np(S, k, { no_of = false })) do
    -- "a decent plumber ANYWHERE around X": a place adverb before the locative phrase carries nothing
    local sk = np.nxt
    local ac = C(S, sk)
    local skipped = {}
    while ac and ac.single and not ac.masked and not barrier(ac) and EXIST_FILLERS[ac.unit.form] and not cat(ac, "prep") do skipped[#skipped + 1] = sk; sk = sk + 1; ac = C(S, sk) end
    if np.head_kind == "typenoun" or np.head_kind == "unknown" or np.head_kind == "concept" then
      local hs = {}
      F.from_object_np(S, hs, np, { act = "retrieve", lemma = "find" }, "question", lead)
      for _, h in ipairs(hs) do
        if h.intent == "search" then
          for _, i in ipairs(skipped) do h.used[i] = true end
          addf(h, "existential_question", 0.4, "'is there ...?' asks for such things")
          out[#out + 1] = h
        end
      end
    end
  end
end

---------------------------------------------------------------- yes/no with a support verb and a possessed relational noun: "Does X have its headquarters in Y?"
function F.yes_no_support(S, out)
  local c0 = C(S, S.first)
  if not (c0 and c0.single and not c0.masked and cat(c0, "aux_do") and not cat(c0, "wh")) then return end
  for _, snp in ipairs(P.parse_np(S, S.first + 1)) do
    for _, vp in ipairs(P.parse_vp(S, snp.nxt, { aux_hint = "do" })) do
      for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
        local dc = C(S, onp.c1)
        if onp.head_kind == "relnoun" and not onp.of_arg and dc and dc.single and cat(dc, "poss_det") and onp.c1 < onp.nxt - 1 and (is_prep(C(S, onp.nxt), "in") or is_prep(C(S, onp.nxt), "at")) then
          for _, vnp in ipairs(P.parse_np(S, onp.nxt + 1)) do
            for _, o in ipairs(relnp_options(S, onp)) do
              local rel = o.rel
              local supported = (vp.lemma == "have" and rel.support_have) or false
              for _, e in ipairs(vp.analysis.entries or {}) do if e.support and e.rel == rel.id then supported = true end end
              if supported and o.ask_role == "to" then
                local h = newh(S, "yes_no:support_possessed", "question", "verification", "verify")
                use(h, S.first); use_np(h, snp); use_vp(h, vp); use_np(h, onp); use(h, onp.nxt); use_np(h, vnp)
                h.requires_evidence = true
                h.rel, h.rel_obj = rel.id, rel
                h.roles.from, h.roles.to = snp, vnp
                h.verify = { rel = rel.id, from = snp, to = vnp }
                h.items = { snp, vnp }
                addf(h, "support_construction", 0.8, "'" .. tostring(vp.lemma) .. "' + possessed '" .. rel.id .. "' noun, yes/no")
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

return F
