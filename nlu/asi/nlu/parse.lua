-- asi.nlu.parse: chunking + noun-phrase / verb-phrase / wh-phrase parsing over a lattice cover.
-- Closed-class words drive the syntax; open-class meaning comes ONLY from the lexicon (relations, senses, entities).
local U = require("asi.nlu.util")
local Morph = require("asi.nlu.morph")

local P = {}

---------------------------------------------------------------- chunks
function P.new_state(an, lex, lat, cover, ctx)
  local S = { an = an, lex = lex, lat = lat, ctx = ctx or {}, units = an.units, np_memo = {}, vp_memo = {}, wh_memo = {} }
  S.chunks = P.make_chunks(S, cover)
  S.first, S.last = 1, #S.chunks
  return S
end

-- "serves as", "functions as", "acted as", "stands as": a copula-like verb + "as" behaves as ONE copula chunk ("is"/"was") in every frame.
-- Merged only when "as" introduces a noun phrase (not "acts as if", "stands as well as").
local NOT_NP_AFTER_AS = U.set({ "if", "though", "well", "soon", "long", "much", "many", "far", "usual", "such", "before", "after", "when", "while", "of" })
-- raising participles: "is said to be", "is believed to be", "is known to be" (value: whether the statement is only reported / hedged)
local RAISING = { said = true, believed = true, thought = true, reported = true, rumored = true, rumoured = true, alleged = true, claimed = true, assumed = true,
  presumed = true, supposed = true, expected = true, estimated = true, understood = true, known = false, considered = false, deemed = false, seen = false, held = false,
  found = false, regarded = false, taken = false }
