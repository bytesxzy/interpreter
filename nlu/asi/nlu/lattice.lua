-- asi.nlu.lattice: phrase + entity recognition as a LATTICE of competing spans over the lexer's units.
-- Nothing is committed here: every attested reading of every span is kept, and a k-best dynamic program
-- proposes alternative non-overlapping covers (segmentations) for the semantic stage to compete over.
local U = require("asi.nlu.util")
local UC = require("asi.nlu.unicode")

local Lattice = {}

local NAME_CONNECTORS = U.set({ "of", "de", "van", "von", "der", "la", "le", "du", "di", "da", "del", "for", "the", "&", "den", "al", "bin" })
local TITLE_PREFIX = U.set({ "dr", "mr", "mrs", "ms", "prof", "sir", "lady", "lord", "president", "senator", "gen", "col", "capt", "rev" })

local function span_key(i, j) return i .. ":" .. j end

-- a word the lexicon knows as an ordinary word (function word, verb, adjective, relational/type noun) -- not a name
local function is_common(lex, u)
  local f = u.form
  if lex:cats(f) then return true end
  for _, r in ipairs(lex:readings(f)) do if r.pos == "verb" or r.pos == "adj" then return true end end
  local has_entity, has_word = false, false
  for _, m in ipairs(lex:match_at({ u }, 1)) do
    if m.j == 1 then
      for _, e in ipairs(m.entries) do
        if e.kind == "entity" then has_entity = true else has_word = true end
      end
    end
  end
  return has_word and not has_entity
end

