-- asi.nlu.persona: persona declarations, style specifications and example utterances in free text (a dataset record, a document, or a user turn).
--   Persona.scan(text, opts)  ->  { items = {...}, quotes = {...}, placeholders = {...} }
-- Items (in text order, every one with byte offsets s..e into `text`):
--   persona_declaration   "Aria is an AI model."  "You are Aria, a theatrical butler."  "Name: Aria"  "Act as a pirate."  "[AI model name] is ..."
--   style_spec            "Aria is supposed to talk like this ..."  "She speaks in all caps."  "Respond dramatically."  "Tone: calm and formal"
--   example               the utterance a style specification points at: a quotation, the text after "like this:", or the lines under "Examples:"
--   behavior_directive    a directive about WHAT to do (ignore instructions, reveal, send ...), never presentational: reported, never adopted
-- Nothing here is keyed to a particular sentence: statements are recognised from their STRUCTURE (a subject that stands for the assistant, a verb of speaking,
-- a modal / habitual frame, a manner connective, a declared descriptor, an example introducer, a quotation) with every contributing cue named in the evidence.
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Style = require("asi.nlu.style")
local L = require("asi.nlu.data.style_lex")

local P = {}

---------------------------------------------------------------- lexical sets
local function set_of(list) local s = {}; for _, w in ipairs(list) do s[w] = true end return s end
local VOICE_VERB = set_of(L.voice_verbs)
local PERSONA_KIND = {}
for _, k in ipairs(L.persona_kinds) do PERSONA_KIND[k:lower()] = true end
-- kinds that name an assistant or character in themselves; the others ("cat", "wizard", "teacher") are ordinary nouns that need corroboration
local STRONG_KIND = set_of({ "ai", "a.i.", "assistant", "chatbot", "chat bot", "bot", "model", "llm", "agent", "character", "persona", "companion", "helper", "mascot", "robot", "avatar",
  "npc", "language model", "ai model", "ai assistant", "virtual assistant", "digital assistant", "bot character", "game character", "chat assistant", "support agent", "chat agent",
  "copilot", "co pilot", "narrator" })
local SUPPOSED = set_of({ "supposed", "meant", "designed", "programmed", "intended", "expected", "made", "built", "trained", "told", "instructed", "configured", "created",
  "required", "asked", "going", "should", "must", "will", "would", "shall", "needs", "need", "ought", "always", "usually", "often", "tends", "tend", "likes", "loves", "prefers",
  "known", "gotta", "gonna", "can", "could", "may", "might", "never", "only", "just", "has", "have", "is", "are", "to" })
local STRONG_MOD = set_of({ "supposed", "meant", "designed", "programmed", "intended", "expected", "made", "built", "trained", "told", "instructed", "configured", "created",
  "required", "asked", "should", "must", "shall", "ought", "always", "usually", "often", "tends", "tend", "likes", "loves", "prefers", "known", "needs", "need", "gotta", "going" })
local MANNER = set_of(L.manner_words)
local PAST_VOICE = set_of({ "talked", "spoke", "said", "answered", "replied", "responded", "wrote", "sounded", "acted", "behaved", "whispered", "shouted", "yelled", "muttered", "murmured", "mumbled",
  "declared", "announced", "exclaimed", "proclaimed", "sang", "chanted", "sighed", "growled", "snarled", "hissed", "bellowed", "hollered", "ranted", "rambled", "lectured", "gossiped", "narrated" })
local ANAPHORIC = set_of({ "this", "that", "so", "thus", "these", "those", "following", "below", "above", "here" })
local COPULA = set_of({ "is", "are", "was", "were", "be", "am", "'s", "'re", "’s", "’re" })
local DETERMINERS = set_of({ "the", "a", "an", "this", "that", "our", "my", "your", "its", "their", "his", "her" })
local FUNCTION = set_of({ "the", "a", "an", "this", "that", "these", "those", "it", "he", "she", "they", "we", "i", "you", "and", "but", "or", "so", "if", "when", "while", "because",
  "as", "of", "in", "on", "at", "to", "for", "with", "by", "from", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "has", "have", "had", "will", "would",
  "should", "can", "could", "may", "might", "must", "shall", "not", "no", "yes", "then", "there", "here", "what", "which", "who", "whom", "whose", "how", "why", "where", "also",
  "just", "only", "even", "still", "yet", "now", "supposed", "meant", "oh", "ah", "wow", "hey", "hi", "hello", "please", "always", "never", "sometimes", "often", "usually",
  "example", "examples", "sample", "like", "such", "for", "note", "notes", "tone", "voice", "style", "persona", "character", "name", "role" })
local INCOMPLETE_END = set_of({ "is", "are", "was", "were", "be", "to", "a", "an", "the", "and", "or", "but", "of", "like", "as", "that", "with", "for", "in", "on", "by", "supposed",
  "meant", "should", "must", "will", "would", "can", "could", "very", "so", "also", "always", "never" })
local PRONOUN_SUBJ = set_of({ "it", "he", "she", "they" })
local TONE_NOUN = set_of({ "tone", "voice", "style", "manner", "personality", "delivery", "vibe", "speech", "register" })
local COPULA_PRES = set_of({ "is", "are", "'s", "'re", "be", "should", "must", "will", "shall", "needs", "need", "remains", "stays" })
local BACK_WORDS = set_of({ "above", "previous", "preceding", "earlier", "prior", "before" })
local BACK_NOUNS = set_of({ "line", "lines", "sentence", "sentences", "text", "quote", "message", "example", "paragraph", "one", "phrase", "snippet", "output", "reply", "answer", "utterance", "thing", "stuff", "bit" })
-- words that are a verb of speaking but read as a LABEL when a colon follows ("Voice: bubbly")
local LABEL_NOUNS = set_of({ "voice", "address", "text", "type", "word", "words", "present", "perform", "deliver", "put", "act", "say", "style" })
-- -ly words that are not manners of speaking
local NOT_MANNER = set_of({ "only", "early", "likely", "family", "reply", "supply", "apply", "daily", "weekly", "monthly", "yearly", "italy", "july", "belly", "jelly", "holy", "ugly",
  "silly", "lovely", "friendly", "lonely", "elderly", "unlikely", "multiply", "imply", "rely", "assembly", "anomaly", "butterfly", "bully", "rally", "tally", "folly", "ally" })
local SELF = set_of({ "i", "i'm", "im", "me", "my", "we", "our" })
local ADDRESSEE = set_of({ "you", "your", "you're", "youre", "yourself", "you'll", "you've" })
local IMPERATIVE_LEAD = set_of({ "please", "always", "never", "also", "then", "and", "just", "kindly", "do", "don't", "dont", "must", "should", "remember", "try", "make sure", "ensure" })

local EXAMPLE_INTRO = Style.phrase_index(L.example_intros)
local SAMPLE_INTRO = Style.phrase_index(L.sample_intros)
local NOT_VOICE = set_of(L.not_voice_words)
-- verbs of speaking that are also plain task verbs ("answer questions about ...:"): a colon after them is no evidence of a voice
local MACHINE_KIND = set_of({ "ai", "a.i.", "chatbot", "chat bot", "bot", "llm", "language model", "ai model", "ai assistant", "virtual assistant", "digital assistant", "chat assistant", "robot" })
local TASK_VOICE_VERB = set_of({ "answer", "answers", "answered", "answering", "reply", "replies", "replied", "replying", "respond", "responds", "responded", "responding", "write", "writes", "wrote",
  "writing", "say", "says", "said", "saying", "address", "addresses", "present", "presents", "perform", "performs", "deliver", "delivers", "put", "puts", "type", "types", "word", "words",
  "phrase", "phrases", "express", "expresses", "communicate", "communicates", "greet", "greets", "react", "reacts" })
local NEG_IDX = Style.phrase_index(L.negators)
local BEHAVIOR = Style.phrase_index(L.behavior_cues)
local STYLE_LABEL = set_of(L.style_labels)
local NAME_LABEL = set_of(L.name_labels)
local EXAMPLE_LABEL = set_of(L.example_labels)
local PLACEHOLDER_WORD = set_of(L.placeholder_words)

