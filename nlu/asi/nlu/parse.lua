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

function P.make_chunks(S, cover)
  local lex, units = S.lex, S.units
  local chunks = {}
  for i, sp in ipairs(cover.spans) do
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
    for _, r in ipairs(sp.readings) do
      if r.fuzzy then c.fuzzy = math.max(c.fuzzy or 0, r.fuzzy); c.fuzzy_from = r.fuzzy_from end
      if r.kind == "entity" then c.entities[#c.entities + 1] = r
      elseif r.kind == "name" then c.names[#c.names + 1] = r
      elseif r.kind == "sense" then c.senses[#c.senses + 1] = r
      elseif r.kind == "relnoun" then c.relnouns[#c.relnouns + 1] = r.entry
      elseif r.kind == "relverb" then c.relverbs[#c.relverbs + 1] = r.entry
      elseif r.kind == "temporal" then c.temporal = r.expr
      elseif r.kind == "number" then c.number = r.num
      elseif r.kind == "literal" then c.literal = r.unit
      elseif r.kind == "quote" then c.quote = r.text end
    end
    chunks[i] = c
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
  if #out == 0 and c.single and c.kind == "word" and not next(c.cats) and #c.senses == 0 and #c.entities == 0 and #c.relnouns == 0 then
    for _, g in ipairs(Morph.guess(c.unit.form)) do if g.pos == "verb" then add(g.lemma, g.feat, nil, nil, true) end end
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
  if c.cap then
    local prev = S.units[c.u1 - 1]
    local sentence_initial = (c.u1 == 1) or (prev and prev.sent ~= c.unit.sent)
    local sent = S.an.sentences[c.unit.sent or 0]
    if not sentence_initial and not (sent and sent.shout) then return false end
  end
  return true
end

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
      while C(S, q) and C(S, q).single and not barrier(C(S, q)) and (cat(C(S, q), "aux_be") or cat(C(S, q), "aux_have")) do q = q + 1 end
      local vc = C(S, q)
      if vc and vc.single and not barrier(vc) then
        for _, a in ipairs(P.verb_analyses(S, vc)) do
          if a.form == "past" or a.form == "pp" or a.form == "ing" then j = q + 1 break end
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
  while C(S, j) and C(S, j).single and not barrier(C(S, j)) and S.lex:cue_at("backref_adv", S.units, C(S, j).u1) do j = j + 1 end
  return j, who
end
P.backref_at = backref_at

local parse_np

-- core NP (no possessor): [det|poss] modifiers* head [of-complement] [back-reference]
local function parse_np_core(S, k, opts)
  local out = {}
  local c = C(S, k)
  if not c or c.masked then return out end
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
    local nc = nclass(S, cm, (m > j) or det ~= nil or poss_det ~= nil)
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
      if SUPERLATIVE_FORMS[mc.form] or (mc.single and mc.unit.form:find("est$") and (mc.adjs or S.lex:adj_reading(mc.unit.form:gsub("est$", "")))) then
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
      if head.cl.from_verb then np.score = np.score - 0.15; np.from_verb = true end
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
    if nx and nx.single and nx.unit.form == "of" and not nx.masked and not barrier(nx) and not opts.no_of then
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
        end
      end
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
    end
  end
  return final
end

-- NP with optional possessor:  NP 's NP   (France's capital)  and  entity+relnoun compounds are handled in frames
function parse_np(S, k, opts)
  opts = opts or {}
  local key = k .. (opts.no_of and "n" or "") .. ":" .. (opts.depth or 0)
  local memo = S.np_memo[key]
  if memo then return memo end
  S.np_memo[key] = {} -- recursion guard
  local out = {}
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
        end
      end
    end
  end
  for _, a in ipairs(parse_np_core(S, k, opts)) do out[#out + 1] = a end
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
  if cat(c, "aux_be") then return "be" end
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
  local key = "v" .. k .. (opts.aux_hint or "") .. (opts.require_aux and "r" or "") .. (opts.participle_ok and "p" or "")
  if S.vp_memo[key] then return S.vp_memo[key] end
  local out = {}
  local j = k
  local aux = {}
  local neg, neg_chunk = false, nil
  local advs = {}
  local tscope
  while true do
    local c = C(S, j)
    if not c or c.masked or (j > k and barrier(c)) then break end
    local ak = aux_kind(c)
    if ak and not (cat(c, "clitic_s") and false) then
      -- the verb itself may be an aux-form (is/does/has): only treat as aux if another verb follows
      aux[#aux + 1] = { kind = ak, form = c.unit.form, chunk = c }
      j = j + 1
    elseif P.is_neg(c) then neg, neg_chunk = true, c; j = j + 1
    elseif c.single and cat(c, "adv") and not P.is_neg(c) then advs[#advs + 1] = c; j = j + 1
    elseif c.temporal and (c.temporal.kind == "marker" or c.temporal.kind == "relative") and c.temporal.scope then
      tscope = c.temporal.scope; advs[#advs + 1] = c; j = j + 1
    else break end
  end
  local vc = C(S, j)
  if vc and not vc.masked and not (j > k and barrier(vc)) then
    local ana = P.verb_analyses(S, vc)
    if #ana > 0 then
      local last_aux = (aux[#aux] and aux[#aux].kind) or opts.aux_hint
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

function P.parse_wh(S, k)
  local key = "w" .. k
  if S.wh_memo[key] then return S.wh_memo[key] end
  local out = {}
  local c = C(S, k)
  if c and c.single and cat(c, "wh") and not c.masked then
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
      elseif n1 and n1.single and n1.adjs and n1.adjs[1] then
        out[#out + 1] = { wh = "how_adj", adj = n1.unit.form, dim = n1.adjs[1].dim, nxt = k + 2, c1 = k, c2 = k + 1, u1 = c.u1, u2 = n1.u2 }
      elseif n1 and n1.single and (n1.unit.form == "often" or n1.unit.form == "far" or n1.unit.form == "long") then
        out[#out + 1] = { wh = "how_adj", adj = n1.unit.form, nxt = k + 2, c1 = k, c2 = k + 1, u1 = c.u1, u2 = n1.u2 }
      end
      out[#out + 1] = { wh = "how", adverbial = true, nxt = k + 1, c1 = k, c2 = k, u1 = c.u1, u2 = c.u2 }
    end
  end
  S.wh_memo[key] = out
  return out
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
        w.chunks[#w.chunks + 1] = k; w.chunks[#w.chunks + 1] = k + 1
        w.verb = c2.unit.form
        k = k + 2
      end
    end
  end
  if not progressed then skip_polite() end
  w.first = k
  S.first = k
  return k, w
end

return P
