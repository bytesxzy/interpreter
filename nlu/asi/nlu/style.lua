-- asi.nlu.style: how a piece of text SOUNDS.  Deterministic, no model, no word list of "example sentences".
--   Style.measure(text)            surface and lexical features of a sample (caps, exclamations, emoji, ellipses, sentence length, interjections, ...)
--   Style.describe(features)       descriptors that the MEASURED features support, each with a strength and the evidence it rests on
--   Style.declared(text)           descriptors a text DECLARES in words ("over-dramatic", "never uses caps"), negation aware, with the matching words
--   Style.merge(declared, measured) one ranked descriptor list: source = declared | measured | both, plus conflicts (declared "calm", measured SHOUTING)
--   Style.render(sentence, target) a neutral sentence in the target style (typography, interjection, emoji only: content words are never touched)
--   Style.announce(persona)        the one-paragraph statement of the tone that will be used (built from the profile, never invented)
-- The descriptor taxonomy and every marker list live in asi.nlu.data.style_lex (data, not code).  Thresholds below are DESCRIPTIVE cut-offs with the
-- feature they read named in the evidence; they are not probabilities and are never reported as such.
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local L = require("asi.nlu.data.style_lex")

local Style = {}
Style.LEX = L

---------------------------------------------------------------- phrase matching over lower-case word lists
local function norm_phrase(p) return (p:lower():gsub("[%-_]", " "):gsub("%s+", " ")) end