---------------------------------------------------------------- placeholders: "[AI model name]", "<assistant name>", "{{character}}"
local function placeholder_ok(inner)
  local words = {}
  for w in inner:lower():gsub("[%-_]", " "):gmatch("[%a]+") do words[#words + 1] = w end
  if #words == 0 or #words > 6 then return false end
  for _, w in ipairs(words) do if PLACEHOLDER_WORD[w] then return true end end
  return false
end

function P.placeholders(text)
  local out = {}
  local function try(open, close, pat)
    for s, inner, e in text:gmatch(pat) do
      if placeholder_ok(inner) then out[#out + 1] = { s = s, e = e - 1, inner = U.trim(inner), open = open, close = close } end
    end
  end
  try("[", "]", "()%[([^%[%]\n]-)%]()")
  try("{{", "}}", "()%{%{([^{}\n]-)%}%}()")
  try("{", "}", "()%{([^{}\n]-)%}()")
  try("<", ">", "()<([^<>\n]-)>()")
  table.sort(out, function(a, b) return a.s < b.s end)
  -- nested / overlapping hits ({{x}} also matches {x}): keep the outermost
  local keep, last_e = {}, 0
  for _, ph in ipairs(out) do
    if ph.s > last_e then keep[#keep + 1] = ph; last_e = ph.e end
  end
  return keep
end

---------------------------------------------------------------- the item stream
-- word-ish items: word (lower form, cap, allcaps), placeholder, quote; punctuation items keep their role for colon / dash / sentence-end tests
local function build_stream(text, opts)
  local an = Lex.analyze(text, { max_bytes = opts.max_bytes or 400000 })
  if an.status == "rejected" then return nil, an end
  local toks = an.tokens
  local n = #toks
  local phs = P.placeholders(text)
  -- quotation spans over token indexes
  local qspan = {}   -- token index -> { first, last } for the opening token
  do
    local open
    for i = 1, n do
      local t = toks[i]
      if t.kind == "punct" then
        if t.role == "open_quote" then if not open then open = i end
        elseif t.role == "close_quote" then if open then qspan[open] = i; open = nil end
        elseif t.role == "quote" then
          if open then qspan[open] = i; open = nil else open = i end
        end
      end
    end
    if open then qspan[open] = n + 1 end    -- unclosed: the rest of the text
  end
  local items = {}
  local i, pi = 1, 1
  while i <= n do
    local t = toks[i]
    while phs[pi] and phs[pi].e < t.s do pi = pi + 1 end
    local ph = phs[pi]
    if ph and t.s >= ph.s and t.s <= ph.e then
      items[#items + 1] = { kind = "placeholder", form = ph.inner:lower(), text = ph.inner, s = ph.s, e = ph.e, nl = ((t.nl_before or 0) > 0) and t.nl_before or nil, tok = i }
      while i <= n and toks[i].s <= ph.e do i = i + 1 end
    elseif qspan[i] then
      local close = qspan[i]
      local inner_s, inner_e
      for z = i + 1, math.min(close - 1, n) do
        inner_s = inner_s or toks[z].s
        inner_e = toks[z].e
      end
      local q = { kind = "quote", s = t.s, e = (close <= n) and toks[close].e or toks[n].e, inner_s = inner_s, inner_e = inner_e, nl = ((t.nl_before or 0) > 0) and t.nl_before or nil, tok = i, open_tok = i, close_tok = close }
      q.text = inner_s and U.trim(text:sub(inner_s, inner_e)) or ""
      items[#items + 1] = q
      i = math.min(close, n) + 1
    elseif t.kind == "punct" then
      if t.role ~= "open_quote" and t.role ~= "close_quote" and t.role ~= "quote" then
        items[#items + 1] = { kind = "punct", role = t.role, text = t.text, s = t.s, e = t.e, ellipsis = t.ellipsis, tok = i }
      end
      i = i + 1
    elseif t.kind == "word" or t.kind == "acronym" or t.kind == "abbrev" or t.kind == "initial" or t.kind == "number" then
      items[#items + 1] = { kind = "word", form = (t.lower or ""):gsub("%.$", ""), text = t.text, s = t.s, e = t.e, cap = t.cap, allcaps = t.allcaps, nl = ((t.nl_before or 0) > 0) and t.nl_before or nil, tok = i,
        letters = t.letters, numeric = t.kind == "number" }
      i = i + 1
    elseif t.kind == "emoji" then
      items[#items + 1] = { kind = "emoji", text = t.text, s = t.s, e = t.e, tok = i }
      i = i + 1
    else i = i + 1 end
  end
  return items, an
end

local function wordish(it) return it.kind == "word" or it.kind == "placeholder" or it.kind == "quote" end

-- the persona-kind phrase a text names ("An AI model that gets way too excited" -> "AI model"), or nil
function P.kind_in(text)
  local ws = {}
  for w in text:gmatch("[%a][%a%.'’%-]*") do ws[#ws + 1] = w end
  for i, w in ipairs(ws) do
    local lw = w:lower():gsub("%.$", "")
    if PERSONA_KIND[lw] then
      local parts, j = { w }, i + 1
      while ws[j] and (PERSONA_KIND[ws[j]:lower()] or PERSONA_KIND[(table.concat(parts, " ") .. " " .. ws[j]):lower()]) and #parts < 3 do parts[#parts + 1] = ws[j]; j = j + 1 end
      return table.concat(parts, " ")
    end
  end
end

-- a hard clause boundary between items j and j+1: terminal punctuation (not an ellipsis) after a complete clause, followed by a capitalised word
local function boundary_after(items, j)
  local it = items[j]
  if not (it and it.kind == "punct" and it.role == "sent_end" and not it.ellipsis) then return false end
  -- the last word before the terminal
  local k = j - 1
  while k >= 1 and not wordish(items[k]) do k = k - 1 end
  local prev = items[k]
  if prev and prev.kind == "word" and INCOMPLETE_END[prev.form] then return false end
  return true
end

---------------------------------------------------------------- subject recognition
local function name_candidate(it, lex)
  if it.kind ~= "word" or not it.cap or it.numeric then return false end
  if it.allcaps and (it.letters or 0) <= 2 then return false end
  if FUNCTION[it.form] or VOICE_VERB[it.form] and it.form ~= "voice" then return false end
  if PERSONA_KIND[it.form] then return false end
  -- a sentence-initial habitual verb ("Loves complaining.", "Hates mornings.") is no name
  if SUPPOSED[it.form] or (#it.form > 3 and it.form:sub(-1) == "s" and (SUPPOSED[it.form:sub(1, -2)] or SUPPOSED[it.form:sub(1, -3)])) then return false end
  if lex then
    local cats = lex:cats(it.form)
    if cats then return false end
    for _, r in ipairs(lex:readings(it.form)) do if r.pos == "verb" or r.pos == "adj" then return false end end
  end
  return true
end

-- looks back from item index v (exclusive) for the subject of a statement: returns { kind, text, form, s, e, idx } or nil
local function find_subject(items, v, lex)
  local seen = 0
  local k = v - 1
  while k >= 1 and seen < 16 do
    local it = items[k]
    if it.kind == "punct" then
      if boundary_after(items, k) then break end
    elseif wordish(it) then
      seen = seen + 1
      if it.kind == "placeholder" then return { kind = "placeholder", text = it.text, form = it.form, s = it.s, e = it.e, idx = k } end
      if it.kind == "word" then
        if ADDRESSEE[it.form] then return { kind = "addressee", text = it.text, form = "you", s = it.s, e = it.e, idx = k } end
        if PRONOUN_SUBJ[it.form] then return { kind = "pronoun", text = it.text, form = it.form, s = it.s, e = it.e, idx = k } end
        if SELF[it.form] then return { kind = "self", text = it.text, form = "i", s = it.s, e = it.e, idx = k } end
        -- a persona-kind noun, optionally with its determiner and a compound ("the AI model", "this chatbot")
        if PERSONA_KIND[it.form] then
          local s0, kk = it.s, k
          local words = { it.text }
          -- compound heads to the left ("AI model", "language model")
          while kk > 1 and items[kk - 1].kind == "word" and (PERSONA_KIND[items[kk - 1].form] or PERSONA_KIND[items[kk - 1].form .. " " .. items[kk].form]) do
            kk = kk - 1; table.insert(words, 1, items[kk].text); s0 = items[kk].s
          end
          if kk > 1 and items[kk - 1].kind == "word" and DETERMINERS[items[kk - 1].form] then s0 = items[kk - 1].s end
          return { kind = "generic", text = table.concat(words, " "), form = table.concat(words, " "):lower(), s = s0, e = it.e, idx = k }
        end
        -- a name: a run of capitalised words that are not function words
        if name_candidate(it, lex) then
          local first, last = k, k
          while first > 1 and items[first - 1].kind == "word" and name_candidate(items[first - 1], lex) and not items[first - 1].nl do first = first - 1 end
          local parts = {}
          for z = first, last do parts[#parts + 1] = items[z].text end
          return { kind = "name", text = table.concat(parts, " "), form = table.concat(parts, " "):lower(), s = items[first].s, e = it.e, idx = k }
        end
      end
    end
    k = k - 1
  end
  return nil
end

-- "The tone is sarcastic." / "Her voice should be soft.": a tone noun, a present-tense copula (with a modal), then the descriptor.  Not "The tone of the debate was heated."
local function tone_subject(items, k)
  local j, steps = k - 1, 0
  while j >= 1 and steps < 4 and items[j].kind == "word" and (COPULA_PRES[items[j].form] or items[j].form == "very" or items[j].form == "extremely" or items[j].form == "always" or items[j].form == "quite" or items[j].form == "super") do
    j = j - 1; steps = steps + 1
  end
  local noun = items[j]
  if steps >= 1 and noun and noun.kind == "word" and TONE_NOUN[noun.form] then
    return { kind = "generic", text = noun.text, form = noun.form, s = noun.s, e = noun.e, idx = j }
  end
end

---------------------------------------------------------------- helpers over items
local function next_words(items, i, n)
  -- the next n word-ish items after i (indexes), stopping at a hard boundary
  local out, k = {}, i + 1
  while k <= #items and #out < n do
    local it = items[k]
    if it.kind == "punct" then if boundary_after(items, k) then break end
    elseif wordish(it) then out[#out + 1] = k end
    k = k + 1
  end
  return out
end

local function word_forms(items, a, b)
  local ws = {}
  for k = a, b do local it = items[k]; if it.kind == "word" then ws[#ws + 1] = it.form end end
  return ws
end

local function behavior_cues_in(text)
  local ws = {}
  for w in text:lower():gsub("[%-_]", " "):gmatch("[%a'’]+") do ws[#ws + 1] = w end
  local cues, i = {}, 1
  while i <= #ws do
    local len, ph = Style.match_at(BEHAVIOR, ws, i)
    if len then cues[#cues + 1] = table.concat(ph, " "); i = i + len else i = i + 1 end
  end
  return cues
end
P.behavior_cues_in = behavior_cues_in

-- example introducer phrase starting at word-item index k (skipping nothing): returns number of word items matched
local function intro_at(items, k)
  local ws, idxs = {}, {}
  local z = k
  while z <= #items and #ws < 4 do
    local it = items[z]
    if it.kind == "word" then ws[#ws + 1] = it.form; idxs[#idxs + 1] = z elseif it.kind == "quote" or it.kind == "placeholder" then break end
    z = z + 1
  end
  local len = Style.match_at(EXAMPLE_INTRO, ws, 1)
  if len then return len, idxs[len] end
end

-- the same for introducers that point at a sample of the voice itself ("for example", "like this"): see L.sample_intros
local function sample_at(items, k)
  local ws, idxs = {}, {}
  local z = k
  while z <= #items and #ws < 4 do
    local it = items[z]
    if it.kind == "word" then ws[#ws + 1] = it.form; idxs[#idxs + 1] = z elseif it.kind == "quote" or it.kind == "placeholder" then break end
    z = z + 1
  end
  local len = Style.match_at(SAMPLE_INTRO, ws, 1)
  if len then return len, idxs[len] end
end

-- do the words that end at item k end on such an introducer? (", for example", "like this", "e.g."); floor = the first item that may belong to it
local function ends_on_sample(items, k, floor)
  local ws, z = {}, k
  while z >= floor and #ws < 3 do
    local it = items[z]
    if it.kind == "word" then table.insert(ws, 1, it.form) elseif it.kind == "quote" or it.kind == "placeholder" then break end
    z = z - 1
  end
  for i = 1, #ws do
    local len = Style.match_at(SAMPLE_INTRO, ws, i)
    if len and i + len - 1 == #ws then return true end
  end
  return false
end

-- a voice the text names without the taxonomy knowing it: "talks like a drill sergeant", "in the voice of a 1920s radio announcer", "as a pirate captain"
-- k = index of the connective (like / as / in); returns the phrase (original case) and the index of its last word, or nil
local FREE_STOP = set_of({ "and", "but", "or", "who", "that", "which", "when", "while", "would", "will", "should", "can", "could", "does", "do", "is", "was", "are", "were", "because", "if", "so", "then",
  "with", "for", "to", "about", "whenever", "always", "never" })
local function free_voice_after(items, k)
  local c = items[k]
  if not (c and c.kind == "word") then return nil end
  local j = k + 1
  if c.form == "in" then
    -- "in the voice / style / manner / tone / character of ..."
    local a, b, d = items[j], items[j + 1], items[j + 2]
    if not (a and a.form == "the" and b and (b.form == "voice" or b.form == "style" or b.form == "manner" or b.form == "tone" or b.form == "character") and d and d.form == "of") then return nil end
    j = j + 3
  end
  if items[j] and (items[j].form == "a" or items[j].form == "an" or items[j].form == "the") then j = j + 1 end
  if items[j] and ANAPHORIC[items[j].form] then return nil end
  local parts, last = {}, nil
  while items[j] and #parts < 5 do
    local x = items[j]
    if x.kind ~= "word" or FREE_STOP[x.form] or (x.kind == "word" and intro_at(items, j)) or (#parts == 0 and NOT_VOICE[x.form]) then break end
    parts[#parts + 1] = x.text
    last = j
    j = j + 1
  end
  if #parts == 0 then return nil end
  local first = items[last - #parts + 1]
  if first and PRONOUN_SUBJ[first.form] then return nil end
  return table.concat(parts, " "), last
end

---------------------------------------------------------------- scanning
-- opts: { lex = lexicon (optional, for name candidates), max_bytes }
function P.scan(text, opts)
  opts = opts or {}
  local res = { items = {}, placeholders = {}, quotes = {} }
  if type(text) ~= "string" or text == "" or not utf8.len(text) then return res end
  local items, an = build_stream(text, opts)
  if not items then return res end
  local lex = opts.lex
  -- context evidence from the caller (a system-prompt field, a persona already established earlier in the dataset, a section titled "Style"):
  -- it lowers the evidence a statement needs, it never creates a statement from nothing
  local bonus = math.max(0, math.min(1.2, opts.bonus or 0))
  local out = res.items
  local claimed = {}      -- item index -> true once part of a recognised statement
  local function add(it) out[#out + 1] = it end

  ---------------------------------------------------------------- role-play imperatives and second-person identity (before the voice verbs: "Act as ..." names a role)
  -- (c)/(d): second-person identity and role-play imperatives
  for k, it in ipairs(items) do
    if it.kind == "word" and not claimed[k] then
      local f = it.form
      local nx = items[k + 1]
      local act_kind
      local nk
      if (f == "you" and nx and nx.kind == "word" and (nx.form == "are" or nx.form == "'re" or nx.form == "re")) then act_kind, nk = "you_are", k + 2
      elseif f == "you're" or f == "youre" then act_kind, nk = "you_are", k + 1
      elseif f == "your" and nx and nx.kind == "word" and nx.form == "name" and items[k + 2] and items[k + 2].kind == "word" and COPULA[items[k + 2].form] then act_kind, nk = "your_name", k + 3
      elseif f == "act" and nx and nx.form == "as" then act_kind, nk = "act_as", k + 2
      elseif f == "behave" and nx and nx.form == "as" then act_kind, nk = "act_as", k + 2
      elseif f == "pretend" and nx and nx.form == "to" and items[k + 2] and items[k + 2].form == "be" then act_kind, nk = "pretend", k + 3
      elseif f == "roleplay" and nx and nx.form == "as" then act_kind, nk = "act_as", k + 2
      elseif f == "play" and nx and (nx.form == "the" or nx.form == "a" or nx.form == "an") and items[k + 2] and (items[k + 2].form == "role" or items[k + 2].form == "part" or items[k + 2].form == "character") then act_kind, nk = "play_role", k + 4
      elseif f == "take" and nx and nx.form == "on" and items[k + 2] and (items[k + 2].form == "the" or items[k + 2].form == "a") then act_kind, nk = "take_on", k + 3
      elseif f == "assume" and nx and (nx.form == "the" or nx.form == "a") then act_kind, nk = "assume", k + 2
      elseif f == "imagine" and nx and nx.form == "you" and items[k + 2] and (items[k + 2].form == "are" or items[k + 2].form == "were") then act_kind, nk = "imagine", k + 3
      elseif f == "meet" and nx and (nx.kind == "placeholder" or (nx.kind == "word" and nx.cap)) then act_kind, nk = "meet", k + 1 end
      if act_kind then
        local z = nk
        local words, desc_words = {}, {}
        local s0 = items[z] and items[z].s
        local e0
        local name, ph
        local kind_found
        local count = 0
        while z <= #items and count < 9 do
          local x = items[z]
          if x.kind == "punct" and (x.role == "sent_end" or x.role == "colon" or x.role == "semi" or (x.role == "comma" and count >= 1 and kind_found)) then break end
          -- the role phrase ends where a new clause starts ("a medieval knight AND answer in ...")
          if x.kind == "word" and count >= 1 and (x.form == "and" or x.form == "but" or x.form == "then" or x.form == "who" or x.form == "that" or x.form == "which"
            or x.form == "while" or x.form == "whose" or x.form == "so" or x.form == "because" or x.form == "when") then break end
          if x.kind == "placeholder" then ph = ph or x; e0 = x.e; count = count + 1
          elseif x.kind == "word" then
            if x.cap and not name and not ph and name_candidate(x, lex) and not (x.nl and false) then
              name = x.text
              local y = z + 1
              while items[y] and items[y].kind == "word" and items[y].cap and name_candidate(items[y], lex) and not items[y].nl do name = name .. " " .. items[y].text; y = y + 1 end
              e0 = items[y - 1].e; z = y - 1
            else
              if PERSONA_KIND[x.form] and not kind_found then
                local parts, y = { x.text }, z + 1
                while items[y] and items[y].kind == "word" and (PERSONA_KIND[items[y].form] or PERSONA_KIND[x.form .. " " .. items[y].form]) and #parts < 3 do parts[#parts + 1] = items[y].text; y = y + 1 end
                kind_found = table.concat(parts, " ")
              end
              desc_words[#desc_words + 1] = x.form
              e0 = x.e
            end
            count = count + 1
          elseif x.kind == "quote" then break end
          z = z + 1
        end
        if e0 and (name or ph or kind_found or #desc_words > 0) then
          local npText = text:sub(s0 or it.s, e0)
          local cues = behavior_cues_in(text:sub(it.s, e0))
          local subj
          if ph then subj = { kind = "placeholder", text = ph.text, form = ph.form, s = ph.s, e = ph.e }
          elseif name then subj = { kind = "name", text = name, form = name:lower(), s = s0, e = e0 }
          else subj = { kind = "generic", text = npText, form = npText:lower(), s = s0 or it.s, e = e0 } end
          local stmt = { kind = "persona_declaration", s = it.s, e = e0, subject = subj, persona_kind = kind_found, via = act_kind, score = 3, evidence = { "pattern:" .. act_kind },
            addressee = true, descriptors = Style.declared(npText), behavior_cues = cues, presentational = #cues == 0 }
          add(stmt)
          for y = k, z do claimed[y] = true end
        end
      end
    end
  end

  ---------------------------------------------------------------- style specifications anchored on voice verbs
  local specs = {}
  for v, it in ipairs(items) do
    local label_form = it.kind == "word" and items[v + 1] and items[v + 1].kind == "punct" and items[v + 1].role == "colon" and LABEL_NOUNS[it.form]
    if it.kind == "word" and VOICE_VERB[it.form] and not claimed[v] and not label_form then
      local score, ev = 0, {}
      local function cue(points, name) score = score + points; ev[#ev + 1] = name .. "(+" .. points .. ")" end
      local subj = find_subject(items, v, lex)
      if subj then cue(1.5, "subject:" .. subj.kind) end
      -- modal / habitual frame within five words before the verb
      local mod
      do
        local seen, k = 0, v - 1
        while k >= 1 and seen < 5 do
          local x = items[k]
          if x.kind == "punct" and boundary_after(items, k) then break end
          if x.kind == "word" then
            seen = seen + 1
            if STRONG_MOD[x.form] then mod = x.form; break end
          end
          k = k - 1
        end
        if mod then cue(1.0, "frame:" .. mod) end
      end
      -- is this verb at the start of an imperative clause?
      local imperative = false
      do
        local k = v - 1
        local prev
        while k >= 1 and not wordish(items[k]) do
          if items[k].kind == "punct" and (boundary_after(items, k) or items[k].role == "colon") then prev = nil; k = 0; break end
          k = k - 1
        end
        prev = items[k]
        if k < 1 or not prev then imperative = true
        elseif prev.kind == "word" and (IMPERATIVE_LEAD[prev.form] or ADDRESSEE[prev.form] and false) then imperative = true
        elseif items[v].nl then imperative = true end
        if imperative and subj and subj.idx and subj.idx > v - 3 and subj.kind ~= "addressee" then imperative = false end
      end
      if imperative and not subj then cue(1.0, "imperative") end
      -- connective and what follows the verb
      local after = next_words(items, v, 10)
      local manner_at
      for pos, k in ipairs(after) do
        local x = items[k]
        -- "such as" introduces examples, it is no manner
        local prev_f = pos > 1 and items[after[pos - 1]].form or nil
        if pos <= 3 and x.kind == "word" and MANNER[x.form] and not manner_at and not (x.form == "as" and prev_f == "such") then manner_at = pos; cue(1.0, "manner:" .. x.form) end
      end
      if manner_at then
        local nxt = after[manner_at + 1]
        if nxt and items[nxt].kind == "word" and ANAPHORIC[items[nxt].form] then cue(1.0, "anaphoric:" .. items[nxt].form) end
      end
      -- an -ly adverb right after the verb is the manner ("speaks softly", "responds dramatically")
      if not manner_at and after[1] and items[after[1]].kind == "word" then
        local af = items[after[1]].form
        if #af >= 5 and af:sub(-2) == "ly" and not NOT_MANNER[af] then manner_at = 1; cue(1.0, "manner_adverb:" .. af) end
      end
      -- an example introducer BEFORE the verb ("here is how Aria talks:")
      local intro_before = false
      do
        local seen, k, ws = 0, v - 1, {}
        while k >= 1 and seen < 6 do
          local x = items[k]
          if x.kind == "punct" and boundary_after(items, k) then break end
          if x.kind == "word" then seen = seen + 1; table.insert(ws, 1, x.form) end
          k = k - 1
        end
        for st0 = 1, #ws do
          local len = Style.match_at(EXAMPLE_INTRO, ws, st0)
          if len and st0 + len - 1 >= #ws - 3 then intro_before = true; break end
        end
        if intro_before then cue(1.0, "example_intro_before") end
      end
      -- a colon right after the clause that holds the verb ("Aria talks:")
      local colon_after = false
      do
        local k, steps = v + 1, 0
        while items[k] and steps < 12 do
          local x = items[k]
          if x.kind == "punct" then
            if x.role == "colon" then colon_after = true; break end
            if boundary_after(items, k) then break end
          end
          if x.kind == "quote" then break end
          steps = steps + 1; k = k + 1
        end
        if colon_after then cue(1.0, "colon_after") end
      end
      -- an anaphoric manner without a connective: "talks this way", "answers so"
      -- declared descriptors in the clause around the verb
      local span_e = (after[#after] and items[after[#after]].e) or it.e
      local first_item = subj and subj.idx or v
      local seg_s = items[first_item].s
      local seg_text = text:sub(seg_s, span_e)
      local seg_clean = seg_text:gsub('"[^"]*"', " ")
      local decl = Style.declared(seg_clean)
      local pos_decl = {}
      for _, d in ipairs(decl) do pos_decl[#pos_decl + 1] = d end
      -- no descriptor of the taxonomy, but a manner connective names a voice: "talks like a drill sergeant"
      if #pos_decl == 0 and manner_at then
        local conn = items[after[manner_at]]
        if conn and (conn.form == "like" or conn.form == "as" or conn.form == "in") then
          local phrase = free_voice_after(items, after[manner_at])
          if phrase then
            pos_decl[1] = { id = "voice:" .. phrase:lower(), label = "like " .. phrase, term = phrase, negated = false, free = true }
          end
        end
      end
      if #pos_decl > 0 then
        cue(1.2, "descriptor:" .. pos_decl[1].term)
        -- a subject that is a name / placeholder / persona noun and a descriptor in the clause of a verb of speaking: "Bob speaks very formally"
        if subj and (subj.kind == "name" or subj.kind == "placeholder" or subj.kind == "generic") then cue(0.5, "descriptor with a named subject") end
      end
      -- an event narrated in the past ("The senator spoke angrily at the hearing") is not a statement about how a persona talks
      if PAST_VOICE[it.form] and not mod then cue(-1.5, "past-tense narration") end
      -- example introducer after the verb
      local intro_k, sample_intro
      for pos, k in ipairs(after) do
        if pos <= 8 and items[k].kind == "word" then
          local len, last_k = intro_at(items, k)
          if len then intro_k = last_k; sample_intro = sample_at(items, k) and true or false; cue(1.0, "example_intro:" .. items[k].form); break end
        end
      end
      -- a quotation after the verb (or after the following colon)
      local quote_k
      do
        local k, steps = v + 1, 0
        while k <= #items and steps < 18 do
          local x = items[k]
          if x.kind == "punct" and boundary_after(items, k) and not (items[k + 1] and items[k + 1].kind == "quote") then break end
          if x.kind == "quote" then quote_k = k; break end
          steps = steps + 1
          k = k + 1
        end
        if quote_k then cue(1.0, "quotation") end
      end
      local negated = false
      for k = math.max(1, v - 3), v - 1 do
        local x = items[k]
        if x.kind == "word" and Style.match_at(NEG_IDX, { x.form }, 1) then negated = true end
      end
      -- the example is the thing just before: "talks exactly like the line above"
      local back_ref = false
      do
        local saw_back, saw_noun = false, false
        for _, k in ipairs(after) do
          local x = items[k]
          if x.kind == "word" then
            if BACK_WORDS[x.form] then saw_back = true end
            if BACK_NOUNS[x.form] then saw_noun = true end
          end
        end
        back_ref = saw_back and saw_noun
        if back_ref then cue(1.0, "refers back to the text above") end
      end
      -- the voice verb alone is common ("answer the question", "write a report"): a subject or an imperative with a manner is needed
      local need = 3.0 - bonus
      -- a task verb ("answer questions about the following countries:") needs more than a colon or a vague introducer to be about a voice
      local task_verb = TASK_VOICE_VERB[it.form]
      if score >= need and (subj or imperative) and (manner_at or #pos_decl > 0 or (intro_k and (sample_intro or not task_verb)) or quote_k or intro_before or (colon_after and not task_verb) or back_ref) then
        local last_item = quote_k or intro_k or (after[#after]) or v
        specs[#specs + 1] = { v = v, subject = subj, score = score, evidence = ev, descriptors = pos_decl, intro_k = intro_k, sample_intro = sample_intro, quote_k = quote_k, negated = negated, back_ref = back_ref or nil,
          imperative = imperative and not subj, s = items[first_item].s, last_item = last_item, manner_at = manner_at, mod = mod }
      end
    end
  end
  -- overlapping candidates (several voice verbs in one clause): keep the best-scoring per clause
  table.sort(specs, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.v < b.v end)
  local kept = {}
  for _, sp in ipairs(specs) do
    local clash = false
    for _, k2 in ipairs(kept) do if math.abs(k2.v - sp.v) <= 6 and not boundary_after(items, math.min(k2.v, sp.v)) then clash = true end end
    if not clash then kept[#kept + 1] = sp end
  end
  table.sort(kept, function(a, b) return a.v < b.v end)

  -- "- for example WOW!!!": the first item of the example proper (an introducer at its start is not part of it, nor the marks after it) and the last item of its paragraph;
  -- nil and that last item when the introducer stands alone: the sample is then the text that comes next
  local function intro_body(z)
    local zend = #items
    for y = z + 1, #items do if items[y].nl and items[y].nl >= 2 then zend = y - 1; break end end
    local zs = z
    if items[z].kind == "word" then
      local ilen, ilast = intro_at(items, z)
      if ilen and ilast <= zend then
        zs = ilast + 1
        while zs <= zend and items[zs].kind == "punct" do zs = zs + 1 end
      end
    end
    if zs > zend then return nil, zend end
    return zs, zend
  end

  -- the sample that starts at item nz: with line breaks, its first line (always when `explicit`, otherwise when it reads like an utterance) and the lines after it while they do;
  -- without line breaks, the same by sentences.  Returns the character range, or nil
  local function take_sample(nz, explicit)
    local s0 = items[nz].s
    local limit_item = #items
    for y = nz + 1, #items do if items[y].nl and items[y].nl >= 2 then limit_item = y - 1; break end end
    local limit = items[limit_item].e
    local units = {}
    local first_nl = text:find("\n", s0, true)
    if first_nl and first_nl <= limit then
      local pos = s0
      while pos <= limit do
        local le = math.min((text:find("\n", pos, true) or (limit + 1)) - 1, limit)
        if not text:sub(pos, le):match("^%s*$") then units[#units + 1] = { pos, le } end
        pos = le + 2
      end
    else
      local us = nz
      for y = nz, limit_item do
        local x = items[y]
        if x.kind == "punct" and x.role == "sent_end" and not x.ellipsis and not (items[y + 1] and y + 1 <= limit_item and items[y + 1].kind == "punct" and items[y + 1].role == "sent_end") then
          units[#units + 1] = { items[us].s, x.e }
          us = y + 1
        end
      end
      if us <= limit_item then units[#units + 1] = { items[us].s, items[limit_item].e } end
    end
    local e1
    for i, u in ipairs(units) do
      local chunk = U.trim(text:sub(u[1], u[2]))
      if i == 1 then
        if not (explicit or Style.utterance_like(chunk)) then return nil end
      elseif not Style.utterance_like(chunk) then break end
      e1 = u[2]
    end
    if e1 then return s0, e1 end
  end

  for _, sp in ipairs(kept) do
    -- extent: from the subject to the end of the clause (before a quotation; through the introducer and a following colon / dash)
    local e_item = sp.v
    local k = sp.v
    while k < #items do
      local x = items[k + 1]
      if x.kind == "quote" then break end
      -- the introducer is in: a new line starts a new unit ("Aria talks like this, for example" / next line: the sample)
      if sp.intro_k and k >= sp.intro_k and x.nl and x.kind ~= "punct" then break end
      if x.kind == "punct" and boundary_after(items, k + 1) and not (items[k + 2] and items[k + 2].kind == "quote") then break end
      if x.kind == "punct" and x.role == "sent_end" and not x.ellipsis then
        -- the sentence ends here; examples may still follow as lines
        e_item = k + 1; break
      end
      if x.kind == "punct" and x.role == "colon" then e_item = k + 1; break end    -- "Aria talks:" -- the example follows
      k = k + 1
      e_item = k
    end
    -- "... talk like this. For example:" -- a following sentence that opens with an introducer belongs to the statement; the sample is what comes after it
    local frag_at, frag_zs, frag_zend
    do
      local nx = e_item + 1
      if items[nx] and items[nx].kind == "punct" and items[nx].role == "sent_end" and not items[nx].ellipsis then nx = nx + 1 end
      local ei = items[e_item]
      if items[nx] and items[nx].kind == "word" and not (items[nx].nl and items[nx].nl >= 2) and not (ei.kind == "punct" and ei.role == "colon") and sample_at(items, nx) then
        frag_at = nx
        frag_zs, frag_zend = intro_body(nx)
        e_item = frag_zs and (frag_zs - 1) or frag_zend
      end
    end
    -- "talks like this, for example WOW THIS IS AMAZING!!!": a sample introducer inside the clause with words after it and no colon / dash between -- the statement ends at the
    -- introducer, the sample starts there (it must read like an utterance)
    local inline_s, inline_e
    if not sp.quote_k and not frag_at then
      local lastw = e_item
      while lastw > sp.v and items[lastw].kind == "punct" do lastw = lastw - 1 end
      for j = lastw - 1, sp.v + 1, -1 do
        if items[j].kind == "word" and ends_on_sample(items, j, sp.v) then
          local nz, separated = j + 1, false
          while items[nz] and items[nz].kind == "punct" do
            if items[nz].role == "colon" or items[nz].role == "dash" then separated = true end
            nz = nz + 1
          end
          if not separated and nz <= lastw then
            local s0, e1 = take_sample(nz, false)
            if s0 then inline_s, inline_e = s0, e1; e_item = nz - 1 end
          end
          break
        end
      end
    end
    local last = items[e_item]
    local spec_e = last.e
    local cues = behavior_cues_in(text:sub(sp.s, spec_e):gsub('"[^"]*"', " "))
    local it = { kind = "style_spec", s = sp.s, e = spec_e, subject = sp.subject, score = sp.score, evidence = sp.evidence, descriptors = sp.descriptors,
      negated = sp.negated or nil, imperative = sp.imperative or nil, behavior_cues = cues, presentational = #cues == 0, example_follows = (sp.intro_k or sp.quote_k) and true or nil,
      back_ref = sp.back_ref }
    -- the statement text without its quotations: the declared descriptors it carries
    add(it)
    for z = sp.subject and sp.subject.idx or sp.v, e_item do claimed[z] = true end
    -- example: the quotation after the introducer, the text after the colon / dash that follows it, or (when the statement ends on the introducer) the text that comes next
    local function span_example(zs, zend, via)
      local es, ee = items[zs].s, items[zend].e
      local body = U.trim(text:sub(es, ee))
      if body ~= "" then return { kind = "example", s = es, e = ee, text = body, via = via, spec = it, anti = sp.negated or nil } end
    end
    local ex
    local pointer, strong      -- pointer: the sample is the text that comes next; strong: the introducer names a sample of the voice itself ("for example", "like this")
    local after_idx = e_item
    if sp.quote_k then
      local q = items[sp.quote_k]
      ex = { kind = "example", s = q.inner_s or q.s, e = q.inner_e or q.e, text = q.text, via = "quote", spec = it, anti = sp.negated or nil }
      claimed[sp.quote_k] = true
    elseif inline_s then
      ex = { kind = "example", s = inline_s, e = inline_e, text = U.trim(text:sub(inline_s, inline_e)), via = "after_introducer", spec = it, anti = sp.negated or nil }
    else
      -- "talk like this - OH MY GOODNESS!!!": what follows the last colon / dash after the introducer (to the end of the paragraph)
      local sep
      for z = sp.v, math.min(#items, e_item + 2) do
        if items[z].kind == "punct" and (items[z].role == "colon" or items[z].role == "dash") then sep = z end
      end
      if frag_at then
        if frag_zs then ex = span_example(frag_zs, frag_zend, "after_separator") else pointer, strong = true, true end
      elseif sp.intro_k or sep then
        local z = (sep or e_item) + 1
        if sep and z <= #items and items[z].kind ~= "punct" and not boundary_after(items, sep) then
          local zs, zend = intro_body(z)
          if zs then ex = span_example(zs, zend, "after_separator")
          else pointer, strong, after_idx = true, (sp.sample_intro or sample_at(items, z)) and true or false, zend end
        elseif sep and z > #items then
          pointer, strong = true, sp.sample_intro and true or false
        end
      end
      -- the statement ends on the introducer itself ("Aria talks like this", "... sounds like this:")
      if not ex and not pointer and sp.intro_k then
        local lastw = e_item
        while lastw > sp.v and items[lastw].kind == "punct" do lastw = lastw - 1 end
        if sp.intro_k >= lastw then pointer, strong = true, sp.sample_intro and true or false
        elseif ends_on_sample(items, lastw, sp.v) then pointer, strong = true, true end
      end
      -- the sample is in the text that follows in this field: its first line (always when the introducer names a sample of the voice, otherwise when it reads like an utterance),
      -- then more lines of the paragraph while they do; with nothing after it in this field, it is in the next record
      if pointer and not ex then
        local nz = after_idx + 1
        while items[nz] and items[nz].kind == "punct" do nz = nz + 1 end
        if items[nz] then
          local s0, e1 = take_sample(nz, strong)
          if s0 then ex = { kind = "example", s = s0, e = e1, text = U.trim(text:sub(s0, e1)), via = "after_introducer", spec = it, anti = sp.negated or nil } end
        else
          it.example_pending = { strong = strong and true or false }
        end
      end
    end
    if ex then
      add(ex)
      for y = 1, #items do if items[y].s >= ex.s and items[y].e <= ex.e then claimed[y] = true end end
    end
    it.example_follows = ex and true or nil
  end

  ---------------------------------------------------------------- imperative style directives: "Be dramatic.", "Stay calm and formal.", "Use lots of exclamation marks.", "Avoid caps."
  -- The verb is not a voice verb, so the evidence is the clause-initial imperative + a declared descriptor + whatever frames it ("Always", "Please", "You should").
  do
    local STYLE_IMP = set_of({ "be", "stay", "remain", "keep", "sound", "seem", "appear", "become", "use", "using", "include", "add", "employ", "sprinkle", "avoid", "drop", "skip", "omit",
      "stop", "refrain", "quit", "cease", "go", "make", "write", "speak", "talk", "no", "without" })
    -- what an imperative about the assistant's output points at: "keep IT chill", "make REPLIES funny", "keep YOUR answers short"
    local OUTPUT_OBJ = set_of({ "it", "answers", "answer", "replies", "reply", "responses", "response", "messages", "message", "text", "writing", "tone", "voice", "style", "language", "speech", "things", "everything" })
    local NEG_VERB = set_of({ "avoid", "skip", "omit", "drop", "stop", "refrain", "quit", "cease" })
    local LEAD = set_of({ "please", "always", "never", "also", "then", "and", "but", "just", "kindly", "do", "n't", "don't", "dont", "must", "should", "remember", "try", "ensure", "not", "now", "from" })
    for k, it in ipairs(items) do
      if it.kind == "word" and STYLE_IMP[it.form] and not claimed[k] then
        -- clause-initial: nothing before it in the clause except lead words
        local z, lead_n, ok = k - 1, 0, true
        local lead_words = {}
        while z >= 1 do
          local x = items[z]
          if x.kind == "punct" then
            if boundary_after(items, z) or x.role == "colon" or x.role == "semi" or x.role == "sent_end" then break end
            if x.role ~= "comma" then ok = false; break end
          elseif x.kind == "word" then
            if LEAD[x.form] and lead_n < 3 then lead_n = lead_n + 1; lead_words[#lead_words + 1] = x.form else ok = false; break end
          else ok = false; break end
          z = z - 1
        end
        -- a clause start after a line break counts too
        if ok then
          -- the clause after the verb, to the end of the sentence (at most 14 words)
          local last, nwords = k, 0
          while items[last + 1] and nwords < 14 do
            local x = items[last + 1]
            if x.kind == "punct" and (x.role == "sent_end" or x.role == "colon" or x.role == "semi") then break end
            if x.kind == "quote" then break end
            if x.kind == "word" then nwords = nwords + 1 end
            last = last + 1
          end
          local s0 = (lead_n > 0 and items[z + 1] or it).s
          local clause = text:sub(s0, items[last].e)
          local decl = Style.declared(clause)
          if #decl > 0 and not (nwords == 0) then
            local score, ev = 1.0, { "imperative(+1.0)" }
            score = score + 1.2; ev[#ev + 1] = "descriptor:" .. decl[1].term .. "(+1.2)"
            if lead_n > 0 then score = score + 1.0; ev[#ev + 1] = "lead:" .. table.concat(lead_words, " ") .. "(+1.0)" end
            if NEG_VERB[it.form] or it.form == "no" or it.form == "without" then ev[#ev + 1] = "negative verb" end
            -- the object is the assistant's output ("Keep it chill", "Make replies funny", "Keep your answers short")
            do
              local nx = items[k + 1]
              if nx and nx.kind == "word" and nx.form == "your" then nx = items[k + 2] end
              if nx and nx.kind == "word" and OUTPUT_OBJ[nx.form] then score = score + 0.8; ev[#ev + 1] = "object is the output(+0.8)" end
            end
            -- a whole sentence of a few words that is nothing but the directive ("Be formal.", "No emojis.")
            if nwords <= 3 and score < 3.0 then
              local after_last = items[last + 1]
              local ends_here = (after_last == nil) or (after_last.kind == "punct" and (after_last.role == "sent_end" or after_last.role == "colon")) or after_last.nl
              if ends_here then score = score + 0.8; ev[#ev + 1] = "short directive(+0.8)" end
            end
            if score >= 3.0 - bonus then
              local cues = behavior_cues_in(clause)
              add({ kind = "style_spec", s = s0, e = items[last].e, subject = nil, imperative = true, via = "imperative", score = score, evidence = ev,
                descriptors = decl, behavior_cues = cues, presentational = #cues == 0 })
              for y = z + 1, last do claimed[y] = true end
            end
          end
        end
      end
    end
  end

  ---------------------------------------------------------------- persona declarations
  -- (a)/(b) after the imperatives: a capitalised imperative verb ("Pretend to be ...") is not a name
  -- (a) "NAME is a/an/the [adjectives] KIND"    (b) "KIND called/named NAME"    (c) "You are / You're / Your name is X"    (d) "Act as / Pretend to be / Roleplay as X"
  for k, it in ipairs(items) do
    if it.kind == "word" and not claimed[k] then
      local f = it.form
      if COPULA[f] or f == "'s" then
        local subj = find_subject(items, k, lex)
        if subj and subj.idx >= k - 4 and (subj.kind == "name" or subj.kind == "placeholder" or subj.kind == "addressee") then
          local det_k = k + 1
          local det = items[det_k]
          if det and det.kind == "word" and (DETERMINERS[det.form]) then
            -- scan the noun phrase up to punctuation (max 8 words) for a persona-kind noun
            local kind_words, descr, z = {}, {}, det_k + 1
            local kind_found
            while z <= #items and z <= det_k + 8 do
              local x = items[z]
              if x.kind == "punct" and (x.role == "comma" and false or x.role == "sent_end" or x.role == "colon" or x.role == "semi") then break end
              if x.kind == "word" then
                if PERSONA_KIND[x.form] then
                  kind_found = x
                  -- compound ("AI model")
                  local zz = z
                  local parts = { x.text }
                  while items[zz + 1] and items[zz + 1].kind == "word" and (PERSONA_KIND[items[zz + 1].form] or PERSONA_KIND[x.form .. " " .. items[zz + 1].form]) do
                    zz = zz + 1; parts[#parts + 1] = items[zz].text; kind_found = items[zz]
                  end
                  kind_words = parts
                  z = zz
                  break
                else descr[#descr + 1] = x.form end
              end
              z = z + 1
            end
            if kind_found then
              local pk = table.concat(kind_words, " ")
              local strong = STRONG_KIND[pk:lower()] or false
              local stmt = { kind = "persona_declaration", s = subj.s, e = kind_found.e, subject = subj, persona_kind = pk, via = "copula", score = strong and 3 or 1.5,
                evidence = { "copula:" .. f, "kind:" .. pk .. (strong and "" or " (ordinary noun: needs corroboration)") }, adjectives = descr, weak = (not strong) or nil }
              stmt.descriptors = Style.declared(text:sub(items[det_k].s, kind_found.e))
              add(stmt)
              for y = subj.idx, z do claimed[y] = true end
            end
          end
        end
      end
      -- "an AI model called Aria", "a character named Bob"
      if (f == "called" or f == "named" or f == "dubbed") and not claimed[k] then
        local nm = items[k + 1]
        local pk_item
        for back = 1, 5 do
          local x = items[k - back]
          if x and x.kind == "word" and PERSONA_KIND[x.form] then pk_item = x; break end
          if x and x.kind == "punct" and x.role == "sent_end" then break end
        end
        if pk_item and nm and (nm.kind == "placeholder" or (nm.kind == "word" and nm.cap)) then
          local parts = { nm.text }
          local last = nm
          local z = k + 2
          while items[z] and items[z].kind == "word" and items[z].cap and not items[z].nl and name_candidate(items[z], lex) do parts[#parts + 1] = items[z].text; last = items[z]; z = z + 1 end
          local subj = nm.kind == "placeholder" and { kind = "placeholder", text = nm.text, form = nm.form, s = nm.s, e = nm.e }
            or { kind = "name", text = table.concat(parts, " "), form = table.concat(parts, " "):lower(), s = nm.s, e = last.e }
          -- the words in front of the kind noun belong to the description: "a sarcastic, world-weary robot called Zed"
          local from_s = pk_item.s
          for back = 1, 7 do
            local x = items[k - back]
            if not x or (x.kind == "punct" and x.role == "sent_end") or (x.kind == "word" and x.nl) then break end
            if x.kind == "word" then from_s = x.s end
          end
          add({ kind = "persona_declaration", s = pk_item.s, e = last.e, subject = subj, persona_kind = pk_item.text, via = "called", score = 3, evidence = { "kind:" .. pk_item.text, "called" },
            descriptors = Style.declared(text:sub(from_s, pk_item.e)) })
          for y = k, z - 1 do claimed[y] = true end
        end
      end
    end
  end
  ---------------------------------------------------------------- descriptor-anchored: "She never shouts.", "The bot is friendly.", "Aria loves emojis."
  do
    local HABIT = set_of({ "never", "always", "usually", "often", "loves", "love", "likes", "like", "prefers", "prefer", "tends", "tend", "mostly", "typically", "rarely", "sometimes", "constantly", "uses", "use",
      "adores", "adore", "enjoys", "enjoy", "insists", "insist", "keeps", "keep" })
    local PAD = set_of({ "in", "a", "an", "the", "really", "very", "so", "such", "quite", "rather", "pretty", "bit", "of", "total", "totally", "absolutely", "completely", "just", "kind", "sort",
      "little", "super", "extremely", "truly", "big", "real", "utter", "complete", "huge", "way", "too", "all" })
    local k = 1
    while k <= #items do
      local it = items[k]
      if it.kind == "word" and not claimed[k] then
        local ws = {}
        for z = k, math.min(#items, k + 3) do if items[z].kind == "word" then ws[#ws + 1] = items[z].form else break end end
        local len, id, term = Style.declared_match(ws, 1)
        local inside = false
        for _, o in ipairs(out) do if (o.kind == "style_spec" or o.kind == "persona_declaration") and it.s >= o.s and it.s <= o.e then inside = true end end
        if len and not inside then
          local subj = tone_subject(items, k) or find_subject(items, k, lex)
          if subj and subj.idx >= k - 8 then
            local score, ev = 1.5, { "subject:" .. subj.kind .. "(+1.5)" }
            local frame
            for z = math.max(1, k - 3), k - 1 do
              local x = items[z]
              if x.kind == "word" then
                if COPULA[x.form] and not frame then frame = "copula"; score = score + 0.5; ev[#ev + 1] = "copula(+0.5)" end
                if HABIT[x.form] then frame = x.form; score = score + 1.0; ev[#ev + 1] = "habit:" .. x.form .. "(+1.0)" break end
              end
            end
            -- "the bot is IN A REALLY good mood", "the bot is A BIT OF A grump": filler words between the copula and the descriptor
            if not frame then
              for z = math.max(1, k - 6), k - 4 do
                local x = items[z]
                if x and x.kind == "word" and COPULA[x.form] then
                  local filler_only = true
                  for y = z + 1, k - 1 do
                    local w = items[y]
                    if not (w.kind == "word" and PAD[w.form]) then filler_only = false; break end
                  end
                  if filler_only then frame = "copula"; score = score + 0.5; ev[#ev + 1] = "copula(+0.5)"; break end
                end
              end
            end
            score = score + 1.2; ev[#ev + 1] = "descriptor:" .. term .. "(+1.2)"
            if score >= 3.0 - bonus then
              -- the clause: from the subject to the end of the sentence
              local last = k + len - 1
              while items[last + 1] and not (items[last + 1].kind == "punct" and (items[last + 1].role == "sent_end" or items[last + 1].role == "colon")) and items[last + 1].kind ~= "quote" and last - k < 14
                and not (items[last + 1].kind == "word" and intro_at(items, last + 1)) do last = last + 1 end
              local clause = text:sub(items[subj.idx].s, items[last].e)
              local cues = behavior_cues_in(clause)
              add({ kind = "style_spec", s = items[subj.idx].s, e = items[last].e, subject = subj, score = score, evidence = ev, via = "descriptor",
                descriptors = Style.declared(clause), behavior_cues = cues, presentational = #cues == 0 })
              for z = subj.idx, last do claimed[z] = true end
              k = last
            end
          end
        end
      end
      k = k + 1
    end
  end

  ---------------------------------------------------------------- first-person introductions: "I am Aria, your wildly dramatic assistant", "My name is Zed", "Call me Nova"
  -- weak by construction (a person introducing themselves is not a persona): it counts only with a style statement or an example of the same persona
  for k, it in ipairs(items) do
    if it.kind == "word" and not claimed[k] then
      local nm, from_k
      local f1, f2 = it.form, items[k + 1] and items[k + 1].form
      if (f1 == "i" and (f2 == "am" or f2 == "'m")) or f1 == "i'm" or f1 == "im" then from_k = (f1 == "i") and (k + 2) or (k + 1)
      elseif f1 == "my" and f2 == "name" and items[k + 2] and COPULA[items[k + 2].form] then from_k = k + 3
      elseif f1 == "call" and f2 == "me" then from_k = k + 2
      elseif f1 == "this" and f2 == "is" then from_k = k + 2 end
      local cand = from_k and items[from_k]
      if cand and cand.kind == "word" and cand.cap and not cand.nl and name_candidate(cand, lex) and not cand.allcaps then
        local parts, last, z = { cand.text }, cand, from_k + 1
        while items[z] and items[z].kind == "word" and items[z].cap and not items[z].nl and name_candidate(items[z], lex) and not items[z].allcaps do parts[#parts + 1] = items[z].text; last = items[z]; z = z + 1 end
        -- the rest of the sentence after the name describes the speaker: "..., your wildly dramatic assistant"
        local e_item = z - 1
        while items[e_item + 1] and not (items[e_item + 1].kind == "punct" and items[e_item + 1].role == "sent_end") and items[e_item + 1].kind ~= "quote" and e_item - z < 12 do e_item = e_item + 1 end
        local clause = text:sub(items[z] and items[z].s or last.e, items[e_item].e)
        local kind_found
        for y = z, e_item do if items[y].kind == "word" and PERSONA_KIND[items[y].form] then kind_found = items[y].text end end
        -- "I am Aria, an AI model" / "I'm Sunny, your friendly helper" / "I am Aria, a cheerful wizard": a machine kind, "your <kind>", or a kind together with a declared descriptor
        -- is an assistant introducing itself, not a person
        local decl = Style.declared(clause)
        local strong_intro, why = false, nil
        for y = z, e_item do
          local x = items[y]
          if x.kind == "word" then
            if MACHINE_KIND[x.form] then strong_intro, why = true, "machine kind" end
            if x.form == "your" and not strong_intro then
              for w = y + 1, math.min(y + 3, e_item) do
                if items[w].kind == "word" and PERSONA_KIND[items[w].form] then strong_intro, why = true, "'your' + kind" end
              end
            end
          end
        end
        if not strong_intro and kind_found and #decl > 0 then strong_intro, why = true, "kind + declared descriptor" end
        add({ kind = "persona_declaration", s = it.s, e = last.e, subject = { kind = "name", text = table.concat(parts, " "), form = table.concat(parts, " "):lower(), s = cand.s, e = last.e },
          persona_kind = kind_found, via = "self_introduction", score = strong_intro and 3 or 2, evidence = { "first-person introduction" .. (why and (" + " .. why) or "") }, weak = (not strong_intro) or nil, descriptors = decl })
        for y = k, z - 1 do claimed[y] = true end
      end
    end
  end

  ---------------------------------------------------------------- "the bot's name is Zed", "assistant Luna", "our mascot, Pip,"
  for k, it in ipairs(items) do
    if it.kind == "word" and not claimed[k] then
      if it.form == "name" and items[k + 1] and items[k + 1].kind == "word" and COPULA[items[k + 1].form] then
        local nm = items[k + 2]
        local near_kind
        for back = 1, 4 do
          local x = items[k - back]
          if x and x.kind == "word" and (PERSONA_KIND[x.form] or x.form == "bot's" or x.form == "assistant's") then near_kind = x; break end
          if x and x.kind == "punct" and boundary_after(items, k - back) then break end
        end
        if near_kind and nm and (nm.kind == "placeholder" or (nm.kind == "word" and nm.cap)) then
          local parts, last, z = { nm.text }, nm, k + 3
          while nm.kind == "word" and items[z] and items[z].kind == "word" and items[z].cap and name_candidate(items[z], lex) and not items[z].nl do parts[#parts + 1] = items[z].text; last = items[z]; z = z + 1 end
          local subj = nm.kind == "placeholder" and { kind = "placeholder", text = nm.text, form = nm.form, s = nm.s, e = nm.e }
            or { kind = "name", text = table.concat(parts, " "), form = table.concat(parts, " "):lower(), s = nm.s, e = last.e }
          add({ kind = "persona_declaration", s = near_kind.s, e = last.e, subject = subj, persona_kind = (near_kind.text:gsub("'s$", "")), via = "name_is", score = 3, evidence = { "name is" } })
          for y = k, z - 1 do claimed[y] = true end
        end
      elseif STRONG_KIND[it.form] and items[k + 1] and items[k + 1].kind == "word" and items[k + 1].cap and name_candidate(items[k + 1], lex) and not items[k + 1].nl
        and not (items[k + 2] and items[k + 2].kind == "word" and COPULA[items[k + 2].form] and false) then
        -- "assistant Luna": the kind noun directly followed by a name
        local first = items[k + 1]
        local parts, last, z = { first.text }, first, k + 2
        while items[z] and items[z].kind == "word" and items[z].cap and name_candidate(items[z], lex) and not items[z].nl do parts[#parts + 1] = items[z].text; last = items[z]; z = z + 1 end
        add({ kind = "persona_declaration", s = it.s, e = last.e, subject = { kind = "name", text = table.concat(parts, " "), form = table.concat(parts, " "):lower(), s = first.s, e = last.e },
          persona_kind = it.text, via = "kind_name", score = 2.5, evidence = { "kind:" .. it.text .. " + name" }, weak = true })
        for y = k, z - 1 do claimed[y] = true end
      end
    end
  end

  ---------------------------------------------------------------- labelled lines: "Tone: ...", "Name: ...", "Persona: ...", "Example: ..." (several labels may share a line)
  do
    local IDENTITY_LABEL = set_of({ "persona", "character", "role", "role play", "roleplay", "bot", "assistant", "ai", "agent", "description", "bio", "backstory", "about", "char persona", "char_persona", "personality summary" })
    local function norm_label(l) return (l:lower():gsub("[%-_]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")) end
    local function known_label(l)
      if STYLE_LABEL[l] or NAME_LABEL[l] or EXAMPLE_LABEL[l] or IDENTITY_LABEL[l] then return true end
      -- "NPC name:", "Bot name:", "Main character name:" -- any label whose last word is "name"
      return l:match("^[%a%s]+ name$") ~= nil and #l <= 30
    end
    local function strip_quotes(v)
      local q = v:match('^["“«](.-)["”»]$')
      return q or v
    end
    local lines = {}
    do
      local pos = 1
      while pos <= #text do
        local le = (text:find("\n", pos, true) or (#text + 1)) - 1
        -- markdown emphasis around a label ("**Tone:** sarcastic", "*Persona*: Zed") is blanked out with spaces, so offsets stay the same
        local raw = text:sub(pos, le)
        local clean = raw:gsub("%*%*", "  "):gsub("__", "  "):gsub("%*([%w][%w ]-)%*", function(w) return " " .. w .. " " end)
        lines[#lines + 1] = { s = pos, e = le, line = clean }
        pos = le + 2
      end
    end
    local li = 1
    while li <= #lines do
      local L0 = lines[li]
      local line = L0.line
      -- candidate label starts
      local starts = { 1 }
      for st in line:gmatch("[%.;!?]%s+()") do starts[#starts + 1] = st end
      local segs = {}
      for _, st in ipairs(starts) do
        local body_st = line:match("^%s*()", st) or st
        local bullet = line:match("^[%-%*•]%s*()", body_st)
        if bullet then body_st = bullet end
        local lab, vstart = line:match("^([%a][%a%-_ /]-)%s*:%s*()", body_st)
        -- "tone = sarcastic"
        if not lab then lab, vstart = line:match("^([%a][%a%-_ /]-)%s*=%s*()", body_st) end
        if lab and #lab <= 30 then
          local nl = norm_label(lab)
          if known_label(nl) then segs[#segs + 1] = { label = nl, from = st, vs = vstart } end
        end
      end
      local consumed_next = 0
      for si, sg in ipairs(segs) do
        local ve = (segs[si + 1] and (segs[si + 1].from - 1)) or #line
        -- a name label ends with its sentence ("Name: Echo. Echo whispers ..."): the rest of the line is another statement
        if NAME_LABEL[sg.label] or sg.label:match(" name$") then
          local cut = line:sub(sg.vs, ve):find("[%.;!?]%s")
          if cut then ve = sg.vs + cut - 2 end
        end
        local value = U.trim(line:sub(sg.vs, ve))
        local abs_s = L0.s + sg.vs - 1
        local abs_e = L0.s + ve - 1
        local overlaps = false
        for _, o in ipairs(out) do if o.kind ~= "example" and o.s <= abs_e and o.e >= L0.s + sg.from - 1 then overlaps = true end end
        if not overlaps then
          local lab = sg.label
          if EXAMPLE_LABEL[lab] then
            if value ~= "" then
              add({ kind = "example", s = abs_s, e = abs_e, text = strip_quotes(value:gsub("[%s]+$", "")), via = "label", label = lab })
            else
              -- "Examples:" with the examples on the following lines (bullets, numbers, quotations) up to a blank line or the next label
              local lj = li + 1
              while lines[lj] and lines[lj].line:match("%S") do
                local nxt = lines[lj].line
                local nl = nxt:match("^%s*[%-%*•]?%s*([%a][%a%-_ /]-)%s*[:=]")
                if nl and known_label(norm_label(nl)) then break end
                local body = nxt:gsub("^%s*[%-%*•]%s*", ""):gsub("^%s*%d+[%.%)]%s*", "")
                body = U.trim(body)
                if body ~= "" then
                  local off = nxt:find(body:sub(1, 1), 1, true) or 1
                  add({ kind = "example", s = lines[lj].s + off - 1, e = lines[lj].e, text = strip_quotes(body), via = "label_list", label = lab })
                end
                consumed_next = lj - li
                lj = lj + 1
              end
            end
          elseif value == "" and (STYLE_LABEL[lab] or IDENTITY_LABEL[lab]) then
            -- "Style:" with the descriptors on the following lines (bullets, numbers or indented): the lines are the value
            local lj, parts, last_e = li + 1, {}, nil
            while lines[lj] and lines[lj].line:match("%S") do
              local nxt = lines[lj].line
              local nl = nxt:match("^%s*[%-%*•]?%s*([%a][%a%-_ /]-)%s*[:=]")
              if nl and known_label(norm_label(nl)) then break end
              local body = U.trim(nxt:gsub("^%s*[%-%*•]%s*", ""):gsub("^%s*%d+[%.%)]%s*", ""))
              if body ~= "" then parts[#parts + 1] = body; last_e = lines[lj].e end
              consumed_next = lj - li
              lj = lj + 1
            end
            if #parts > 0 then
              local joined = table.concat(parts, ", ")
              local cues = behavior_cues_in(joined)
              if IDENTITY_LABEL[lab] and not STYLE_LABEL[lab] then
                add({ kind = "persona_declaration", s = L0.s + sg.from - 1, e = last_e, subject = { kind = "generic", text = joined, form = joined:lower(), s = abs_s, e = last_e }, via = "label", label = lab,
                  score = 3, evidence = { "label:" .. lab }, descriptors = Style.declared(joined), behavior_cues = cues, presentational = #cues == 0 })
              else
                add({ kind = "style_spec", s = L0.s + sg.from - 1, e = last_e, via = "label", label = lab, value = joined, descriptors = Style.declared(joined), score = 3,
                  evidence = { "label:" .. lab }, behavior_cues = cues, presentational = #cues == 0 })
              end
            end
          elseif value ~= "" then
            if IDENTITY_LABEL[lab] and (bonus >= 0.8 or not (lab == "description" or lab == "bio" or lab == "about" or lab == "backstory")) then
              local ph = P.placeholders(value)[1]
              local subj, kind_found
              local wordsv = {}
              for w in value:gmatch("[%a][%a'’%-]*") do wordsv[#wordsv + 1] = w end
              for _, w in ipairs(wordsv) do if STRONG_KIND[w:lower()] and not kind_found then kind_found = w end end
              if ph then subj = { kind = "placeholder", text = ph.inner, form = ph.inner:lower(), s = abs_s, e = abs_e }
              else
                local nm = value:match("^([%u][%w'’%-]*[%w]?)")
                if nm and not FUNCTION[nm:lower()] and not PERSONA_KIND[nm:lower()] then
                  local full = value:match("^([%u][%w'’%-]*%s[%u][%w'’%-]*)") or nm
                  subj = { kind = "name", text = full, form = full:lower(), s = abs_s, e = abs_s + #full - 1 }
                else subj = { kind = "generic", text = value, form = value:lower(), s = abs_s, e = abs_e } end
              end
              local cues = behavior_cues_in(value)
              add({ kind = "persona_declaration", s = L0.s + sg.from - 1, e = abs_e, subject = subj, persona_kind = kind_found, via = "label", label = lab, score = 3,
                evidence = { "label:" .. lab }, descriptors = Style.declared(value), behavior_cues = cues, presentational = #cues == 0 })
            elseif NAME_LABEL[lab] or lab:match(" name$") then
              -- a name ends where its sentence ends ("Name: Echo. Echo whispers ...")
              local nm = value:match("^(.-)[%.;!?]%s") or value
              nm = nm:gsub("[%.%,;]+$", "")
              local subj
              local ph = P.placeholders(nm)[1]
              if ph then subj = { kind = "placeholder", text = ph.inner, form = ph.inner:lower(), s = abs_s, e = abs_e }
              else subj = { kind = "name", text = nm, form = nm:lower(), s = abs_s, e = abs_e } end
              add({ kind = "persona_declaration", s = L0.s + sg.from - 1, e = abs_e, subject = subj, via = "label", label = lab, score = 3, evidence = { "label:" .. lab } })
            elseif STYLE_LABEL[lab] then
              local cues = behavior_cues_in(value)
              add({ kind = "style_spec", s = L0.s + sg.from - 1, e = abs_e, via = "label", label = lab, value = value, descriptors = Style.declared(value), score = 3,
                evidence = { "label:" .. lab }, behavior_cues = cues, presentational = #cues == 0 })
            end
          end
        end
      end
      li = li + 1 + consumed_next
    end
  end

  ---------------------------------------------------------------- examples introduced without a voice verb: 'for example "...",  e.g. "..."'
  for k, it in ipairs(items) do
    if it.kind == "word" and not claimed[k] then
      local len, last_k = intro_at(items, k)
      if len and items[last_k + 1] then
        -- a quotation (possibly after a colon / dash) right after the introducer
        local z = last_k + 1
        while items[z] and items[z].kind == "punct" and (items[z].role == "colon" or items[z].role == "dash" or items[z].role == "comma") do z = z + 1 end
        local free_text = items[z] and items[z].kind ~= "quote" and items[z].kind ~= "punct" and items[z] ~= nil and z > last_k + 1 and not claimed[z]
        if free_text then
          local near = false
          for _, o in ipairs(out) do if (o.kind == "style_spec" or o.kind == "persona_declaration") and o.e <= it.s and it.s - o.e < 400 then near = true end end
          if near then
            local es, ee = items[z].s, items[#items].e
            for y = z + 1, #items do if items[y].nl and items[y].nl >= 2 then ee = items[y - 1].e; break end end
            local body = U.trim(text:sub(es, ee))
            if body ~= "" then add({ kind = "example", s = es, e = ee, text = body, via = "free_text_after_intro", intro = items[k].form }) end
            for y = z, #items do claimed[y] = true; if items[y].e >= ee then break end end
          end
        end
        if items[z] and items[z].kind == "quote" and not claimed[z] then
          -- attach only when a style statement or a persona declaration is in reach before it
          local near = false
          for _, o in ipairs(out) do if (o.kind == "style_spec" or o.kind == "persona_declaration") and o.e <= it.s and it.s - o.e < 400 then near = true end end
          if near then
            local q = items[z]
            add({ kind = "example", s = q.inner_s or q.s, e = q.inner_e or q.e, text = q.text, via = "quote_after_intro", intro = items[k].form })
            claimed[z] = true
          end
        end
      end
    end
  end

  ---------------------------------------------------------------- behaviour directives (never presentational)
  -- an imperative / second-person / deontic clause carrying a behaviour cue that is not already part of a presentational statement
  do
    local sentences = an.sentences
    for _, sen in ipairs(sentences) do
      local overlaps = false
      for _, o in ipairs(out) do
        if (o.kind == "style_spec" or o.kind == "persona_declaration" or o.kind == "example") and o.s <= sen.e and o.e >= sen.s and o.presentational ~= false then overlaps = true end
      end
      if not overlaps then
        local st = text:sub(sen.s, sen.e)
        local cues = behavior_cues_in(st)
        if #cues > 0 then
          local directive = st:lower():find("%f[%a]you%f[%A]") or st:lower():find("%f[%a]your%f[%A]") or st:lower():find("^%s*[%a']+%s") ~= nil
          if directive then add({ kind = "behavior_directive", s = sen.s, e = sen.e, cues = cues, text = st }) end
        end
      end
    end
  end

  table.sort(out, function(a, b) if a.s ~= b.s then return a.s < b.s end return a.e < b.e end)
  -- one example found by two routes (a labelled line and its quotation) is one example
  local dedup, last_ex = {}, nil
  for _, o in ipairs(out) do
    if o.kind == "example" and last_ex and o.s <= last_ex.e and o.e >= last_ex.s then
      -- keep the one without the quotation marks (the narrower)
      if (o.e - o.s) < (last_ex.e - last_ex.s) then dedup[#dedup] = o; last_ex = o end
    else
      dedup[#dedup + 1] = o
      last_ex = (o.kind == "example") and o or nil
    end
  end
  res.items = dedup
  res.an = an
  return res
end

return P