local function joined_forms(units, i, j)
  local t = {}
  for k = i, j do t[#t + 1] = units[k].form end
  return table.concat(t, " ")
end

local function joined_raw(units, i, j)
  local t = {}
  for k = i, j do t[#t + 1] = units[k].raw end
  return table.concat(t, " ")
end

-- does the surface text honour the entry's case sensitivity? (US vs us)
local function cs_ok(units, i, j, entry)
  if not entry.cs then return true end
  local want = entry.name:gsub("%.", ""):gsub("%s+", "")
  local have = joined_raw(units, i, j):gsub("%.", ""):gsub("%s+", "")
  return want == have
end

local function case_exact(units, i, j, entry)
  return joined_raw(units, i, j):gsub("%.", "") == entry.name:gsub("%.", "")
end

---------------------------------------------------------------- build
function Lattice.build(an, lex, opts)
  opts = opts or {}
  local units = an.units
  local n = #units
  local spans, by_ext = {}, {}
  local meter = opts.meter

  local function add(i, j, reading, kind, score)
    local key = span_key(i, j)
    local sp = by_ext[key]
    if not sp then
      sp = { i = i, j = j, readings = {}, kind = kind, score = score, text = an.original:sub(units[i].s, units[j].e) }
      by_ext[key] = sp
      spans[#spans + 1] = sp
    end
    -- one reading per entity id (several names of one entity may match the same extent): keep the best-matching one
    if reading.kind == "entity" then
      for idx, r in ipairs(sp.readings) do
        if r.kind == "entity" and r.entry.id == reading.entry.id and not r.fuzzy == not reading.fuzzy then
          if reading.exact_case and not r.exact_case then sp.readings[idx] = reading end
          return sp
        end
      end
    end
    sp.readings[#sp.readings + 1] = reading
    if score > sp.score then sp.score = score; sp.kind = kind end
    return sp
  end

  -- 1. attested spans from the phrase trie (core lexicon + dataset overlay)
  for i = 1, n do
    if meter and not meter:tick("lattice_match", 1) then break end
    for _, m in ipairs(lex:match_at(units, i)) do
      local len = m.j - i + 1
      for _, e in ipairs(m.entries) do
        if e.kind == "entity" then
          if cs_ok(units, i, m.j, e) then
            local exact = case_exact(units, i, m.j, e)
            add(i, m.j, { kind = "entity", entry = e, exact_case = exact }, "entity", 2.0 + 0.5 * (len - 1) + (exact and 0.2 or 0))
          end
        elseif e.kind == "sense" then
          local sc = (len > 1) and (1.8 + 0.5 * (len - 1)) or 0.4
          local sp = add(i, m.j, { kind = "sense", sense = e.sense, num = e.num }, len > 1 and "mwe" or "word_sense", sc)
        elseif e.kind == "relnoun" then
          add(i, m.j, { kind = "relnoun", entry = e }, len > 1 and "mwe" or "word_sense", (len > 1) and (1.6 + 0.4 * (len - 1)) or 0.6)
        elseif e.kind == "relverb" then
          add(i, m.j, { kind = "relverb", entry = e }, len > 1 and "mwe" or "word_sense", (len > 1) and (1.6 + 0.4 * (len - 1)) or 0.5)
        end
      end
    end
  end

  -- 2. temporal expressions and numbers (typed spans keep dates from being split into words)
  for _, t in ipairs(an.temporal or {}) do
    if t.u1 and t.u2 and t.kind ~= "weekday" then
      add(t.u1, t.u2, { kind = "temporal", expr = t }, "temporal", 1.0 + 0.3 * (t.u2 - t.u1))
    end
  end
  for _, nm in ipairs(an.numbers or {}) do
    if nm.kind ~= "digit" or nm.u2 > nm.u1 then
      add(nm.u1, nm.u2, { kind = "number", num = nm }, "number", 0.9 + 0.2 * (nm.u2 - nm.u1))
    end
  end

  -- 3. atomic literals: identifiers, URLs, paths, handles, versions
  for i = 1, n do
    local u = units[i]
    if u.case_sensitive and not u.hy then
      add(i, i, { kind = "literal", unit = u }, "literal", 1.5)
    end
  end

  -- 4. quoted strings (titles, exact phrases)
  do
    local toks = an.tokens
    local tok2unit = {}
    for ui, u in ipairs(units) do tok2unit[u.tok] = tok2unit[u.tok] or ui end
    local k = 1
    while k <= #toks do
      local t = toks[k]
      if t.kind == "punct" and (t.role == "open_quote" or t.role == "quote") and not t.single then
        local close
        for z = k + 1, math.min(#toks, k + 14) do
          local c = toks[z]
          if c.kind == "punct" and (c.role == "close_quote" or c.role == "quote") and not c.single then close = z break end
          if c.kind == "punct" and c.role == "sent_end" then break end
        end
        if close and close > k + 1 then
          local a, b
          for z = k + 1, close - 1 do
            if tok2unit[toks[z].i] then a = a or tok2unit[toks[z].i]; b = tok2unit[toks[z].i] end
          end
          if a and b then
            local ub = b
            while units[ub + 1] and units[ub + 1].tok == units[b].tok do ub = ub + 1 end
            add(a, ub, { kind = "quote", text = an.original:sub(units[a].s, units[ub].e) }, "quote", 1.4 + 0.1 * (ub - a))
          end
          k = close
        end
      end
      k = k + 1
    end
  end

  -- 5. unseen proper names (open-set): capitalised runs typed by head words
  local function sentence_initial(u) return u.i == 1 or units[u.i - 1].sent ~= u.sent end
  local i = 1
  while i <= n do
    local u = units[i]
    local sent = an.sentences[u.sent or 0]
    local shout = sent and sent.shout
    local capital = u.cap and not shout and (u.kind == "word" or u.kind == "abbrev" or u.kind == "acronym" or u.kind == "initial") and not u.case_sensitive
    local initial = capital and sentence_initial(u)
    local common = capital and is_common(lex, u)
    -- "Compare", "Did", "Is" ... are capitalised only by position: they must not swallow the names that follow them
    if capital and not (initial and common) then
      local j = i
      -- connectors ("of", "for", ...) join a name only after an organisation/place head word ("University of X", "Bank of X"),
      -- never after an ordinary common word ("CEO of Acme": CEO is a relational noun, not the start of a name)
      local connect_ok = lex:headcue(u.form) ~= nil or not common
      -- extend over capitalised units and name connectors (never "and")
      while true do
        local nx = units[j + 1]
        if not nx or nx.pre or nx.sent ~= u.sent then break end
        if nx.cap and not shout and (nx.kind == "word" or nx.kind == "abbrev" or nx.kind == "acronym" or nx.kind == "initial" or nx.kind == "number") then j = j + 1
        elseif NAME_CONNECTORS[nx.form] and not nx.cap and connect_ok then
          local nn = units[j + 2]
          if nn and not nn.pre and nn.cap and nn.sent == u.sent then j = j + 2 else break end
        else break end
      end
      local multi = j > i
      local last = units[j]
      local type_guess = lex:headcue(last.form) or lex:headcue(u.form) or (TITLE_PREFIX[u.form] and "person") or nil
      local sc = 0.8 + 0.3 * (j - i)
      local ok = true
      if initial and not multi and not type_guess and not u.hy then
        -- sentence-initial single unknown word: weak name guess only if the lexicon has never seen the word
        if is_common(lex, u) then ok = false else sc = 0.45 end
      end
      if common and not multi and not initial and u.form ~= "i" then
        -- a known common word capitalised mid-sentence ("Apple" is handled by the gazetteer; "Is" after a colon is not a name)
        sc = 0.55
      end
      if u.form == "i" then ok = false end
      if ok then
        -- capitalisation is the ONLY evidence for a sentence-initial single word: flagged so memory does not treat it as an established entity
        local weak = (initial and not multi and not type_guess) or nil
        add(i, j, { kind = "name", type_guess = type_guess, text = an.original:sub(units[i].s, units[j].e), multiword = multi, weak = weak,
          head_cue = (lex:headcue(last.form) or lex:headcue(u.form)) and true or nil }, "name_guess", sc)
      end
      i = j + 1
    else
      i = i + 1
    end
  end

  -- 6. fuzzy readings for UNKNOWN words (typos): proposals only, flagged and down-weighted. Known words are never reinterpreted.
  --    4-letter words are too short to trust. Entities need a capitalised surface (or a strong match); relation words / senses any case.
  for ui, u in ipairs(units) do
    if u.alts and #u.alts > 0 and #u.form >= 5 then
      for _, a in ipairs(u.alts) do
        if a.conf >= 0.45 then
          local fake = { { form = a.form } }
          for _, m in ipairs(lex:match_at(fake, 1)) do
            for _, e in ipairs(m.entries) do
              -- a fuzzy span ties with a plain word in the cover search (0.1): the literal reading is never displaced by a guess;
              -- hypotheses decide, and a fuzzy lexeme earns no attestation credit and pays a penalty
              if e.kind == "entity" and not e.cs and a.kind == "entity" and (u.cap or a.conf >= 0.7) then
                add(ui, ui, { kind = "entity", entry = e, fuzzy = a.conf, fuzzy_from = u.raw, fuzzy_to = a.form }, "entity", 0.1)
              elseif e.kind == "relnoun" or e.kind == "relverb" then
                local ec = U.shallow(e); ec.fuzzy = a.conf
                add(ui, ui, { kind = e.kind, entry = ec, fuzzy = a.conf, fuzzy_from = u.raw }, "word_sense", 0.1)
              elseif e.kind == "sense" and not u.cap then
                add(ui, ui, { kind = "sense", sense = e.sense, num = e.num, fuzzy = a.conf, fuzzy_from = u.raw }, "word_sense", 0.1)
              end
            end
          end
        end
      end
    end
  end

  -- 7. compositional kind readings: an attested multiword concept "<kind> <relational noun>" ("financial capital") is ALSO read
  --    as the relation with a kind modifier, so the relation reading is not lost to the lexicalised concept.
  for _, sp in ipairs(spans) do
    if sp.j > sp.i then
      local last = by_ext[span_key(sp.j, sp.j)]
      if last then
        local prefix = joined_forms(units, sp.i, sp.j - 1)
        for _, r in ipairs(last.readings) do
          if r.kind == "relnoun" then
            local rel = lex:get_rel(r.entry.rel)
            if rel and rel.kinds and rel.kinds[prefix] then
              local ec = U.shallow(r.entry); ec.kind_prefix = prefix
              add(sp.i, sp.j, { kind = "relnoun", entry = ec }, sp.kind, sp.score)
            end
          end
        end
      end
    end
  end

  -- index
  local by_start = {}
  for _, sp in ipairs(spans) do
    by_start[sp.i] = by_start[sp.i] or {}
    table.insert(by_start[sp.i], sp)
  end
  for _, list in pairs(by_start) do table.sort(list, function(a, b) return (a.j - a.i) > (b.j - b.i) end) end

  local lat = { an = an, units = units, spans = spans, by_start = by_start, n = n }

  -- k-best covers: choose non-overlapping spans maximising total score; unit not in a span costs a small word score
  -- covers(k [, a, b]): k-best covers of unit range [a, b] (default: everything); spans must lie inside the range
  function lat:covers(k, a, b)
    k = k or 4
    a, b = a or 1, b or n
    local W = 0.1
    -- best[p] = list of {score, span|nil, next_rank} for suffix starting at p, size <= k
    local best = { [b + 1] = { { score = 0 } } }
    for p = b, a, -1 do
      local cand = {}
      for rank, bb in ipairs(best[p + 1]) do cand[#cand + 1] = { score = bb.score + W, span = nil, nxt = p + 1, rank = rank } end
      for _, sp in ipairs(by_start[p] or {}) do
        if sp.j <= b then
          for rank, bb in ipairs(best[sp.j + 1]) do
            cand[#cand + 1] = { score = bb.score + sp.score, span = sp, nxt = sp.j + 1, rank = rank }
          end
        end
      end
      table.sort(cand, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        local la = a.span and (a.span.j - a.span.i) or -1
        local lb = b.span and (b.span.j - b.span.i) or -1
        return la > lb
      end)
      -- k-best with distinct extents so alternatives are real segmentations, not duplicates
      local keep, seen = {}, {}
      for _, c in ipairs(cand) do
        local sig = (c.span and (c.span.j .. "") or "w") .. ":" .. c.nxt .. ":" .. c.rank
        if not seen[sig] then seen[sig] = true; keep[#keep + 1] = c end
        if #keep >= k then break end
      end
      best[p] = keep
    end
    local out = {}
    for rank = 1, #best[a] do
      local chosen, p, r = {}, a, rank
      local total = best[a][rank].score
      while p <= b do
        local c = best[p][r]
        chosen[#chosen + 1] = c.span or { i = p, j = p, kind = "word", readings = {}, score = W, text = an.original:sub(units[p].s, units[p].e) }
        p, r = c.nxt, c.rank
      end
      out[#out + 1] = { score = total, spans = chosen }
    end
    -- drop covers identical in extents to an earlier one
    local uniq, seen = {}, {}
    for _, c in ipairs(out) do
      local sig = {}
      for _, sp in ipairs(c.spans) do sig[#sig + 1] = sp.i .. "-" .. sp.j .. sp.kind end
      sig = table.concat(sig, ",")
      if not seen[sig] then seen[sig] = true; uniq[#uniq + 1] = c end
    end
    return uniq
  end

  -- segmentation confidence: margin between the best and runner-up cover (raw, uncalibrated)
  function lat:segmentation_margin()
    local cv = self:covers(2)
    if #cv < 2 then return 1.0, cv end
    local a, b = cv[1].score, cv[2].score
    return U.clamp((a - b) / math.max(a, 1e-6), 0, 1), cv
  end

  if meter then meter:tick("lattice_spans", #spans) end
  return lat
end

return Lattice
