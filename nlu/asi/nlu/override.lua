-- asi.nlu.override: what the user says about HOW the dataset should be read and HOW the assistant should sound.
--   Override.parse(text, ctx) -> { items = { { kind, ops, label, s, e, evidence } ... } }
-- Kinds:   tone          adjust the tone the dataset gave the persona   ("use a calmer tone", "no caps", "less dramatic", "be more formal", "tone it down", "speak normally")
--          persona       choose / drop / rename the persona             ("ignore the personality", "play Bob instead", "her name is Zed")
--          dataset_role  re-read the dataset                            ("treat the dataset as facts", "the examples are facts too", "ignore the second paragraph")
--          query_tone    "what tone will you use?"                      query_reading  "how did you read the dataset?"
-- ops are short strings ("drop:all_caps", "persona:off", "dataset:include:style_example") that asi.nlu.voice and asi.nlu.knowledge apply.  The recogniser is built from
-- word classes (verbs of treating / ignoring / using, role nouns, descriptors, negators, degree words) and the clause structure around them, not from whole sentences.
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Style = require("asi.nlu.style")
local L = require("asi.nlu.data.style_lex")

local O = {}
O.SCHEMA = "nlu.override/1"

local function set_of(list) local s = {}; for _, w in ipairs(list) do s[w] = true end return s end
local PH = Style.phrase_index
local match_at = Style.match_at

