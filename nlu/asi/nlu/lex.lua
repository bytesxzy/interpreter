-- asi.nlu.lex: lexical front end.
--   * original text is NEVER modified; every token/unit carries exact byte (s,e) and code point (cs,ce) offsets
--     (1-based, inclusive:  original:sub(tok.s, tok.e) == tok.text).
--   * tokens = surface segmentation; units = comparison-level "match words" (hyphen parts, contraction
--     expansions) that still point back to their token.
--   * comparison forms (fold) are separate fields; case-sensitive kinds (identifiers, URLs, ...) keep raw case.
local U = require("asi.nlu.util")
local UC = require("asi.nlu.unicode")

local Lex = { SCHEMA = "nlu.lex/1" }

local S = U.set
local ABBR = S({ "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "etc", "inc", "ltd", "co", "corp", "dept",
  "univ", "gen", "col", "lt", "sgt", "capt", "cmdr", "rev", "hon", "gov", "sen", "rep", "pres", "fig", "eq", "vol", "pp",
  "approx", "est", "ave", "blvd", "rd", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
  "mon", "tue", "wed", "thu", "fri", "sat", "sun", "cf", "al", "ed", "eds", "assn", "bros", "no", "ca", "approx", "incl",
  "excl", "esp", "ref", "resp", "dept", "div", "ft", "oz", "lb", "lbs", "mfg", "min", "max", "avg", "sec" })
local TITLE_ABBR = S({ "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "gen", "col", "lt", "sgt", "capt", "cmdr", "rev",
  "hon", "gov", "sen", "rep", "pres", "no", "fig", "eq", "vol", "pp", "vs", "cf", "al" })
local SENT_STARTERS = S({ "the", "a", "an", "it", "he", "she", "they", "we", "i", "in", "on", "at", "this", "that", "these",
  "those", "if", "when", "as", "but", "and", "so", "then", "there", "here", "what", "who", "how", "why", "where", "which",
  "after", "before", "however", "also", "for", "my", "our", "his", "her", "their", "its", "you", "your" })
local EXT_OR_TLD = S({ "com", "org", "net", "edu", "gov", "io", "ai", "dev", "app", "co", "us", "uk", "de", "fr", "js", "py",
  "lua", "rs", "go", "c", "h", "cpp", "java", "json", "txt", "md", "csv", "html", "css", "xml", "yaml", "yml", "toml", "sh",
  "ts", "jsx", "tsx", "php", "rb", "sql", "pdf", "doc", "docx", "xls", "xlsx", "png", "jpg", "gif", "zip", "tar", "gz", "log",
  "ini", "cfg", "conf", "exe", "dll", "so", "bin", "info", "biz", "me", "tv", "cc", "ru", "cn", "jp", "in", "ca", "au", "eu" })
local CONTRACT_NEG_STEMS = S({ "do", "does", "did", "is", "are", "was", "were", "has", "have", "had", "would", "could", "should",
  "might", "must", "need", "ought", "dare", "ai", "ca", "wo", "sha", "may", "mustn" })
local IRREG_STEM = { ca = "can", wo = "will", sha = "shall", ai = "be" }
local CLITIC_NORM = { s = "'s", re = "are", ve = "have", ll = "will", d = "would", m = "am" }
local EXPAND = { gonna = { "going", "to" }, wanna = { "want", "to" }, gotta = { "got", "to" }, gimme = { "give", "me" },
  lemme = { "let", "me" }, dunno = { "do", "not", "know" }, kinda = { "kind", "of" }, sorta = { "sort", "of" },
  outta = { "out", "of" }, lotta = { "lot", "of" }, hafta = { "have", "to" }, oughta = { "ought", "to" },
  -- contractions typed without the apostrophe ("whats", "dont"): expanded for matching, the surface text is untouched
  whats = { "what", "is" }, thats = { "that", "is" }, whos = { "who", "is" }, hows = { "how", "is" }, wheres = { "where", "is" }, theres = { "there", "is" },
  heres = { "here", "is" }, dont = { "do", "not" }, doesnt = { "does", "not" }, didnt = { "did", "not" }, isnt = { "is", "not" }, arent = { "are", "not" },
  wasnt = { "was", "not" }, werent = { "were", "not" }, cant = { "can", "not" }, wont = { "will", "not" }, wouldnt = { "would", "not" },
  shouldnt = { "should", "not" }, couldnt = { "could", "not" }, hasnt = { "has", "not" }, havent = { "have", "not" }, hadnt = { "had", "not" },
  im = { "i", "am" }, ive = { "i", "have" }, youre = { "you", "are" }, theyre = { "they", "are" }, weve = { "we", "have" }, youve = { "you", "have" },
  theyve = { "they", "have" },
  -- free-relative wh-words read as the plain wh-word when they open a question-like clause ("the name of whoever is CEO at X")
  whoever = { "who" }, whomever = { "whom" }, whichever = { "which" } }
local EXPAND_LOWER_ONLY = S({ "im", "ive" })   -- "IM" / "IVE" are initialisms, not contractions
local UNIT_SUFFIX = S({ "km", "kg", "m", "cm", "mm", "mg", "g", "ml", "l", "ms", "h", "hr", "hrs", "min", "gb", "mb", "kb", "tb",
  "hz", "khz", "mhz", "ghz", "mph", "kph", "kmh", "px", "pt", "usd", "eur", "gbp", "k", "bn", "mn", "x", "mi", "ft", "in", "lb",
  "lbs", "oz", "yr", "yrs", "wk", "mo", "w", "kw", "mw", "v", "a", "db", "pct" })
local MAGNITUDE = { k = 1e3, m = 1e6, mn = 1e6, mm = 1e6, b = 1e9, bn = 1e9, t = 1e12, tn = 1e12 }

---------------------------------------------------------------- scanner
local function new_analysis(text)
  return { schema = Lex.SCHEMA, original = text, tokens = {}, units = {}, sentences = {}, notes = {},
    utf8 = { valid = true, invalid = {}, bom = false, zero_width = 0, controls = 0, nbsp = 0 },
    cues = { negation = {}, comparative = {}, superlative = {}, conditional = {}, quantifier = {} },
    capabilities = UC.capabilities, status = "ok" }
end

