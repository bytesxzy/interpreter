-- asi.nlu.frames4: attribution and placement constructions (extends asi.nlu.frames / frames2 / frames3 on the same table; every function adds competing hypotheses).
--   wh_identity_person   "Who is the person serving as CEO of X?"                                   a reduced relative clause naming the post
--   wh_credit            "Who was behind the founding of X?"  "Who is credited with founding X?"     attribution idioms: the agent of the event named by a verb / derived noun
--                        "Who gets the credit for starting X?"  "Whom do we have to thank for founding X?"
--   wh_locus_host        "Which city hosts the headquarters of X?"  "Which city is home to X's head office?"
--   where_find           "Where can I find the headquarters of X?"  "In which city will I find the head office of X?"
--   wh_relnoun_same_pred "Which currency is legal tender in K?"                                       the predicate noun is another name of the relation the wh-noun names
--   generic_holder       "What currency do the locals use when they shop in K?"                      a generic subject is not the holder: the place named in the locative phrase is
-- Roles come from the relation lexicon (the subject role of the relation's verbs, the role a noun denotes) and from type fit, never from word proximity.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local F = require("asi.nlu.frames2")
require("asi.nlu.frames3")

local cat = P.cat
local newh, addf, use_np = F.newh, F.addf, F.use_np
local set_lookup, use_wh, use_vp = F.set_lookup, F.use_wh, F.use_vp
local is_be = F.is_be
local relnp_options, mark_unresolved_pron = F.relnp_options, F.mark_pron

local function C(S, k) return S.chunks[k] end
local function barrier(c) return c ~= nil and c.pre ~= nil end
local function other(role) return role == "to" and "from" or "to" end
local function use(h, a, b) for i = a, b or a do h.used[i] = true end end
-- the lower-case form of an ordinary (unmasked, unbroken) chunk
local function form_of(c) return c and not c.masked and not barrier(c) and (c.form or (c.unit and c.unit.form)) or nil end

-- does the phrase (space-separated words) start at chunk k, either as one chunk per word or as one multiword chunk?  -> index after it
local function phrase_at(S, k, phrase)
  local one = form_of(C(S, k))
  if one and one == phrase then return k + 1 end
  local j = k
  for w in phrase:gmatch("%S+") do
    local f = form_of(C(S, j))
    local c = C(S, j)
    if not (f and c.single and f == w) then return nil end
    j = j + 1
  end
  return j
end
local function first_phrase(S, k, phrases)
  for _, ph in ipairs(phrases) do
    local n = phrase_at(S, k, ph)
    if n then return n, ph end
  end
end

-- derived event nouns of the relations' verbs:  "founding" -> { founder (agent role "to") }
local function deverbal_index(lex)
  if lex._deverbal_index and lex._deverbal_rev == lex.revision then return lex._deverbal_index end
  local idx = {}
  for _, rel in ipairs(lex:all_rels()) do
    if not rel.open and rel.deverbals and #rel.deverbals > 0 then
      local agent
      for _, v in ipairs(rel.verbs or {}) do if not v.support and v.subj and not v.prep then agent = agent or v.subj end end
      for _, n in ipairs(rel.deverbals) do
        local k = n:lower()
        idx[k] = idx[k] or {}
        idx[k][#idx[k] + 1] = { rel = rel, agent = agent or "to" }
      end
    end
  end
  lex._deverbal_index, lex._deverbal_rev = idx, lex.revision
  return idx
end

---------------------------------------------------------------- "Who is the person serving as CEO of X?"
local PERSONISH = U.set({ "person", "one", "individual", "man", "woman", "executive", "guy", "gentleman", "lady", "official", "someone" })
local SERVING = U.set({ "serving as", "acting as", "working as", "functioning as", "operating as", "employed as", "sitting as" })
function F.wh_identity_person(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if not wh.adverbial and (wh.wh == "who" or wh.wh == "whom") and not wh.np then
      local bk = wh.nxt
      local bc = C(S, bk)
      if is_be(bc) and not barrier(bc) then
        for _, tnp in ipairs(P.parse_np(S, bk + 1, { no_of = true })) do
          local th = tnp.head
          local sc = C(S, tnp.nxt)
          if th and th.single and PERSONISH[th.unit.form] and sc and SERVING[form_of(sc) or ""] then
            for _, rnp in ipairs(P.parse_np(S, tnp.nxt + 1)) do
              if rnp.head_kind == "relnoun" and (rnp.of_arg or rnp.possessor) then
                for _, o in ipairs(relnp_options(S, rnp)) do
                  if o.arg and o.rel and not o.rel.open then
                    local h = newh(S, "wh_identity_person", "question")
                    set_lookup(h, o.rel, o.known_role, o.arg, o.ask_role, wh)
                    use_wh(h, wh); use(h, bk); use_np(h, tnp); use(h, tnp.nxt); use_np(h, rnp)
                    addf(h, "serving_as_construction", 0.9, "'the person serving as <post noun> of X' asks who fills the post")
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
  end
end

---------------------------------------------------------------- attribution idioms
-- cue phrases that follow the wh-word and introduce the attributed event
local CREDIT_NOUNS = U.set({ "credit", "recognition", "honour", "honor", "praise", "glory", "kudos", "thanks", "blame" })
local CREDIT_VERBS = U.set({ "get", "gets", "got", "getting", "deserve", "deserves", "deserved", "take", "takes", "took", "earn", "earns", "earned", "claim", "claims", "claimed",
  "receive", "receives", "received", "merit", "merits", "merited" })
local DET_SET = U.set({ "the", "a", "an", "some", "any", "due", "all", "full", "most", "much" })
local SKIP_AUX = U.set({ "do", "does", "did", "should", "would", "could", "can", "will", "must", "shall", "might", "may", "has", "have", "had", "ought", "really", "actually", "ultimately", "finally", "rightly" })
local SKIP_SUBJ = U.set({ "we", "i", "you", "people", "one", "they", "everyone", "anyone", "somebody", "someone" })
local SKIP_NEED = U.set({ "have", "has", "need", "needs", "ought", "must", "should", "got", "to", "always", "really", "ultimately" })

-- positions (chunk index after the cue) at which an attributed event may start; each entry also carries the chunk range of the cue
local function credit_cues(S, k)
  local res = {}
  local function add(n, from, to) if n then res[#res + 1] = { nxt = n, c1 = from, c2 = to } end end
  local c = C(S, k)
  if not c or c.masked then return res end
  -- "was behind ...", "was the driving force behind ...", "was responsible for ...", "is credited with ...", "is to thank for ..."
  if is_be(c) and not barrier(c) then
    local j = k + 1
    local cj = C(S, j)
    -- "have been" style perfect chains are tolerated by the parser upstream; here only the simple copula
    local n = phrase_at(S, j, "behind")
    add(n, k, j)
    -- "the driving force behind", "the brains behind", "the man behind": one to four ordinary chunks, then "behind"
    for m = j, math.min(j + 4, S.last) do
      local cm = C(S, m)
      if not cm or cm.masked or (m > j and barrier(cm)) then break end
      local nb = phrase_at(S, m + 1, "behind")
      if nb and m >= j then add(nb, k, m + 1) end
    end
    add(phrase_at(S, j, "responsible for"), k, j)
    add(phrase_at(S, j, "credited with"), k, j)
    add(phrase_at(S, j, "to thank for"), k, j)
    add(phrase_at(S, j, "the one to thank for"), k, j)
    add(phrase_at(S, j, "the person to thank for"), k, j)
    add(phrase_at(S, j, "the one responsible for"), k, j)
    add(phrase_at(S, j, "the person responsible for"), k, j)
    add(phrase_at(S, j, "the one behind"), k, j)
    add(phrase_at(S, j, "the person behind"), k, j)
    add(phrase_at(S, j, "accountable for"), k, j)
    add(phrase_at(S, j, "in charge of creating"), k, j)
  end
  -- "gets the credit for ...", "should get credit for ...", "deserves the credit for ...", "takes credit for ..."
  do
    local j = k
    while C(S, j) and not C(S, j).masked and not barrier(C(S, j)) and C(S, j).single and SKIP_AUX[C(S, j).unit.form] do j = j + 1 end
    local vc = C(S, j)
    if vc and vc.single and not vc.masked and not barrier(vc) and CREDIT_VERBS[vc.unit.form] then
      local m = j + 1
      while C(S, m) and C(S, m).single and not C(S, m).masked and not barrier(C(S, m)) and DET_SET[C(S, m).unit.form] do m = m + 1 end
      local nc = C(S, m)
      if nc and nc.single and not nc.masked and CREDIT_NOUNS[nc.unit.form] then
        local fc = C(S, m + 1)
        if fc and fc.single and not fc.masked and not barrier(fc) and fc.unit.form == "for" then add(m + 2, k, m + 1) end
      end
    end
  end
  -- "do we have to thank for ...", "should we thank for ...", "do I owe thanks to"  (the wh-word is the object of "thank")
  do
    local j = k
    local aux_seen = false
    while C(S, j) and not C(S, j).masked and not barrier(C(S, j)) and C(S, j).single and SKIP_AUX[C(S, j).unit.form] do j = j + 1; aux_seen = true end
    local sc = C(S, j)
    if aux_seen and sc and sc.single and not sc.masked and not barrier(sc) and SKIP_SUBJ[sc.unit.form] then
      local m = j + 1
      while C(S, m) and not C(S, m).masked and not barrier(C(S, m)) and C(S, m).single and SKIP_NEED[C(S, m).unit.form] do m = m + 1 end
      local tc, fc = C(S, m), C(S, m + 1)
      if tc and fc and tc.single and fc.single and not tc.masked and not fc.masked and not barrier(tc) and not barrier(fc) and tc.unit.form == "thank" and fc.unit.form == "for" then
        add(m + 2, k, m + 1)
      end
    end
  end
  return res
end

-- the attributed event: a gerund with its object ("founding X", "setting up X") or a derived noun with "of" ("the founding of X", "the creation of X")
local function credit_targets(S, t)
  local res = {}
  local c = C(S, t)
  if not c or c.masked or barrier(c) then return res end
  -- "credited with HAVING established O": a perfect gerund names the same event
  local perfect = false
  if c.single and c.unit.form == "having" then
    local nc = C(S, t + 1)
    if nc and not nc.masked and not barrier(nc) then perfect = true; t = t + 1; c = nc end
  end
  if c.single or c.kind == "mwe" then
    for _, a in ipairs(P.verb_analyses(S, c)) do
      if (not perfect and a.form == "ing") or (perfect and (a.form == "pp" or a.form == "past")) then
        for _, e in ipairs(a.entries or {}) do
          local rel = S.lex:get_rel(e.rel)
          if rel and not rel.open and not e.prep and not e.support and not e.as_only then
            for _, onp in ipairs(P.parse_np(S, t + 1)) do
              res[#res + 1] = { rel = rel, agent = e.subj, obj = onp, c1 = t, c2 = t, kind = "gerund" }
            end
          end
        end
      end
    end
  end
  local idx = deverbal_index(S.lex)
  for _, np in ipairs(P.parse_np(S, t)) do
    local hf = np.head and np.head.single and np.head.unit.form
    if hf and idx[hf] and np.of_arg then
      for _, d in ipairs(idx[hf]) do
        res[#res + 1] = { rel = d.rel, agent = d.agent, obj = np.of_arg, np = np, kind = "noun" }
      end
    end
  end
  return res
end

F.credit_cues, F.credit_targets, F.phrase_at, F.first_phrase, F.deverbal_index = credit_cues, credit_targets, phrase_at, first_phrase, deverbal_index

function F.wh_credit(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if not wh.adverbial and (wh.wh == "who" or wh.wh == "whom" or wh.wh == "whose") and not wh.np and wh.wh ~= "whose" then
      for _, cue in ipairs(credit_cues(S, wh.nxt)) do
        for _, tg in ipairs(credit_targets(S, cue.nxt)) do
          local h = newh(S, "wh_credit", "question")
          set_lookup(h, tg.rel, other(tg.agent), tg.obj, tg.agent, wh)
          use_wh(h, wh); use(h, cue.c1, cue.nxt - 1)
          if tg.kind == "gerund" then use(h, tg.c1) else use_np(h, tg.np) end
          use_np(h, tg.obj)
          addf(h, "credit_construction", 0.9, "attribution idiom: the wh-word asks for the agent of the event '" .. tostring(tg.rel.id) .. "'")
          mark_unresolved_pron(h, tg.obj)
          out[#out + 1] = h
        end
      end
    end
  end
end

---------------------------------------------------------------- locus relations: which place hosts / is home to the thing
local HOST_LEMMAS = U.set({ "host", "house", "contain", "hold", "shelter", "accommodate", "harbour", "harbor", "have", "boast" })
local HOME_PHRASES = { "home to", "the home of", "the site of", "the seat of", "the base of", "the location of", "the location for", "the venue for", "the setting for", "host to", "the host of" }

F.HOME_PHRASES, F.HOST_LEMMAS = HOME_PHRASES, HOST_LEMMAS
local function locus_options(S, np)
  local opts = {}
  for _, o in ipairs(relnp_options(S, np)) do
    if o.arg and o.rel and not o.rel.open and o.rel.locus and o.ask_role == "to" then opts[#opts + 1] = o end
  end
  return opts
end

F.locus_options = locus_options

function F.wh_locus_host(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if not wh.adverbial and wh.np and wh.type then
      local function emit(onp, frame_note, k_after, extra_use)
        for _, o in ipairs(locus_options(S, onp)) do
          local h = newh(S, "wh_locus_host", "question")
          set_lookup(h, o.rel, o.known_role, o.arg, o.ask_role, wh)
          use_wh(h, wh); use_np(h, onp)
          for _, i in ipairs(extra_use) do use(h, i) end
          addf(h, "locus_host_construction", 0.9, frame_note)
          F.option_factors(h, o)
          mark_unresolved_pron(h, o.arg)
          out[#out + 1] = h
        end
      end
      -- (a) "Which city HOSTS the headquarters of X?"
      for _, vp in ipairs(P.parse_vp(S, wh.nxt)) do
        if vp.voice == "active" and HOST_LEMMAS[vp.lemma] then
          for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
            if onp.head_kind == "relnoun" then
              local used = {}
              for i = vp.c1, vp.c2 do used[#used + 1] = i end
              emit(onp, "'" .. tostring(vp.lemma) .. "' + a locus noun: the wh-place is the value of the relation", vp.nxt, used)
            end
          end
        end
      end
      -- (b) "Which city IS HOME TO the headquarters of X?"
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        local n, ph = first_phrase(S, wh.nxt + 1, HOME_PHRASES)
        if n then
          for _, onp in ipairs(P.parse_np(S, n)) do
            if onp.head_kind == "relnoun" then
              local used = { wh.nxt }
              for i = wh.nxt + 1, n - 1 do used[#used + 1] = i end
              emit(onp, "'" .. ph .. "' + a locus noun: the wh-place is the value of the relation", n, used)
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- "Where can I find the headquarters of X?"
local FIND_VERBS = U.set({ "find", "locate", "see", "spot", "discover", "reach" })
local FINDER = U.set({ "i", "we", "you", "one", "someone", "anyone", "somebody", "anybody", "people", "tourists", "visitors", "travellers", "travelers", "customers", "clients" })
function F.where_find(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    local where = wh.adverbial and wh.wh == "where"
    local pied = (not wh.adverbial) and wh.pied and wh.np and wh.type
    if where or pied then
      local ac = C(S, wh.nxt)
      if ac and ac.single and not ac.masked and not barrier(ac) and (cat(ac, "modal") or cat(ac, "aux_do")) then
        local sc = C(S, wh.nxt + 1)
        local vc = C(S, wh.nxt + 2)
        if sc and vc and sc.single and vc.single and not sc.masked and not vc.masked and not barrier(sc) and not barrier(vc)
          and FINDER[sc.unit.form] and FIND_VERBS[vc.unit.form] then
          for _, onp in ipairs(P.parse_np(S, wh.nxt + 3)) do
            if onp.head_kind == "relnoun" then
              for _, o in ipairs(locus_options(S, onp)) do
                local h = newh(S, "where_find", "question")
                set_lookup(h, o.rel, o.known_role, o.arg, o.ask_role, wh)
                use_wh(h, wh); use(h, wh.nxt, wh.nxt + 2); use_np(h, onp)
                if pied then h.pied_consumed = true end
                addf(h, "where_find_construction", 0.9, "'where can one find <locus noun>' asks for the value of " .. o.rel.id)
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

---------------------------------------------------------------- "Which currency is legal tender in K?"
local PLACE_PREPS = U.set({ "in", "of", "for", "at", "across", "throughout", "within" })
function F.wh_relnoun_same_pred(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if not wh.adverbial and wh.relnoun and wh.np and wh.wh ~= "how_adj" and wh.wh ~= "how_many" and wh.wh ~= "how_much" then
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        local nk = wh.nxt + 1
        for _, pnp in ipairs(P.parse_np(S, nk, { no_of = true })) do
          if pnp.head_kind == "relnoun" and not pnp.of_arg and not pnp.possessor then
            local pc = C(S, pnp.nxt)
            if pc and pc.single and not pc.masked and not barrier(pc) and PLACE_PREPS[pc.unit.form] then
              for _, anp in ipairs(P.parse_np(S, pnp.nxt + 1)) do
                for _, we in ipairs(wh.np.relnouns or {}) do
                  for _, pe in ipairs(pnp.relnouns or {}) do
                    if pe.rel == we.rel and pe.role == we.role then
                      local rel = S.lex:get_rel(we.rel)
                      if rel and not rel.open then
                        local h = newh(S, "wh_relnoun_same_pred", "question")
                        set_lookup(h, rel, other(we.role), anp, we.role, wh)
                        use_wh(h, wh); use(h, wh.nxt); use_np(h, pnp); use(h, pnp.nxt); use_np(h, anp)
                        addf(h, "same_relation_predicate", 0.7, "the predicate noun '" .. tostring(pnp.head and pnp.head.form) .. "' is another name of " .. rel.id .. ", the relation the wh-noun names")
                        F.wh_relnoun_agreement(h, wh, rel)
                        mark_unresolved_pron(h, anp)
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
  end
end

---------------------------------------------------------------- generic subjects: "What currency do the locals use when they shop in K?"
-- A generic subject (they, people, the locals) cannot hold a country-level relation: the place named in a locative phrase of the sentence is the holder.
local GENERIC_NOUN = U.set({ "locals", "people", "residents", "citizens", "inhabitants", "natives", "folks", "visitors", "tourists", "travellers", "travelers", "shoppers",
  "customers", "everyone", "everybody", "nationals", "countrymen", "population", "public", "workers", "students", "shopkeepers", "merchants", "traders", "farmers" })
local GENERIC_PRON = U.set({ "they", "you", "one", "we", "everyone", "everybody", "people" })
local LOC_PREPS = U.set({ "in", "at", "across", "throughout", "within", "around", "inside", "to", "for", "from", "into", "of" })

local function generic_np(np)
  if not np then return false end
  if np.head_kind == "pronoun" then return GENERIC_PRON[np.pron and np.pron.form or ""] == true end
  if np.head and np.head.single and GENERIC_NOUN[np.head.unit.form] and not np.of_arg then return true end
  return false
end

function F.generic_holder(S, out)
  local n0 = #out
  for hi = 1, n0 do
    local h = out[hi]
    if h.op == "lookup" and h.rel_obj and not h.rel_obj.open and h.known_role and h.roles and h.roles[h.known_role] and not h.generic_rebound then
      local gnp = h.roles[h.known_role]
      local role_type = h.rel_obj[h.known_role]
      if generic_np(gnp) then
        -- candidate holders: a name in a locative phrase that this hypothesis leaves unused, of a type the relation's holder accepts
        local found, count = nil, 0
        for k = S.first, S.last do
          local pc = C(S, k)
          if pc and pc.single and not pc.masked and LOC_PREPS[pc.unit.form] and not h.used[k] then
            for _, np in ipairs(P.parse_np(S, k + 1)) do
              if (np.head_kind == "entity" or (np.head_kind == "unknown" and np.head and np.head.cap)) and not np.det and not np.poss_det then
                local ty
                for _, cd in ipairs(np.cands or {}) do ty = ty or cd.type end
                if np.head and np.head.names and np.head.names[1] then ty = ty or np.head.names[1].type_guess end
                if S.lex:compat(ty, role_type) > -1.0 then found = found or { prep = k, np = np }; count = count + 1 end
                break
              end
            end
          end
        end
        if found and count == 1 then
          local h2 = U.shallow(h)
          h2.roles, h2.used, h2.factors = U.shallow(h.roles), U.shallow(h.used), U.shallow(h.factors)
          h2.pronouns = nil
          h2.roles[h.known_role] = found.np
          use(h2, found.prep); use_np(h2, found.np)
          h2.generic_rebound = true
          addf(h2, "generic_subject_holder", 0.9, "the generic subject '" .. P.span_text(S, gnp) .. "' is not the holder; the place named in the locative phrase is")
          out[#out + 1] = h2
        end
      end
    end
  end
end

---------------------------------------------------------------- "Which country is Kyoto in?"   (a typed place wh-noun + copula + subject + stranded "in")
function F.wh_place_stranded_in(S, out)
  local lrel = S.lex:get_rel("located_in")
  if not lrel then return end
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if not wh.adverbial and wh.np and wh.type and S.lex:compat(wh.type, "place") >= 0.9 and not wh.pied then
      local bc = C(S, wh.nxt)
      if is_be(bc) and not barrier(bc) then
        for _, snp in ipairs(P.parse_np(S, wh.nxt + 1)) do
          local pc = C(S, snp.nxt)
          if pc and pc.single and not pc.masked and not barrier(pc) and pc.unit.form == "in" and snp.nxt == S.last then
            local h = newh(S, "wh_place_stranded_in", "question")
            set_lookup(h, lrel, "from", snp, "to", wh)
            use_wh(h, wh); use(h, wh.nxt); use_np(h, snp); use(h, snp.nxt)
            addf(h, "stranded_in_place", 0.7, "'Which " .. tostring(wh.type) .. " is X in?' asks for the place that contains X")
            mark_unresolved_pron(h, snp)
            out[#out + 1] = h
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- comparisons with an explicit dimension
--   "Compare the populations of Chile and Peru."   "Compare Tesla and Toyota by revenue."   "How does Norway compare with Sweden and Denmark in terms of area?"
--   "Rank Mount Everest, K2 and Kangchenjunga by height."
-- The dimension is a number-valued relation named by a relational noun; the items are the things compared.
local function numeric_rel(S, np)
  if not np or np.head_kind ~= "relnoun" then return nil end
  for _, e in ipairs(np.relnouns or {}) do
    local rel = S.lex:get_rel(e.rel)
    if rel and not rel.open and e.role == "to" and S.lex:compat(rel.to, "number") >= 0.9 then return rel end
  end
end

-- the unique defined relation of a measurable dimension ("height" -> height); nil when the dimension spans several ("age", "size")
function F.dim_unique_rel(lex, dim)
  local d = lex.dims and lex.dims[dim] or (lex.parent and lex.parent.dims and lex.parent.dims[dim])
  if not d then return nil end
  local found
  for _, rid in ipairs(d.rels or {}) do
    local r = lex:get_rel(rid)
    if r and not r.open then
      if found then return nil end
      found = r
    end
  end
  return found
end

local DIM_CUES = { "in terms of", "by", "on", "regarding", "with respect to", "as to", "according to", "based on", "using", "for" }
-- "(by|in terms of|on ...) [the] DIM"  ->  rel, np, next chunk
local function trailing_dimension(S, k)
  local n = first_phrase(S, k, DIM_CUES)
  if not n then return nil end
  local dc = C(S, n)
  if dc and dc.single and not dc.masked and cat(dc, "det") then n = n + 1 end
  for _, np in ipairs(P.parse_np(S, n, { no_of = true })) do
    local rel = numeric_rel(S, np)
    if rel then return rel, np, np.nxt end
  end
end

local ITEM_JOINERS = U.set({ "and", "or", "versus", "vs", "vs.", "against", "with", "to", "&", "and/or" })
-- items "A, B and C" / "A with B": returns the NPs and the chunk after the last
local function item_list(S, k, limit)
  local items = {}
  local cur = k
  for _ = 1, 8 do
    local np
    for _, cand_np in ipairs(P.parse_np(S, cur, { no_of = true })) do
      if cand_np.head_kind ~= "relnoun" or #items == 0 then np = cand_np; break end
    end
    if not np then break end
    items[#items + 1] = np
    cur = np.nxt
    local nx = C(S, cur)
    if not nx or nx.masked then break end
    if nx.single and ITEM_JOINERS[nx.unit.form] and not (nx.pre and false) then cur = cur + 1
    elseif nx.pre and nx.pre:find("comma") then
      -- ", and C" or ", C"
      local c2 = C(S, cur + 1)
      if nx.single and ITEM_JOINERS[nx.unit.form] then cur = cur + 1 elseif nx.single and cat(nx, "prep") then break end
    else break end
    if limit and cur > limit then break end
  end
  return items, cur
end

F.item_list = item_list

local COMPARE_VERBS = U.set({ "compare", "contrast", "benchmark", "weigh" })
local RANK_VERBS = U.set({ "rank", "sort", "order", "arrange", "list" })
function F.compare_dimension(S, out)
  local vc = C(S, S.first)
  -- (1) imperative "Compare ..."   (2) imperative "Rank ... by DIM"
  if vc and vc.single and not vc.masked and (COMPARE_VERBS[vc.unit.form] or RANK_VERBS[vc.unit.form]) then
    local ranking = RANK_VERBS[vc.unit.form] and not COMPARE_VERBS[vc.unit.form]
    local k = S.first + 1
    local first_np
    -- "the populations of Chile and Peru": the dimension noun with the first item as its argument
    for _, np in ipairs(P.parse_np(S, k)) do
      local rel = numeric_rel(S, np)
      if rel and np.of_arg and not ranking then
        local items, endk = { np.of_arg }, np.nxt
        local jc = C(S, endk)
        if jc and not jc.masked then
          -- "of A and B" / "of A, B and C": a joiner or a comma follows the first item
          local joiner = jc.single and ITEM_JOINERS[jc.unit.form]
          if joiner or (jc.pre and jc.pre:find("comma")) then
            local rest, e2 = item_list(S, joiner and endk + 1 or endk)
            for _, it in ipairs(rest) do items[#items + 1] = it end
            endk = e2
          end
        end
        if #items >= 2 then
          local h = newh(S, "compare_dimension:noun", "request", "comparison", "compare")
          use(h, S.first); use_np(h, np)
          for _, it in ipairs(items) do use_np(h, it) end
          for i = np.nxt, endk - 1 do h.used[i] = true end
          h.items, h.rel, h.rel_obj, h.dimension = items, rel.id, rel, "size"
          h.requires_evidence = true
          addf(h, "comparison_items", 0.5, #items .. " items to compare on " .. rel.id)
          addf(h, "dimension_noun", 0.5, "'" .. tostring(np.head and np.head.form) .. "' names the compared dimension")
          out[#out + 1] = h
        end
      end
    end
    -- plain item list + trailing dimension
    local items, endk = item_list(S, k)
    if #items >= (ranking and 2 or 2) then
      local rel, dnp, after = trailing_dimension(S, endk)
      if rel then
        local h = newh(S, ranking and "compare_dimension:rank" or "compare_dimension:by", "request", "comparison", ranking and "rank" or "compare")
        use(h, S.first)
        for _, it in ipairs(items) do use_np(h, it) end
        for i = items[#items].nxt, after - 1 do h.used[i] = true end
        h.items, h.rel, h.rel_obj, h.dimension = items, rel.id, rel, "size"
        h.requires_evidence = true
        addf(h, "comparison_items", 0.5, #items .. " items on " .. rel.id)
        addf(h, "dimension_noun", 0.5, "'" .. tostring(dnp.head and dnp.head.form) .. "' names the compared dimension")
        out[#out + 1] = h
      end
    end
  end
  -- (3) "How does A compare with B and C in terms of DIM?"
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh.adverbial and wh.wh == "how" then
      local dc = C(S, wh.nxt)
      if dc and dc.single and not dc.masked and cat(dc, "aux_do") then
        for _, snp in ipairs(P.parse_np(S, wh.nxt + 1, { no_of = true })) do
          local cvc = C(S, snp.nxt)
          local pc = C(S, snp.nxt + 1)
          if cvc and cvc.single and not cvc.masked and COMPARE_VERBS[cvc.unit.form] and pc and pc.single and ITEM_JOINERS[pc.unit.form] then
            local rest, endk = item_list(S, snp.nxt + 2)
            if #rest >= 1 then
              local items = { snp }
              for _, it in ipairs(rest) do items[#items + 1] = it end
              local rel, dnp, after = trailing_dimension(S, endk)
              local h = newh(S, "compare_dimension:how", "question", "comparison", "compare")
              use_wh(h, wh); use(h, wh.nxt); use_np(h, snp); use(h, snp.nxt, snp.nxt + 1)
              for _, it in ipairs(rest) do use_np(h, it) end
              if rel then
                for i = endk, after - 1 do h.used[i] = true end
                h.rel, h.rel_obj = rel.id, rel
              end
              h.items, h.dimension = items, "size"
              h.requires_evidence = true
              addf(h, "comparison_items", 0.5, #items .. " items compared")
              if rel then addf(h, "dimension_noun", 0.5, "'" .. tostring(dnp.head and dnp.head.form) .. "' names the compared dimension") end
              out[#out + 1] = h
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- wh-questions whose answer is the set defined by filters
--   "Which cities in Germany have more than a million inhabitants?"   "Which cities are in Germany?"   "Which companies have more than 500 employees?"
--   "What companies were founded after 1990?"
-- The wh-noun is the target set; the rest of the sentence is the same chain of filters a "Find ..." request would carry.
function F.which_filtered(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    local nnp = wh.np
    if nnp and not wh.adverbial and not wh.relnoun and (wh.wh == "which" or wh.wh == "what") and nnp.plural and not nnp.of_arg
      and (nnp.head_kind == "typenoun" or nnp.head_kind == "unknown") then
      local k = wh.nxt
      local cop = C(S, k)
      local used_cop
      -- "Which cities ARE in Germany?": the copula joins the target to its filters
      if cop and cop.single and not cop.masked and not barrier(cop) and (cat(cop, "aux_be") or cat(cop, "aux_have") and false) then used_cop = k; k = k + 1 end
      local filters, kf = F.parse_filters(S, k, nnp)
      if #filters > 0 and kf > S.last then
        local h = newh(S, "wh_which:filtered", "question", "search", "search")
        use_wh(h, wh); use_np(h, nnp)
        if used_cop then use(h, used_cop) end
        h.target, h.filters = nnp, filters
        for _, f in ipairs(filters) do for i = f.span.first, f.span.last do h.used[i] = true end end
        h.requires_evidence = true
        h.wh = wh
        addf(h, "search_target", 0.5, "typed target set")
        addf(h, "filters_parsed", 0.15 * #filters, #filters .. " filter(s) from the clause")
        -- a lookup of a known relation reads the same words more exactly; the set reading is the fallback for questions no relation covers
        addf(h, "filtered_set_fallback", -0.6, "the question asks for the members of a set defined by filters")
        if nnp.head_kind == "unknown" then addf(h, "unknown_target_type", -0.1, "search target type is not in the lexicon") end
        out[#out + 1] = h
      end
    end
  end
end

---------------------------------------------------------------- bans stated as what must (not) appear
--   "Agencies should never appear in your answers."   "Make sure agencies never show up in your answers."   "Don't let agencies show up in your answers."
--   "Please make sure there are no agencies in the results."   "Leave agencies out of the results."   "Take agencies off the list."
-- All of them exclude the noun phrase from the results; the particle verbs put the object BETWEEN verb and particle, which the cue-led exclusion segments do not see.
local APPEAR_PHRASES = { "show up", "shows up", "showing up", "appear", "appears", "appearing", "come up", "comes up", "turn up", "turns up", "pop up", "pops up", "surface", "surfaces",
  "occur", "occurs", "feature", "features", "be included", "be listed", "be shown", "be returned", "be displayed", "be present", "be there", "be in", "be among", "creep in", "slip in", "get in",
  "get through", "make it in", "make it into", "end up in" }
local PARTICLE_VERBS = U.set({ "leave", "keep", "take", "cut", "weed", "filter", "strike", "screen", "throw", "kick", "drop", "rule", "block", "shut", "sort", "leave" })
local PARTICLES = U.set({ "out", "off", "away" })
local MODALS_BAN = U.set({ "should", "must", "shall", "will", "can", "may", "might", "ought", "could", "would" })
local NEG_WORDS_BAN = U.set({ "never", "not", "no longer", "n't" })
local MAKE_SURE = { "make sure that", "make sure", "ensure that", "ensure", "see to it that", "be sure that", "be sure", "check that", "just make sure", "please make sure", "do make sure" }

local MAKE_SURE_WORDS = U.set({ "make", "sure", "ensure", "check", "see", "to", "it", "that", "be", "careful", "just", "do", "also", "and", "so", "please", "kindly", "always", "okay", "ok", "yes", "oh" })
local function ban_hyp(S, frame, np, from, to, verb)
  local persist = false
  for _, ch in ipairs(S.chunks) do
    if ch.temporal and (ch.temporal.kind == "persist" or ch.temporal.persist) then persist = true end
    if ch.single and ch.unit and (ch.unit.form == "always" or ch.unit.form == "never") then persist = true end
  end
  local h = newh(S, "instruction:" .. frame, "instruction", "instruction_update", "instruct")
  for i = from, to do if C(S, i) then h.used[i] = true end end
  use_np(h, np)
  -- the frame words in front of the clause ("make sure", "ensure that", "see to it that", "be careful that") belong to the instruction too
  for i = S.first, from - 1 do
    local ci = C(S, i)
    if ci and ci.single and ci.unit and MAKE_SURE_WORDS[ci.unit.form] then h.used[i] = true end
  end
  -- a persistence marker or a polite word around the clause belongs to the instruction too
  for i = S.first, S.last do
    local ci = C(S, i)
    if ci and ((ci.temporal and (ci.temporal.kind == "persist" or ci.temporal.persist)) or (ci.single and ci.unit and (cat(ci, "polite") or cat(ci, "discourse")))) then h.used[i] = true end
  end
  h.instruction = { verb = verb, act = "exclude", np = np, correction = false, persist = persist }
  h.polarity = "negative"
  h.persist = persist
  addf(h, "exclusion_clause", 0.9, "an exclusion is stated (" .. frame .. ")")
  if persist then addf(h, "persist_cue", 0.3, "applies from now on") end
  mark_unresolved_pron(h, np)
  return h
end

local function ban_scan(S, out)
  if S.sentence and S.sentence.question_mark then return end
  local function neg_at(k)
    local c = C(S, k)
    if not (c and c.single and c.unit and not barrier(c)) then return nil end
    if c.unit.form == "never" or P.is_neg(c) then return k + 1 end
  end
  local function appear_at(k)
    for _, ph in ipairs(APPEAR_PHRASES) do
      local n = phrase_at(S, k, ph)
      if n then return n end
    end
  end
  for k = S.first, math.min(S.last, S.first + 199) do      -- a request is short; longer inputs are not scanned for bans here
    -- (A) NP [modal] never|not APPEAR: find the negation first, then the noun phrase that ends right before it (a bounded look-back keeps this linear)
    local nk0 = neg_at(k)
    if nk0 then
      local e = appear_at(nk0)
      if e then
        local end_before = k
        local pm = C(S, k - 1)
        if pm and pm.single and pm.unit and MODALS_BAN[pm.unit.form] and k - 1 > S.first then end_before = k - 1 end
        local made = false
        for kstart = math.max(S.first, end_before - 6), end_before - 1 do
          if made then break end
          for _, np in ipairs(P.parse_np(S, kstart, { no_of = false })) do
            if np.c1 == kstart and np.nxt == end_before and (np.head_kind == "typenoun" or np.head_kind == "unknown" or np.head_kind == "concept" or np.head_kind == "entity" or np.head_kind == "relnoun") then
              out[#out + 1] = ban_hyp(S, "appearance", np, kstart, e - 1, "appear")
              made = true
              break
            end
          end
        end
      end
    end
    -- (C) don't let|allow|have NP APPEAR
    local c = C(S, k)
    if c and c.single and (cat(c, "aux_do") or cat(c, "modal")) and not c.masked then
      local nk = neg_at(k + 1)
      if nk then
        local lc = C(S, nk)
        if lc and lc.single and (lc.unit.form == "let" or lc.unit.form == "allow" or lc.unit.form == "have" or lc.unit.form == "permit") then
          for _, np in ipairs(P.parse_np(S, nk + 1)) do
            local e = appear_at(np.nxt)
            if e then out[#out + 1] = ban_hyp(S, "let_appear", np, k, e - 1, "let") end
          end
        end
      end
    end
    -- (D) make sure there are no NP in the results / there should be no NP
    local tc = C(S, k)
    if tc and tc.single and tc.unit and tc.unit.form == "there" and not tc.masked then
      local bk = k + 1
      local bc = C(S, bk)
      if bc and bc.single and MODALS_BAN[bc.unit.form] then bk = bk + 1; bc = C(S, bk) end
      if bc and bc.single and (cat(bc, "aux_be") or bc.unit.form == "be") then
        local nc = C(S, bk + 1)
        if nc and nc.single and nc.unit.form == "no" then
          for _, np in ipairs(P.parse_np(S, bk + 2)) do
            out[#out + 1] = ban_hyp(S, "no_existential", np, k, np.nxt - 1, "exclude")
          end
        end
      end
    end
    -- (E) leave|keep|take NP out|off (of|from X)
    if c and c.single and PARTICLE_VERBS[c.unit.form] and not c.masked then
      for _, np in ipairs(P.parse_np(S, k + 1, { no_of = false })) do
        local pc = C(S, np.nxt)
        if pc and pc.single and PARTICLES[pc.unit.form] and not barrier(pc) then
          local e = np.nxt
          local oc = C(S, e + 1)
          if oc and oc.single and (oc.unit.form == "of" or oc.unit.form == "from") then
            local nps = P.parse_np(S, e + 2)
            e = nps[1] and (nps[1].nxt - 1) or (e + 1)
          end
          out[#out + 1] = ban_hyp(S, "particle_out", np, k, e, c.unit.form)
        end
      end
    end
  end
end

function F.appearance_ban(S, out)
  -- the exclusion cue words of the sentence mask exactly what this frame reads: lift the masks while scanning
  local saved
  for i, ch in ipairs(S.chunks) do if ch.masked then saved = saved or {}; saved[i] = ch.mask_kind or true end end
  if saved then
    for i in pairs(saved) do S.chunks[i].masked = nil end
    S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
  end
  local ok, err = pcall(ban_scan, S, out)
  if saved then
    for i, kind in pairs(saved) do S.chunks[i].masked = true; S.chunks[i].mask_kind = kind ~= true and kind or nil end
    S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
  end
  if not ok then error(err, 0) end
end

---------------------------------------------------------------- relational statements
--   "Paris is the capital of France."   "The capital of France is Paris."   "Acme was founded by Jane Doe."   "Acme is headquartered in Oslo."
-- With a negated copula ("Paris is not the capital of France.") the polarity is negative.  A statement that is asked for confirmation (", right?", "Is it true that ...")
-- becomes a verification in asi.nlu.sem.
local function is_prep_chunk(c, form) return c and c.single and not c.masked and cat(c, "prep") and (form == nil or c.unit.form == form) end
function F.statement_relational(S, out)
  if S.sentence and S.sentence.question_mark and not S.polar then return end
  for _, np1 in ipairs(P.parse_np(S, S.first)) do
    local bk = np1.nxt
    local bc = C(S, bk)
    if is_be(bc) and not barrier(bc) then
      local nk, neg_chunk = bk + 1, nil
      local nc = C(S, nk)
      if nc and P.is_neg(nc) and not barrier(nc) then neg_chunk = nk; nk = nk + 1 end
      local function base(frame)
        local h = newh(S, frame, "statement", "statement", "assert")
        use_np(h, np1); use(h, bk)
        if neg_chunk then use(h, neg_chunk); h.polarity = "negative" end
        mark_unresolved_pron(h, np1)
        return h
      end
      for _, np2 in ipairs(P.parse_np(S, nk)) do
        for _, pair in ipairs({ { np1, np2 }, { np2, np1 } }) do
          local value, relnp = pair[1], pair[2]
          if relnp.head_kind == "relnoun" and value.head_kind ~= "relnoun" and value.head_kind ~= "pronoun" then
            for _, o in ipairs(relnp_options(S, relnp)) do
              if o.arg and o.rel and not o.rel.open then
                local h = base("statement:be_rel")
                use_np(h, np2)
                h.rel, h.rel_obj = o.rel.id, o.rel
                h.roles[o.known_role] = o.arg
                h.roles[o.ask_role] = value
                h.known_role = o.known_role
                addf(h, "relnp_statement", 0.5, "statement of a relational fact")
                F.option_factors(h, o)
                mark_unresolved_pron(h, o.arg); mark_unresolved_pron(h, value)
                out[#out + 1] = h
              end
            end
          end
        end
      end
      for _, vp in ipairs(P.parse_vp(S, bk)) do
        if vp.voice == "passive" then
          for _, e in ipairs(vp.analysis.entries or {}) do
            local rel = S.lex:get_rel(e.rel)
            if rel and not rel.open and not e.support and not e.as_only then
              local pc = C(S, vp.nxt)
              local frame, ok_prep
              if e.prep and is_prep_chunk(pc, e.prep) then frame, ok_prep = "statement:be_stative", true
              elseif not e.prep and is_prep_chunk(pc, "by") then frame, ok_prep = "statement:be_passive", true end
              if ok_prep then
                for _, np2 in ipairs(P.parse_np(S, vp.nxt + 1)) do
                  local h = base(frame)
                  use_vp(h, vp); use(h, vp.nxt); use_np(h, np2)
                  h.rel, h.rel_obj = rel.id, rel
                  if e.prep then h.roles[e.subj] = np1; h.roles[other(e.subj)] = np2
                  else h.roles[other(e.subj)] = np1; h.roles[e.subj] = np2 end
                  if vp.neg then h.polarity = "negative" end
                  addf(h, "relation_statement", 0.5, "statement over a relation verb (" .. tostring(vp.voice) .. ")")
                  mark_unresolved_pron(h, np2)
                  out[#out + 1] = h
                end
              end
            end
          end
        end
      end
    elseif bc and not bc.masked and not (S.wrapper and #S.wrapper.kinds > 0) then
      -- active voice with a prepositional relation verb: "I work at Ithari Foundry.", "Acme operates in Germany."
      -- (not after a request wrapper: "I need solar installers based in X" is a request whose object carries a participial clause)
      for _, vp in ipairs(P.parse_vp(S, bk)) do
        if vp.voice ~= "passive" and not vp.neg then
          for _, e in ipairs(vp.analysis.entries or {}) do
            local rel = S.lex:get_rel(e.rel)
            if rel and not rel.open and not e.support and not e.as_only and e.prep and is_prep_chunk(C(S, vp.nxt), e.prep) then
              for _, np2 in ipairs(P.parse_np(S, vp.nxt + 1)) do
                local h = newh(S, "statement:active_prep", "statement", "statement", "assert")
                use_np(h, np1); use_vp(h, vp); use(h, vp.nxt); use_np(h, np2)
                h.rel, h.rel_obj = rel.id, rel
                h.roles[e.subj] = np1; h.roles[other(e.subj)] = np2
                addf(h, "relation_statement", 0.5, "statement over a relation verb with a preposition (active)")
                mark_unresolved_pron(h, np1); mark_unresolved_pron(h, np2)
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