local IDX = {
  tone_down = PH(L.tone_down), tone_up = PH(L.tone_up), neutral = PH(L.tone_neutral), reset = PH(L.tone_reset),
  query_tone = PH(L.query_tone), query_reading = PH(L.query_reading),
  dataset_nouns = PH(L.dataset_nouns), fact_classes = PH(L.fact_classes), persona_nouns = PH(L.persona_nouns), tone_nouns = PH(L.tone_nouns),
}
local ROLE_IDX = {}      -- first word -> list of { words, role }
do
  local phr, owner = {}, {}
  for role, list in pairs(L.role_nouns) do
    for _, p in ipairs(list) do phr[#phr + 1] = p; owner[p:lower():gsub("[%-_]", " ")] = role end
  end
  ROLE_IDX.idx = PH(phr)
  ROLE_IDX.owner = owner
end

local TREAT = set_of({ "treat", "read", "interpret", "take", "regard", "consider", "see", "handle", "parse", "process", "count", "view", "understand", "classify", "label", "mark", "use", "accept", "trust" })
local IGNORE = set_of({ "ignore", "skip", "drop", "disregard", "forget", "exclude", "discard", "omit", "remove", "delete", "cut", "bypass", "stop", "quit", "cease", "lose", "ditch", "kill", "disable", "nix", "eliminate",
  "avoid", "refrain", "abandon", "dismiss", "leave" })
local USE = set_of({ "use", "add", "include", "enable", "keep", "restore", "apply", "adopt", "employ", "try", "start", "resume", "bring", "go", "stick", "switch", "play", "be", "act", "become", "sound", "talk", "speak", "write",
  "respond", "reply", "answer", "make", "take", "channel", "do", "put", "turn", "pretend", "impersonate", "imitate", "mimic", "roleplay" })
local NEG_FULL = set_of({ "not", "no", "never", "without", "don't", "doesn't", "didn't", "won't", "can't", "cannot", "stop", "drop", "remove", "lose", "cut", "skip", "avoid", "ignore", "disable", "ditch", "quit", "cease",
  "forget", "nix", "kill", "eliminate", "delete", "n't", "off" })
local NEG_LESS = set_of({ "less", "fewer", "reduce", "lower", "decrease", "minimise", "minimize", "soften", "tone", "reduced", "toned" })
local MORE = set_of({ "more", "extra", "very", "super", "increase", "boost", "amplify", "heighten", "double", "much", "way", "even", "further", "bigger", "greater", "really", "totally", "extremely" })
local COPULA = set_of({ "is", "are", "was", "were", "be", "'s", "'re", "count", "counts", "should", "can", "could", "may", "might", "remain", "stay", "keep", "also" })
local AS = set_of({ "as", "like", "for", "into" })
local FILLER = set_of({ "the", "a", "an", "this", "that", "these", "those", "my", "our", "your", "its", "their", "his", "her", "any", "all", "of", "to", "in", "from", "on", "at", "with", "please", "just", "only", "simply", "really", "actually", "also", "too", "again", "now", "then", "so", "and", "or", "it", "me", "us", "you", "i", "we", "let", "lets", "let's", "can", "could", "would", "will", "kindly", "instead", "rather", "from", "now", "forward", "going", "onward", "onwards", "henceforth" })

---------------------------------------------------------------- tokens
-- units of the lexer -> words (clitic n't glued to its stem), with the original text and the byte span of each word
local function words_of(text)
  local an = Lex.analyze(text, {})
  local ws = {}
  for _, u in ipairs(an.units or {}) do
    if u.kind == "word" or u.kind == "number" or u.kind == "abbrev" or u.kind == "acronym" then
      local f = (u.form or ""):lower():gsub("’", "'")
      local orig = text:sub(u.s, u.e)
      if f == "n't" and #ws > 0 and ws[#ws].sent == u.sent then
        ws[#ws].w = ws[#ws].w .. "n't"; ws[#ws].e = u.e      -- do + n't = don't, ca + n't = can't, wo + n't = won't
      elseif f == "cannot" then ws[#ws + 1] = { w = "cannot", orig = orig, s = u.s, e = u.e, sent = u.sent }
      else ws[#ws + 1] = { w = f, orig = orig, s = u.s, e = u.e, sent = u.sent, cap = u.cap, number = u.numval } end
    elseif u.kind == "punct" and (u.text == ";" or u.role == "semi") then
      ws[#ws + 1] = { w = ";", orig = ";", s = u.s, e = u.e, sent = u.sent, punct = true }
    elseif u.kind == "punct" and (u.text == "," ) then
      ws[#ws + 1] = { w = ",", orig = ",", s = u.s, e = u.e, sent = u.sent, punct = true }
    end
  end
  return ws, an
end
O.words_of = words_of

local function wlist(ws, a, b)
  local out = {}
  for i = a or 1, b or #ws do out[#out + 1] = ws[i].w end
  return out
end

-- the longest phrase of idx that starts at or after `from`; returns start, length, phrase
local function find(idx, forms, from, to)
  for i = from or 1, to or #forms do
    local len, ph = match_at(idx, forms, i)
    if len and (not to or i + len - 1 <= to) then return i, len, ph end
  end
end

---------------------------------------------------------------- clause splitting
local CLAUSE_START = set_of({ "use", "drop", "stop", "no", "be", "make", "keep", "turn", "ignore", "treat", "don't", "do", "avoid", "add", "switch", "play", "act", "speak", "talk", "sound", "write", "answer", "respond",
  "reply", "lose", "cut", "skip", "remove", "less", "more", "read", "interpret", "count", "consider", "take", "call", "name", "go", "stick", "pretend", "never", "always", "please", "just" })
local function clauses_of(ws)
  local out, cur = {}, {}
  local function flush() if #cur > 0 then out[#out + 1] = cur; cur = {} end end
  for i, x in ipairs(ws) do
    local split = false
    if x.punct and x.w == ";" then split = true
    elseif x.w == "but" or x.w == "then" or x.w == "though" or x.w == "except" or x.w == "however" or x.w == "while" then split = true
    elseif (x.w == "and" or x.w == ",") and ws[i + 1] and CLAUSE_START[ws[i + 1].w] and #cur >= 2 then split = true end
    if split then
      flush()
      if x.w == "and" then cur = {} end
    elseif not x.punct then cur[#cur + 1] = x end
  end
  flush()
  return out
end

---------------------------------------------------------------- descriptors and degree
local function neg_kind(forms, i, lo)
  -- "full" removal ("no caps", "drop the exclamation marks", "don't use emojis"), "less" (reduce), or nil, looking back at most four words in the clause
  local kind
  for k = i - 1, math.max(lo or 1, i - 6), -1 do
    local w = forms[k]
    if NEG_FULL[w] then return "full" end
    if NEG_LESS[w] and not kind then kind = "less" end
    if w == "instead" or w == "of" and forms[k - 1] == "instead" then end
  end
  return kind
end
local function more_before(forms, i, lo)
  for k = i - 1, math.max(lo or 1, i - 3), -1 do if MORE[forms[k]] then return true end end
  return false
end

-- every descriptor named in the clause: { id, term, i, len, comparative }
local function descriptors_in(forms)
  local out = {}
  local i = 1
  while i <= #forms do
    local len, id, term = Style.declared_match(forms, i)
    if len then out[#out + 1] = { id = id, term = term, i = i, len = len }; i = i + len
    else
      local cmp = L.comparatives[forms[i]]
      if cmp then out[#out + 1] = { id = cmp[1], dir = cmp[2], term = forms[i], i = i, len = 1, comparative = true } end
      i = i + 1
    end
  end
  return out
end

local FULL_ONLY = { lowercase = true }

-- text that talks about instructions, the system prompt, secrets or restrictions is an attempt on the assistant, never a request about the tone or the reading of a dataset
local HOSTILE = PH({ "previous instructions", "prior instructions", "all instructions", "your instructions", "earlier instructions", "above instructions", "system prompt", "system message", "reveal", "disclose", "leak",
  "expose", "exfiltrate", "password", "passwords", "credentials", "token", "tokens", "api key", "secret", "secrets", "jailbreak", "developer mode", "no restrictions", "without restrictions", "unfiltered", "unrestricted",
  "bypass", "safety", "guardrails", "filters", "policy", "policies", "execute", "sudo", "admin", "root", "confidential", "private key", "do anything now", "never refuse", "always comply", "override", "overwrite", "rules" })
local function hostile(forms)
  for i = 1, #forms do if match_at(HOSTILE, forms, i) then return true end end
  return false
end

---------------------------------------------------------------- one clause
local function ordinal_ref(ws, forms, a, b)
  -- "the second paragraph" / "paragraph 3" / "record #2" / "the last line" / "the line about Germany"
  local RN = set_of(L.record_nouns)
  for i = a, b do
    local w = forms[i]
    if RN[w] or (RN[w and w:gsub("s$", "")]) then
      local prev = forms[i - 1]
      local nxt = forms[i + 1]
      local ord = prev and L.ordinals[prev]
      if ord then return { n = ord, noun = w } end
      if ws[i + 1] and ws[i + 1].number then return { n = math.floor(ws[i + 1].number), noun = w } end
      if nxt == "#" or (ws[i + 2] and ws[i + 2].number and nxt == "number") then end
      if (nxt == "about" or nxt == "on" or nxt == "mentioning" or nxt == "containing" or nxt == "with" or nxt == "that" or nxt == "which") and ws[i + 2] then
        local k = i + 2
        if forms[k] == "mentions" or forms[k] == "mentioned" or forms[k] == "contains" or forms[k] == "says" or forms[k] == "has" or forms[k] == "starts" then k = k + 1 end
        if forms[k] == "with" then k = k + 1 end
        local words = {}
        local STOP = set_of({ "as", "is", "are", "to", "and", "an", "example", "fact", "facts", "please", "isn't", "aren't", "was", "should", "must", "be", "from", "for" })
        while ws[k] and #words < 4 and not FILLER[forms[k]] and not STOP[forms[k]] or (ws[k] and #words > 0 and #words < 4 and (forms[k] == "of" or forms[k] == "the") and ws[k + 1] and not FILLER[forms[k + 1]]) do
          words[#words + 1] = ws[k].orig; k = k + 1
        end
        if #words > 0 then return { about = table.concat(words, " "), noun = w } end
      end
    end
  end
end

local function role_in(forms, a, b)
  for i = a, b do
    local len, ph = match_at(ROLE_IDX.idx, forms, i)
    if len then
      local key = table.concat(ph, " ")
      return ROLE_IDX.owner[key], i, len
    end
  end
end

local function parse_clause(cl, ctx, whole_forms)
  local forms = wlist(cl)
  local n = #forms
  local ops, ev = {}, {}
  local function op(o, why) ops[#ops + 1] = o; ev[#ev + 1] = why end
  if n == 0 then return ops, ev end
  local lead = forms[1]

  -- neutral / reset / tone up and down -----------------------------------------------------------------------------------
  do
    local i, len, ph = find(IDX.neutral, forms)
    if i then
      op("tone:neutral", "phrase '" .. table.concat(ph, " ") .. "'")
      local text = table.concat(ph, " ")
      if text:find("persona") or text:find("personality") or text:find("character") or text:find("act") then op("persona:off", "phrase '" .. text .. "'") end
      return ops, ev
    end
    i, len, ph = find(IDX.reset, forms)
    if i then
      local negated = NEG_FULL[forms[1]] or (forms[1] == "do" and (forms[2] == "not" or forms[2] == "n't"))
      for k = 1, i - 1 do if IGNORE[forms[k]] or NEG_FULL[forms[k]] then negated = true end end
      if negated then
        -- "don't use the tone from the dataset" / "forget the dataset's tone": the opposite of a reset
        op("persona:off", "negated '" .. table.concat(ph, " ") .. "'"); op("tone:neutral", "negated '" .. table.concat(ph, " ") .. "'")
      else
        op("tone:reset", "phrase '" .. table.concat(ph, " ") .. "'"); op("persona:on", "phrase '" .. table.concat(ph, " ") .. "'")
      end
      return ops, ev
    end
    i, len, ph = find(IDX.tone_down, forms)
    if i and not (forms[1] == "tone" and forms[2] == "of") then
      for _, id in ipairs(L.tone_down_ids) do op("less:" .. id, "phrase '" .. table.concat(ph, " ") .. "'") end
      return ops, ev
    end
    i, len, ph = find(IDX.tone_up, forms)
    if i then op("more:dramatic", "phrase '" .. table.concat(ph, " ") .. "'"); op("more:exclamatory", "phrase '" .. table.concat(ph, " ") .. "'"); return ops, ev end
  end

  -- the parts of the dataset ----------------------------------------------------------------------------------------------
  local role, ri, rlen = role_in(forms, 1, n)
  local dslen, dsi
  for i = 1, n do
    local l = match_at(IDX.dataset_nouns, forms, i)
    if l and not (forms[i] == "it" and false) then dsi, dslen = i, l; break end
  end
  local rec = ordinal_ref(cl, forms, 1, n)
  local treat_i, ignore_i, as_i
  for i = 1, n do
    if TREAT[forms[i]] and not treat_i then treat_i = i end
    if IGNORE[forms[i]] and not ignore_i then ignore_i = i end
  end
  local fact_i, fact_len
  for i = (treat_i or 1), n do
    local l = match_at(IDX.fact_classes, forms, i)
    if l then fact_i, fact_len = i, l; break end
  end
  for i = (treat_i or 0) + 1, n do if AS[forms[i]] and not as_i and (not fact_i or i < fact_i) then as_i = i end end
  local example_class = false
  for i = (as_i or n + 1), n do
    if forms[i] == "example" or forms[i] == "examples" or forms[i] == "sample" or forms[i] == "samples" then example_class = true end
  end
  local persona_i
  for i = 1, n do if match_at(IDX.persona_nouns, forms, i) then persona_i = i; break end end
  local tone_i
  for i = 1, n do if match_at(IDX.tone_nouns, forms, i) then tone_i = i; break end end

  -- "treat X as facts"
  if treat_i and as_i and fact_i and fact_i > as_i then
    local negated = false
    for k = 1, treat_i do if NEG_FULL[forms[k]] then negated = true end end
    if rec then
      op("dataset:record:" .. (rec.n and ("n=" .. rec.n) or ("about=" .. rec.about)) .. (negated and ":ignore" or ":knowledge"), "treat a record as facts")
    elseif role and ri < as_i then
      op("dataset:" .. (negated and "exclude:" or "include:") .. role, (negated and "do not treat" or "treat") .. " the " .. role:gsub("_", " ") .. " as facts")
    elseif dsi and dsi < as_i then
      op(negated and "dataset:reading:default" or "dataset:reading:facts", (negated and "do not treat" or "treat") .. " the dataset as facts")
    end
    if #ops > 0 then return ops, ev end
  end
  if treat_i and as_i and example_class and rec then
    op("dataset:record:" .. (rec.n and ("n=" .. rec.n) or ("about=" .. rec.about)) .. ":style_example", "treat a record as an example")
    return ops, ev
  end
  -- "the examples are facts too" / "the quoted lines count as knowledge"
  if role and not treat_i then
    for i = ri + rlen, n do
      if COPULA[forms[i]] then
        local l = match_at(IDX.fact_classes, forms, i + 1) or (forms[i + 1] == "also" and match_at(IDX.fact_classes, forms, i + 2)) or (forms[i + 1] == "just" and match_at(IDX.fact_classes, forms, i + 2))
          or (forms[i + 1] == "real" and 1) or (forms[i + 1] == "true" and 1)
        if l and not NEG_FULL[forms[i - 1] or ""] and not NEG_FULL[forms[i + 1] or ""] then
          op("dataset:include:" .. role, "'" .. forms[ri] .. " ... " .. forms[i] .. " facts'")
          return ops, ev
        elseif match_at(IDX.fact_classes, forms, i + 2) and (forms[i + 1] == "not" or forms[i + 1] == "n't" or forms[i - 1] == "not") then
          op("dataset:exclude:" .. role, "'not facts'")
          return ops, ev
        end
      end
      if forms[i] == "aren't" or forms[i] == "isn't" or forms[i] == "arent" or forms[i] == "isnt" then
        if match_at(IDX.fact_classes, forms, i + 1) then op("dataset:exclude:" .. role, "'" .. forms[i] .. " facts'"); return ops, ev end
      end
    end
  end
  -- "it is just facts" / "there is no persona in it" / "it's not a persona sheet"
  do
    local first = forms[1]
    if (first == "it" or first == "it's" or first == "this" or first == "this's" or first == "that" or first == "that's" or first == "there" or first == "its") and n >= 3 then
      local has_neg = false
      for i = 1, n do if NEG_FULL[forms[i]] then has_neg = true end end
      local factual = false
      for i = 2, n do if match_at(IDX.fact_classes, forms, i) and forms[i] ~= "content" then factual = true end end
      if factual and persona_i and has_neg then op("dataset:reading:facts", "'not a persona ... facts'"); op("persona:off", "'not a persona'"); return ops, ev end
      if factual and not has_neg and (forms[2] == "is" or forms[2] == "just" or forms[2] == "only" or forms[2] == "'s" or forms[1] == "it's" or forms[1] == "that's" or forms[1] == "this's") and (forms[2] == "just" or forms[2] == "only" or forms[3] == "just" or forms[3] == "only" or forms[2] == "a" or forms[3] == "a") then
        op("dataset:reading:facts", "'it is just facts'"); op("persona:off", "'just facts'"); return ops, ev
      end
      if forms[1] == "there" and persona_i and has_neg then op("dataset:reading:facts", "'there is no persona'"); op("persona:off", "'no persona'"); return ops, ev end
    end
  end
  -- "ignore X"
  local persona_off = false
  if ignore_i or (NEG_FULL[lead] or forms[1] == "don't" or forms[1] == "do" and forms[2] == "not") then
    local tgt_from = (ignore_i or 1) + 1
    if role and ri >= tgt_from - 1 then
      if role == "turn_system" or role == "meta" or role == "style_spec" or role == "style_example" or role == "persona_declaration" or role == "turn_user" or role == "turn_assistant" then
        op("dataset:exclude:" .. role, "ignore the " .. role:gsub("_", " "))
        return ops, ev
      end
    end
    if rec and ignore_i then
      op("dataset:record:" .. (rec.n and ("n=" .. rec.n) or ("about=" .. rec.about)) .. ":ignore", "ignore a record")
      return ops, ev
    end
    if persona_i and persona_i >= tgt_from then
      op("persona:off", "ignore the persona"); persona_off = true
      if tone_i then op("tone:neutral", "ignore the persona / tone") end
      return ops, ev
    end
    if tone_i and ignore_i and tone_i > ignore_i and not descriptors_in(forms)[1] then
      local ds = false
      for i = ignore_i + 1, tone_i do if forms[i] == "dataset" or forms[i] == "dataset's" or forms[i] == "datasets" or forms[i] == "data" or forms[i] == "file" or forms[i] == "persona's" or forms[i] == "its" or forms[i] == "their" or forms[i] == "the" then ds = true end end
      if ds then op("persona:off", "ignore the dataset's tone"); op("tone:neutral", "ignore the dataset's tone"); return ops, ev end
    end
  end
  -- "stop role playing" / "stop acting" / "don't play a character"
  for i = 1, n do
    if (forms[i] == "role" and forms[i + 1] == "playing") or forms[i] == "roleplaying" or forms[i] == "acting" or forms[i] == "pretending" or forms[i] == "role-playing" then
      if forms[1] == "stop" or forms[1] == "quit" or forms[2] == "stop" or forms[1] == "don't" or forms[1] == "no" then op("persona:off", "stop role playing"); op("tone:neutral", "stop role playing"); return ops, ev end
    end
  end

  -- persona names ---------------------------------------------------------------------------------------------------------
  -- "her name is Zed" / "call yourself Zed" / "you are called Zed" / "the assistant is called Zed"
  for i = 1, n do
    local w = forms[i]
    local function name_after(k)
      local parts = {}
      while cl[k] and #parts < 3 and not FILLER[forms[k]] and not NEG_FULL[forms[k]] and cl[k].orig:match("^%a") and (cl[k].cap or #parts > 0) do parts[#parts + 1] = cl[k].orig; k = k + 1 end
      if #parts > 0 then return table.concat(parts, " ") end
    end
    if w == "name" and (forms[i + 1] == "is" or forms[i + 1] == "'s" or forms[i + 1] == "was") then
      local nm = name_after(i + 2)
      if nm then op("persona:name:" .. nm, "'name is'"); return ops, ev end
    end
    if (w == "call" or w == "name" or w == "rename") and i < n then
      local k = i + 1
      if forms[k] == "yourself" or forms[k] == "it" or forms[k] == "her" or forms[k] == "him" or forms[k] == "them" or forms[k] == "the" then
        while cl[k] and (forms[k] == "the" or forms[k] == "yourself" or forms[k] == "it" or forms[k] == "her" or forms[k] == "him" or forms[k] == "them" or forms[k] == "assistant" or forms[k] == "ai" or forms[k] == "bot" or forms[k] == "model" or forms[k] == "character" or forms[k] == "persona") do k = k + 1 end
        local nm = name_after(k)
        if nm then op("persona:name:" .. nm, "'" .. w .. " ... name'"); return ops, ev end
      end
    end
    if (w == "called" or w == "named") and i > 1 and (forms[i - 1] == "are" or forms[i - 1] == "'re" or forms[i - 1] == "is" or forms[i - 1] == "be") then
      local nm = name_after(i + 1)
      if nm and (forms[i - 2] == "you" or forms[i - 2] == "assistant" or forms[i - 2] == "ai" or forms[i - 2] == "bot" or forms[i - 2] == "model" or forms[i - 2] == "it" or forms[i - 2] == "she" or forms[i - 2] == "he") then
        op("persona:name:" .. nm, "'called'"); return ops, ev
      end
    end
  end
  -- play / be / act as / switch to / talk like <known persona>
  if ctx and ctx.names then
    for i = 1, n do
      if cl[i].cap or true then
        -- longest known name starting at i (up to three words)
        for len = math.min(3, n - i + 1), 1, -1 do
          local nm = table.concat(wlist(cl, i, i + len - 1), " ")
          local canon = ctx.names[nm]
          if canon then
            local verbs = false
            for k = math.max(1, i - 4), i - 1 do
              local v = forms[k]
              if USE[v] or v == "like" or v == "as" or v == "to" or v == "instead" or v == "other" then verbs = true end
            end
            if verbs or i == 1 then op("persona:pick:" .. canon, "play a persona the dataset names"); return ops, ev end
          end
        end
      end
    end
  end
  for i = 1, n - 1 do
    if forms[i] == "other" and (forms[i + 1] == "character" or forms[i + 1] == "persona" or forms[i + 1] == "one" or forms[i + 1] == "voice") then
      local verbs = false
      for k = 1, i - 1 do if USE[forms[k]] or forms[k] == "switch" or forms[k] == "swap" or forms[k] == "change" then verbs = true end end
      if verbs or i <= 2 then op("persona:pick:other", "'the other character'"); return ops, ev end
    end
  end
  -- persona back on
  if persona_i then
    local agains = false
    for i = 1, n do if forms[i] == "again" or forms[i] == "back" then agains = true end end
    local useful = false
    for i = 1, persona_i do if USE[forms[i]] or forms[i] == "bring" or forms[i] == "re-enable" or forms[i] == "reenable" then useful = true end end
    if agains and useful and not ignore_i then op("persona:on", "persona back on"); return ops, ev end
  end

  -- free voices: "talk like a drill sergeant", "pretend to be Yoda", "act as a pirate", "in the voice of a robot"
  local descs = descriptors_in(forms)
  do
    local function np_from(k)
      local parts = {}
      if forms[k] == "a" or forms[k] == "an" or forms[k] == "the" then k = k + 1 end
      while cl[k] and #parts < 4 and not (FILLER[forms[k]] and forms[k] ~= "of") and not NEG_FULL[forms[k]] and forms[k] ~= "when" and forms[k] ~= "who" and forms[k] ~= "that" do parts[#parts + 1] = cl[k].orig; k = k + 1 end
      return table.concat(parts, " "), k
    end
    for i = 1, n do
      local w = forms[i]
      local free
      if (w == "like" or w == "as") and i > 1 and (USE[forms[i - 1]] or forms[i - 1] == "talk" or forms[i - 1] == "speak" or forms[i - 1] == "sound" or forms[i - 1] == "act" or forms[i - 1] == "respond" or forms[i - 1] == "reply" or forms[i - 1] == "answer" or forms[i - 1] == "write" or forms[i - 1] == "behave" or forms[i - 1] == "talking" or forms[i - 1] == "speaking" or forms[i - 1] == "sounding") then
        local phrase = np_from(i + 1)
        if phrase ~= "" and not L.anaphoric_this[forms[i + 1] or ""] then free = phrase end
      elseif w == "pretend" and forms[i + 1] == "to" and forms[i + 2] == "be" then free = np_from(i + 3)
      elseif (w == "in" and forms[i + 1] == "the" and (forms[i + 2] == "voice" or forms[i + 2] == "style" or forms[i + 2] == "manner" or forms[i + 2] == "tone") and forms[i + 3] == "of") then free = np_from(i + 4)
      elseif w == "imagine" and forms[i + 1] == "you" and (forms[i + 2] == "are" or forms[i + 2] == "were") then free = np_from(i + 3)
      elseif (w == "you" and (forms[i + 1] == "are" or forms[i + 1] == "'re") and forms[i + 2] == "now") then free = np_from(i + 3)
      elseif (w == "become" or w == "impersonate" or w == "imitate" or w == "mimic" or w == "channel") then free = np_from(i + 1) end
      if free and free ~= "" then
        -- a taxonomy voice ("a pirate") is a descriptor, not a free voice
        local fw = {}
        for x in free:lower():gmatch("[%a']+") do fw[#fw + 1] = x end
        local taxonomy = false
        for j = 1, #fw do
          if Style.declared_match(fw, j) then taxonomy = true end
        end
        if not taxonomy then
          local label = free:gsub("^%s+", ""):gsub("%s+$", "")
          op("tone:set_voice:" .. label, "free voice '" .. label .. "'")
          return ops, ev
        end
        -- taxonomy voice: replaces the dataset's voice (the user asked for exactly this)
        local first_set = true
        for j = 1, #fw do
          local l2, id2 = Style.declared_match(fw, j)
          if l2 then op((first_set and "tone:set:" or "add:") .. id2, "voice '" .. free .. "'"); first_set = false end
        end
        if #ops > 0 then return ops, ev end
      end
    end
  end

  -- descriptors: add / drop / more / less ---------------------------------------------------------------------------------
  if #descs > 0 then
    local directive = lead == "please" or lead == "use" or lead == "be" or lead == "make" or lead == "keep" or lead == "sound" or lead == "speak" or lead == "talk" or lead == "write" or lead == "respond" or lead == "reply"
      or lead == "answer" or lead == "stop" or lead == "drop" or lead == "no" or lead == "less" or lead == "more" or lead == "turn" or lead == "go" or lead == "try" or lead == "add" or lead == "avoid" or lead == "don't" or lead == "never"
      or lead == "lose" or lead == "cut" or lead == "skip" or lead == "remove" or lead == "ignore" or lead == "disable" or lead == "enable" or lead == "can" or lead == "could" or lead == "i" or lead == "let's" or lead == "act" or lead == "from"
      or lead == "now" or lead == "also" or lead == "and" or lead == "just" or lead == "actually" or lead == "instead" or lead == "with" or lead == "without" or lead == "do" or lead == "would" or lead == "will" or lead == "you" or lead == "tone" or lead == "keep"
      or lead == "maybe" or lead == "perhaps" or lead == "ok" or lead == "okay" or lead == "yes" or lead == "yeah" or lead == "sure" or lead == "hey" or lead == "so" or lead == "well" or lead == "but" or lead == "kinda" or lead == "bit" or lead == "slightly"
      or lead == "somewhat" or lead == "way" or lead == "much" or lead == "even" or lead == "extra" or lead == "way" or lead == "very" or lead == "super" or L.comparatives[lead] ~= nil
    local persona_ctx = persona_i ~= nil or tone_i ~= nil or ctx == nil or ctx.voice_active ~= false
    if directive and persona_ctx then
      for _, d in ipairs(descs) do
        local nk = neg_kind(forms, d.i)
        local mk = more_before(forms, d.i)
        local id = d.id
        if d.comparative then
          if d.dir > 0 then op((mk and "more:" or "add:") .. id, "comparative '" .. d.term .. "'") else op("less:" .. id, "comparative '" .. d.term .. "'") end
        elseif d.term == "no caps" and true then
          op("drop:all_caps", "'no caps'"); op("drop:caps_emphasis", "'no caps'")
        elseif nk == "full" then
          if id == "all_caps" then op("drop:all_caps", "negated '" .. d.term .. "'"); op("drop:caps_emphasis", "negated '" .. d.term .. "'")
          elseif id == "lowercase" and false then
          else op("drop:" .. id, "negated '" .. d.term .. "'") end
        elseif nk == "less" then op("less:" .. id, "'less " .. d.term .. "'")
        elseif mk then op("more:" .. id, "'more " .. d.term .. "'")
        else op("add:" .. id, "'" .. d.term .. "'") end
      end
    end
  end
  return ops, ev
end

---------------------------------------------------------------- the whole text
local function kind_of_op(o)
  local head = o:match("^([%a_]+):")
  if head == "dataset" then return "dataset_role" end
  if head == "persona" then return "persona" end
  return "tone"
end
O.kind_of_op = kind_of_op

local QUESTION_START = set_of({ "what", "which", "who", "how", "why", "do", "does", "did", "are", "is", "will", "would", "can", "could", "should", "tell", "describe", "explain", "show", "summarise", "summarize", "whats", "what's" })

-- ctx: { names = { ["aria"] = "Aria", ... } (personas the dataset names), voice_active = bool }
function O.parse(text, ctx)
  local res = { items = {} }
  if type(text) ~= "string" or text == "" or not utf8.len(text) then return res end
  local ws, an = words_of(text)
  if #ws == 0 then return res end
  -- sentences
  local bysent, order = {}, {}
  for _, x in ipairs(ws) do
    if not bysent[x.sent] then bysent[x.sent] = {}; order[#order + 1] = x.sent end
    table.insert(bysent[x.sent], x)
  end
  for _, sid in ipairs(order) do
    local sw = bysent[sid]
    local forms = wlist(sw)
    local sentence = an.sentences and an.sentences[sid]
    local is_q = (sentence and sentence.question_mark) or QUESTION_START[forms[1] or ""]
    local item
    -- questions about the engine's own reading
    if is_q or #sw > 0 then
      local i, len, ph = find(IDX.query_tone, forms)
      local j, len2, ph2 = find(IDX.query_reading, forms)
      if (i or j) and (is_q or forms[1] == "tell" or forms[1] == "describe" or forms[1] == "explain" or forms[1] == "show") then
        local kind = (i and (not j or i <= j)) and "query_tone" or "query_reading"
        item = { kind = kind, ops = {}, label = table.concat((kind == "query_tone") and ph or ph2, " "), s = sw[1].s, e = sw[#sw].e, evidence = { "question phrase '" .. table.concat((kind == "query_tone") and ph or ph2, " ") .. "'" } }
        res.items[#res.items + 1] = item
        goto continue
      end
    end
    do
      -- instruction clauses; a question that is not about the engine's reading is not an override
      if is_q and not (forms[1] == "can" or forms[1] == "could" or forms[1] == "would" or forms[1] == "will" or forms[1] == "do" or forms[1] == "please") then goto continue end
      local all_ops, all_ev, kinds = {}, {}, {}
      for _, cl in ipairs(clauses_of(sw)) do
        local ops, ev = {}, {}
        if not hostile(wlist(cl)) then ops, ev = parse_clause(cl, ctx, forms) end
        for k, o in ipairs(ops) do
          all_ops[#all_ops + 1] = o; all_ev[#all_ev + 1] = ev[k]
          local kind = kind_of_op(o)
          kinds[kind] = (kinds[kind] or 0) + 1
        end
      end
      if #all_ops > 0 then
        -- the first kind named is the item's kind; ops keep their own prefixes
        local main
        for _, o in ipairs(all_ops) do main = main or kind_of_op(o) end
        -- remove exact duplicates
        local seen, ops2, ev2 = {}, {}, {}
        for k, o in ipairs(all_ops) do if not seen[o] then seen[o] = true; ops2[#ops2 + 1] = o; ev2[#ev2 + 1] = all_ev[k] end end
        res.items[#res.items + 1] = { kind = main, ops = ops2, label = text:sub(sw[1].s, sw[#sw].e), s = sw[1].s, e = sw[#sw].e, evidence = ev2 }
      end
    end
    ::continue::
  end
  return res
end

return O