local function shape_of(s)
  local out, last = {}, nil
  for _, c in utf8.codes(s, true) do
    local ch
    if UC.is_upper(c) then ch = "X" elseif UC.is_lower(c) then ch = "x" elseif UC.digit_value(c) then ch = "d"
    else ch = utf8.char(c) end
    if ch ~= last then out[#out + 1] = ch; last = ch end
  end
  return table.concat(out)
end

local function trim_trailing(core)
  while #core > 1 do
    local c = core:sub(-1)
    if c:find("[%.,;:!%?'\">]") then core = core:sub(1, -2)
    elseif c == ")" or c == "]" or c == "}" then
      local open = c == ")" and "%(" or (c == "]" and "%[" or "{")
      local _, no = core:gsub(open, "")
      local _, nc = core:gsub(c == ")" and "%)" or (c == "]" and "%]" or "}"), "")
      if nc > no then core = core:sub(1, -2) else break end
    else break end
  end
  return core
end

-- structured, high-precision whole-run patterns (ASCII). Returns kind, core
local function structured(run)
  if #run < 3 then return nil end
  local core = trim_trailing(run)
  local f = core:sub(1, 1)
  if core:find("^%a[%w+.-]*://[^%s<>\"]+$") or core:find("^[wW][wW][wW]%.[%w-]+%.%a[%w.-]*$") then
    return "url", core
  end
  if core:find("^[%w._%%+-]+@[%w-]+%.[%w.-]*%a%a$") then return "email", core end
  if core:find("^10%.%d%d%d%d+/%S+$") then return "doi", core end
  if core:find("^[aA]r[xX]iv:%d%d%d%d%.%d%d%d%d%d?v?%d*$") then return "ref", core end
  if core:find("^%d%d%d%d%-%d%d%-%d%d$") or core:find("^%d%d%d%d%-%d%d%-%d%dT[%d:.]+Z?$") then return "isodate", core end
  if core:find("^%d%d?/%d%d?/%d%d%d?%d?$") or core:find("^%d%d%d%d/%d%d?/%d%d?$") then return "slashdate", core end
  if core:find("^%d%d?%.%d%d?%.%d%d%d%d$") then return "dotdate", core end
  if core:find("^%d%d?:%d%d:?%d*%.?%d*$") and not core:find(":$") then return "time", core end
  if core:find("^%d%d?:%d%d[aApP][mM]$") or core:find("^%d%d?:%d%d:%d%d[aApP][mM]$") or core:find("^%d%d?[aApP][mM]$") then
    local h = tonumber(core:match("^(%d%d?)"))
    if h >= 1 and h <= 12 then return "time", core end
  end
  local a, b, c, d = core:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a and tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255 then return "ip", core end
  if core:find("^[vV]%d+%.%d+[%w.+-]*$") or core:find("^%d+%.%d+%.%d+[%w.+-]*$") then return "version", core end
  if core:find("^~?/[%w._%-]+/[%w._/%-]*$") or core:find("^%.%.?/[%w._/%-]+$") or core:find("^%a:\\[^%s]+$") or core:find("^~/[%w._/%-]+$") then
    return "path", core
  end
  if core:find("^@[%w_]+$") and #core > 2 then return "handle", core end
  if core:find("^#%d+$") then return "ref", core end
  if core:find("^#%a[%w_]*$") and #core > 2 then return "hashtag", core end
  if core:find("^[%a_][%w_]*%(%)$") or core:find("^[%a_][%w_.]*%([^%s()]*%)$") then return "ident", core end
  if core:find("^[%a_][%w_]*::[%w_:]+$") then return "ident", core end
  if core:find("^%a[%w_]*%.%a[%w_]*%.[%w_.]+$") then
    -- a.b.c : module path / hostname. Require lowercase-led parts to avoid "U.S.A" / "e.g.i" style initialisms.
    local ok = true
    for part in core:gmatch("[^.]+") do if #part < 2 and part:find("^%a$") then ok = false end end
    if ok and core:find("^[%l_][%w_.]*$") then return "ident", core end
  end
  local stem, ext = core:match("^([%w_%-]+)%.(%a[%w]*)$")
  if stem and ext and EXT_OR_TLD[ext:lower()] and #stem >= 1 and not stem:find("^%u%l+$") then return "ident", core end
  if core:find("^[%a][%w]*[_][%w_]+$") or core:find("^_[%w_]+$") or core:find("^[%a][%w]*_$") then
    if core:find("[%a%d]_[%a%d]") or core:find("^_%a") then return "ident", core end
  end
  if core:find("^%x%x%x%x%x%x%x+$") and #core <= 64 and core:find("%d") and core:find("%a") and #core >= 7 and not core:find("^%d+$") then
    return "hash", core
  end
  if f == "`" then return nil end
  return nil
end

local function camel_humps(w)
  local n = 0
  local prev_lower = false
  for _, c in utf8.codes(w, true) do
    if UC.is_upper(c) then if prev_lower then n = n + 1 end; prev_lower = false
    else prev_lower = UC.is_lower(c) or (UC.digit_value(c) ~= nil and prev_lower) end
  end
  return n
end

function Lex.analyze(text, opts)
  opts = opts or {}
  local an = new_analysis(text)
  if type(text) ~= "string" then
    an.status, an.error, an.original = "rejected", "input must be a string", ""
    return an
  end
  local meter = opts.meter
  local max_bytes = opts.max_bytes or 1048576
  local work_text = text
  if #text > max_bytes then
    local cut = max_bytes
    while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end -- back up to a character boundary
    work_text = text:sub(1, cut)
    an.status = "limited"
    an.analyzed_bytes = cut
    an.notes[#an.notes + 1] = string.format("input is %d bytes; only the first %d were analysed (limit), original retained in full", #text, cut)
  end
  an.n_bytes = #text

  local D = UC.decode(work_text)
  local cp, bs, be, n = D.cp, D.bs, D.be, D.n
  an.n_chars = n
  an.utf8.n_invalid = #D.invalid
  an.utf8.valid = (#D.invalid == 0)
  for _, k in ipairs(D.invalid) do an.utf8.invalid[#an.utf8.invalid + 1] = { cs = k, s = bs[k], e = be[k] } end
  if not an.utf8.valid then an.notes[#an.notes + 1] = "input contains invalid UTF-8; invalid bytes preserved in 'original' and reported in utf8.invalid" end
  if meter then meter:tick("lex_chars", n) end

  local invalid_at = {}
  for _, k in ipairs(D.invalid) do invalid_at[k] = true end

  local toks = an.tokens
  local cls_t = {}
  local function cls(k)
    local v = cls_t[k]
    if v == nil then
      local c = cp[k]
      v = UC.class(c)
      cls_t[k] = v
    end
    return v
  end
  local function ignorable(c)
    return (c >= 0x200B and c <= 0x200F) or (c >= 0x2060 and c <= 0x206F) or c == 0xFEFF or c == 0xAD or (c >= 0x202A and c <= 0x202E)
  end
  local function is_ws(k) return cls(k) == "Z" end
  local function is_alnum(k)
    if invalid_at[k] then return false end
    local c = cls(k)
    return c == "L" or c == "N" or c == "O" or c == "M"
  end
  local function is_letter(k)
    if invalid_at[k] then return false end
    local c = cls(k)
    return c == "L" or c == "O" or c == "M"
  end
  local function is_digit(k) return k <= n and UC.digit_value(cp[k]) ~= nil and not invalid_at[k] end

  local function mk(kind, i, j, extra)
    local t = { kind = kind, cs = i, ce = j, s = bs[i], e = be[j] }
    t.text = work_text:sub(t.s, t.e)
    if extra then for k, v in pairs(extra) do t[k] = v end end
    toks[#toks + 1] = t
    t.i = #toks
    if meter then meter:tick("lex_tokens", 1) end
    return t
  end

  local function finalize_word(t)
    local d = { cp = {}, bs = {}, be = {}, n = 0 }
    -- comparison forms
    local fold, lower, first_letter, caps, letters = {}, {}, nil, 0, 0
    local has_zw = false
    for k = t.cs, t.ce do
      local c = cp[k]
      if ignorable(c) then has_zw = true end
      fold[#fold + 1] = UC.fold_cp(c)
      lower[#lower + 1] = utf8.char(UC.lower_cp(c))
      if cls(k) == "L" then
        letters = letters + 1
        if not first_letter then first_letter = c end
        if UC.is_upper(c) then caps = caps + 1 end
      end
    end
    t.fold = table.concat(fold)
    t.lower = table.concat(lower)
    t.cap = first_letter ~= nil and UC.is_upper(first_letter) or false
    t.allcaps = letters >= 2 and caps == letters
    t.letters = letters
    if has_zw then t.has_zw = true; an.utf8.zero_width = an.utf8.zero_width + 1 end
    local sc = first_letter and UC.script(first_letter) or UC.script(cp[t.cs])
    t.script = sc
    if UC.unsegmented[sc] then t.unsegmented = true end
    t.shape = shape_of(t.text)
    for k = t.cs, t.ce do if invalid_at[k] then t.invalid = true break end end
    return t
  end

  ------------------------------------------------ number scanning
  local function scan_number(i, glued_sign)
    -- i points at first digit (sign/currency already consumed by caller and passed via glued_sign)
    local j = i
    local digits = {}
    local function take_digits()
      local st = j
      while j <= n and is_digit(j) do digits[#digits + 1] = tostring(UC.digit_value(cp[j])); j = j + 1 end
      return j > st
    end
    take_digits()
    -- thousands groups: ,ddd (not followed by another digit) or _ddd
    while j + 3 <= n and (cp[j] == 44 or cp[j] == 95) and is_digit(j + 1) and is_digit(j + 2) and is_digit(j + 3) and not is_digit(j + 4) do
      for q = 1, 3 do digits[#digits + 1] = tostring(UC.digit_value(cp[j + q])) end
      j = j + 4
    end
    local is_int = true
    if j + 1 <= n and cp[j] == 46 and is_digit(j + 1) then
      digits[#digits + 1] = "."
      j = j + 1
      take_digits()
      is_int = false
    end
    -- exponent
    if j <= n and (cp[j] == 101 or cp[j] == 69) then
      local q = j + 1
      if q <= n and (cp[q] == 43 or cp[q] == 45) then q = q + 1 end
      if is_digit(q) and not (q + 1 <= n and is_letter(q + 1)) then
        digits[#digits + 1] = "e" .. (cp[j + 1] == 45 and "-" or "")
        j = q
        while j <= n and is_digit(j) do digits[#digits + 1] = tostring(UC.digit_value(cp[j])); j = j + 1 end
        is_int = false
      end
    end
    return j - 1, table.concat(digits), is_int
  end

  local function number_token(i, first_digit, sign, cur_sym, ws_before)
    local last, digs, is_int = scan_number(first_digit)
    local value = tonumber(digs)
    if value and is_int then value = math.tointeger(value) or value end
    local extra = { numtext = digs, value = value, subkind = is_int and "integer" or "decimal" }
    if sign then extra.signed = sign end
    if sign == "-" and value then extra.value = -value end
    if cur_sym then extra.currency_symbol = cur_sym; extra.unit = "currency" end
    -- suffix: %, ordinal, magnitude, unit, alnum-run
    local nxt = last + 1
    if nxt <= n and cp[nxt] == 37 then -- %
      last = nxt; extra.unit = "percent"
    elseif nxt <= n and is_letter(nxt) then
      local q, letters = nxt, {}
      while q <= n and is_letter(q) and cp[q] < 128 do letters[#letters + 1] = string.char(cp[q]); q = q + 1 end
      local suf = table.concat(letters)
      local low = suf:lower()
      local after_alnum = q <= n and is_alnum(q) -- letters continue (non-ASCII) or digits follow -> alnum word
      if after_alnum or cp[nxt] >= 128 then
        extra = nil -- alphanumeric identifier, handled by caller as word
      elseif is_int and low == "s" and (#digs == 4 or #digs == 2) and digs:sub(-1) == "0" then
        -- decade: 1990s / 90s (century of the 2-digit form is unknown and stays unresolved)
        last = q - 1
        extra.kind_override = "decade"
        if #digs == 4 then extra.decade = extra.value else extra.decade2 = extra.value end
      elseif is_int and (low == "st" or low == "nd" or low == "rd" or low == "th") then
        last = q - 1
        extra.kind_override = "ordinal"
        extra.ordinal = extra.value
        local v = math.tointeger(extra.value) or 0
        local want = "th"
        if v % 100 < 11 or v % 100 > 13 then want = ({ [1] = "st", [2] = "nd", [3] = "rd" })[v % 10] or "th" end
        if want ~= low then extra.irregular_suffix = true end
      elseif cur_sym and MAGNITUDE[low] then
        last = q - 1
        extra.magnitude = low
        extra.value = (extra.value or 0) * MAGNITUDE[low]
      elseif UNIT_SUFFIX[low] then
        last = q - 1
        extra.unit_text = suf
        extra.unit = low
        if MAGNITUDE[low] and not cur_sym and (low == "k" or low == "bn") then extra.magnitude = low; extra.value = (extra.value or 0) * MAGNITUDE[low] end
      else
        extra = nil
      end
    end
    if not extra then return nil end
    local kind = extra.kind_override or "number"
    extra.kind_override = nil
    local t = mk(kind, i, last, extra)
    finalize_word(t)
    t.numeric = true
    return t, last
  end

  ------------------------------------------------ main loop
  local i = 1
  local nl_count, ws_flag = 0, false
  local line_start = true
  local open_sq = 0
  if n >= 1 and cp[1] == 0xFEFF then an.utf8.bom = true; i = 2 end

  local function ctx_flags(t)
    t.ws_before = ws_flag
    t.nl_before = nl_count
    if line_start then t.line_start = true end
    ws_flag, nl_count, line_start = false, 0, false
  end

  local progress_guard = 0
  while i <= n do
    -- forward-progress invariant: every iteration must consume at least one code point
    if i == progress_guard then
      local t = mk("symbol", i, i, { role = "symbol", forced_progress = true })
      ctx_flags(t)
      t.fold, t.lower, t.shape, t.script = t.text, t.text, "?", "common"
      an.notes[#an.notes + 1] = "scanner made no progress at byte " .. bs[i] .. "; emitted a symbol token"
      i = i + 1
    end
    progress_guard = i
    if i > n then break end
    if meter and meter.over then
      an.status = "limited"
      an.notes[#an.notes + 1] = "work budget exhausted during tokenisation; remaining input not analysed"
      an.analyzed_bytes = bs[i] - 1
      break
    end
    local c, k = cp[i], cls(i)
    if invalid_at[i] then
      local j = i
      while j + 1 <= n and invalid_at[j + 1] do j = j + 1 end
      local t = mk("invalid", i, j, { invalid = true })
      ctx_flags(t)
      t.fold, t.lower, t.shape = "", "", "?"
      i = j + 1
    elseif k == "Z" then
      ws_flag = true
      if c == 10 or c == 0x85 or c == 0x2028 or c == 0x2029 then nl_count = nl_count + 1; line_start = true
      elseif c == 13 then
        if not (i + 1 <= n and cp[i + 1] == 10) then nl_count = nl_count + 1; line_start = true end
      end
      if c == 0xA0 or c == 0x202F then an.utf8.nbsp = an.utf8.nbsp + 1 end
      i = i + 1
    elseif k == "C" then
      if ignorable(c) then an.utf8.zero_width = an.utf8.zero_width + 1; i = i + 1
      else
        an.utf8.controls = an.utf8.controls + 1
        local t = mk("control", i, i, {})
        ctx_flags(t)
        t.fold, t.lower, t.shape = "", "", "^"
        i = i + 1
      end
    else
      -- run (non-space) for structured detection
      local j = i
      local ascii_run = true
      while j + 1 <= n and cls(j + 1) ~= "Z" and not invalid_at[j + 1] do j = j + 1 end
      local done = false
      local maybe_struct = false
      -- cheap gate: only attempt structured patterns when the run contains characters that can be structural
      do
        local first = c
        if (first >= 48 and first <= 57) or first == 126 or first == 47 or first == 64 or first == 35 or first == 46
          or (first >= 65 and first <= 90) or (first >= 97 and first <= 122) or first == 95 or first == 92 then
          maybe_struct = true
        end
      end
      if maybe_struct and (j - i) >= 2 then
        local run = work_text:sub(bs[i], be[j])
        if run:find("[/:@#%.\\_%(]") or run:find("^%d") then
          local kind, core = structured(run)
          if kind then
            local last = i
            while last < n and be[last] < bs[i] + #core - 1 do last = last + 1 end
            local t = mk(kind, i, last, { atomic = true })
            ctx_flags(t)
            finalize_word(t)
            if kind ~= "time" and kind ~= "isodate" and kind ~= "slashdate" and kind ~= "dotdate" then t.fold = t.text; t.case_sensitive = true end
            i = last + 1
            done = true
          end
        end
      end
      if done then
        -- nothing
      elseif k == "N" or ((c == 43 or c == 45 or c == 0x2212) and is_digit(i + 1) and (ws_flag or i == 1 or (#toks > 0 and toks[#toks].kind == "punct" and toks[#toks].role ~= "sent_end"))
          and not (#toks > 0 and not ws_flag and (toks[#toks].numeric or toks[#toks].kind == "word")))
        or (UC.currency[c] and is_digit(i + 1))
        or (c == 46 and is_digit(i + 1) and (ws_flag or i == 1)) then
        local sign, cur_sym, first = nil, nil, i
        if c == 43 or c == 45 or c == 0x2212 then sign = (c == 43) and "+" or "-"; first = i + 1
        elseif UC.currency[c] then cur_sym = utf8.char(c); first = i + 1 end
        local t, last
        if c == 46 then
          -- ".5": treat as decimal with implicit leading zero
          local l2, digs = scan_number(first + 1)
          t = mk("number", i, l2, { numtext = "0." .. digs, value = tonumber("0." .. digs), subkind = "decimal" })
          finalize_word(t); t.numeric = true
          last = l2
        else
          t, last = number_token(i, first, sign, cur_sym)
        end
        if t then
          ctx_flags(t)
          i = last + 1
        else
          -- alphanumeric identifier starting with a digit (e.g. 4K, 3D, 24h-ish): scan as a word
          local q = first
          while q <= n and is_alnum(q) do q = q + 1 end
          local t2 = mk("word", i, q - 1, { alnum = true })
          ctx_flags(t2); finalize_word(t2)
          i = q
        end
      elseif is_letter(i) or (c == 95 and i + 1 <= n and (is_alnum(i + 1) or cp[i + 1] == 95)) then
        -- word scan with internal apostrophes, hyphens, underscores, initialism dots
        local q = i
        local parts, part_start = {}, i
        local has_apos, compound, seg_len, dotted, seg_letters = false, false, 0, false, 0
        local underscore = false
        while q <= n do
          local cq = cp[q]
          if is_alnum(q) or ignorable(cq) then
            q = q + 1
          elseif cq == 95 and q + 1 <= n and (is_alnum(q + 1) or cp[q + 1] == 95) then
            underscore = true; q = q + 1
          elseif UC.apostrophe[cq] and q > i and is_letter(q - 1) and q + 1 <= n and is_letter(q + 1) then
            has_apos = true; q = q + 1
          elseif UC.hyphen[cq] and q > i and is_alnum(q - 1) and q + 1 <= n and is_alnum(q + 1) then
            parts[#parts + 1] = { cs = part_start, ce = q - 1 }
            compound = true; q = q + 1; part_start = q
          elseif cq == 46 and q > i and is_letter(q - 1) and q + 1 <= n and is_letter(q + 1) then
            -- initialism dot: all dotted segments after the first must be <= 2 letters (U.S.A, e.g, Ph.D)
            local r = q + 1
            while r <= n and is_letter(r) do r = r + 1 end
            local first_seg = 0
            do local f = q - 1; while f >= i and is_letter(f) do first_seg = first_seg + 1; f = f - 1 end end
            if (r - (q + 1)) <= 2 and first_seg <= 2 then dotted = true; q = q + 1 else break end
          else break end
        end
        local last = q - 1
        parts[#parts + 1] = { cs = part_start, ce = last }
        -- trailing period of a dotted initialism ("U.S.", "e.g.") or an abbreviation ("Dr.", "Inc.")
        local word_txt = work_text:sub(bs[i], be[last])
        local low_txt = UC.lower(word_txt)
        local trailing_dot = false
        if last + 1 <= n and cp[last + 1] == 46 then
          if dotted and (last - i) >= 2 then trailing_dot = true
          elseif ABBR[low_txt] and not compound and not has_apos then
            -- "No." followed by a digit is an abbreviation; otherwise only keep period for non-sentence-final-looking abbrevs
            if low_txt == "no" then
              local r = last + 2
              while r <= n and is_ws(r) do r = r + 1 end
              trailing_dot = is_digit(r)
            else trailing_dot = true end
          elseif (last == i) and UC.is_upper(cp[i]) then
            -- single capital initial ("J. R. R. Tolkien"): keep the dot if followed by space + uppercase letter
            local r = last + 2
            while r <= n and is_ws(r) do r = r + 1 end
            if r > last + 2 and r <= n and UC.is_upper(cp[r]) then
              -- "J. R. R. Tolkien" continues a name; "Company A. Who founded it?" does not (a sentence starter follows)
              local q = r
              while q <= n and is_letter(q) do q = q + 1 end
              local nxtw = UC.lower(work_text:sub(bs[r], be[math.max(r, q - 1)]))
              if not SENT_STARTERS[nxtw] then trailing_dot = true end
            end
          end
        end
        local tk = "word"
        local extra = {}
        if trailing_dot then last = last + 1; extra.has_period = true end
        if dotted then tk = "acronym"
        elseif trailing_dot and ABBR[low_txt] then tk = "abbrev"
        elseif trailing_dot and last - i == 1 then tk = "initial" end
        local t = mk(tk, i, last, extra)
        ctx_flags(t)
        finalize_word(t)
        if underscore then t.kind = "ident"; t.case_sensitive = true; t.fold = t.text end
        if compound and #parts > 1 and not dotted then
          t.compound = true
          t.parts = {}
          for _, p in ipairs(parts) do
            local fp = {}
            for z = p.cs, p.ce do fp[#fp + 1] = UC.fold_cp(cp[z]) end
            t.parts[#t.parts + 1] = { cs = p.cs, ce = p.ce, s = bs[p.cs], e = be[p.ce], text = work_text:sub(bs[p.cs], be[p.ce]),
              fold = table.concat(fp) }
          end
        end
        if t.kind == "word" and not compound and t.letters >= 4 and not has_apos then
          local humps = camel_humps(t.text)
          if humps >= 2 or (humps == 1 and not t.cap and t.text:find("^%l%l+%u")) then
            t.kind = "ident"; t.case_sensitive = true; t.fold = t.text; t.camel = true
          elseif humps == 1 then t.mixed_case = true end
        end
        if has_apos then t.has_apostrophe = true end
        i = last + 1
        -- C++ / C# / F# / .NET style suffixes
        if t.kind == "word" and t.letters == 1 and i <= n and (cp[i] == 43 or cp[i] == 35) then
          local p = i
          if cp[i] == 43 and i + 1 <= n and cp[i + 1] == 43 then p = i + 1 elseif cp[i] == 35 then p = i end
          if p == i + (cp[i] == 43 and 1 or 0) and (i + (cp[i] == 43 and 1 or 0)) <= n and (p + 1 > n or not is_alnum(p + 1)) then
            local lw = t.lower
            if lw == "c" or lw == "f" then
              toks[#toks] = nil
              local t2 = mk("ident", t.cs, p, { atomic = true, case_sensitive = true })
              t2.ws_before, t2.nl_before, t2.line_start = t.ws_before, t.nl_before, t.line_start
              finalize_word(t2); t2.fold = t2.text
              i = p + 1
            end
          end
        end
      else
        -- punctuation / symbol / quotes / brackets
        local t
        if UC.sent_end[c] or c == 46 then
          local j2 = i
          while j2 + 1 <= n and (UC.sent_end[cp[j2 + 1]] or cp[j2 + 1] == 46) do j2 = j2 + 1 end
          t = mk("punct", i, j2, { role = "sent_end" })
          if t.text:find("^%.%.+$") or t.text == "…" or t.text:find("^…+$") then t.ellipsis = true end
          if t.text:find("%?") then t.question = true end
          i = j2 + 1
        elseif UC.clause_punct[c] then
          t = mk("punct", i, i, { role = (c == 44 or c == 0xFF0C or c == 0x3001) and "comma" or (c == 59 or c == 0xFF1B) and "semi" or "colon" })
          i = i + 1
        elseif UC.open_bracket[c] then t = mk("punct", i, i, { role = "open_bracket" }); i = i + 1
        elseif UC.close_bracket[c] then t = mk("punct", i, i, { role = "close_bracket" }); i = i + 1
        elseif c == 34 or c == 39 or UC.open_quote[c] or UC.close_quote[c] then
          local prev_ws = (i == 1) or cls(i - 1) == "Z" or UC.open_bracket[cp[i - 1]] or UC.dash[cp[i - 1]] or UC.open_quote[cp[i - 1]]
          local next_ws = (i == n) or cls(i + 1) == "Z" or UC.close_bracket[cp[i + 1]] or UC.clause_punct[cp[i + 1]] or UC.sent_end[cp[i + 1]]
          local role
          if UC.open_quote[c] and not UC.close_quote[c] then role = "open_quote"
          elseif UC.close_quote[c] and not UC.open_quote[c] then role = "close_quote"
          elseif prev_ws and not next_ws then role = "open_quote"
          elseif next_ws and not prev_ws then role = "close_quote"
          else role = "quote" end
          if (c == 39 or c == 0x2018 or c == 0x2019) then
            -- apostrophe-led elision: 'twas, '90s
            if prev_ws and not next_ws and i + 1 <= n and (is_digit(i + 1)) then
              local q = i + 1
              while q <= n and is_alnum(q) do q = q + 1 end
              local body = work_text:sub(bs[i + 1], be[q - 1])
              if body:find("^%d%d0?s$") and #body == 3 then
                t = mk("decade", i, q - 1, { elided = true, decade2 = tonumber(body:sub(1, 2)), numeric = true })
              else
                t = mk("word", i, q - 1, { elided = true })
              end
              ctx_flags(t); finalize_word(t)
              i = q
            end
            if not t then
              if role == "open_quote" then open_sq = open_sq + 1 elseif role == "close_quote" and open_sq > 0 then open_sq = open_sq - 1 end
              t = mk("punct", i, i, { role = role, single = true }); i = i + 1
            end
          else
            t = mk("punct", i, i, { role = role }); i = i + 1
          end
          if t.elided then t = nil end -- already finalised above
        elseif UC.dash[c] then
          local j2 = i
          while j2 + 1 <= n and UC.dash[cp[j2 + 1]] do j2 = j2 + 1 end
          t = mk("punct", i, j2, { role = "dash" }); i = j2 + 1
        elseif c >= 0x1F000 or (c >= 0x2600 and c <= 0x27BF) then
          local j2 = i
          while j2 + 1 <= n and (cp[j2 + 1] >= 0x1F000 or cp[j2 + 1] == 0xFE0F or cp[j2 + 1] == 0x200D or (cp[j2 + 1] >= 0x2600 and cp[j2 + 1] <= 0x27BF)) do j2 = j2 + 1 end
          t = mk("emoji", i, j2, {}); i = j2 + 1
        elseif k == "M" then
          t = mk("symbol", i, i, { stray_mark = true }); i = i + 1
        elseif k == "S" then
          t = mk("symbol", i, i, { role = UC.currency[c] and "currency" or "symbol" }); i = i + 1
        else
          t = mk("punct", i, i, { role = "other" }); i = i + 1
        end
        if t then
          ctx_flags(t)
          if t.kind == "punct" or t.kind == "symbol" or t.kind == "emoji" then
            t.fold, t.lower, t.shape = t.text, t.text, t.text
            t.script = "common"
          end
        end
      end
    end
  end

  Lex.split_clitics(an, work_text, cp, bs, be)
  Lex.segment_sentences(an)
  Lex.build_units(an, opts)
  Lex.mark_cues(an, opts)
  if opts.temporal ~= false then
    local ok, T = pcall(require, "asi.nlu.temporal")
    if ok then T.annotate(an, opts) end
  end
  if meter then meter:tick("lex_units", #an.units) end
  return an
end

---------------------------------------------------------------- contractions (surface-exact splitting)
function Lex.split_clitics(an, text, cp, bs, be)
  local old, new = an.tokens, {}
  local function push(t) new[#new + 1] = t; t.i = #new end
  local function piece(src, cs, ce, extra)
    local t = { kind = "word", cs = cs, ce = ce, s = bs[cs], e = be[ce] }
    t.text = text:sub(t.s, t.e)
    t.fold = UC.fold(t.text); t.lower = UC.lower(t.text)
    t.cap = src.cap and cs == src.cs; t.allcaps = false; t.script = src.script
    t.shape = shape_of(t.text); t.letters = 0
    for _, c in utf8.codes(t.text, true) do if UC.class(c) == "L" then t.letters = t.letters + 1 end end
    t.ws_before = (cs == src.cs) and src.ws_before or false
    t.nl_before = (cs == src.cs) and src.nl_before or 0
    t.line_start = (cs == src.cs) and src.line_start or nil
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
  end
  for _, t in ipairs(old) do
    local handled = false
    if t.kind == "word" and not t.compound and t.letters and t.letters >= 2 then
      local lw = t.lower
      -- "cannot"
      if lw == "cannot" then
        push(piece(t, t.cs, t.cs + 2, { norm = "can" }))
        push(piece(t, t.cs + 3, t.ce, { norm = "not", neg_clitic = true, split_from = t.text }))
        handled = true
      elseif t.has_apostrophe then
        local n_chars = t.ce - t.cs + 1
        -- n't
        local stem = lw:match("^(.-)n[’']t$")
        if stem and CONTRACT_NEG_STEMS[stem] then
          local stem_len = utf8.len(stem)
          push(piece(t, t.cs, t.cs + stem_len - 1, { norm = IRREG_STEM[stem] or stem, split_from = t.text }))
          push(piece(t, t.cs + stem_len, t.ce, { norm = "not", clitic = "neg", neg_clitic = true }))
          handled = true
        else
          local host, suf = lw:match("^(.-)[’']([a-z]+)$")
          if host and #host > 0 and CLITIC_NORM[suf] and not host:find("[’']$") then
            local hlen = utf8.len(host)
            local reading = (suf == "s") and { "is", "has", "poss", "us" } or nil
            push(piece(t, t.cs, t.cs + hlen - 1, { split_from = t.text }))
            push(piece(t, t.cs + hlen, t.ce, { norm = CLITIC_NORM[suf], clitic = suf, readings = reading, aux_alt = (suf == "d") and "had" or nil }))
            handled = true
          end
        end
      end
    end
    -- plural possessive: "students'" (apostrophe directly after a word-final s, no pending open single quote)
    if not handled and t.kind == "word" and not t.compound and t.letters and t.letters >= 2 and t.lower:find("s$") then
      local nxt = old[t.i + 1]
      if nxt and nxt.kind == "punct" and nxt.single and nxt.cs == t.ce + 1 and (nxt.role == "close_quote" or nxt.role == "quote") then
        local after = old[t.i + 2]
        -- treat as possessive only when no opening single quote precedes in this sentence span
        local opened = false
        for z = t.i - 1, math.max(1, t.i - 40), -1 do
          local p = old[z]
          if p.kind == "punct" and p.single and p.role == "open_quote" then opened = true break end
          if p.kind == "punct" and p.role == "sent_end" then break end
        end
        if not opened then
          t.poss_plural = true
          nxt.kind = "word"; nxt.role = nil; nxt.clitic = "poss_pl"; nxt.norm = "'s"; nxt.readings = { "poss" }
          nxt.fold, nxt.lower, nxt.shape, nxt.letters, nxt.script, nxt.single = "'", "'", "'", 0, "common", nil
        end
      end
    end
    if not handled then push(t) end
  end
  an.tokens = new
end

---------------------------------------------------------------- sentence segmentation
function Lex.segment_sentences(an)
  local toks = an.tokens
  local sents, first = {}, 1
  local para = 1
  local function close(last, terminal)
    if last < first then return end
    local a, b = toks[first], toks[last]
    local s = { id = #sents + 1, first_tok = first, last_tok = last, s = a.s, e = b.e, cs = a.cs, ce = b.ce, para = para, terminal = terminal }
    if terminal and terminal:find("%?") then s.question_mark = true end
    -- shouting: most cased tokens all-caps
    local cased, up = 0, 0
    for z = first, last do
      local t = toks[z]
      if t.letters and t.letters >= 2 then cased = cased + 1; if t.allcaps then up = up + 1 end end
    end
    s.shout = cased >= 4 and up / cased >= 0.7
    sents[#sents + 1] = s
    for z = first, last do toks[z].sent = s.id end
    first = last + 1
  end
  local function starts_upper_or_open(t)
    if not t then return true end
    if t.kind == "punct" then return t.role == "open_quote" or t.role == "open_bracket" or t.role == "quote" end
    if t.letters and t.letters > 0 then return t.cap or t.script ~= "latin" and t.script ~= "greek" and t.script ~= "cyrillic" end
    return t.numeric or t.kind == "ident" or t.kind == "url" or t.kind == "ref" or t.kind == "handle" or t.kind == "emoji" or true
  end
  local t = 1
  while t <= #toks do
    local tk = toks[t]
    if tk.nl_before and tk.nl_before >= 2 and t > first then
      close(t - 1, nil); para = para + 1
    elseif tk.line_start and tk.nl_before and tk.nl_before == 1 and t > first and (tk.bullet_hint or false) then
      close(t - 1, nil)
    end
    -- bullets / list markers at line start
    if tk.line_start and (tk.kind == "punct" and (tk.text == "-" or tk.text == "*" or tk.text == "•" or tk.text == "–"))
      and toks[t + 1] and toks[t + 1].ws_before then
      tk.bullet = true
      if t > first then close(t - 1, nil) end
    elseif tk.line_start and tk.numeric and toks[t + 1] and toks[t + 1].kind == "punct" and (toks[t + 1].text == "." or toks[t + 1].text == ")")
      and toks[t + 2] and toks[t + 2].ws_before and tk.value and tk.value < 100 then
      tk.bullet = true
      if t > first then close(t - 1, nil) end
    end
    if tk.kind == "punct" and tk.role == "sent_end" then
      local last = t
      -- absorb closing quotes / brackets that belong to the terminal
      local absorbed_quote = false
      while toks[last + 1] and toks[last + 1].kind == "punct" and (toks[last + 1].role == "close_quote" or toks[last + 1].role == "close_bracket"
        or (toks[last + 1].role == "quote" and toks[last + 1].cs == toks[last].ce + 1)) and not toks[last + 1].ws_before do
        absorbed_quote = absorbed_quote or toks[last + 1].role == "close_quote" or toks[last + 1].role == "quote"
        last = last + 1
      end
      local nxt = toks[last + 1]
      local boundary
      local txt = tk.text
      if not nxt then boundary = true
      elseif nxt.nl_before and nxt.nl_before >= 1 then boundary = true
      elseif txt:find("[!?]") and not tk.ellipsis then
        boundary = not (absorbed_quote and nxt.letters and nxt.letters > 0 and not nxt.cap)
      elseif tk.ellipsis then
        boundary = nxt.cap == true and (nxt.ws_before or false)
      else -- a single period
        local prev = toks[t - 1]
        if prev and not tk.ws_before and nxt and not nxt.ws_before and nxt.cap and prev.letters and prev.letters >= 3 and not prev.cap then
          boundary = true; an.notes[#an.notes + 1] = "missing space after sentence-final period near byte " .. tk.s
        elseif nxt.letters and nxt.letters > 0 then
          boundary = nxt.cap == true or (nxt.script ~= "latin" and nxt.script ~= "greek" and nxt.script ~= "cyrillic")
        else
          boundary = starts_upper_or_open(nxt) and (nxt.numeric or nxt.kind == "punct" or nxt.kind == "ident") and true or false
          if nxt.numeric and not nxt.ws_before then boundary = false end
        end
      end
      if boundary then close(last, txt) end
      t = last + 1
    else
      -- period-ending abbreviation at a sentence end
      if tk.kind == "abbrev" and tk.has_period then
        local nxt = toks[t + 1]
        local low = tk.lower:gsub("%.$", "")
        if (not nxt) or (nxt.nl_before and nxt.nl_before >= 1) then
          close(t, ".");
        elseif not TITLE_ABBR[low] and nxt.cap and nxt.lower and SENT_STARTERS[nxt.lower] then
          close(t, ".")
        end
      elseif tk.kind == "acronym" and tk.has_period then
        local nxt = toks[t + 1]
        if (not nxt) or (nxt.nl_before and nxt.nl_before >= 1) or (nxt.cap and nxt.lower and SENT_STARTERS[nxt.lower]) then close(t, ".") end
      end
      t = t + 1
    end
  end
  if first <= #toks then close(#toks, nil) end
  an.sentences = sents
  -- Shouting is a property of a stretch of text, not of one sentence: "OH. MY. GOODNESS!!!" is three one-word sentences, and a short all-caps exclamation
  -- ("SO COOL!!!") beside shouted text is shouted too.  Capitalisation is then no evidence that a word is a name.
  local para_stats = {}
  local own = {}
  for _, s in ipairs(sents) do
    local c, u = 0, 0
    for z = s.first_tok, s.last_tok do
      local tk2 = toks[z]
      if tk2.letters and tk2.letters >= 2 then c = c + 1; if tk2.allcaps then u = u + 1 end end
    end
    own[s] = { c = c, u = u }
    local ps = para_stats[s.para]
    if not ps then ps = { cased = 0, up = 0 }; para_stats[s.para] = ps end
    ps.cased, ps.up = ps.cased + c, ps.up + u
  end
  for _, s in ipairs(sents) do
    if not s.shout then
      local o, ps = own[s], para_stats[s.para]
      if o.c >= 1 and o.u == o.c and ps.cased >= 3 and ps.up / ps.cased >= 0.7 then s.shout = true
      elseif o.c >= 2 and o.u == o.c and s.terminal and s.terminal:find("!", 1, true) then s.shout = true end
    end
  end
end

---------------------------------------------------------------- elongation ("whaaat", "peruuu", "sooo", "goood")
-- Every run of three or more equal letters is shortened to one or two letters (the more natural length first); the first candidate the caller knows as a word or
-- name wins.  Nothing is guessed beyond that: an elongated word that collapses to nothing known stays as written.
local function deelongate(form, known)
  if not known or type(form) ~= "string" or not form:find("(%a)%1%1") then return nil end
  local parts, runs, pos = {}, {}, 1
  while pos <= #form do
    local c = form:sub(pos, pos)
    local e = pos
    while form:sub(e + 1, e + 1) == c do e = e + 1 end
    if e - pos + 1 >= 3 and c:match("%a") then
      runs[#runs + 1] = #parts + 1
      parts[#parts + 1] = { c = c, n = e - pos + 1, run = true }
    else parts[#parts + 1] = { s = form:sub(pos, e) } end
    pos = e + 1
  end
  if #runs == 0 or #runs > 4 then return nil end
  local combos = {}
  for mask = 0, (1 << #runs) - 1 do
    local bits = 0
    for b = 0, #runs - 1 do if mask & (1 << b) ~= 0 then bits = bits + 1 end end
    combos[#combos + 1] = { mask = mask, bits = bits }
  end
  table.sort(combos, function(a, b) if a.bits ~= b.bits then return a.bits < b.bits end return a.mask < b.mask end)
  for _, cb in ipairs(combos) do
    local out, ri = {}, 0
    for _, p in ipairs(parts) do
      if p.run then
        ri = ri + 1
        local first = (p.n == 3) and 2 or 1
        local pick = (cb.mask & (1 << (ri - 1)) ~= 0) and (3 - first) or first
        out[#out + 1] = p.c:rep(pick)
      else out[#out + 1] = p.s end
    end
    local cand = table.concat(out)
    if cand ~= form and known(cand) then return cand end
  end
  return nil
end

---------------------------------------------------------------- units
local CASE_SENSITIVE_KINDS = S({ "ident", "url", "email", "path", "version", "ref", "doi", "handle", "hashtag", "hash", "ip" })
local ROLE_BARRIER = { comma = "comma", semi = "semi", colon = "colon", sent_end = "sent", open_bracket = "paren_open",
  close_bracket = "paren_close", open_quote = "quote_open", close_quote = "quote_close", quote = "quote", dash = "dash", other = "other" }

function Lex.build_units(an, opts)
  local units, toks = an.units, an.tokens
  local pending = {}
  local spell = opts and opts.spell
  local known = opts and (opts.known or (spell and function(f) return spell:known(f) end)) or nil
  local function push(u)
    u.i = #units + 1
    if #pending > 0 then u.pre = table.concat(pending, ","); pending = {} end
    units[#units + 1] = u
    return u
  end
  for _, t in ipairs(toks) do
    local barrier = nil
    if t.kind == "punct" then barrier = ROLE_BARRIER[t.role or "other"] or "other"
    elseif t.kind == "control" or t.kind == "invalid" or t.kind == "emoji" or t.kind == "symbol" then barrier = t.kind end
    if barrier then
      pending[#pending + 1] = barrier
      if barrier == "sent" and #units > 0 then units[#units].post = (units[#units].post and (units[#units].post .. ",") or "") .. "sent" end
    else
      local base = { tok = t.i, sent = t.sent, kind = t.kind, ws_before = t.ws_before, cap = t.cap, allcaps = t.allcaps, script = t.script,
        numval = t.value, unit = t.unit, ordinal = t.ordinal, mixed_case = t.mixed_case, line_start = t.line_start, has_zw = t.has_zw,
        decade = t.decade, decade2 = t.decade2, signed = t.signed, numtext = t.numtext, currency_symbol = t.currency_symbol }
      local function with(extra) local u = U.shallow(base); for k, v in pairs(extra) do u[k] = v end; return u end
      if t.compound and t.parts then
        for pi, p in ipairs(t.parts) do
          local u = with({ part = pi, raw = p.text, form = p.fold, lower = UC.lower(p.text), s = p.s, e = p.e, cs = p.cs, ce = p.ce,
            hy = true, hy_first = pi == 1, hy_last = pi == #t.parts })
          local c1 = utf8.codepoint(p.text, 1)
          u.cap = UC.is_upper(c1)
          push(u)
        end
      elseif EXPAND[t.lower] and t.kind == "word" and not t.compound and not (EXPAND_LOWER_ONLY[t.lower] and t.text == t.text:upper()) then
        for pi, w in ipairs(EXPAND[t.lower]) do
          push(with({ part = pi, raw = t.text, form = w, lower = w, s = t.s, e = t.e, cs = t.cs, ce = t.ce, expanded = true, neg_clitic = (w == "not") or nil }))
        end
      elseif t.neg_clitic or t.clitic then
        push(with({ raw = t.text, form = t.norm or t.fold, lower = t.norm or t.lower, s = t.s, e = t.e, cs = t.cs, ce = t.ce,
          clitic = t.clitic, readings = t.readings, aux_alt = t.aux_alt, neg_clitic = t.neg_clitic }))
      elseif t.norm then
        push(with({ raw = t.text, form = t.norm, lower = t.norm, s = t.s, e = t.e, cs = t.cs, ce = t.ce, surface_form = t.fold }))
      elseif t.numeric then
        local form = t.numtext and (t.signed == "-" and ("-" .. t.numtext) or t.numtext) or t.fold
        push(with({ raw = t.text, form = form, lower = form, s = t.s, e = t.e, cs = t.cs, ce = t.ce }))
      else
        local form = CASE_SENSITIVE_KINDS[t.kind] and t.text or t.fold
        -- match forms drop the abbreviation/initialism dots ("Dr." -> "dr", "U.S.A." -> "usa"); `raw` keeps them
        if t.kind == "abbrev" or t.kind == "initial" then form = form:gsub("%.$", "")
        elseif t.kind == "acronym" then form = form:gsub("%.", "") end
        -- elongation: "whaaat" / "peruuu" read as the known word they stretch
        local stretched = (t.kind == "word" and not t.alnum) and deelongate(form, known) or nil
        local surface
        if stretched then surface, form = form, stretched end
        local u = push(with({ raw = t.text, form = form, lower = stretched or t.lower, s = t.s, e = t.e, cs = t.cs, ce = t.ce,
          case_sensitive = CASE_SENSITIVE_KINDS[t.kind] or nil, atomic = t.atomic, elongated = stretched and true or nil, surface_form = surface,
          acr = (t.kind == "acronym" or (t.allcaps and t.letters <= 6)) or nil }))
        if spell and t.kind == "word" and t.letters and t.letters >= 4 and not t.alnum and not t.invalid and not u.hy then
          u.unknown = not spell:known(form)
          if u.unknown then u.alts = spell:suggest(form, { cap = t.cap }) end
        end
      end
    end
  end
  an.stats = { tokens = #toks, units = #units, sentences = #an.sentences }
end

---------------------------------------------------------------- cue flags (closed-class, lexicon-independent defaults)
local NEG_FORMS = S({ "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither", "nor", "without", "exclude",
  "excluding", "excluded", "excludes", "exclusion", "except", "excepting", "minus", "unless", "lacking", "absent", "cannot" })
local COND_FORMS = S({ "if", "unless", "provided", "assuming", "otherwise", "whether", "whenever", "once" })
local QUANT_FORMS = S({ "all", "every", "each", "some", "any", "many", "few", "several", "most", "both", "either", "only", "enough", "no" })
local COMP_IRREG = S({ "more", "less", "fewer", "better", "worse", "than", "versus", "vs", "compare", "compared", "comparison", "differ",
  "difference", "differences", "between", "older", "newer", "larger", "smaller", "bigger", "higher", "lower", "longer", "shorter",
  "younger", "earlier", "later", "faster", "slower", "cheaper", "stronger", "weaker", "greater" })
local SUP_IRREG = S({ "most", "least", "fewest", "best", "worst", "oldest", "newest", "largest", "smallest", "biggest", "highest",
  "lowest", "longest", "shortest", "youngest", "earliest", "latest", "fastest", "slowest", "cheapest", "strongest", "greatest", "top",
  "first", "last" })
local ADJ_BASE = S({ "old", "new", "big", "large", "small", "high", "low", "long", "short", "young", "early", "late", "fast", "slow",
  "cheap", "rich", "poor", "strong", "weak", "near", "far", "wide", "narrow", "deep", "tall", "heavy", "light", "hot", "cold", "good",
  "bad", "great", "recent", "popular", "common", "rare", "close", "safe", "simple", "easy", "hard", "large", "major", "minor" })

function Lex.mark_cues(an, opts)
  local cues = an.cues
  for _, u in ipairs(an.units) do
    local f = u.form
    if u.neg_clitic then cues.negation[#cues.negation + 1] = { u = u.i, form = "not", clitic = true } end
    if not u.case_sensitive then
      if NEG_FORMS[f] and not u.neg_clitic then cues.negation[#cues.negation + 1] = { u = u.i, form = f } end
      if COND_FORMS[f] then cues.conditional[#cues.conditional + 1] = { u = u.i, form = f } end
      if QUANT_FORMS[f] then cues.quantifier[#cues.quantifier + 1] = { u = u.i, form = f } end
      if COMP_IRREG[f] then cues.comparative[#cues.comparative + 1] = { u = u.i, form = f } end
      if SUP_IRREG[f] then cues.superlative[#cues.superlative + 1] = { u = u.i, form = f } end
      if u.kind == "word" and #f >= 5 then
        local b = f:match("^(.+)er$")
        if b and (ADJ_BASE[b] or ADJ_BASE[b:gsub("(.)%1$", "%1")] or ADJ_BASE[b .. "e"] or ADJ_BASE[b:gsub("i$", "y")]) then
          cues.comparative[#cues.comparative + 1] = { u = u.i, form = f, base = b }
        end
        b = f:match("^(.+)est$")
        if b and (ADJ_BASE[b] or ADJ_BASE[b:gsub("(.)%1$", "%1")] or ADJ_BASE[b .. "e"] or ADJ_BASE[b:gsub("i$", "y")]) then
          cues.superlative[#cues.superlative + 1] = { u = u.i, form = f, base = b }
        end
      end
    end
  end
end

---------------------------------------------------------------- accessors
function Lex.slice(an, t) return an.original:sub(t.s, t.e) end

function Lex.describe(an)
  local out = {}
  for _, t in ipairs(an.tokens) do
    out[#out + 1] = string.format("%s:%s[%d-%d]", t.kind, t.text, t.s, t.e)
  end
  return table.concat(out, " ")
end

function Lex.capabilities() return UC.capabilities end

return Lex