local function merge_copula_like(S, spans)
  local lex, units = S.lex, S.units
  local out, i = {}, 1
  local function is_be_span(sp) return sp and sp.i == sp.j and units[sp.i].kind == "word" and (lex:cats(units[sp.i].form) or {}).aux_be end
  local function is_have_span(sp) return sp and sp.i == sp.j and units[sp.i].kind == "word" and (lex:cats(units[sp.i].form) or {}).aux_have end
  local function is_adv_span(sp)
    if not (sp and sp.i == sp.j and units[sp.i].kind == "word" and not units[sp.i].pre) then return false end
    local fm = units[sp.i].form
    return (lex:cats(fm) or {}).adv == true or (#fm > 4 and fm:sub(-2) == "ly" and not units[sp.i].cap)
  end
  while i <= #spans do
    local sp, nx, after = spans[i], spans[i + 1], spans[i + 2]
    local merged
    if nx and sp.i == sp.j and nx.i == nx.j and sp.kind ~= "punct" and nx.kind ~= "punct" and not units[nx.i].pre then
      local u, nu = units[sp.i], units[nx.i]
      local cl = lex:cats(u.form)
      if cl and cl.copula_like and nu.form == "as" and after and not NOT_NP_AFTER_AS[units[after.i].form] and not units[after.i].pre then
        local past = false
        for _, r in ipairs(lex:readings(u.form)) do if r.pos == "verb" and (r.feat == "past" or r.feat == "pp") then past = true end end
        merged = { i = sp.i, j = nx.j, kind = "word", readings = {}, text = sp.text .. " " .. nx.text, copula_like = true, past = past, score = sp.score }
      end
    end
    if merged then out[#out + 1] = merged; i = i + 2
    else
      -- "(has been) designated (as) the capital", "is (widely) known as", "was named the CEO": a be-participle that introduces a noun phrase is a copula;
      -- "is said to be the capital": a raising participle + "to be" is a (possibly hedged) copula;  "became the capital": an inchoative copula
      local u = units[sp.i]
      local cl = sp.i == sp.j and u.kind == "word" and (lex:cats(u.form) or {})
      -- the nearest preceding be-span, skipping adverbs ("is WIDELY regarded as")
      local pi = #out
      while pi >= 1 and #out - pi < 2 and is_adv_span(out[pi]) do pi = pi - 1 end
      local prev = out[pi]
      local function absorb_be()
        local head = prev
        local past = (units[prev.i].form == "was" or units[prev.i].form == "were" or units[prev.i].form == "been")
        for j = #out, pi, -1 do out[j] = nil end
        -- "has been" / "have been" / "had been": absorb the perfect auxiliary too
        local pp = out[#out]
        if units[prev.i].form == "been" and is_have_span(pp) then head = pp; out[#out] = nil; past = past or units[pp.i].form == "had" end
        return head, past
      end
      if cl and (cl.be_participle or RAISING[u.form] ~= nil) and is_be_span(prev) and not units[sp.i].pre then
        local nxt_i = i + 1
        if RAISING[u.form] ~= nil and nx and nx.i == nx.j and units[nx.i].form == "to" and not units[nx.i].pre and after and is_be_span(after) and not units[after.i].pre then
          local head, past = absorb_be()
          out[#out + 1] = { i = head.i, j = after.j, kind = "word", readings = {}, text = head.text .. " " .. sp.text .. " to " .. after.text,
            copula_like = true, past = past, hedged = RAISING[u.form] or nil, score = sp.score }
          i = i + 3
          goto continue
        end
        if cl.be_participle then
          local last = sp
          if nx and nx.i == nx.j and units[nx.i].form == "as" and not units[nx.i].pre then last = nx; nxt_i = i + 2 end
          local follow = spans[nxt_i]
          local fu = follow and units[follow.i]
          local np_follows = fu and not fu.pre and fu.kind ~= "punct" and not (lex:cats(fu.form) or {}).prep
          if np_follows then
            local head, past = absorb_be()
            out[#out + 1] = { i = head.i, j = last.j, kind = "word", readings = {}, text = head.text .. " " .. sp.text .. (last ~= sp and (" " .. last.text) or ""),
              copula_like = true, past = past, score = sp.score }
            i = nxt_i
            goto continue
          end
        end
      end
      -- "has been the CEO of X", "had been the capital": a perfect auxiliary + "been" that introduces a noun phrase is one copula chunk
      if cl and cl.aux_have and nx and nx.i == nx.j and units[nx.i].form == "been" and not units[nx.i].pre and after then
        local fu = units[after.i]
        local fcl = fu and lex:cats(fu.form) or {}
        local verbish = false
        for _, r in ipairs(fu and lex:readings(fu.form) or {}) do if r.pos == "verb" and (r.feat == "past" or r.feat == "pp" or r.feat == "ing") then verbish = true end end
        if fu and not fu.pre and fu.kind ~= "punct" and not fcl.prep and not verbish and not fcl.neg_word and not fcl.adv then
          out[#out + 1] = { i = sp.i, j = nx.j, kind = "word", readings = {}, text = sp.text .. " " .. nx.text, copula_like = true, past = (u.form == "had"), score = sp.score }
          i = i + 2
          goto continue
        end
      end
      if cl and cl.copula_become and not units[sp.i].pre and nx then
        local nu = units[nx.i]
        if nu and not nu.pre and nu.kind ~= "punct" and not (lex:cats(nu.form) or {}).prep then
          local past = (u.form == "became")
          out[#out + 1] = { i = sp.i, j = sp.j, kind = "word", readings = {}, text = sp.text, copula_like = true, past = past, onset = true, score = sp.score }
          i = i + 1
          goto continue
        end
      end
      out[#out + 1] = sp; i = i + 1
    end
    ::continue::
  end
  return out
end

-- repair variant of a cover (see asi.nlu.repair): misspelled words corrected through the lexicon, filler words ignored
function P.repair_cover(lex, units, cover, original) return require("asi.nlu.repair").repair_cover(lex, units, cover, original) end

function P.make_chunks(S, cover)
  local lex, units = S.lex, S.units
  local chunks = {}
  local spans = merge_copula_like(S, cover.spans)
  for i, sp in ipairs(spans) do
    local u = units[sp.i]
    local c = { idx = i, u1 = sp.i, u2 = sp.j, kind = sp.kind, readings = sp.readings, text = sp.text, span = sp, cap = u.cap,
      pre = u.pre, raw = u.raw, sent = u.sent, single = sp.i == sp.j, unit = u,
      entities = {}, names = {}, senses = {}, relnouns = {}, relverbs = {}, quotes = {} }
    local forms = {}
    for k = sp.i, sp.j do forms[#forms + 1] = units[k].form end
    c.form = table.concat(forms, " ")
    if c.single then
      c.cats = lex:cats(u.form) or {}
      c.pron = lex:pron_feats(u.form)
      for _, r in ipairs(lex:readings(u.form)) do
        if r.pos == "verb" then c.verbs = c.verbs or {}; c.verbs[#c.verbs + 1] = r
        elseif r.pos == "adj" then c.adjs = c.adjs or {}; c.adjs[#c.adjs + 1] = r end
      end
    else c.cats = {} end
    if sp.copula_like then
      -- one copula chunk; its proxy unit reads "is"/"was" so every frame that tests for the copula accepts it, while offsets stay those of the surface words
      c.single, c.copula_like = true, true
      c.hedged, c.onset = sp.hedged, sp.onset
      c.unit = setmetatable({ form = sp.past and "was" or "is", surface_form = c.form }, { __index = u })
      c.cats = lex:cats("is") or {}
    end
    for _, r in ipairs(sp.readings) do
      if r.fuzzy then c.fuzzy = math.max(c.fuzzy or 0, r.fuzzy); c.fuzzy_from = r.fuzzy_from end
      if r.kind == "entity" then c.entities[#c.entities + 1] = r
      elseif r.kind == "name" then c.names[#c.names + 1] = r
      elseif r.kind == "sense" then c.senses[#c.senses + 1] = r
      elseif r.kind == "relnoun" then c.relnouns[#c.relnouns + 1] = r.entry
      elseif r.kind == "relverb" then c.relverbs[#c.relverbs + 1] = r.entry
      elseif r.kind == "actverb" then c.verbs = c.verbs or {}; c.verbs[#c.verbs + 1] = { pos = "verb", lemma = r.entry.lemma, feat = r.entry.feat, act = r.entry.act }
      elseif r.kind == "temporal" then c.temporal = r.expr
      elseif r.kind == "number" then c.number = r.num
      elseif r.kind == "literal" then c.literal = r.unit
      elseif r.kind == "quote" then c.quote = r.text end
    end
    chunks[i] = c
  end
  -- "who's running X", "she's leading Y", "there's ...": a clitic 's right after a wh-word / personal pronoun is the auxiliary "is"
  for i = 2, #chunks do
    local c, p = chunks[i], chunks[i - 1]
    if c.single and c.cats and c.cats.clitic_s and not c.pre and p.single and p.cats and (p.cats.wh or p.cats.pron or p.unit.form == "there" or p.unit.form == "here") then
      c.be_clitic = true
    end
  end
  return chunks
end

local function C(S, k) return S.chunks[k] end
local function cat(c, name) return c ~= nil and c.cats ~= nil and c.cats[name] == true end
P.cat = cat

---------------------------------------------------------------- domain evidence (shared by entity and sense disambiguation)
-- domain -> list of unit indices carrying a cue word of that domain (whole analysis: neighbouring sentences count as context)
function P.domain_profile(S)
  local an = S.an
  if an._domain_profile then return an._domain_profile end
  local prof = {}
  for ui, u in ipairs(S.units) do
    for d in pairs(S.lex:domains_of(u.form)) do prof[d] = prof[d] or {}; table.insert(prof[d], ui) end
  end
  an._domain_profile = prof   -- a property of the analysis, shared by every sentence of it
  return prof
end

local function lower_bound(list, x)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid] < x then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- number of distinct cue hits supporting any of `domains`, excluding the units of the mention itself (capped at 2 per domain).
-- Only cues within two sentences of the mention count: topical context is local, and the lookup stays O(log n) in message length.
function P.domain_hits(S, ctx, domains, ex_u1, ex_u2)
  local prof = P.domain_profile(S)
  local lo_u, hi_u = 1, #S.units
  local sid = S.sentence and S.sentence.id
  if sid then
    local an = S.an
    local r = an._ranges
    if r then
      local a = r[sid - 2] or r[sid - 1] or r[sid]
      local b = r[sid + 2] or r[sid + 1] or r[sid]
      if a then lo_u = a[1] end
      if b then hi_u = b[2] end
    end
  end
  local total = 0
  for d in pairs(domains or {}) do
    local list = prof[d]
    local own = 0
    if list then
      local i = lower_bound(list, lo_u)
      while list[i] and list[i] <= hi_u do
        local ui = list[i]
        if not (ex_u1 and ui >= ex_u1 and ui <= ex_u2) then own = own + 1 end
        if own >= 2 then break end
        i = i + 1
      end
    end
    local disc = (ctx and ctx.domains and ctx.domains[d]) or 0
    total = total + math.min(2, own + disc)
  end
  return total
end

-- evidence strength -> score gain (one cue is real but modest evidence, two or more is strong)
function P.domain_gain(hits) if hits >= 2 then return 0.8 elseif hits >= 1 then return 0.45 end return 0 end

-- barrier strings that end a phrase (hyphen parts carry no barrier, so compounds are unaffected)
local function barrier(c) return c ~= nil and c.pre ~= nil end

function P.is_neg(c) return c ~= nil and c.single and (c.unit.form == "not" or c.unit.neg_clitic == true) end

-- verb analyses of a chunk: {lemma, form(base|3sg|past|pp|ing), entries={relverb entries}, act, guessed}
function P.verb_analyses(S, c)
  if c.vana then return c.vana end
  local out, seen = {}, {}
  local function add(lemma, form, entry, act, guessed)
    local key = lemma .. "|" .. form
    local a = seen[key]
    if not a then a = { lemma = lemma, form = form, entries = {}, act = act, guessed = guessed }; seen[key] = a; out[#out + 1] = a end
    if entry then a.entries[#a.entries + 1] = entry end
    if act and not a.act then a.act = act end
    return a
  end
  for _, e in ipairs(c.relverbs) do add(e.lemma, e.vform, e, nil) end
  for _, r in ipairs(c.verbs or {}) do add(r.lemma, r.feat, nil, r.act) end
  -- "have" as a MAIN verb ("Acme has its headquarters in Oslo", "Where does Acme have its headquarters"): no relation of its own; the support-verb
  -- constructions give it meaning together with the relational noun it governs
  if #out == 0 and c.single and cat(c, "aux_have") then
    local f = c.unit.form
    if f == "have" then add("have", "base", nil)
    elseif f == "has" then add("have", "3sg", nil)
    elseif f == "had" then add("have", "past", nil)
    elseif f == "having" then add("have", "ing", nil) end
  end
  if #out == 0 and c.single and c.kind == "word" and not next(c.cats) and #c.senses == 0 and #c.entities == 0 and #c.relnouns == 0 then
    local seen_feat = {}
    for _, g in ipairs(Morph.guess(c.unit.form)) do
      if g.pos == "verb" then
        -- an unknown verb is an OPEN relation: represented under its own lemma, never mapped onto a familiar relation (one lemma per form)
        local ol = g.lemma:gsub("e$", "")
        add(g.lemma, g.feat, { kind = "relverb", rel = "open:" .. ol, subj = "to", vform = g.feat, lemma = g.lemma, open = true }, nil, true)
      end
    end
  end
  -- fill acts for relation verbs that are also speech-act verbs ("create", "launch", ...)
  for _, a in ipairs(out) do
    if not a.act and S.lex.verbs[a.lemma] then a.act = S.lex.verbs[a.lemma].act end
  end
  c.vana = out
  return out
end

---------------------------------------------------------------- noun classification
local function has_noun_reading(c)
  return #c.entities > 0 or #c.names > 0 or #c.senses > 0 or #c.relnouns > 0
end

-- what can this chunk be inside a noun phrase?  returns a table of flags or nil.
-- in_np = true when a determiner / possessive / modifier already opened the NP (then verb-only words may act as nouns/modifiers).
local function nclass(S, c, in_np)
  if not c or c.masked then return nil end
  local f = {}
  if c.kind == "entity" or c.kind == "name_guess" or #c.entities > 0 or #c.names > 0 then f.entity = true end
  if #c.senses > 0 then f.sense = true end
  if #c.relnouns > 0 then f.relnoun = true end
  if c.temporal and (c.temporal.kind == "year" or c.temporal.kind == "date" or c.temporal.kind == "decade" or c.temporal.kind == "century"
    or c.temporal.kind == "fiscal_year" or c.temporal.kind == "quarter" or c.temporal.kind == "interval" or c.temporal.kind == "month") then f.temporal = true end
  if c.number then f.number = true end
  if c.single and c.unit.kind == "number" and c.unit.numval ~= nil then f.number = true end
  -- a word recognised ONLY through spelling variants keeps its literal (unknown-word) reading: guesses never displace what was written
  if c.fuzzy and #c.names == 0 and c.single and not (c.cats and next(c.cats)) then
    local attested = false
    for _, e in ipairs(c.entities) do if not e.fuzzy then attested = true end end
    for _, s in ipairs(c.senses) do if not s.fuzzy then attested = true end end
    for _, e in ipairs(c.relnouns) do if not e.fuzzy then attested = true end end
    for _, e in ipairs(c.relverbs) do if not e.fuzzy then attested = true end end
    if not attested then f.unknown = true end
  end
  if c.literal then f.literal = true end
  if c.quote then f.quote = true end
  if c.single and not next(f) then
    local cats = c.cats
    if cats.pron or cats.pron_dem or cats.pron_indef or cats.pron_poss or cats.pron_refl then f.pron = true end
    if cats.poss_det then f.poss_det = true end
    local closed = cats.det or cats.prep or cats.conj or cats.wh or cats.aux_be or cats.aux_do or cats.aux_have or cats.modal or cats.polite
      or cats.neg_word or cats.clitic_s or cats.adv or cats.particle or f.pron or f.poss_det
    -- "a VERY small business", "an extremely successful firm": a degree adverb inside a noun phrase modifies the adjective after it
    if cats.degree and in_np then
      local nx = S.chunks[(c.idx or 0) + 1]
      if nx and not nx.masked and not barrier(nx) then
        local nn = nclass(S, nx, true)
        if nn and not nn.pron then f.adj = true end
      end
    end
    if not closed then
      -- open-class word with no noun reading in the lexicon: modifier / unknown noun / verb used as a noun
      if c.adjs then
        f.adj = true -- a gradable adjective only modifies; it is never the head ("the latest" is elliptical, not a noun phrase)
      elseif (c.verbs and #c.verbs > 0) or #c.relverbs > 0 then
        if in_np then f.unknown = true; f.from_verb = true end -- "the list of ...", "the revised version"
      else
        f.unknown = true
      end
      if c.unit.kind == "ident" then f.literal = true end
    end
  end
  if next(f) == nil then return nil end
  return f
end

local function entity_cands(S, c)
  local cands = {}
  for _, r in ipairs(c.entities) do
    local e = S.lex:get_entity(r.entry.id)
    cands[#cands + 1] = { id = r.entry.id, type = r.entry.etype, name = r.entry.name, exact_case = r.exact_case, fuzzy = r.fuzzy,
      fuzzy_from = r.fuzzy_from, domain = e and e.domain or {}, source = e and e.source or "lexicon", prior = e and e.prior or 0.5,
      attrs = e and e.attr or nil, kind = "attested" }
  end
  -- an unseen-entity reading is only a fallback: when attested exact-case candidates exist it would just shadow them
  local attested_exact = false
  for _, cd in ipairs(cands) do if not cd.fuzzy and cd.exact_case then attested_exact = true end end
  if not attested_exact then
    for _, r in ipairs(c.names) do
      cands[#cands + 1] = { id = "mention:" .. c.form, type = r.type_guess, name = r.text, unseen = true, weak = r.weak, kind = "unseen",
        domain = {}, prior = 0.3, head_cue = r.head_cue }
    end
  end
  return cands
end
P.entity_cands = entity_cands

---------------------------------------------------------------- noun phrases
local SUPERLATIVE_FORMS = U.set({ "latest", "newest", "oldest", "largest", "smallest", "biggest", "highest", "lowest", "longest", "shortest",
  "youngest", "earliest", "fastest", "slowest", "cheapest", "best", "worst", "top", "first", "last", "most recent", "greatest" })

local function new_np(c)
  return { u1 = c.u1, u2 = c.u2, c1 = c.idx, c2 = c.idx, mods = {}, score = 0, notes = {} }
end

local function span_text(S, np) return S.an.original:sub(S.units[np.u1].s, S.units[np.u2].e) end
P.span_text = span_text

-- text of the NP without its determiner / possessive determiner (lower-cased comparison form)
function P.core_text(S, np)
  local c1 = np.c1
  if np.det or np.poss_det then c1 = c1 + 1 end
  local a, b = S.chunks[c1], S.chunks[np.c2]
  if not a or not b then return span_text(S, np):lower() end
  local parts = {}
  for k = a.u1, b.u2 do parts[#parts + 1] = S.units[k].form end
  return table.concat(parts, " ")
end

-- closed-class words are "function words" only when they look like it: a capitalised "A"/"The" in the middle of a sentence is not an article
function P.is_function_chunk(S, c)
  if not c.single then return false end
  local cats = c.cats
  if not cats then return false end
  local closed = cats.det or cats.prep or cats.conj or cats.aux_be or cats.aux_do or cats.aux_have or cats.modal or cats.wh or cats.pron
    or cats.pron_poss or cats.polite or cats.neg_word or cats.clitic_s or cats.adv or cats.particle or cats.poss_det
  if not closed then return false end
  if c.cap and c.unit.form ~= "i" then   -- the pronoun "I" is capitalised wherever it stands
    local prev = S.units[c.u1 - 1]
    local sentence_initial = (c.u1 == 1) or (prev and prev.sent ~= c.unit.sent)
    local sent = S.an.sentences[c.unit.sent or 0]
    if not sentence_initial and not (sent and sent.shout) then return false end
  end
  return true
end

-- adverbs that may stand between the subject and the verb of mention in a discourse-linked relative clause ("the company I FIRST brought up")
local BACKREF_ADV_WORD = U.set({ "first", "originally", "initially", "previously", "earlier", "briefly", "once", "recently", "already", "just", "also", "actually", "really", "even", "ever", "only" })

-- consume a back-reference cue ("I mentioned earlier") starting at chunk index m; returns next chunk index or nil
local function backref_at(S, m)
  local c = C(S, m)
  if not c then return nil end
  local j
  local n = S.lex:cue_at("backref", S.units, c.u1)
  if n then
    local consumed = 0
    j = m
    while j <= #S.chunks and consumed < n do
      consumed = consumed + (S.chunks[j].u2 - S.chunks[j].u1 + 1)
      j = j + 1
    end
    if consumed ~= n then return nil end
  else
    -- discourse-linked relative clause: "[that] I|we|you [was|have ...] <past/progressive verb>"  ("the business I mentioned",
    -- "the architecture we were improving", "the correction I made").  Structural, so it covers verbs no cue list names.
    local k = m
    if c.single and (c.unit.form == "that" or c.unit.form == "which") then k = k + 1 end
    local p = C(S, k)
    local f = p and p.single and p.unit.form
    if p and not barrier(p) and (f == "i" or f == "we" or f == "you") then
      local q = k + 1
      -- auxiliaries and adverbs between the subject and the verb of mention: "I was", "I have", "I first brought up", "I originally mentioned", "I had actually told you about"
      while C(S, q) and C(S, q).single and not barrier(C(S, q)) and (cat(C(S, q), "aux_be") or cat(C(S, q), "aux_have") or cat(C(S, q), "adv") or cat(C(S, q), "ignorable") or BACKREF_ADV_WORD[C(S, q).unit.form]) do q = q + 1 end
      local vc = C(S, q)
      -- a multiword verb of mention ("brought up", "talked about") is one chunk
      if vc and (vc.single or (vc.verbs and #vc.verbs > 0)) and not barrier(vc) then
        for _, a in ipairs(P.verb_analyses(S, vc)) do
          if a.form == "past" or a.form == "pp" or a.form == "ing" then
            j = q + 1
            -- "told YOU ABOUT", "brought UP", "talked ABOUT", "came ACROSS": an object pronoun and/or a particle complete the verb of mention
            local oc = C(S, j)
            if oc and oc.single and not barrier(oc) and (oc.unit.form == "you" or oc.unit.form == "me" or oc.unit.form == "us") then j = j + 1 end
            local pc = C(S, j)
            if pc and pc.single and not barrier(pc) and (cat(pc, "particle") or pc.unit.form == "about" or pc.unit.form == "of" or pc.unit.form == "across" or pc.unit.form == "to") then
              j = j + 1
              -- "brought up WITH YOU", "talked about WITH YOU": the addressee after a particle
              local wc, yc = C(S, j), C(S, j + 1)
              if wc and yc and wc.single and yc.single and not barrier(wc) and not barrier(yc) and wc.unit.form == "with" and (yc.unit.form == "you" or yc.unit.form == "me" or yc.unit.form == "us") then j = j + 2 end
            end
            break
          end
        end
      end
    end
  end
  if not j then return nil end
  -- who produced the referent: first person -> the user, second person -> the assistant
  local who
  for k = m, math.min(j - 1, m + 2) do
    local ck = C(S, k)
    local f = ck and ck.unit and ck.unit.form
    if f == "i" or f == "we" or f == "my" or f == "our" then who = "user" break
    elseif f == "you" or f == "your" then who = "assistant" break end
  end
  -- trailing temporal adverbs belong to the clause ("... I mentioned earlier")
  while C(S, j) and not barrier(C(S, j)) do
    local n = S.lex:cue_at("backref_adv", S.units, C(S, j).u1)
    if not n then break end
    local consumed = 0
    while C(S, j) and consumed < n do consumed = consumed + (C(S, j).u2 - C(S, j).u1 + 1); j = j + 1 end
    if consumed ~= n then break end
  end
  return j, who
end
P.backref_at = backref_at

local parse_np
local PARTICIPLE_PREP = U.set({ "in", "by", "throughout", "across", "within", "among" })
local POSS_PRON = { its = "it", his = "he", her = "she", their = "they" }

-- an unknown head noun with an entity argument ("the mascot of Zorbland", "Zorbland's mascot") may name an OPEN relation
local function open_relnoun_alt(S, np, arg)
  if np.head_kind ~= "unknown" or not np.head or not np.head.single or np.from_verb then return nil end
  if arg.head_kind ~= "entity" then return nil end
  local w = np.head.unit.form
  if #w < 3 or not w:match("^%a+$") then return nil end
  -- a word the lexicon already knows as a relational noun ("members", "founders") has its KNOWN relation: an open relation of the same name would only compete with it
  for _, m in ipairs(S.lex:match_at(S.units, np.head.u1)) do
    if m.j == np.head.u2 then
      for _, e in ipairs(m.entries) do if e.kind == "relnoun" then return nil end end
    end
  end
  local lemma = w
  if lemma:match("s$") and not lemma:match("ss$") and #lemma > 3 then lemma = lemma:sub(1, -2) end
  lemma = lemma:gsub("e$", "")
  local cp = U.shallow(np)
  cp.head_kind = "relnoun"
  cp.relnouns = { { kind = "relnoun", rel = "open:" .. lemma, role = "to", lemma = lemma, num = (lemma ~= w) and "pl" or "sg", open = true } }
  cp.open_relnoun = true
  return cp
end

-- core NP (no possessor): [det|poss] modifiers* head [of-complement] [back-reference]
local function parse_np_core(S, k, opts)
  local out = {}
  local c = C(S, k)
  if not c or c.masked then return out end
  -- "the second one", "the third", "the last one", "the former": an ordinal reference to a member of the latest list in the conversation
  -- (only offered when the conversation holds such a list; an ordinal followed by a nominal -- "the second solution" -- is an ordinary modifier)
  do
    local dm = S.ctx and S.ctx.discourse and S.ctx.discourse.mem
    if dm and dm.artifacts and dm.artifacts.entity and #dm.artifacts.entity > 0 then
      local k1, dc = k, nil
      if c.single and cat(c, "det") and c.unit.form == "the" then dc = c; k1 = k + 1 end
      local oc = C(S, k1)
      local ord
      if dc and oc and oc.single and not oc.masked and not barrier(oc) then
        if oc.unit.ordinal then ord = oc.unit.ordinal
        elseif oc.number and oc.number.kind == "ordinal" then ord = oc.number.value
        elseif oc.unit.form == "last" or oc.unit.form == "latter" then ord = "last"
        elseif oc.unit.form == "former" then ord = 1 end
      end
      if ord then
        local nk = k1 + 1
        local oc2 = C(S, nk)
        if oc2 and oc2.single and not oc2.masked and not barrier(oc2) and (oc2.unit.form == "one" or oc2.unit.form == "ones") then nk = nk + 1 end
        local nominal = false
        local nxt = C(S, nk)
        if nxt and not nxt.masked and not barrier(nxt) then
          local nn = nclass(S, nxt, true)
          if nn and (nn.sense or nn.relnoun or nn.entity or nn.number or nn.temporal) then nominal = true end
        end
        if not nominal then
          local np = new_np(dc)
          local lastc = C(S, nk - 1)
          np.head_kind, np.head, np.ordinal, np.det = "ordinal_ref", oc, ord, "the"
          np.hchunk_idx = oc.idx
          np.u2, np.c2, np.nxt, np.score = lastc.u2, lastc.idx, nk, 0.9
          out[#out + 1] = np
          return out
        end
      end
    end
  end
  local j = k
  local det, poss_det
  local c0 = c
  -- demonstratives / indefinites double as pronouns: only a determiner when a nominal follows
  if c.single and cat(c, "det") then
    local nxt = C(S, k + 1)
    local nc = nxt and not barrier(nxt) and nclass(S, nxt, true)
    if nc and not nc.pron then det = c.unit.form; j = k + 1 end
  elseif c.single and cat(c, "poss_det") then
    local nxt = C(S, k + 1)
    local nc = nxt and not barrier(nxt) and nclass(S, nxt, true)
    if nc and not nc.pron then poss_det = c.unit.form; j = k + 1 end -- else "her" is an object pronoun
  end
  -- pronoun NP (a demonstrative is a pronoun when no nominal follows it)
  if j == k and c.single then
    local nc = nclass(S, c)
    if nc and nc.pron and not nc.poss_det then
      local np = new_np(c)
      np.head_kind, np.pron = "pronoun", { form = c.unit.form, feats = c.pron or {}, cats = c.cats }
      np.head = c; np.nxt = k + 1; np.score = 0.1
      out[#out + 1] = np
      -- "the one" etc. fall through to the generic path
      return out
    end
  end
  -- gather the modifier/head run
  local run = {}
  local m = j
  while true do
    local cm = C(S, m)
    if not cm or cm.masked then break end
    if m > j and barrier(cm) then break end
    -- "the ONE small business I'm evaluating", "the one company I trust": "one" after a determiner only emphasises uniqueness when a noun phrase follows
    if m == j and det and cm.single and cm.unit.form == "one" then
      local nn = C(S, m + 1)
      local ncn = nn and not barrier(nn) and nclass(S, nn, true)
      if ncn and not ncn.pron then m = m + 1; goto continue_run end
    end
    local np_ctx = (m > j) or det ~= nil or poss_det ~= nil
    -- "Find DESIGN studios", "RESEARCH labs", "CLEANING services": a verb-form word that opens a bare noun phrase is a compound-noun modifier when a noun follows it
    if not np_ctx then
      -- an imperative / speech-act verb ("define", "find", "list") opens a clause, not a compound noun
      local acty = false
      for _, v in ipairs(cm.verbs or {}) do if v.act then acty = true end end
      local nx = (not acty) and C(S, m + 1) or nil
      if nx and not nx.masked and not barrier(nx) then
        local nn = nclass(S, nx, true)
        if nn and (nn.sense or nn.unknown or nn.relnoun) and not nn.from_verb and not nn.pron and not nn.adj then np_ctx = true end
      end
    end
    local nc = nclass(S, cm, np_ctx)
    if not nc then break end
    if nc.pron and not nc.entity and not nc.sense then break end
    -- a verb form right after a head noun starts a participial/relative clause ("companies hiring interns"); it is only a
    -- modifier when it follows a determiner or another pure modifier ("the supplied 2020 dataset")
    if nc.from_verb and #run > 0 then
      local prev = run[#run].cl
      if prev.entity or prev.sense or prev.relnoun or (prev.unknown and not prev.from_verb) then break end
    end
    run[#run + 1] = { c = cm, cl = nc }
    m = m + 1
    -- an entity directly followed by 's ends the run (possessor boundary handled by the caller)
    local nx = C(S, m)
    if nx and nx.single and cat(nx, "clitic_s") then break end
    ::continue_run::
  end
  if #run == 0 then return out end
  -- candidate head positions: last head-capable element first, then shorter prefixes (so "Acme pioneered automation"
  -- can still be split as NP + verb + NP by the frames); each truncation is penalised
  local function head_capable(cl)
    return cl.entity or cl.sense or cl.relnoun or cl.number or cl.temporal or cl.literal or cl.quote or cl.unknown
  end
  local heads = {}
  for hi_ = #run, 1, -1 do
    if head_capable(run[hi_].cl) then heads[#heads + 1] = hi_ end
    if #heads >= 3 then break end
  end
  if #heads == 0 then return out end
  -- "firms OFFERING carbon accounting software", "startups SEEKING funding": a head noun directly followed by a participial verb form may end the noun phrase there
  for hi_ = #run - 1, 1, -1 do
    if head_capable(run[hi_].cl) and not run[hi_].cl.entity and not run[hi_].cl.number and not run[hi_].cl.temporal then
      local nxtc = run[hi_ + 1].c
      local part = false
      if nxtc.single then for _, a in ipairs(P.verb_analyses(S, nxtc)) do if a.form == "ing" or a.form == "pp" then part = true end end end
      if part then
        local already = false
        for _, x in ipairs(heads) do if x == hi_ then already = true end end
        if not already then heads[#heads + 1] = hi_ end
      end
    end
  end
  for hn, hi in ipairs(heads) do
  local head = run[hi]
  local after = j + hi -- chunk index after head
  local trunc_penalty = (hn - 1) * 0.2
  -- modifiers before the head
  local function build(kind)
    local np = new_np(run[1].c)
    np.u1 = (det or poss_det) and c0.u1 or run[1].c.u1
    np.c1 = (det or poss_det) and c0.idx or run[1].c.idx
    np.det, np.poss_det = det, poss_det
    np.head, np.head_kind = head.c, kind
    np.hchunk_idx = head.c.idx
    for z = 1, hi - 1 do
      local mc, cl = run[z].c, run[z].cl
      local f = mc.unit and mc.unit.form or mc.form
      local entry = { chunk = mc, form = mc.form, text = mc.text }
      -- "the first draft" / "the last version": before a conversational-artifact noun (solution, draft, version ...) "first" is the ordinal 1
      local artifact_ordinal = mc.single and mc.unit.ordinal and next(S.lex:refclasses(head.c.form or "")) ~= nil
      if artifact_ordinal then
        np.ordinal = mc.unit.ordinal; entry.kind = "ordinal"
      elseif SUPERLATIVE_FORMS[mc.form] or (mc.single and mc.unit.form:find("est$") and (mc.adjs or S.lex:adj_reading(mc.unit.form:gsub("est$", "")))) then
        np.superlative = mc.form; entry.kind = "superlative"
      elseif mc.single and (mc.unit.ordinal or (mc.number and mc.number.kind == "ordinal")) then
        np.ordinal = mc.unit.ordinal or (mc.number and mc.number.value); entry.kind = "ordinal"
      elseif mc.number or (mc.single and mc.unit.kind == "number" and mc.unit.numval and not mc.temporal and not S.lex:resource(S.chunks[(mc.idx or 0) + 1] and S.chunks[mc.idx + 1].form or "")) then
        np.count = mc.number and mc.number.value or mc.unit.numval; entry.kind = "number"
      elseif mc.temporal then np.temporal_mod = mc.temporal; entry.kind = "temporal"
      elseif mc.single and mc.unit.temporal_scope then np.temporal_scope = mc.unit.temporal_scope; entry.kind = "temporal_adj"
      elseif cl.entity then entry.kind = "entity_mod"; entry.cands = entity_cands(S, mc)
      else entry.kind = "mod" end
      np.mods[#np.mods + 1] = entry
    end
    np.u2 = head.c.u2; np.c2 = head.c.idx
    np.nxt = after
    return np
  end
  local kinds = {}
  if head.cl.relnoun then kinds[#kinds + 1] = "relnoun" end
  if head.cl.entity then kinds[#kinds + 1] = "entity" end
  if head.cl.sense then
    local typenoun, concept = false, false
    for _, r in ipairs(head.c.senses) do if r.sense.kind == "typenoun" then typenoun = true else concept = true end end
    if typenoun then kinds[#kinds + 1] = "typenoun" end
    if concept then kinds[#kinds + 1] = "concept" end
  end
  if head.cl.number then kinds[#kinds + 1] = "number" end
  if head.cl.temporal then kinds[#kinds + 1] = "temporal" end
  if head.cl.literal then kinds[#kinds + 1] = "literal" end
  if head.cl.quote then kinds[#kinds + 1] = "quote" end
  if head.cl.unknown then kinds[#kinds + 1] = "unknown" end
  if head.cl.adj and #kinds == 0 then kinds[#kinds + 1] = "unknown" end
  for _, kind in ipairs(kinds) do
    local np = build(kind)
    -- scores from lexical attestation
    if kind == "entity" then
      np.cands = entity_cands(S, head.c)
      np.score = np.score + (#head.c.entities > 0 and 0.5 or 0.15)
      -- a PLURAL common noun cannot classify a proper name ("the companies Google acquired" is not an entity called that): only singular nouns, titles and
      -- other modifiers can stand before a name ("the company Apple", "Professor Smith", "CEO Dana Whitcombe")
      for _, md in ipairs(np.mods) do
        local mc = md.chunk
        if md.kind == "mod" and mc and mc.single then
          local pl = false
          for _, r in ipairs(mc.senses or {}) do if r.num == "pl" then pl = true end end
          for _, r in ipairs(mc.relnouns or {}) do if r.num == "pl" then pl = true end end
          if pl then np.score = np.score - 0.8; np.plural_classifier = true end
        end
      end
    elseif kind == "typenoun" or kind == "concept" then
      np.senses = {}
      for _, r in ipairs(head.c.senses) do
        if (kind == "typenoun") == (r.sense.kind == "typenoun") then np.senses[#np.senses + 1] = r.sense end
      end
      np.plural = false
      for _, r in ipairs(head.c.senses) do if r.num == "pl" then np.plural = true end end
      -- a word matched only through a spelling variant earns no attestation credit
      if not head.c.fuzzy then np.score = np.score + 0.4 + ((head.c.kind == "mwe") and 0.3 or 0) end
    elseif kind == "relnoun" then
      np.relnouns = head.c.relnouns
      if not head.c.fuzzy then np.score = np.score + 0.4 + ((head.c.kind == "mwe") and 0.2 or 0) end
      for _, e in ipairs(head.c.relnouns) do if e.num == "pl" then np.plural = true end end
    elseif kind == "unknown" then
      np.score = np.score - 0.05
      -- a lowercase unknown head after a named entity ("Google acquired", "Sequoia has") is rarely a noun phrase; an entity modifier does not make a compound
      if head.c.single and not head.c.cap then
        for _, md in ipairs(np.mods) do if md.kind == "entity_mod" then np.score = np.score - 0.4; break end end
      end
      if head.cl.from_verb then
        np.score = np.score - 0.15; np.from_verb = true
        -- "Google acquired": a proper name followed by a verb form is a clause, not a compound noun
        local pv = hi > 1 and run[hi - 1].cl
        if pv and pv.entity then np.score = np.score - 0.5 end
      end
    end
    if (kind == "typenoun" or kind == "concept" or kind == "unknown") and head.c.single then
      local f = head.c.unit.form
      if f:find("s$") and not head.c.unit.form:find("ss$") then np.plural = np.plural or (kind ~= "concept") end
    end
    np.score = np.score - trunc_penalty
    -- a spelling-variant reading must earn its place through structure; the literal unknown-word reading pays nothing
    if head.c.fuzzy and kind ~= "unknown" then np.score = np.score - 0.35 end
    out[#out + 1] = np
  end
  end -- heads
  -- post-modifiers: of-complement for relational / concept heads, back-reference cue
  local final = {}
  for _, np in ipairs(out) do
    local alts = { np }
    local nx = C(S, np.nxt)
    if nx and nx.single and (nx.unit.form == "of" or ((nx.unit.form == "at" or nx.unit.form == "for") and np.head_kind == "relnoun")) and not nx.masked and not barrier(nx) and not opts.no_of then
      local subs = parse_np(S, np.nxt + 1, { depth = (opts.depth or 0) + 1 })
      if (opts.depth or 0) < 3 then
        for si = 1, math.min(#subs, 2) do
          local sub = subs[si]
          local cp = U.shallow(np)
          cp.of_arg = sub
          cp.nxt = sub.nxt
          cp.u2 = sub.u2; cp.c2 = sub.c2
          cp.score = np.score + sub.score * 0.3
          alts[#alts + 1] = cp
          local ocp = open_relnoun_alt(S, cp, sub)
          if ocp then ocp.score = cp.score - 0.2; alts[#alts + 1] = ocp end
        end
      end
    end
    -- "the currency USED IN Tavoria", "the language spoken in X": a support participle of the noun's own relation + a locative preposition takes the place of "of"
    if np.head_kind == "relnoun" and nx and not nx.masked and not barrier(nx) and nx.relverbs and #nx.relverbs > 0 then
      local mine = {}
      for _, ne in ipairs(np.relnouns or {}) do mine[ne.rel] = true end
      local hit
      for _, ev in ipairs(nx.relverbs) do
        if ev.support and not ev.as_only and mine[ev.rel] and (ev.vform == "pp" or ev.vform == "past") then hit = true end
      end
      local pc = C(S, np.nxt + 1)
      if hit and pc and pc.single and not pc.masked and not barrier(pc) and PARTICIPLE_PREP[pc.unit.form] and (opts.depth or 0) < 3 then
        for si, sub_ in ipairs(parse_np(S, np.nxt + 2, { depth = (opts.depth or 0) + 1 })) do
          if si > 2 then break end
          local cp = U.shallow(np)
          cp.of_arg, cp.participial_arg = sub_, true
          cp.nxt = sub_.nxt
          cp.u2, cp.c2 = sub_.u2, sub_.c2
          cp.score = np.score + sub_.score * 0.3 - 0.1
          alts[#alts + 1] = cp
        end
      end
    end
    -- "the city of Paris", "the country of France": a type noun + of + a proper name denotes the named entity (typed by the noun)
    if np.head_kind == "typenoun" and alts[2] and alts[2].of_arg and (alts[2].of_arg.head_kind == "entity" or (alts[2].of_arg.head_kind == "unknown" and alts[2].of_arg.head and alts[2].of_arg.head.cap)) then
      local sub = alts[2].of_arg
      local cp = U.shallow(sub)
      cp.u1, cp.c1 = np.u1, np.c1
      cp.type_noun = np
      cp.score = sub.score + 0.45
      alts[#alts + 1] = cp
    end
    for _, a in ipairs(alts) do
      local br, who = backref_at(S, a.nxt)
      if br then
        local cp = U.shallow(a)
        cp.backref, cp.backref_who = true, who
        -- right association: a discourse-linked clause attaches to the nearest noun ("the CEO of [the company I mentioned]")
        if a.of_arg and not a.of_arg.backref then cp.score = a.score - 0.5 end
        local last = C(S, br - 1)
        cp.nxt = br; cp.u2 = last.u2; cp.c2 = last.idx
        final[#final + 1] = cp
      end
      final[#final + 1] = a
      -- "this company", "that firm": a demonstrative + kind noun denotes something already in the conversation
      if S.ctx and S.ctx.discourse and (a.det == "this" or a.det == "that") and a.head_kind == "typenoun" and not a.plural and not a.of_arg and not a.possessor and not a.backref
        and not (S.ctx.flags and S.ctx.flags.no_coref) then
        local cp = U.shallow(a)
        cp.backref, cp.demonstrative = true, true
        cp.score = a.score + 0.35
        final[#final + 1] = cp
      end
    end
  end
  -- a possessive determiner of the fronted-topic frame ("As for France, ITS capital ...") takes the topic as its argument
  local poss_topic = poss_det and (poss_det == "its" or poss_det == "their" or poss_det == "his" or poss_det == "her")
  if S.topic and (poss_topic or det == "the") then
    local extra = {}
    for _, a in ipairs(final) do
      if a.head_kind == "relnoun" and not a.of_arg and not a.possessor then
        local cp = U.shallow(a)
        cp.of_arg, cp.topic_arg = S.topic, true
        cp.score = a.score + (poss_topic and 0.4 or 0.3)
        extra[#extra + 1] = cp
      end
    end
    for _, e in ipairs(extra) do final[#final + 1] = e end
  end
  return final
end

-- NP with optional possessor:  NP 's NP   (France's capital)  and  entity+relnoun compounds are handled in frames
local TRANSPARENT_HEAD = U.set({ "name", "names", "identity", "location", "whereabouts",
  -- quantity / collection heads: "a list of organisations", "a handful of firms", "a couple of options" denote the things listed
  "list", "lists", "handful", "couple", "bunch", "selection", "sample", "variety", "range", "assortment", "series", "group", "set" })
function parse_np(S, k, opts)
  opts = opts or {}
  local key = k .. (opts.no_of and "n" or "") .. ":" .. (opts.depth or 0)
  local memo = S.np_memo[key]
  if memo then return memo end
  S.np_memo[key] = {} -- recursion guard
  local out = {}
  -- "the name of X's currency", "the location of X's headquarters": the head carries no relation of its own; the NP is the noun phrase after "of"
  do
    local ca, cb, cc = C(S, k), C(S, k + 1), C(S, k + 2)
    local shift
    if ca and cb and cc and ca.single and cb.single and cc.single and cat(ca, "det") and TRANSPARENT_HEAD[cb.unit.form] and cc.unit.form == "of"
      and not ca.masked and not barrier(cb) and not barrier(cc) then shift = 3
    elseif ca and cb and ca.single and cb.single and TRANSPARENT_HEAD[ca.unit.form] and cb.unit.form == "of" and not ca.masked and not barrier(cb) then shift = 2 end
    if shift then
      local subs = parse_np(S, k + shift, opts)
      for si = 1, math.min(#subs, 4) do
        local cp = U.shallow(subs[si])
        cp.c1, cp.u1 = ca.idx, ca.u1
        cp.transparent_head = true
        cp.score = subs[si].score - 0.05
        -- "the location of X's headquarters": the location-valued noun already names where; reading "location" as a relation of its own would add a hop
        if cp.head_kind == "relnoun" then
          for _, e in ipairs(cp.relnouns or {}) do
            local r = S.lex:get_rel(e.rel)
            if r and r.locus then cp.score = cp.score + 0.7 end
          end
        end
        out[#out + 1] = cp
      end
    end
  end
  local simple = parse_np_core(S, k, { no_of = true, depth = opts.depth })
  for _, a in ipairs(simple) do
    local nx = C(S, a.nxt)
    if nx and nx.single and cat(nx, "clitic_s") and not nx.masked and (a.head_kind == "entity" or a.head_kind == "typenoun" or a.head_kind == "unknown"
      or a.head_kind == "concept" or a.head_kind == "pronoun") then
      local subs = parse_np(S, a.nxt + 1, { depth = (opts.depth or 0) + 1 })
      for si = 1, math.min(#subs, 3) do
        local b = subs[si]
        if b.head_kind ~= "pronoun" then
          local cp = U.shallow(b)
          cp.possessor = a
          cp.u1, cp.c1 = a.u1, a.c1
          cp.score = b.score + a.score * 0.3 + 0.2
          out[#out + 1] = cp
          local ocp = open_relnoun_alt(S, cp, a)
          if ocp then ocp.score = cp.score - 0.2; out[#out + 1] = ocp end
        end
      end
    end
  end
  for _, a in ipairs(parse_np_core(S, k, opts)) do out[#out + 1] = a end
  -- "its currency", "his birthplace", "their founder": a possessive pronoun is the (anaphoric) argument of a relational noun
  if not S.topic then
    local extra = {}
    for _, a in ipairs(out) do
      local pd = a.poss_det
      if a.head_kind == "relnoun" and pd and POSS_PRON[pd] and not a.of_arg and not a.possessor then
        local c0 = C(S, a.c1)
        local pform = POSS_PRON[pd]
        local pnp = { head_kind = "pronoun", head = c0, pron = { form = pform, feats = S.lex:pron_feats(pform) or {}, cats = S.lex:cats(pform) or {}, possessive = pd },
          u1 = c0.u1, u2 = c0.u2, c1 = c0.idx, c2 = c0.idx, nxt = c0.idx + 1, mods = {}, score = 0.1, notes = {} }
        local cp = U.shallow(a)
        cp.possessor = pnp
        cp.score = a.score + 0.35
        extra[#extra + 1] = cp
      end
    end
    for _, e in ipairs(extra) do out[#out + 1] = e end
  end
  -- ties: the reading that consumes more input first (a discourse-linked clause explains strictly more words), then a stable order
  table.sort(out, function(x, y)
    if x.score ~= y.score then return x.score > y.score end
    if x.nxt ~= y.nxt then return x.nxt > y.nxt end
    return (x.head_kind or "") < (y.head_kind or "")
  end)
  local trimmed = {}
  for i = 1, math.min(#out, 6) do trimmed[i] = out[i] end
  S.np_memo[key] = trimmed
  return trimmed
end
P.parse_np = parse_np

---------------------------------------------------------------- verb phrases
local function aux_kind(c)
  if not c or not c.single then return nil end
  if cat(c, "aux_be") or c.be_clitic then return "be" end
  if cat(c, "aux_do") then return "do" end
  if cat(c, "aux_have") then return "have" end
  if cat(c, "modal") then return "modal" end
  return nil
end
P.aux_kind = aux_kind

-- parse [aux]* [not] [adv]* VERB at chunk k.  opts.stative_ok allows copula-only VPs.
-- opts.aux_hint ("be"|"do"|"have"|"modal"): evaluate verb forms as if that auxiliary had just been consumed elsewhere
-- (needed for split constructions such as "Which company did P found" where the auxiliary and verb are not adjacent)
function P.parse_vp(S, k, opts)
  opts = opts or {}
  local key = "v" .. k .. (opts.aux_hint or "") .. (opts.require_aux and "r" or "") .. (opts.participle_ok and "p" or "") .. (opts.finite_ok and "f" or "")
  if S.vp_memo[key] then return S.vp_memo[key] end
  local out = {}
  local j = k
  local aux = {}
  local neg, neg_chunk = false, nil
  local advs = {}
  local tscope
  local semi_ing, semi_inf
  while true do
    local c = C(S, j)
    if not c or c.masked or (j > k and barrier(c)) then break end
    -- aspectual semi-auxiliaries: "ENDED UP acquiring", "WENT ON TO found", "MANAGED TO buy" (the verb that follows carries the meaning)
    do
      local f, n1, n2 = c.single and c.unit.form, C(S, j + 1), C(S, j + 2)
      if f and (f == "end" or f == "ends" or f == "ended" or f == "ending") and n1 and n1.single and n1.unit.form == "up" and not barrier(n1) then
        aux[#aux + 1] = { kind = "semi", form = f .. " up", chunk = c }; semi_ing = true; j = j + 2; goto continue_aux
      elseif f and (f == "managed" or f == "manage" or f == "manages" or f == "proceeded" or f == "proceeds" or f == "tried" or f == "decided") and n1 and n1.single and n1.unit.form == "to" and not barrier(n1) then
        aux[#aux + 1] = { kind = "semi", form = f .. " to", chunk = c }; semi_inf = true; j = j + 2; goto continue_aux
      elseif f and (f == "went" or f == "goes" or f == "go") and n1 and n1.single and n1.unit.form == "on" and n2 and n2.single and n2.unit.form == "to" and not barrier(n1) then
        aux[#aux + 1] = { kind = "semi", form = f .. " on to", chunk = c }; semi_inf = true; j = j + 3; goto continue_aux
      end
    end
    local ak = aux_kind(c)
    if ak == "have" then
      -- perfect auxiliary only if a participle / "been" follows (skipping not / adverbs): "has founded", "had been", "could have founded"
      local q, is_aux = j + 1, false
      while true do
        local nc = C(S, q)
        if nc and nc.single and not nc.masked and not barrier(nc) and (P.is_neg(nc) or cat(nc, "adv")) then q = q + 1 else break end
      end
      local nc = C(S, q)
      if nc and nc.single and not nc.masked and not barrier(nc) then
        if cat(nc, "aux_be") then is_aux = true
        else for _, a in ipairs(P.verb_analyses(S, nc)) do if a.form == "pp" then is_aux = true end end end
      end
      if not is_aux then ak = nil end
    end
    if ak and not (cat(c, "clitic_s") and false) then
      -- the verb itself may be an aux-form (is/does/has): only treat as aux if another verb follows
      aux[#aux + 1] = { kind = ak, form = c.unit.form, chunk = c }
      j = j + 1
    elseif P.is_neg(c) then neg, neg_chunk = true, c; j = j + 1
    elseif c.single and cat(c, "adv") and not P.is_neg(c) then advs[#advs + 1] = c; j = j + 1
    elseif c.temporal and (c.temporal.kind == "marker" or c.temporal.kind == "relative") and c.temporal.scope then
      tscope = c.temporal.scope; advs[#advs + 1] = c; j = j + 1
    else break end
    ::continue_aux::
  end
  local vc = C(S, j)
  if vc and not vc.masked and not (j > k and barrier(vc)) then
    local ana = P.verb_analyses(S, vc)
    local last_aux = (aux[#aux] and aux[#aux].kind) or opts.aux_hint
    -- after do-support / a modal the verb MUST be a base form: an entirely unknown word there is a base verb ("Why did the plan fail?")
    if (last_aux == "do" or last_aux == "modal") and vc.single and vc.kind == "word" and not next(vc.cats) and #vc.senses == 0 and #vc.entities == 0
      and #vc.relnouns == 0 and #vc.names == 0 and not vc.number and not vc.temporal then
      local has_base = false
      for _, a in ipairs(ana) do if a.form == "base" then has_base = true end end
      if not has_base then
        local ext = {}
        for i, a in ipairs(ana) do ext[i] = a end
        local ol = vc.unit.form:gsub("e$", "")
        ext[#ext + 1] = { lemma = vc.unit.form, form = "base", guessed = true,
          entries = { { kind = "relverb", rel = "open:" .. ol, subj = "to", vform = "base", lemma = vc.unit.form, open = true } } }
        ana = ext
      end
    end
    if #ana > 0 then
      local variants = {}
      for _, a in ipairs(ana) do
        local voice, ok = "active", false
        if not last_aux then
          if opts.participle_ok then
            -- reduced relative clause: bare -ing is active ("companies hiring interns"), bare participle is passive ("founded by X")
            if a.form == "ing" then ok = true elseif a.form == "pp" then voice, ok = "passive", true end
          else
            ok = (a.form == "past" or a.form == "3sg" or a.form == "base") and not (opts.require_aux)
          end
        elseif (last_aux == "do" or last_aux == "modal") and opts.finite_ok then ok = a.form == "base" or a.form == "3sg" or a.form == "past"
        elseif last_aux == "semi" then ok = (semi_ing and a.form == "ing") or (semi_inf and a.form == "base")
        elseif last_aux == "do" or last_aux == "modal" then ok = a.form == "base"
        elseif last_aux == "have" then ok = a.form == "pp"
        elseif last_aux == "be" then
          if a.form == "pp" then voice, ok = "passive", true
          elseif a.form == "ing" then voice, ok = "active", true end
        end
        if ok then variants[#variants + 1] = { analysis = a, voice = voice } end
      end
      for _, v in ipairs(variants) do
        out[#out + 1] = { u1 = (aux[1] and aux[1].chunk.u1) or vc.u1, u2 = vc.u2, c1 = k, c2 = j, aux = aux, neg = neg, neg_chunk = neg_chunk,
          advs = advs, verb = vc, analysis = v.analysis, lemma = v.analysis.lemma, vform = v.analysis.form, voice = v.voice,
          progressive = (last_aux == "be" and v.analysis.form == "ing") or nil, tscope = tscope, nxt = j + 1,
          perfect = (last_aux == "have") or nil, aux_hint = opts.aux_hint }
      end
    end
  end
  S.vp_memo[key] = out
  return out
end

---------------------------------------------------------------- wh-phrases
local KIND_NOUN = U.set({ "kind", "type", "sort", "form" })
local WH_INTENSIFIER = U.set({ "exactly", "precisely", "specifically", "actually", "even", "ever", "really" })

-- a preposition fronted together with its wh-phrase ("In which city is X headquartered?", "By whom was X founded?", "To which country does P belong?")
local PIED_PREP = U.set({ "in", "on", "at", "from", "to", "by", "with", "for", "of", "during", "under", "through", "into", "about", "against", "across" })
local WH_PLACE_PREP, WH_TIME_PREP = U.set({ "in", "at", "from" }), U.set({ "in", "on", "at", "during" })

function P.parse_wh(S, k)
  local key = "w" .. k
  if S.wh_memo[key] then return S.wh_memo[key] end
  local out = {}
  local c = C(S, k)
  if c and c.single and cat(c, "prep") and not c.masked and PIED_PREP[c.unit.form] then
    local nc = C(S, k + 1)
    if nc and nc.single and not nc.masked and not barrier(nc) and cat(nc, "wh") and (nc.unit.form == "which" or nc.unit.form == "what" or nc.unit.form == "whom") then
      for _, w in ipairs(P.parse_wh(S, k + 1)) do
        if not w.adverbial then
          local cl = {}
          for kk, vv in pairs(w) do cl[kk] = vv end
          cl.pied, cl.c1, cl.u1 = c.unit.form, k, c.u1
          out[#out + 1] = cl
          -- "In which CITY ..." asks for a place exactly like "Where ...", "In which YEAR ..." exactly like "When ..." (the type of the wh-noun is kept as answer type)
          local lexty = w.type
          if lexty and WH_PLACE_PREP[c.unit.form] and S.lex:isa(lexty, "place") then
            out[#out + 1] = { wh = "where", adverbial = true, type = lexty, np = nil, pied = c.unit.form, pied_adv = true, nxt = w.nxt, c1 = k, c2 = w.c2, u1 = c.u1, u2 = w.u2 }
          elseif lexty and WH_TIME_PREP[c.unit.form] and S.lex:isa(lexty, "time") then
            out[#out + 1] = { wh = "when", adverbial = true, type = lexty, pied = c.unit.form, pied_adv = true, nxt = w.nxt, c1 = k, c2 = w.c2, u1 = c.u1, u2 = w.u2 }
          end
        end
      end
    end
  elseif c and c.single and cat(c, "wh") and not c.masked then
    local f = c.unit.form
    if f == "who" or f == "whom" then
      out[#out + 1] = { wh = "who", type = "agent", nxt = k + 1, c1 = k, c2 = k, u1 = c.u1, u2 = c.u2 }
    elseif f == "what" or f == "which" then
      out[#out + 1] = { wh = f, nxt = k + 1, c1 = k, c2 = k, u1 = c.u1, u2 = c.u2 }
      local j = k + 1
      local nx = C(S, j)
      -- "what kind of X" / "which sort of X"
      if nx and nx.single and KIND_NOUN[nx.unit.form] and C(S, j + 1) and C(S, j + 1).unit.form == "of" then j = j + 2 end
      -- "which one(s)"
      local n1 = C(S, j)
      if n1 and n1.single and (n1.unit.form == "one" or n1.unit.form == "ones") and not barrier(n1) then
        out[#out + 1] = { wh = f, one = true, nxt = j + 1, c1 = k, c2 = j, u1 = c.u1, u2 = n1.u2 }
      else
        for _, np in ipairs(parse_np(S, j, { no_of = true })) do
          if np.head_kind == "typenoun" or np.head_kind == "concept" or np.head_kind == "unknown" then
            local t = np.senses and np.senses[1] and np.senses[1].type
            out[#out + 1] = { wh = f, type = t, np = np, nxt = np.nxt, c1 = k, c2 = np.c2, u1 = c.u1, u2 = np.u2, plural = np.plural }
            -- "What YEAR did X start?": a wh-noun of time asks the same thing as "When did X start?"
            if t and np.head and np.head.single and (np.head.unit.form == "year" or np.head.unit.form == "date") and S.lex:isa(t, "time") then
              out[#out + 1] = { wh = "when", adverbial = true, type = t, nxt = np.nxt, c1 = k, c2 = np.c2, u1 = c.u1, u2 = np.u2, from_noun = true }
            end
          elseif np.head_kind == "relnoun" and not np.of_arg and not np.possessor and #np.mods == 0 then
            -- the wh-noun names the RELATION that is asked about ("What currency does X use?", "Which language is spoken in Y?"); it is not a known argument
            local e = np.relnouns[1]
            local rel = e and S.lex:get_rel(e.rel)
            out[#out + 1] = { wh = f, type = rel and rel[e.role] or nil, np = np, relnoun = true, nxt = np.nxt, c1 = k, c2 = np.c2, u1 = c.u1, u2 = np.u2, plural = np.plural }
          end
        end
      end
    elseif f == "whose" then
      for _, np in ipairs(parse_np(S, k + 1, { no_of = true })) do
        out[#out + 1] = { wh = "whose", np = np, nxt = np.nxt, c1 = k, c2 = np.c2, u1 = c.u1, u2 = np.u2 }
      end
    elseif f == "when" or f == "where" or f == "why" or f == "whether" then
      out[#out + 1] = { wh = f, adverbial = true, nxt = k + 1, c1 = k, c2 = k, u1 = c.u1, u2 = c.u2 }
    elseif f == "how" then
      local n1 = C(S, k + 1)
      if n1 and n1.single and (n1.unit.form == "many" or n1.unit.form == "much") then
        for _, np in ipairs(parse_np(S, k + 2, { no_of = true })) do
          out[#out + 1] = { wh = "how_" .. n1.unit.form, np = np, nxt = np.nxt, c1 = k, c2 = np.c2, u1 = c.u1, u2 = np.u2, plural = true }
        end
        -- "How much does X cost?", "How much is X?": the quantity word stands alone (an auxiliary follows)
        local a1 = C(S, k + 2)
        if a1 and a1.single and not a1.masked and not barrier(a1) and (cat(a1, "aux_do") or cat(a1, "aux_be") or cat(a1, "aux_have") or cat(a1, "modal")) then
          out[#out + 1] = { wh = "how_" .. n1.unit.form, bare = true, nxt = k + 2, c1 = k, c2 = k + 1, u1 = c.u1, u2 = n1.u2 }
        end
      elseif n1 and n1.single and n1.adjs and n1.adjs[1] then
        out[#out + 1] = { wh = "how_adj", adj = n1.unit.form, dim = n1.adjs[1].dim, nxt = k + 2, c1 = k, c2 = k + 1, u1 = c.u1, u2 = n1.u2 }
      elseif n1 and n1.single and (n1.unit.form == "often" or n1.unit.form == "far" or n1.unit.form == "long") then
        out[#out + 1] = { wh = "how_adj", adj = n1.unit.form, nxt = k + 2, c1 = k, c2 = k + 1, u1 = c.u1, u2 = n1.u2 }
      end
      out[#out + 1] = { wh = "how", adverbial = true, nxt = k + 1, c1 = k, c2 = k, u1 = c.u1, u2 = c.u2 }
    end
  end
  -- "who EXACTLY is the CEO of X?", "what precisely is Y?": an intensifier right after the wh-phrase adds nothing
  for _, w in ipairs(out) do
    while true do
      local ic = C(S, w.nxt)
      if ic and ic.single and not ic.masked and not barrier(ic) and WH_INTENSIFIER[ic.unit.form] then w.nxt = w.nxt + 1 else break end
    end
  end
  S.wh_memo[key] = out
  return out
end

---------------------------------------------------------------- fronted topic
-- "As for France, its capital is Paris."  /  "Regarding Acme, who is its CEO?"  The topic phrase is consumed (S.first moves past it) and recorded as S.topic;
-- a possessive determiner ("its", "their") or the definite article on an argument-less relational noun ("the CEO") in the rest of the sentence takes it
-- as its argument (see parse_np_core).
local LOCATIVE_TOPIC = U.set({ "at", "in", "for", "within", "inside", "across", "among" })
function P.take_topic(S)
  local c = C(S, S.first)
  if not c or c.masked or S.topic then return nil end
  local tn = S.lex:cue_at("topic_intro", S.units, c.u1)
  -- "Quick question about the company I mentioned: which business acquired it?" -- "about X" opens a topic only when a question follows the separator
  local about = false
  if not tn and c.single and c.unit.form == "about" then tn, about = 1, true end
  -- "At Acme Corp, who is the CEO?"  "In France, what is the capital?": a fronted locative / scope phrase naming a proper name opens a topic like "As for"
  local scope_pp = false
  if not tn and c.single and LOCATIVE_TOPIC[c.unit.form] and cat(c, "prep") then tn, scope_pp = 1, true end
  if not tn then return nil end
  local k, consumed = S.first, 0
  while k <= S.last and consumed < tn do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); k = k + 1 end
  if consumed ~= tn then return nil end
  for _, np in ipairs(P.parse_np(S, k)) do
    local nx = C(S, np.nxt)
    local sep = nx and nx.pre and (nx.pre:find("comma") or nx.pre:find("colon") or nx.pre:find("dash"))
    local okkind = np.head_kind == "entity" or np.head_kind == "unknown" or np.head_kind == "typenoun"
    -- a scope phrase must be a bare proper name followed by a comma (never "In which city, ...", "In 2020, ...", "At the end, ...")
    if scope_pp then
      okkind = (np.head_kind == "entity" or (np.head_kind == "unknown" and np.head and np.head.cap)) and not np.det and not np.poss_det
        and nx and nx.pre and nx.pre:find("comma") ~= nil
    end
    if about and sep then
      local w1 = nx and nx.single and cat(nx, "wh")
      local wh_follows = nx and #P.parse_wh(S, np.nxt) > 0
      if not (w1 or wh_follows) then okkind = false end
    end
    if sep and okkind then
      S.topic = np
      S.first = np.nxt
      return np
    end
  end
  return nil
end

-- "According to the ministry, the capital of Tavoria is Brelmont."  The source phrase is recorded (S.attribution) and moved out of the way; the clause
-- that follows carries the relation.
function P.take_attribution(S)
  local c = C(S, S.first)
  if not c or c.masked or S.attribution then return nil end
  local tn = S.lex:cue_at("attribution", S.units, c.u1)
  if not tn then return nil end
  local k, consumed = S.first, 0
  while k <= S.last and consumed < tn do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); k = k + 1 end
  if consumed ~= tn then return nil end
  for _, np in ipairs(P.parse_np(S, k)) do
    local nx = C(S, np.nxt)
    if nx and nx.pre and nx.pre:find("comma") then
      S.attribution = { text = P.span_text(S, np), kind = "according" }
      S.first = np.nxt
      return S.attribution
    end
  end
  return nil
end

-- "Officials confirmed that the capital of Tavoria is Brelmont."  /  "The ministry said Paris is the capital."  A subject, a reporting verb and (usually) "that"
-- introduce a clause.  With an explicit "that" it is unambiguous; without it, it is used only as a SECOND attempt when the sentence as written yields nothing,
-- because many reporting verbs are relation verbs too.
function P.take_reported(S, that_only)
  if S.attribution then return nil end
  for _, np in ipairs(P.parse_np(S, S.first)) do
    local vc = C(S, np.nxt)
    if vc and vc.single and not vc.masked and not barrier(vc) and cat(vc, "report_verb") and np.head_kind ~= "relnoun" then
      local k2 = np.nxt + 1
      local tc = C(S, k2)
      local had_that = tc and tc.single and tc.unit.form == "that" and not tc.masked
      if had_that then k2 = k2 + 1 end
      if S.last - k2 >= 2 and (had_that or (not that_only and not (vc.relverbs and #vc.relverbs > 0))) then
        S.attribution = { text = P.span_text(S, np) .. " " .. vc.form, kind = "reported" }
        S.first = k2
        return S.attribution
      end
    end
  end
  return nil
end

---------------------------------------------------------------- chunk-list normalisations (order / presence of chunks only; offsets untouched)
local function remove_chunks(S, drop)
  local new = {}
  for i, c in ipairs(S.chunks) do if not drop[i] then new[#new + 1] = c end end
  for i, c in ipairs(new) do c.idx = i end
  S.chunks = new
  S.last = #new
  S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
end

-- clefts: "It was P who set up O" -> "P set up O";  "Who was it that founded O?" -> "Who founded O?"
function P.normalize_cleft(S)
  local f = S.first
  local c1, c2 = C(S, f), C(S, f + 1)
  if c1 and c1.single and c1.unit.form == "it" and not c1.masked and c2 and c2.single and cat(c2, "aux_be") and not barrier(c2) then
    -- a prepositional cleft: "It is in Oslo that Acme keeps its head office" -> "Acme keeps its head office in Oslo"
    local pc = C(S, f + 2)
    if pc and pc.single and not pc.masked and cat(pc, "prep") and not barrier(pc) then
      for _, np1 in ipairs(P.parse_np(S, f + 3)) do
        local rc = C(S, np1.nxt)
        if rc and rc.single and not rc.masked and not barrier(rc) and (rc.unit.form == "that" or rc.unit.form == "which") then
          for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
            for _, vp in ipairs(P.parse_vp(S, np2.nxt)) do
              if vp.voice == "active" then
                local new = {}
                for i = 1, f - 1 do new[#new + 1] = S.chunks[i] end
                for i = np1.nxt + 1, #S.chunks do new[#new + 1] = S.chunks[i] end        -- NP2 VP ... rest
                for i = f + 2, np1.nxt - 1 do new[#new + 1] = S.chunks[i] end            -- the clefted prepositional phrase goes last
                local first = new[f]
                if first and first.pre and first.pre:find("comma") then first.pre = nil end
                for i, ch in ipairs(new) do ch.idx = i end
                S.chunks = new
                S.last = #new
                S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
                S.cleft = true
                return true
              end
            end
          end
        end
      end
    end
    for _, np in ipairs(P.parse_np(S, f + 2)) do
      local rc = C(S, np.nxt)
      if rc and rc.single and not rc.masked and not barrier(rc) and (rc.unit.form == "who" or rc.unit.form == "that" or rc.unit.form == "which") then
        -- a subject cleft only: the relativizer must be followed by a verb phrase
        if #P.parse_vp(S, np.nxt + 1) > 0 then
          remove_chunks(S, { [f] = true, [f + 1] = true, [np.nxt] = true })
          S.cleft = true
          return true
        end
        -- an object cleft: "It is Paris that France recognizes as its capital" -> "France recognizes Paris as its capital"
        if (rc.unit.form == "that" or rc.unit.form == "which" or rc.unit.form == "who") then
          for _, np2 in ipairs(P.parse_np(S, np.nxt + 1)) do
            for _, vp in ipairs(P.parse_vp(S, np2.nxt)) do
              if vp.voice == "active" then
                local new = {}
                for i = 1, f - 1 do new[#new + 1] = S.chunks[i] end
                for i = np.nxt + 1, vp.c2 do new[#new + 1] = S.chunks[i] end        -- NP2 + VP
                for i = f + 2, np.nxt - 1 do new[#new + 1] = S.chunks[i] end        -- the clefted NP1 takes the gap
                for i = vp.c2 + 1, #S.chunks do new[#new + 1] = S.chunks[i] end
                local first = new[f]
                if first and first.pre and first.pre:find("comma") then first.pre = nil end
                for i, ch in ipairs(new) do ch.idx = i end
                S.chunks = new
                S.last = #new
                S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
                S.cleft = true
                return true
              end
            end
          end
        end
      end
    end
  end
  if c1 and c1.single and cat(c1, "wh") and not c1.masked then
    for _, wh in ipairs(P.parse_wh(S, f)) do
      local j = wh.nxt
      local a, b, c = C(S, j), C(S, j + 1), C(S, j + 2)
      if a and a.single and cat(a, "aux_be") and b and b.single and b.unit.form == "it" and c and c.single and (c.unit.form == "that" or c.unit.form == "who")
        and not barrier(b) and not barrier(c) then
        remove_chunks(S, { [j] = true, [j + 1] = true, [j + 2] = true })
        S.cleft = true
        -- "What is it that France uses as its currency?": what remains is a clause with an object gap, in direct (embedded) order
        if #P.parse_vp(S, j) == 0 and #P.parse_np(S, j) > 0 then S.embedded = true end
        return true
      end
    end
  end
  return false
end

-- a wh-phrase left in place in a question ("Acme is headquartered in which city?") is fronted and the clause un-inverted ("In which city is Acme headquartered?")
-- A declarative clause asked for confirmation is the yes/no question about it:
--   "Is it true that Canberra is the capital of Australia?"   "Canberra is the capital of Australia, right?"   "Siemens has bought Brightwater, hasn't it?"
-- The wrapper / tag is removed and, when the clause has a copula or a perfect auxiliary, the auxiliary moves to the front ("Is Canberra the capital of ...").
function P.invert_declarative(S)
  local f = S.first
  for _, np1 in ipairs(P.parse_np(S, f)) do
    local ac = C(S, np1.nxt)
    if ac and ac.single and not ac.masked and not barrier(ac) and (cat(ac, "aux_be") or cat(ac, "aux_have")) and np1.nxt < S.last then
      local new = {}
      for i = 1, f - 1 do new[#new + 1] = S.chunks[i] end
      new[#new + 1] = ac
      for i = f, np1.nxt - 1 do new[#new + 1] = S.chunks[i] end
      for i = np1.nxt + 1, #S.chunks do new[#new + 1] = S.chunks[i] end
      for i, ch in ipairs(new) do ch.idx = i end
      S.chunks, S.last = new, #new
      S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
      S.inverted = true
      return true
    end
  end
  return false
end

function P.take_polar(S)
  if S.polar or S.inverted then return false end
  local f = S.first
  local c = C(S, f)
  if not c or c.masked then return false end
  local opened, tagged = false, false
  local n = S.lex:cue_at("polar_open", S.units, c.u1)
  if n then
    local k, consumed = f, 0
    while k <= S.last and consumed < n do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); k = k + 1 end
    if consumed == n and k <= S.last then S.first = k; opened = true end
  end
  -- a tag after the last comma: ", right?"  ", isn't it?"  ", correct?"
  for p = S.last, S.first + 2, -1 do
    local cp = C(S, p)
    if cp and cp.pre and cp.pre:find("comma") then
      local nt = S.lex:cue_at("polar_tag", S.units, cp.u1)
      if nt then
        local q, consumed = p, 0
        while q <= S.last and consumed < nt do consumed = consumed + (C(S, q).u2 - C(S, q).u1 + 1); q = q + 1 end
        if consumed == nt and q > S.last then
          for i = S.last, p, -1 do table.remove(S.chunks, i) end
          S.last = p - 1
          S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
          tagged = true
        end
      end
      break
    end
  end
  -- an it-cleft question: "Was it Microsoft THAT bought LinkedIn?" asks whether "Microsoft bought LinkedIn"
  if not opened and not tagged then
    local f0 = S.first
    local b0, it0 = C(S, f0), C(S, f0 + 1)
    if b0 and it0 and b0.single and it0.single and not b0.masked and not it0.masked and cat(b0, "aux_be") and it0.unit.form == "it" and not barrier(it0) then
      for _, np in ipairs(P.parse_np(S, f0 + 2)) do
        local tc = C(S, np.nxt)
        if tc and tc.single and not tc.masked and not barrier(tc) and (tc.unit.form == "that" or tc.unit.form == "who") and np.nxt < S.last then
          local new = {}
          for i = 1, f0 - 1 do new[#new + 1] = S.chunks[i] end
          for i = np.c1, np.c2 do new[#new + 1] = S.chunks[i] end
          for i = np.nxt + 1, #S.chunks do new[#new + 1] = S.chunks[i] end
          for i, ch in ipairs(new) do ch.idx = i end
          S.chunks, S.last = new, #new
          S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
          S.polar = true
          return true
        end
      end
    end
  end
  if not (opened or tagged) then return false end
  S.polar = true
  P.invert_declarative(S)
  return true
end

function P.front_insitu_wh(S)
  if not (S.sentence and S.sentence.question_mark) then return false end
  local f = S.first
  local c0 = C(S, f)
  if not c0 or #P.parse_wh(S, f) > 0 then return false end
  for p = f + 1, S.last do
    local cp = C(S, p)
    if cp and cp.single and not cp.masked and cat(cp, "wh") and (cp.unit.form == "which" or cp.unit.form == "what" or cp.unit.form == "whom" or cp.unit.form == "who") and not barrier(cp) then
      local best
      for _, w in ipairs(P.parse_wh(S, p)) do if w.type and (not best or w.nxt > best.nxt) then best = w end end
      -- truly in situ: the wh-phrase closes the sentence ("Kenya is on WHICH CONTINENT?"); after a clause break it is an ordinary fronted question ("..., but WHICH CONTINENT is Kenya in?")
      if best and best.nxt > S.last and not (cp.pre and cp.pre:find("comma")) then
        local start = p
        local pc = C(S, p - 1)
        if pc and pc.single and cat(pc, "prep") and p - 1 >= f then start = p - 1 end
        local new = {}
        for i = 1, f - 1 do new[#new + 1] = S.chunks[i] end
        for i = start, best.nxt - 1 do new[#new + 1] = S.chunks[i] end
        for i = f, start - 1 do new[#new + 1] = S.chunks[i] end
        for i = best.nxt, #S.chunks do new[#new + 1] = S.chunks[i] end
        for i, c in ipairs(new) do c.idx = i end
        S.chunks = new
        S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
        S.embedded = true
        P.uninvert_embedded(S, f)
        return true
      end
    end
  end
  return false
end

-- a proxy copula chunk for a stative verb ("stands", "sits", "lies"): every frame that tests for the copula accepts it, offsets stay those of the verb
local function as_copula_chunk(S, c, past)
  local cc = setmetatable({}, { __index = c })
  cc.single, cc.copula_like = true, true
  cc.unit = setmetatable({ form = past and "was" or "is", surface_form = c.form }, { __index = c.unit })
  cc.cats = S.lex:cats("is") or {}
  cc.verbs, cc.relverbs = nil, {}
  return cc
end

local STATIVE_VERBS = { stands = "is", stand = "are", stood = "was", sits = "is", sit = "are", sat = "was", lies = "is", lie = "are", lay = "was", rests = "is", remains = "is", remain = "are",
  remained = "was", is = "is", are = "are", was = "was", were = "was" }
local INVERSION_PP = U.set({ "in", "at", "within", "near", "on", "across", "inside", "outside" })

-- declarative inversions are put back into subject-first order (only the chunk ORDER changes; offsets and provenance stay with the original words):
--   "Serving as CEO of O is P."              -> "P serving as CEO of O"        (copula-like -ing phrase fronted)
--   "Headquartered in C is O."               -> "O is headquartered in C"      (locative participle fronted)
--   "In C stands the headquarters of O."     -> "The headquarters of O is in C" (locative inversion)
--   "What K calls its capital is C."         -> "K calls its capital C"         (pseudo-cleft)
function P.normalize_inversion(S)
  if S.sentence and S.sentence.question_mark then return false end
  local f = S.first
  local c1 = C(S, f)
  if not c1 or c1.masked or S.inverted then return false end
  local function finish(new)
    local first = new[f]
    if first and first.pre and first.pre:find("comma") then first.pre = nil end
    for i, ch in ipairs(new) do ch.idx = i end
    S.chunks = new
    S.last = #new
    S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
    S.inverted = true
    return true
  end
  local function range(new, a, b) for i = a, b do new[#new + 1] = S.chunks[i] end end
  local function before(new) for i = 1, f - 1 do new[#new + 1] = S.chunks[i] end end
  -- (a) copula-like -ing phrase
  if c1.copula_like and c1.form:match("ing as$") then
    for _, np1 in ipairs(P.parse_np(S, f + 1)) do
      local be = C(S, np1.nxt)
      if be and be.single and not be.masked and cat(be, "aux_be") then
        for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
          if np2.nxt > S.last then
            local new = {}
            before(new); range(new, np2.c1, np2.c2); new[#new + 1] = c1; range(new, np1.c1, np1.c2)
            return finish(new)
          end
        end
      end
    end
  end
  -- (b) fronted locative participle
  if c1.single and c1.relverbs and #c1.relverbs > 0 then
    for _, e in ipairs(c1.relverbs) do
      local pc = C(S, f + 1)
      if e.prep and (e.vform == "pp" or e.vform == "past") and pc and pc.single and not pc.masked and pc.unit.form == e.prep then
        for _, np1 in ipairs(P.parse_np(S, f + 2)) do
          local be = C(S, np1.nxt)
          if be and be.single and not be.masked and cat(be, "aux_be") then
            for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
              if np2.nxt > S.last then
                local new = {}
                before(new); range(new, np2.c1, np2.c2); new[#new + 1] = be; new[#new + 1] = c1; new[#new + 1] = pc; range(new, np1.c1, np1.c2)
                return finish(new)
              end
            end
          end
        end
      end
    end
  end
  -- (c) locative inversion
  if c1.single and cat(c1, "prep") and INVERSION_PP[c1.unit.form] then
    for _, np1 in ipairs(P.parse_np(S, f + 1)) do
      local vc = C(S, np1.nxt)
      local form = vc and vc.single and not vc.masked and not barrier(vc) and STATIVE_VERBS[vc.unit.form]
      if form and (np1.head_kind == "entity" or np1.head_kind == "unknown" or np1.head_kind == "typenoun") then
        for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
          if np2.nxt > S.last then
            local new = {}
            local cop = cat(vc, "aux_be") and vc or as_copula_chunk(S, vc, form == "was")
            before(new); range(new, np2.c1, np2.c2); new[#new + 1] = cop; new[#new + 1] = c1; range(new, np1.c1, np1.c2)
            return finish(new)
          end
        end
      end
    end
  end
  -- (d) pseudo-cleft:  What NP VERB ... is NP.
  if c1.single and not c1.masked and c1.unit.form == "what" then
    for b = S.last, f + 3, -1 do
      local be = C(S, b)
      if be and be.single and not be.masked and cat(be, "aux_be") and not barrier(be) then
        for _, np3 in ipairs(P.parse_np(S, b + 1)) do
          if np3.nxt > S.last then
            for _, np2 in ipairs(P.parse_np(S, f + 1)) do
              for _, vp in ipairs(P.parse_vp(S, np2.nxt)) do
                if vp.voice == "active" and vp.nxt <= b then
                  local new = {}
                  before(new)
                  range(new, f + 1, vp.c2)
                  local rest_as = C(S, vp.nxt) and C(S, vp.nxt).single and C(S, vp.nxt).unit.form == "as"
                  if rest_as then range(new, np3.c1, np3.c2); range(new, vp.nxt, b - 1)
                  else range(new, vp.nxt, b - 1); range(new, np3.c1, np3.c2) end
                  return finish(new)
                end
              end
            end
          end
        end
      end
    end
  end
  return false
end

-- a fronted temporal adjunct is moved behind the clause it modifies:  "In 2020, who was the CEO of X?" -> "Who was the CEO of X in 2020?",
-- "Back in 2015, what was the capital of K?", "Before 2010 who founded Acme?".  Only the chunk order changes (offsets and provenance still point at the
-- original words).  The adjunct must be followed by a comma or by the start of a clause (a wh-word or an auxiliary).
local TEMPORAL_LEAD = U.set({ "back", "way", "just", "only", "even" })
function P.front_temporal(S)
  local f = S.first
  local k = f
  local c = C(S, k)
  while c and c.single and not c.masked and TEMPORAL_LEAD[c.unit.form] and k < S.last do k = k + 1; c = C(S, k) end
  if not (c and c.temporal and not c.masked) or k >= S.last then return false end
  local nxt = C(S, k + 1)
  if not nxt or nxt.masked then return false end
  local comma = nxt.pre and nxt.pre:find("comma") ~= nil
  local clause = nxt.single and (cat(nxt, "wh") or cat(nxt, "aux_do") or cat(nxt, "aux_be") or cat(nxt, "aux_have") or cat(nxt, "modal"))
  if not (comma or clause) then return false end
  if S.last - k < 2 then return false end            -- something substantial must remain
  local new = {}
  for i = 1, f - 1 do new[#new + 1] = S.chunks[i] end
  for i = k + 1, #S.chunks do new[#new + 1] = S.chunks[i] end
  for i = f, k do new[#new + 1] = S.chunks[i] end
  local first = new[f]
  if first and first.pre and first.pre:find("comma") then first.pre = nil end
  for i, ch in ipairs(new) do ch.idx = i end
  S.chunks = new
  S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
  S.fronted_temporal = true
  return true
end

---------------------------------------------------------------- indirect questions
-- "what [a quokka] is" -> "what is [a quokka]": the copula that closes (or precedes the participle of) an embedded wh-clause moves in front of the subject
-- noun phrase.  Only the chunk ORDER changes -- chunks keep their unit offsets, so every span, quote and provenance record still points at the original text.
function P.uninvert_embedded(S, k)
  -- wh-phrases whose noun carries no determiner ("which city", "in which city"); "what the capital" is a wh-word + a determined noun phrase, not a wh-phrase
  local cands = {}
  for _, wh in ipairs(P.parse_wh(S, k)) do
    if not (wh.np and (wh.np.det or wh.np.poss_det)) then cands[#cands + 1] = wh end
  end
  -- already in direct order ("which city IS the capital"): nothing to move
  for _, wh in ipairs(cands) do
    local a = C(S, wh.nxt)
    if a and a.single and not a.masked and cat(a, "aux_be") and wh.np and wh.nxt < S.last then return false end   -- a clause-final copula leaves the wh-phrase without a predicate
  end
  table.sort(cands, function(x, y) return x.nxt > y.nxt end)    -- the longest wh-phrase first
  for _, wh in ipairs(cands) do
    local j = wh.nxt
    for b = j + 1, S.last do
      local cb = C(S, b)
      if cb and cb.single and not cb.masked and cat(cb, "aux_be") and not barrier(cb) then
        local ok = false
        for _, np in ipairs(P.parse_np(S, j)) do if np.nxt == b then ok = true end end
        if ok then
          local new = {}
          for i = 1, j - 1 do new[#new + 1] = S.chunks[i] end
          new[#new + 1] = cb
          for i = j, b - 1 do new[#new + 1] = S.chunks[i] end
          for i = b + 1, #S.chunks do new[#new + 1] = S.chunks[i] end
          for i, c in ipairs(new) do c.idx = i end
          S.chunks = new
          S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
          return true
        end
        break   -- only the first copula after the wh-phrase can belong to this clause
      end
    end
  end
  return false
end

---------------------------------------------------------------- wrappers ("Could you tell me ...", "I want ...")
-- returns first core chunk index, wrapper description
function P.strip_wrapper(S)
  local lex, units = S.lex, S.units
  local k = S.first
  local w = { kinds = {}, chunks = {} }
  local function skip_units(n)
    local consumed = 0
    while k <= S.last and consumed < n do
      consumed = consumed + (S.chunks[k].u2 - S.chunks[k].u1 + 1)
      w.chunks[#w.chunks + 1] = k
      k = k + 1
    end
    return consumed == n
  end
  local function cue(name)
    local c = C(S, k)
    if not c then return nil end
    return lex:cue_at(name, units, c.u1)
  end
  local function skip_polite()
    local c = C(S, k)
    while c and c.single and cat(c, "polite") do w.chunks[#w.chunks + 1] = k; k = k + 1; c = C(S, k); w.polite = true end
  end
  -- discourse lead-ins ("Quick question:", "By the way,", "Oh and"): they carry no content for the clause that follows
  do
    local guard = 0
    while guard < 3 do
      guard = guard + 1
      local c0 = C(S, k)
      local n0 = c0 and not c0.masked and lex:cue_at("lead_in", units, c0.u1)
      -- "Going back to X, who ...": a longer topic introducer starting at the same word wins over the shorter lead-in ("going back")
      if n0 then
        local nt = lex:cue_at("topic_intro", units, c0.u1)
        if nt and nt > n0 then n0 = nil end
      end
      -- "Remind me, which ...": a lead-in only when a comma follows; "Remind me what we decided" is a recall request of its own
      if n0 and c0.unit.form == "remind" then
        local after, consumed, kk2 = nil, 0, k
        while C(S, kk2) and consumed < n0 do consumed = consumed + (C(S, kk2).u2 - C(S, kk2).u1 + 1); kk2 = kk2 + 1 end
        after = C(S, kk2)
        if not (after and after.pre and after.pre:find("comma")) then n0 = nil end
      end
      if not (n0 and skip_units(n0)) then break end
      w.lead_in = true       -- not a request wrapper: it must not turn the clause into a wrapper-led request"
    end
    S.first = k
  end
  do
    local first0 = S.first
    local topic = P.take_topic(S)
    if topic then
      for i = first0, S.first - 1 do w.chunks[#w.chunks + 1] = i end
      k = S.first
      w.kinds[#w.kinds + 1] = "topic_frame"
    end
  end
  skip_polite()
  local n = cue("question_polite")
  local progressed = false
  if n then
    local save = k
    if skip_units(n) then
      progressed = true; w.kinds[#w.kinds + 1] = "polite_question"
      skip_polite()
      -- "tell me" / "show me" / "give me" / "help me" after a modal-request
      local c, c2 = C(S, k), C(S, k + 1)
      if c and c.single and c.verbs and (c.verbs[1].act == "inform" or c.verbs[1].act == "retrieve" or c.unit.form == "help") and c2 and c2.single and c2.unit.form == "me" then
        w.chunks[#w.chunks + 1] = k; w.chunks[#w.chunks + 1] = k + 1
        w.verb = c.unit.form
        k = k + 2
        skip_polite()
        -- "help me with X" / "help me find X"
        local c3 = C(S, k)
        if c3 and c3.single and (c3.unit.form == "with" or c3.unit.form == "to") then w.chunks[#w.chunks + 1] = k; k = k + 1 end
      end
      -- bare "can you X" keeps X as an imperative: nothing else to skip
    else k = save end
  end
  local n2 = (not progressed) and cue("request_open") or nil
  if n2 then
    if skip_units(n2) then
      w.kinds[#w.kinds + 1] = "request_open"
      progressed = true
      local c, c2 = C(S, k), C(S, k + 1)
      -- "I want to know X" / "I need to find X" / "I'd like to see X"
      if c and c.single and c.unit.form == "to" and c2 and c2.single and c2.verbs then
        local action = false
        for _, vr in ipairs(c2.verbs) do if vr.act == "constraint" or vr.act == "exclude" or vr.act == "include" then action = true end end
        if action then
          w.chunks[#w.chunks + 1] = k; k = k + 1        -- "I want to USE the 2019 dataset": the verb is the instruction itself
        else
          w.chunks[#w.chunks + 1] = k; w.chunks[#w.chunks + 1] = k + 1
          w.verb = c2.unit.form
          k = k + 2
        end
      end
    end
  end
  if not progressed then skip_polite() end
  -- "Explain what a quokka is." / "Describe who founded X.": an informative imperative directly followed by a wh-word introduces an indirect question
  if not progressed then
    local c, c2 = C(S, k), C(S, k + 1)
    if c and c.single and not c.masked and c.verbs and c.verbs[1] and c.verbs[1].act == "inform" and not cat(c, "wh") then
      local nk = k + 1
      if c2 and c2.single and c2.unit.form == "me" then nk = k + 2 end
      local cw = C(S, nk)
      if cw and cw.single and not cw.masked and cat(cw, "wh") and cw.unit.form ~= "why" and cw.unit.form ~= "how" and not barrier(cw) then
        for i = k, nk - 1 do w.chunks[#w.chunks + 1] = i end
        w.verb = c.unit.form
        w.kinds[#w.kinds + 1] = "embed_imperative"
        k = nk
        progressed = true
      end
    end
  end
  -- indirect question: after a wrapper the clause keeps declarative order ("what a quokka is", "where Acme is headquartered", "what currency Sweden uses")
  if progressed then
    local cw = C(S, k)
    if cw and cw.single and not cw.masked and cat(cw, "wh") then
      S.embedded = true
      P.uninvert_embedded(S, k)
    end
  end
  S.first = k
  P.front_temporal(S)
  P.normalize_cleft(S)
  P.take_polar(S)
  P.front_insitu_wh(S)
  w.first = S.first
  return S.first, w
end

return P