-- list of phrases -> { [first word] = { {w1, w2, ...}, ... } } (longest first)
local function phrase_index(list)
  local idx = {}
  for _, p in ipairs(list) do
    local ws = {}
    for w in norm_phrase(p):gmatch("[^%s]+") do ws[#ws + 1] = w end
    if #ws > 0 then
      local l = idx[ws[1]]
      if not l then l = {}; idx[ws[1]] = l end
      l[#l + 1] = ws
    end
  end
  for _, l in pairs(idx) do table.sort(l, function(a, b) return #a > #b end) end
  return idx
end

-- the phrase of idx that starts at words[i] (longest), or nil; returns length in words
local function match_at(idx, words, i)
  local l = idx[words[i]]
  if not l then return nil end
  for _, ph in ipairs(l) do
    local ok = true
    for k = 2, #ph do if words[i + k - 1] ~= ph[k] then ok = false break end end
    if ok then return #ph, ph end
  end
end

local function count_hits(idx, words)
  local n, distinct, i = 0, {}, 1
  while i <= #words do
    local len, ph = match_at(idx, words, i)
    if len then n = n + 1; distinct[table.concat(ph, " ")] = true; i = i + len else i = i + 1 end
  end
  local d = 0
  for _ in pairs(distinct) do d = d + 1 end
  return n, d
end

local INDEX = {}      -- built lazily, once per process
local function idx(name, list)
  local x = INDEX[name]
  if not x then x = phrase_index(list); INDEX[name] = x end
  return x
end
Style.phrase_index, Style.match_at = phrase_index, match_at

-- acronyms are capitalised without shouting
local ACRONYMS = U.set({ "ai", "uk", "us", "usa", "eu", "un", "tv", "pc", "ok", "id", "ceo", "cfo", "cto", "coo", "faq", "pdf", "url", "api", "gdp", "nasa", "fbi", "cia", "nato",
  "nba", "nfl", "usd", "eur", "gbp", "dna", "rna", "hiv", "ufo", "vip", "diy", "asap", "fyi", "gpu", "cpu", "os", "ui", "ux", "html", "css", "sql", "json", "xml", "http", "https",
  "www", "ssh", "vpn", "ram", "rom", "usb", "wifi", "sms", "gps", "atm", "dvd", "cd", "pin", "iq", "eq", "md", "phd", "mba", "hr", "pr", "qa", "kpi", "roi", "ngo", "llm", "ml",
  "ip", "it", "pm", "am", "bc", "ad", "ii", "iii", "iv", "vi", "vii", "viii", "ix", "mr", "mrs", "dr", "st", "mt", "inc", "ltd", "llc", "plc", "gmbh", "ag", "sa" })

---------------------------------------------------------------- measurement
local function words_of(an)
  local ws, caps = {}, {}
  for _, t in ipairs(an.tokens) do
    if (t.kind == "word" or t.kind == "acronym" or t.kind == "abbrev" or t.kind == "initial") and (t.letters or 0) >= 1 then
      local w = (t.lower or ""):gsub("[%.]", "")
      ws[#ws + 1] = w
      caps[#caps + 1] = t
    end
  end
  return ws, caps
end

local EMOTICONS = { ":%)", ":%-%)", ":%(", ":%-%(", ";%)", ";%-%)", ":D", ":%-D", "xD", "XD", ":P", ":p", ":%-P", ":3", "<3", "%^_%^", ">_<", "T_T", ";_;", "o_o", "O_O", "%^%^", ":'%(", ":o", ":O" }
local function count_emoticons(text)
  local n = 0
  for _, pat in ipairs(EMOTICONS) do
    for _ in text:gmatch(pat) do n = n + 1 end
  end
  return n
end

function Style.measure(text, opts)
  opts = opts or {}
  local f = { n_chars = #text, n_words = 0, n_sentences = 0 }
  if type(text) ~= "string" or text == "" or not utf8.len(text) then return f end
  local an = Lex.analyze(text, { max_bytes = opts.max_bytes or 200000 })
  if an.status == "rejected" then return f end
  local ws, toks = words_of(an)
  local nw = #ws
  f.n_words = nw
  local sents = an.sentences
  local ns = math.max(#sents, nw > 0 and 1 or 0)
  f.n_sentences = ns
  if nw == 0 then return f end
  -- capitals: acronyms and the pronoun "I" are not shouting
  local cased, up, cased_all, up_all = 0, 0, 0, 0
  local elong, contr, repeated, lower_only_letters, any_upper = 0, 0, 0, true, false
  local wlen = 0
  for i, t in ipairs(toks) do
    local w = ws[i]
    wlen = wlen + (t.letters or #w)
    if (t.letters or 0) >= 2 then
      cased_all = cased_all + 1
      if t.allcaps then up_all = up_all + 1 end
      if not ACRONYMS[w] then
        cased = cased + 1
        if t.allcaps then up = up + 1 end
      end
    end
    if (t.letters or 0) >= 1 and (t.cap and not (t.letters == 1 and w == "i")) then any_upper = true end
    if w:find("(%a)%1%1") then elong = elong + 1 end
    if (t.text or ""):find("%a['’]%a") then contr = contr + 1 end
    if i > 1 and ws[i - 1] == w and #w >= 2 then repeated = repeated + 1 end
  end
  f.caps_words, f.cased_words = up, cased
  f.caps_ratio = cased > 0 and up / cased or 0
  f.caps_ratio_all = cased_all > 0 and up_all / cased_all or 0
  f.elongated_words = elong
  f.elongated_ratio = elong / nw
  f.contraction_ratio = contr / nw
  f.repeated_word_ratio = repeated / nw
  f.avg_word_len = wlen / nw
  f.no_upper = not any_upper
  -- sentences: terminal punctuation, length
  local excl, excl_sent, excl_multi, quest, ell, short, first_interj = 0, 0, 0, 0, 0, 0, 0
  local longest, lower_start = 0, 0
  local interj = idx("interj", L.interjections)
  for _, s in ipairs(sents) do
    local term = s.terminal or ""
    local ne = select(2, term:gsub("!", ""))
    if ne > 0 then excl = excl + ne; excl_sent = excl_sent + 1 end
    if ne >= 2 or term:find("%?!") or term:find("!%?") then excl_multi = excl_multi + 1 end
    if term:find("%?") then quest = quest + 1 end
    if term:find("%.%.") or term:find("…") then ell = ell + 1 end
    -- words of the sentence
    local sw, first_alpha = 0, nil
    for z = s.first_tok, s.last_tok do
      local t = an.tokens[z]
      if (t.kind == "word" or t.kind == "acronym" or t.kind == "abbrev") and (t.letters or 0) >= 1 then
        sw = sw + 1
        if sw == 1 then
          first_alpha = t
          if match_at(interj, { (t.lower or ""):gsub("%.", "") }, 1) then first_interj = first_interj + 1 end
        end
      end
    end
    if sw <= 3 and sw > 0 then short = short + 1 end
    if sw > longest then longest = sw end
    if first_alpha and not first_alpha.cap then lower_start = lower_start + 1 end
  end
  f.exclamations = excl
  f.excl_per_sentence = excl / ns
  f.excl_ratio = excl_sent / ns
  f.excl_multi_ratio = excl_multi / ns
  f.question_ratio = quest / ns
  f.ellipses = ell
  f.ellipsis_ratio = ell / ns
  f.short_sentence_ratio = short / ns
  f.avg_sentence_words = nw / ns
  f.max_sentence_words = longest
  f.lower_start_ratio = lower_start / ns
  f.init_interjection_ratio = first_interj / ns
  -- emoji and emoticons
  local emoji = 0
  for _, t in ipairs(an.tokens) do if t.kind == "emoji" then emoji = emoji + math.max(1, utf8.len(t.text) or 1) end end
  emoji = emoji + count_emoticons(text)
  f.emoji = emoji
  f.emoji_per_100w = emoji * 100 / nw
  -- lexical markers per 100 words
  local function rate(name, list) local n, d = count_hits(idx(name, list), ws); return n * 100 / nw, n, d end
  f.interjection_rate, f.interjections = rate("interj", L.interjections)
  f.intensifier_rate = rate("intens", L.intensifiers)
  f.hyperbole_rate, f.hyperbole = rate("hyper", L.hyperbole)
  f.positive_rate = rate("pos", L.positive)
  f.formal_rate = rate("formal", L.formal_markers)
  f.informal_rate, f.informal_hits, f.informal_distinct = rate("informal", L.informal_markers)
  f.polite_rate = rate("polite", L.polite_markers)
  f.hedge_rate = rate("hedge", L.hedges)
  local second, first = 0, 0
  for _, w in ipairs(ws) do
    if w == "you" or w == "your" or w == "yours" or w == "you're" or w == "youre" then second = second + 1 end
    if w == "i" or w == "me" or w == "my" or w == "i'm" or w == "im" or w == "mine" or w == "myself" then first = first + 1 end
  end
  f.second_person_rate, f.first_person_rate = second * 100 / nw, first * 100 / nw
  -- character voices recognised from their own markers
  f.voices = {}
  for voice, list in pairs(L.voice_markers) do
    local r, n, d = rate("voice_" .. voice, list)
    f.voices[voice] = { rate = r, hits = n, distinct = d }
  end
  return f
end

-- does a short text read like something somebody SAYS in a voice (loud, exclamatory, emoji, interjections, first / second person, questions, trailing off, a quotation)?
-- a descriptive cut-off on the measured form, used to decide which text under "talks like this:" is the sample
function Style.utterance_like(text)
  local f = Style.measure(text)
  if (f.n_words or 0) == 0 or f.n_words > 90 then return false end
  if text:find('^%s*["“«]') then return true end
  return f.caps_ratio >= 0.3 or f.excl_per_sentence >= 0.5 or f.emoji >= 1 or f.interjection_rate >= 5 or f.first_person_rate >= 6 or f.second_person_rate >= 6
    or f.question_ratio >= 0.5 or f.ellipsis_ratio >= 0.3
end

---------------------------------------------------------------- descriptors supported by measured features
local function sat(x, lo, hi) if hi == lo then return x >= hi and 1 or 0 end local v = (x - lo) / (hi - lo); return v < 0 and 0 or (v > 1 and 1 or v) end
local function fmt(x) return string.format("%.2f", x) end

-- returns a list of { id, strength (0..1), evidence (string), source = "measured" } sorted by strength
function Style.describe(f)
  local out = {}
  if not f or (f.n_words or 0) == 0 then return out end
  local function add(id, strength, evidence) out[#out + 1] = { id = id, strength = U.round(strength, 3), evidence = evidence, source = "measured" } end
  local nw, ns = f.n_words, f.n_sentences
  if f.cased_words >= 1 and f.caps_ratio >= 0.5 and (f.cased_words >= 2 or nw <= 3) then
    add("all_caps", sat(f.caps_ratio, 0.4, 1.0), string.format("%d of %d cased words are ALL-CAPS (%s)", f.caps_words, f.cased_words, fmt(f.caps_ratio)))
  elseif f.caps_words >= 1 and f.caps_ratio >= 0.04 then
    add("caps_emphasis", sat(f.caps_ratio, 0.03, 0.4), string.format("%d ALL-CAPS word(s) among %d cased words", f.caps_words, f.cased_words))
  end
  if f.no_upper and nw >= 4 then add("lowercase", 1, "no capital letters in " .. nw .. " words") end
  if f.excl_per_sentence >= 0.7 or (f.excl_ratio >= 0.5 and ns >= 2) then
    add("exclamatory", sat(f.excl_per_sentence, 0.5, 2.0), string.format("%s exclamation marks per sentence (%d in %d sentences)", fmt(f.excl_per_sentence), f.exclamations, ns))
  end
  if f.emoji >= 1 and (f.emoji_per_100w >= 2 or nw <= 30) then add("emoji", sat(f.emoji_per_100w, 1, 8), string.format("%d emoji/emoticons (%s per 100 words)", f.emoji, fmt(f.emoji_per_100w))) end
  if f.ellipses >= 2 and f.ellipsis_ratio >= 0.3 then add("ellipsis", sat(f.ellipsis_ratio, 0.2, 0.8), string.format("%d of %d sentences trail off with an ellipsis", f.ellipses, ns)) end
  if f.elongated_words >= 1 and f.elongated_ratio >= 0.04 then add("elongation", sat(f.elongated_ratio, 0.03, 0.2), string.format("%d stretched word(s) (%s of the words)", f.elongated_words, fmt(f.elongated_ratio))) end
  -- dramatic: the theatrical signals together
  local sig, why = 0, {}
  local function signal(ok, label) if ok then sig = sig + 1; why[#why + 1] = label end end
  signal(f.caps_ratio >= 0.5 and f.cased_words >= 2, "ALL-CAPS")
  signal(f.excl_multi_ratio >= 0.4 or f.excl_per_sentence >= 1.5, "stacked exclamation marks")
  signal(f.interjection_rate >= 6 or f.init_interjection_ratio >= 0.25, "interjections")
  signal(f.hyperbole_rate >= 3 or f.intensifier_rate >= 4, "hyperbole / intensifiers")
  signal(f.short_sentence_ratio >= 0.5 and ns >= 3, "staccato one-word sentences")
  signal(f.elongated_ratio >= 0.05 and f.elongated_words >= 1, "stretched words")
  signal(f.repeated_word_ratio >= 0.03, "repeated words")
  signal(f.ellipsis_ratio >= 0.3 and f.ellipses >= 2, "dramatic pauses")
  if sig >= 3 then add("dramatic", sig / 6 > 1 and 1 or sig / 6, sig .. " theatrical signals: " .. table.concat(why, ", ")) end
  -- enthusiastic: positive energy
  if f.positive_rate >= 3 and (f.excl_per_sentence >= 0.5 or f.emoji >= 1) then
    add("enthusiastic", sat(f.positive_rate, 2, 10), string.format("%s positive words per 100 words with %s exclamation marks per sentence", fmt(f.positive_rate), fmt(f.excl_per_sentence)))
  end
  -- register: a handful of words says nothing about formality or length (the descriptors below need a sample of some size)
  local drama = sig >= 3
  if nw < 20 then
    table.sort(out, function(a, b) if a.strength ~= b.strength then return a.strength > b.strength end return a.id < b.id end)
    -- voices with their own markers still count in a short sample
    for voice, v in pairs(f.voices or {}) do
      if v.distinct >= 2 or (v.rate >= 3 and v.hits >= 2) then add(voice, sat(v.rate, 1, 8), string.format("%d %s marker(s), %d distinct", v.hits, voice, v.distinct)) end
    end
    table.sort(out, function(a, b) if a.strength ~= b.strength then return a.strength > b.strength end return a.id < b.id end)
    return out
  end
  if f.avg_sentence_words <= 6 and f.short_sentence_ratio >= 0.6 and ns >= 2 and not drama and f.caps_ratio < 0.5 then
    add("terse", sat(7 - f.avg_sentence_words, 0, 4), string.format("average %s words per sentence", fmt(f.avg_sentence_words)))
  end
  if f.avg_sentence_words >= 24 and ns >= 2 then add("verbose", sat(f.avg_sentence_words, 20, 40), string.format("average %s words per sentence", fmt(f.avg_sentence_words))) end
  if (f.formal_rate >= 2 and f.informal_rate < 1) or (nw >= 25 and f.contraction_ratio == 0 and f.informal_rate == 0 and f.avg_sentence_words >= 12 and f.excl_per_sentence < 0.3
    and f.caps_ratio < 0.2 and f.interjection_rate < 1) then
    add("formal", f.formal_rate >= 2 and sat(f.formal_rate, 1, 6) or 0.4, string.format("%s formal markers per 100 words, %s contractions per word", fmt(f.formal_rate), fmt(f.contraction_ratio)))
  end
  if (f.informal_rate >= 2 and (f.informal_distinct or 0) >= 2 and not drama) or (f.contraction_ratio >= 0.06 and f.formal_rate < 1 and not drama) then
    add("casual", math.max(sat(f.informal_rate, 1, 6), sat(f.contraction_ratio, 0.05, 0.2)), string.format("%s informal markers per 100 words, %s contractions per word", fmt(f.informal_rate), fmt(f.contraction_ratio)))
  end
  if f.polite_rate >= 2 then add("polite", sat(f.polite_rate, 1, 6), string.format("%s politeness markers per 100 words", fmt(f.polite_rate))) end
  -- voices with their own markers
  for voice, v in pairs(f.voices or {}) do
    if v.distinct >= 2 then
      add(voice, sat(v.rate, 1, 8), string.format("%d %s marker(s), %d distinct", v.hits, voice, v.distinct))
    end
  end
  table.sort(out, function(a, b) if a.strength ~= b.strength then return a.strength > b.strength end return a.id < b.id end)
  return out
end

---------------------------------------------------------------- declared descriptors
local function clause_words(text)
  -- lower-case words with the clause they belong to (punctuation . ! ? ; : - ends a clause for negation scope; commas do not)
  local ws, cl, c, pos = {}, {}, 1, 1
  local t = text:lower():gsub("[%-_]", " ")
  local i = 1
  while i <= #t do
    local ch = t:sub(i, i)
    if ch:match("[%a]") then
      local j = i
      while j + 1 <= #t and t:sub(j + 1, j + 1):match("[%a'’]") do j = j + 1 end
      ws[#ws + 1] = (t:sub(i, j):gsub("’", "'"))
      cl[#cl + 1] = c
      i = j + 1
    else
      if ch:match("[%.!%?;:]") then c = c + 1 end
      i = i + 1
    end
  end
  return ws, cl
end

local DECL_INDEX
local function declared_index()
  if DECL_INDEX then return DECL_INDEX end
  local idxs = {}
  local phrases, owner = {}, {}
  for id, d in pairs(L.descriptors) do
    for _, p in ipairs(d.declared or {}) do phrases[#phrases + 1] = p; owner[norm_phrase(p)] = id end
  end
  DECL_INDEX = { idx = phrase_index(phrases), owner = owner, neg = phrase_index(L.negators) }
  return DECL_INDEX
end

-- the declared descriptor that starts at words[i] (lower-case words): returns length, id, term
function Style.declared_match(words, i)
  local D = declared_index()
  local len, ph = match_at(D.idx, words, i)
  if len then local term = table.concat(ph, " "); return len, D.owner[term], term end
end

-- returns a list of { id, negated, term, word_index } in text order
function Style.declared(text)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  local D = declared_index()
  local ws, cl = clause_words(text)
  local i = 1
  while i <= #ws do
    local len, ph = match_at(D.idx, ws, i)
    if len then
      local term = table.concat(ph, " ")
      local id = D.owner[term]
      -- negation: a negator within the three words before (same clause); "no exclamation marks" / "not very dramatic" / "never uses caps"
      local negated = false
      for k = math.max(1, i - 3), i - 1 do
        if cl[k] == cl[i] and match_at(D.neg, ws, k) then negated = true end
      end
      -- "instead of shouting": the negator covers what follows it
      out[#out + 1] = { id = id, negated = negated, term = term, word_index = i }
      i = i + len
    else i = i + 1 end
  end
  return out
end

---------------------------------------------------------------- merging
-- declared: list from Style.declared; measured: list from Style.describe.  Returns descriptors (ranked) and conflicts.
function Style.merge(declared, measured)
  local by = {}
  local order = {}
  local function slot(id, label)
    local s = by[id]
    if not s then s = { id = id, label = (L.descriptors[id] and L.descriptors[id].label) or label or id }; by[id] = s; order[#order + 1] = id end
    return s
  end
  local negated = {}
  for _, d in ipairs(declared or {}) do
    if d.negated then negated[d.id] = d
    else
      local s = slot(d.id, d.label)
      s.declared = s.declared or {}
      s.declared[#s.declared + 1] = d.term
    end
  end
  for _, m in ipairs(measured or {}) do
    local s = slot(m.id)
    s.measured = m
  end
  local list, conflicts = {}, {}
  for _, id in ipairs(order) do
    local s = by[id]
    local dsrc, msrc = s.declared ~= nil, s.measured ~= nil
    local strength = msrc and s.measured.strength or 0
    if dsrc then strength = math.max(strength, 0.7 + 0.1 * math.min(#s.declared, 3)) end
    if dsrc and msrc then strength = math.min(1, strength + 0.1) end
    list[#list + 1] = { id = id, label = s.label, source = (dsrc and msrc) and "both" or (dsrc and "declared" or "measured"), strength = U.round(math.min(1, strength), 3),
      declared_terms = s.declared, evidence = msrc and s.measured.evidence or nil }
  end
  -- declared negations remove the measured descriptor of the same id and add the opposite requirement
  local keep = {}
  for _, d in ipairs(list) do
    local neg = negated[d.id]
    if neg and d.source == "measured" then
      conflicts[#conflicts + 1] = { kind = "declared_negation", id = d.id, declared = "not " .. neg.term, measured = d.evidence }
    elseif neg then
      -- both declared and negated in the same text: keep neither (the text contradicts itself)
      conflicts[#conflicts + 1] = { kind = "self_contradiction", id = d.id, declared = "not " .. neg.term .. " / " .. table.concat(d.declared or {}, ", ") }
    else keep[#keep + 1] = d end
  end
  list = keep
  for id, neg in pairs(negated) do
    local present = false
    for _, d in ipairs(list) do if d.id == id then present = true end end
    local opposite = L.descriptors[id] and L.descriptors[id].opposite
    local label = (L.descriptors[id] and L.descriptors[id].label) or id
    if not present then list[#list + 1] = { id = "not_" .. id, label = "not " .. label, source = "declared", strength = 0.7, declared_terms = { "not " .. neg.term }, negates = id } end
    if opposite and not present then
      -- the opposite is implied only when it is itself declared or measured; never invented
    end
  end
  -- conflicts between a declared descriptor and a contradicting measured one
  local has = {}
  for _, d in ipairs(list) do has[d.id] = d end
  for _, d in ipairs(list) do
    local def = L.descriptors[d.id]
    local opp = def and def.opposite
    if opp and has[opp] and d.source ~= has[opp].source and d.id < opp then
      conflicts[#conflicts + 1] = { kind = "contradiction", a = d.id, b = opp, a_source = d.source, b_source = has[opp].source }
    end
  end
  table.sort(list, function(a, b) if a.strength ~= b.strength then return a.strength > b.strength end return a.id < b.id end)
  return list, conflicts
end

---------------------------------------------------------------- tone preview
-- target: { descriptors = { id = true }, terminal = "!!!" | nil, interjection = "OH. MY. GOODNESS!!!" | nil (the persona's own opener), emoji = "😀" | nil }.
-- Typography only: content words are never changed, and nothing is invented (no canned interjection: the opener must come from the persona's own example).
function Style.render(sentence, target)
  local d = target.descriptors or {}
  local body = sentence:gsub("%s*[%.!%?…]+%s*$", "")
  local terminal = target.terminal
  if not terminal then
    if d.exclamatory or d.dramatic then terminal = "!!!" elseif d.ellipsis then terminal = "..." else terminal = "." end
  end
  if d.caps_emphasis and not d.all_caps then
    body = body:gsub("%f[%a][%a']+", function(w) if #w >= 5 then return w:upper() end end)
  end
  local out = ((target.interjection and target.interjection ~= "") and (target.interjection .. " ") or "") .. body .. terminal
  if d.emoji and target.emoji then out = out .. " " .. target.emoji end
  if d.all_caps then out = out:upper()
  elseif d.lowercase then out = out:lower() end
  return out
end

---------------------------------------------------------------- announcement
local function list_text(items)
  if #items == 0 then return "" end
  if #items == 1 then return items[1] end
  if #items == 2 then return items[1] .. " and " .. items[2] end
  return table.concat(items, ", ", 1, #items - 1) .. " and " .. items[#items]
end

-- persona: { name, name_placeholder, descriptors = {...}, sources = {...}, authority, examples = n }
function Style.announce(p)
  if not p then return nil end
  local labels = {}
  for _, d in ipairs(p.descriptors or {}) do
    if #labels < 6 and d.strength >= 0.5 then labels[#labels + 1] = d.label end
  end
  local who = p.name or (p.name_placeholder and ("the persona (name not given: '" .. p.name_placeholder .. "')")) or "the persona"
  local parts = { "I will speak as " .. who }
  if #labels > 0 then parts[#parts + 1] = "in a " .. list_text(labels) .. " tone" else parts[#parts + 1] = "with no distinctive tone detected" end
  return table.concat(parts, " ") .. "."
end

return Style
