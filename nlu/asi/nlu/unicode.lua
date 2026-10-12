-- asi.nlu.unicode: strict UTF-8 decoding + a DOCUMENTED SUBSET of Unicode behaviour.
--
-- Supported (tested): ASCII, Latin-1 Supplement, Latin Extended-A, Latin Extended Additional (Vietnamese
-- block), Greek, Cyrillic, Armenian case mapping; combining marks U+0300-036F treated as marks; common
-- punctuation/space/symbol/digit classes; script identification for ~20 blocks.
-- NOT supported (explicit): full NFC/NFD/NFKC normalisation, locale-specific casing (Turkish i), word
-- segmentation of unspaced scripts (Han/Kana/Thai), bidi, grapheme clusters, emoji sequences.
-- Unknown code points >= 0x80 are treated as word characters of script "other" with no case folding.
local UC = {}

UC.capabilities = {
  utf8 = "strict decode; invalid bytes reported, never dropped",
  case_folding = { "latin", "latin1", "latin-ext-a", "latin-ext-additional", "greek", "cyrillic", "armenian" },
  diacritic_folding = { "latin1", "latin-ext-a", "vietnamese", "greek-tonos" },
  normalization = "partial: combining marks U+0300-036F stripped in folded form only; no NFC/NFD composition",
  segmentation = { "whitespace+punctuation (all scripts)", "no dictionary segmentation for han/kana/thai/hangul" },
  unsupported = { "turkish/azeri dotted-i casing", "full unicode normalization", "bidi", "emoji ZWJ sequences" },
}

---------------------------------------------------------------- strict decode
function UC.decode(s)
  local cp, bs, be, inv, n, i, len = {}, {}, {}, {}, 0, 1, #s
  local byte = string.byte
  while i <= len do
    local c = byte(s, i)
    local need, v, min = 0, c, 0
    if c < 0x80 then need = 0
    elseif c >= 0xC2 and c <= 0xDF then need, v, min = 1, c & 0x1F, 0x80
    elseif c >= 0xE0 and c <= 0xEF then need, v, min = 2, c & 0x0F, 0x800
    elseif c >= 0xF0 and c <= 0xF4 then need, v, min = 3, c & 0x07, 0x10000
    else need = -1 end
    local ok = need >= 0
    if ok and need > 0 then
      if i + need > len then ok = false
      else
        for k = 1, need do
          local cc = byte(s, i + k)
          if cc & 0xC0 ~= 0x80 then ok = false break end
          v = (v << 6) | (cc & 0x3F)
        end
        if ok and (v < min or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) then ok = false end
      end
    end
    n = n + 1
    if ok then
      cp[n], bs[n], be[n] = v, i, i + need
      i = i + need + 1
    else
      cp[n], bs[n], be[n] = 0xFFFD, i, i
      inv[#inv + 1] = n
      i = i + 1
    end
  end
  return { cp = cp, bs = bs, be = be, n = n, invalid = inv }
end

function UC.encode(c) if c < 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF) then c = 0xFFFD end return utf8.char(c) end

---------------------------------------------------------------- classes
-- class letters: L letter, N digit, M mark, P punctuation, S symbol, Z space, C control/format, O other(word-like)
local ASCII = {}
for c = 0, 31 do ASCII[c] = "C" end
ASCII[127] = "C"
for _, c in ipairs({ 9, 10, 11, 12, 13, 32 }) do ASCII[c] = "Z" end
for c = 48, 57 do ASCII[c] = "N" end
for c = 65, 90 do ASCII[c] = "L" end
for c = 97, 122 do ASCII[c] = "L" end
for c in ("!\"#%&'()*,-./:;?@[\\]_{}"):gmatch(".") do ASCII[c:byte()] = "P" end
for c in ("$+<=>^`|~"):gmatch(".") do ASCII[c:byte()] = "S" end

-- {lo, hi, class} sorted ascending, non-overlapping; checked by binary search
local R = {
  { 0x80, 0x84, "C" }, { 0x85, 0x85, "Z" }, { 0x86, 0x9F, "C" }, { 0xA0, 0xA0, "Z" }, { 0xA1, 0xA1, "P" },
  { 0xA2, 0xA9, "S" }, { 0xAA, 0xAA, "L" }, { 0xAB, 0xAB, "P" }, { 0xAC, 0xAC, "S" }, { 0xAD, 0xAD, "C" },
  { 0xAE, 0xB1, "S" }, { 0xB2, 0xB3, "N" }, { 0xB4, 0xB4, "S" }, { 0xB5, 0xB5, "L" }, { 0xB6, 0xB7, "P" },
  { 0xB8, 0xB8, "S" }, { 0xB9, 0xB9, "N" }, { 0xBA, 0xBA, "L" }, { 0xBB, 0xBB, "P" }, { 0xBC, 0xBE, "N" },
  { 0xBF, 0xBF, "P" }, { 0xC0, 0xD6, "L" }, { 0xD7, 0xD7, "S" }, { 0xD8, 0xF6, "L" }, { 0xF7, 0xF7, "S" },
  { 0xF8, 0x2C1, "L" }, { 0x2C2, 0x2C5, "S" }, { 0x2C6, 0x2D1, "L" }, { 0x2D2, 0x2DF, "S" }, { 0x2E0, 0x2FF, "L" },
  { 0x300, 0x36F, "M" }, { 0x370, 0x373, "L" }, { 0x374, 0x375, "S" }, { 0x376, 0x377, "L" }, { 0x37A, 0x37D, "L" },
  { 0x37E, 0x37E, "P" }, { 0x37F, 0x37F, "L" }, { 0x384, 0x385, "S" }, { 0x386, 0x386, "L" }, { 0x387, 0x387, "P" },
  { 0x388, 0x3F5, "L" }, { 0x3F6, 0x3F6, "S" }, { 0x3F7, 0x481, "L" }, { 0x482, 0x482, "S" }, { 0x483, 0x489, "M" },
  { 0x48A, 0x52F, "L" }, { 0x531, 0x556, "L" }, { 0x559, 0x559, "L" }, { 0x55A, 0x55F, "P" }, { 0x560, 0x588, "L" },
  { 0x589, 0x58A, "P" }, { 0x591, 0x5BD, "M" }, { 0x5BE, 0x5BE, "P" }, { 0x5C0, 0x5C0, "P" }, { 0x5D0, 0x5EA, "L" },
  { 0x600, 0x605, "C" }, { 0x60C, 0x60D, "P" }, { 0x61B, 0x61B, "P" }, { 0x61F, 0x61F, "P" }, { 0x620, 0x64A, "L" },
  { 0x64B, 0x65F, "M" }, { 0x660, 0x669, "N" }, { 0x66A, 0x66D, "P" }, { 0x66E, 0x6D3, "L" }, { 0x6D4, 0x6D4, "P" },
  { 0x6D5, 0x6DC, "L" }, { 0x6F0, 0x6F9, "N" }, { 0x700, 0x70D, "P" }, { 0x900, 0x903, "M" }, { 0x904, 0x939, "L" },
  { 0x93A, 0x94F, "M" }, { 0x950, 0x950, "L" }, { 0x951, 0x957, "M" }, { 0x958, 0x961, "L" }, { 0x962, 0x963, "M" },
  { 0x964, 0x965, "P" }, { 0x966, 0x96F, "N" }, { 0x970, 0x970, "P" }, { 0x971, 0x97F, "L" }, { 0xE01, 0xE30, "L" },
  { 0xE31, 0xE31, "M" }, { 0xE32, 0xE33, "L" }, { 0xE34, 0xE3A, "M" }, { 0xE3F, 0xE3F, "S" }, { 0xE40, 0xE46, "L" },
  { 0xE47, 0xE4E, "M" }, { 0xE4F, 0xE4F, "P" }, { 0xE50, 0xE59, "N" }, { 0x10A0, 0x10FF, "L" }, { 0x1100, 0x11FF, "L" },
  { 0x1AB0, 0x1AFF, "M" }, { 0x1DC0, 0x1DFF, "M" }, { 0x1E00, 0x1FFF, "L" }, { 0x2000, 0x200A, "Z" },
  { 0x200B, 0x200F, "C" }, { 0x2010, 0x2027, "P" }, { 0x2028, 0x2029, "Z" }, { 0x202A, 0x202E, "C" },
  { 0x202F, 0x202F, "Z" }, { 0x2030, 0x205E, "P" }, { 0x205F, 0x205F, "Z" }, { 0x2060, 0x206F, "C" },
  { 0x2070, 0x2070, "N" }, { 0x2071, 0x2071, "L" }, { 0x2074, 0x2079, "N" }, { 0x207A, 0x207E, "S" }, { 0x207F, 0x207F, "L" },
  { 0x2080, 0x2089, "N" }, { 0x208A, 0x208E, "S" }, { 0x2090, 0x209C, "L" }, { 0x20A0, 0x20CF, "S" }, { 0x20D0, 0x20FF, "M" },
  { 0x2100, 0x214F, "S" }, { 0x2150, 0x218B, "N" }, { 0x2190, 0x23FF, "S" }, { 0x2460, 0x249B, "N" }, { 0x2500, 0x27BF, "S" },
  { 0x2E00, 0x2E4F, "P" }, { 0x3000, 0x3000, "Z" }, { 0x3001, 0x3003, "P" }, { 0x3005, 0x3007, "L" }, { 0x3008, 0x3011, "P" },
  { 0x3012, 0x3013, "S" }, { 0x3014, 0x301F, "P" }, { 0x3021, 0x3029, "N" }, { 0x3041, 0x3096, "L" }, { 0x3099, 0x309A, "M" },
  { 0x309B, 0x309C, "S" }, { 0x309D, 0x309F, "L" }, { 0x30A0, 0x30A0, "P" }, { 0x30A1, 0x30FA, "L" }, { 0x30FB, 0x30FB, "P" },
  { 0x30FC, 0x30FF, "L" }, { 0x3105, 0x312F, "L" }, { 0x3130, 0x318E, "L" }, { 0x31F0, 0x31FF, "L" }, { 0x3400, 0x4DBF, "L" },
  { 0x4E00, 0x9FFF, "L" }, { 0xA000, 0xA4CF, "L" }, { 0xAC00, 0xD7AF, "L" }, { 0xF900, 0xFAFF, "L" },
  { 0xFB00, 0xFB06, "L" }, { 0xFE00, 0xFE0F, "M" }, { 0xFE20, 0xFE2F, "M" }, { 0xFE30, 0xFE6B, "P" }, { 0xFEFF, 0xFEFF, "C" },
  { 0xFF01, 0xFF0F, "P" }, { 0xFF10, 0xFF19, "N" }, { 0xFF1A, 0xFF20, "P" }, { 0xFF21, 0xFF3A, "L" }, { 0xFF3B, 0xFF40, "P" },
  { 0xFF41, 0xFF5A, "L" }, { 0xFF5B, 0xFF65, "P" }, { 0xFF66, 0xFFDC, "L" }, { 0xFFE0, 0xFFEE, "S" }, { 0xFFFC, 0xFFFD, "S" },
  { 0x1D400, 0x1D7FF, "L" }, { 0x1F000, 0x1FAFF, "S" }, { 0x20000, 0x2FA1F, "L" }, { 0xE0000, 0xE007F, "C" },
}

function UC.class(c)
  if c < 128 then return ASCII[c] or "O" end
  local lo, hi = 1, #R
  while lo <= hi do
    local mid = (lo + hi) >> 1
    local r = R[mid]
    if c < r[1] then hi = mid - 1 elseif c > r[2] then lo = mid + 1 else return r[3] end
  end
  return "O"
end

local SCRIPTS = {
  { 0x0041, 0x024F, "latin" }, { 0x0250, 0x02FF, "latin" }, { 0x0370, 0x03FF, "greek" }, { 0x0400, 0x052F, "cyrillic" },
  { 0x0531, 0x058F, "armenian" }, { 0x0590, 0x05FF, "hebrew" }, { 0x0600, 0x06FF, "arabic" }, { 0x0900, 0x097F, "devanagari" },
  { 0x0E00, 0x0E7F, "thai" }, { 0x10A0, 0x10FF, "georgian" }, { 0x1100, 0x11FF, "hangul" }, { 0x1E00, 0x1EFF, "latin" },
  { 0x1F00, 0x1FFF, "greek" }, { 0x3040, 0x309F, "hiragana" }, { 0x30A0, 0x30FF, "katakana" }, { 0x3130, 0x318F, "hangul" },
  { 0x3400, 0x4DBF, "han" }, { 0x4E00, 0x9FFF, "han" }, { 0xAC00, 0xD7AF, "hangul" }, { 0xF900, 0xFAFF, "han" },
  { 0xFF21, 0xFF5A, "latin" }, { 0x20000, 0x2FA1F, "han" },
}
function UC.script(c)
  if c < 0x80 then
    if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then return "latin" end
    return "common"
  end
  if c >= 0xC0 and c <= 0x24F then return "latin" end
  for i = 1, #SCRIPTS do
    local r = SCRIPTS[i]
    if c >= r[1] and c <= r[2] then return r[3] end
  end
  local k = UC.class(c)
  if k == "L" or k == "O" then return "other" end
  return "common"
end

-- scripts without whitespace word boundaries: tokenised as runs, flagged `unsegmented`
UC.unsegmented = { han = true, hiragana = true, katakana = true, thai = true }

---------------------------------------------------------------- case mapping
local function even_odd(c, lo, hi) -- even = upper, odd = lower within [lo, hi]
  if c >= lo and c <= hi then return (c - lo) % 2 == 0 and "U" or "L" end
end
local function odd_even(c, lo, hi) -- odd = upper, even = lower
  if c >= lo and c <= hi then return (c - lo) % 2 == 0 and "U" or "L" end
end

-- returns "U", "L" or nil (uncased / unknown) and the case partner code point
local function case_info(c)
  if c < 128 then
    if c >= 65 and c <= 90 then return "U", c + 32 end
    if c >= 97 and c <= 122 then return "L", c - 32 end
    return nil
  end
  if c >= 0xC0 and c <= 0xDE and c ~= 0xD7 then return "U", c + 32 end
  if c >= 0xE0 and c <= 0xFE and c ~= 0xF7 then return "L", c - 32 end
  if c == 0xFF then return "L", 0x178 end
  if c == 0xDF or c == 0xB5 or c == 0xAA or c == 0xBA then return "L", nil end
  if c >= 0x100 and c <= 0x17F then
    if c == 0x130 then return "U", 0x69 end
    if c == 0x131 then return "L", 0x49 end
    if c == 0x138 or c == 0x149 then return "L", nil end
    if c == 0x178 then return "U", 0xFF end
    if c == 0x17F then return "L", 0x53 end
    local k
    if c <= 0x137 then k = even_odd(c, 0x100, 0x137)
    elseif c <= 0x148 then k = odd_even(c, 0x139, 0x148)
    elseif c <= 0x177 then k = even_odd(c, 0x14A, 0x177)
    else k = odd_even(c, 0x179, 0x17E) end
    if k == "U" then return "U", c + 1 elseif k == "L" then return "L", c - 1 end
    return nil
  end
  if c >= 0x1E00 and c <= 0x1EFF then
    if c >= 0x1E96 and c <= 0x1E9F then return "L", nil end
    return ((c % 2 == 0) and "U" or "L"), ((c % 2 == 0) and c + 1 or c - 1)
  end
  if c >= 0x391 and c <= 0x3AB and c ~= 0x3A2 then return "U", c + 32 end
  if c >= 0x3B1 and c <= 0x3CB then return "L", c - 32 end
  if c == 0x386 then return "U", 0x3AC end
  if c >= 0x388 and c <= 0x38A then return "U", c + 37 end
  if c == 0x38C then return "U", 0x3CC end
  if c == 0x38E or c == 0x38F then return "U", c + 63 end
  if c == 0x3AC then return "L", 0x386 end
  if c >= 0x3AD and c <= 0x3AF then return "L", c - 37 end
  if c == 0x3CC then return "L", 0x38C end
  if c == 0x3CD or c == 0x3CE then return "L", c - 63 end
  if c == 0x3C2 then return "L", 0x3A3 end
  if c >= 0x410 and c <= 0x42F then return "U", c + 32 end
  if c >= 0x430 and c <= 0x44F then return "L", c - 32 end
  if c >= 0x400 and c <= 0x40F then return "U", c + 80 end
  if c >= 0x450 and c <= 0x45F then return "L", c - 80 end
  if c >= 0x460 and c <= 0x481 then return ((c % 2 == 0) and "U" or "L"), ((c % 2 == 0) and c + 1 or c - 1) end
  if c >= 0x48A and c <= 0x4BF then return ((c % 2 == 0) and "U" or "L"), ((c % 2 == 0) and c + 1 or c - 1) end
  if c == 0x4C0 then return "U", 0x4CF end
  if c == 0x4CF then return "L", 0x4C0 end
  if c >= 0x4C1 and c <= 0x4CE then return ((c % 2 == 1) and "U" or "L"), ((c % 2 == 1) and c + 1 or c - 1) end
  if c >= 0x4D0 and c <= 0x52F then return ((c % 2 == 0) and "U" or "L"), ((c % 2 == 0) and c + 1 or c - 1) end
  if c >= 0x531 and c <= 0x556 then return "U", c + 48 end
  if c >= 0x561 and c <= 0x586 then return "L", c - 48 end
  if c >= 0xFF21 and c <= 0xFF3A then return "U", c + 32 end
  if c >= 0xFF41 and c <= 0xFF5A then return "L", c - 32 end
  return nil
end

function UC.is_upper(c) return (case_info(c)) == "U" end
function UC.is_lower(c) return (case_info(c)) == "L" end
function UC.is_cased(c) return case_info(c) ~= nil end
function UC.lower_cp(c)
  local k, p = case_info(c)
  if k == "U" and p then return p end
  return c
end
function UC.upper_cp(c)
  local k, p = case_info(c)
  if k == "L" and p then return p end
  return c
end

---------------------------------------------------------------- diacritic / ligature folding
local DIA = {}
local function group(base, chars)
  local i = 0
  for _, c in utf8.codes(chars) do
    i = i + 1
    DIA[c] = base
  end
end
for _, g in ipairs({
  { "A", "ÀÁÂÃÄÅĀĂĄ" }, { "a", "àáâãäåāăą" }, { "AE", "ÆǼ" }, { "ae", "æǽ" }, { "C", "ÇĆĈĊČ" }, { "c", "çćĉċč" },
  { "D", "ĎĐÐ" }, { "d", "ďđð" }, { "E", "ÈÉÊËĒĔĖĘĚ" }, { "e", "èéêëēĕėęě" }, { "G", "ĜĞĠĢ" }, { "g", "ĝğġģ" },
  { "H", "ĤĦ" }, { "h", "ĥħ" }, { "I", "ÌÍÎÏĨĪĬĮİ" }, { "i", "ìíîïĩīĭįı" }, { "IJ", "Ĳ" }, { "ij", "ĳ" },
  { "J", "Ĵ" }, { "j", "ĵ" }, { "K", "Ķ" }, { "k", "ķĸ" }, { "L", "ĹĻĽĿŁ" }, { "l", "ĺļľŀł" },
  { "N", "ÑŃŅŇŊ" }, { "n", "ñńņňŋ" }, { "'n", "ŉ" }, { "O", "ÒÓÔÕÖØŌŎŐ" }, { "o", "òóôõöøōŏő" },
  { "OE", "Œ" }, { "oe", "œ" }, { "R", "ŔŖŘ" }, { "r", "ŕŗř" }, { "S", "ŚŜŞŠ" }, { "s", "śŝşšſ" },
  { "T", "ŢŤŦ" }, { "t", "ţťŧ" }, { "U", "ÙÚÛÜŨŪŬŮŰŲ" }, { "u", "ùúûüũūŭůűų" }, { "W", "Ŵ" }, { "w", "ŵ" },
  { "Y", "ÝŶŸ" }, { "y", "ýÿŷ" }, { "Z", "ŹŻŽ" }, { "z", "źżž" }, { "TH", "Þ" }, { "th", "þ" }, { "ss", "ß" },
  { "α", "ά" }, { "ε", "έ" }, { "η", "ή" }, { "ι", "ίϊΐ" }, { "ο", "ό" }, { "υ", "ύϋΰ" }, { "ω", "ώ" }, { "σ", "ς" },
  { "ff", "ﬀ" }, { "fi", "ﬁ" }, { "fl", "ﬂ" }, { "ffi", "ﬃ" }, { "ffl", "ﬄ" }, { "st", "ﬅﬆ" },
}) do group(g[1], g[2]) end
-- Vietnamese block U+1EA0..U+1EF9 : base letter by sub-range (upper/lower alternate)
for _, r in ipairs({ { 0x1EA0, 0x1EB7, "a" }, { 0x1EB8, 0x1EC7, "e" }, { 0x1EC8, 0x1ECB, "i" }, { 0x1ECC, 0x1EE3, "o" },
  { 0x1EE4, 0x1EF1, "u" }, { 0x1EF2, 0x1EF9, "y" } }) do
  for c = r[1], r[2] do DIA[c] = (c % 2 == 0) and r[3]:upper() or r[3] end
end
DIA[0x1E9E] = "ss"

local FULLWIDTH_SPACE = 0x3000

-- Comparison fold of ONE code point: lowercase + strip diacritics/ligatures + width folding.
-- Returns a string ("" for marks / zero-width). Original text is never modified; this is a *comparison* form.
function UC.fold_cp(c)
  if c < 128 then
    if c >= 65 and c <= 90 then return string.char(c + 32) end
    return string.char(c)
  end
  local cls = UC.class(c)
  if cls == "M" then return "" end
  if cls == "C" then return "" end
  if c == 0xA0 or c == 0x202F or c == FULLWIDTH_SPACE or (c >= 0x2000 and c <= 0x200A) then return " " end
  if c >= 0xFF01 and c <= 0xFF5E then return UC.fold_cp(c - 0xFEE0) end
  local d = DIA[c] or DIA[UC.lower_cp(c)] -- uppercase accented Greek is only listed in lowercase form
  if d then
    if d:byte() < 128 then return d:lower() end
    local lc = utf8.codepoint(d, 1)
    return utf8.char(UC.lower_cp(lc))
  end
  if c == 0x2018 or c == 0x2019 or c == 0x2032 or c == 0x2B9 or c == 0x2BC then return "'" end
  if c == 0x201C or c == 0x201D or c == 0x2033 then return '"' end
  if c >= 0x2010 and c <= 0x2015 or c == 0x2212 then return "-" end
  if c == 0x2026 then return "..." end
  return utf8.char(UC.lower_cp(c))
end

-- Fold a decoded slice [i, j] (indices into dec.cp) into a comparison string.
function UC.fold_slice(dec, i, j)
  local out = {}
  local cp = dec.cp
  for k = i, j do out[#out + 1] = UC.fold_cp(cp[k]) end
  return table.concat(out)
end

function UC.fold(s)
  local dec = UC.decode(s)
  return UC.fold_slice(dec, 1, dec.n)
end

-- lowercase only (keeps diacritics)
function UC.lower(s)
  local dec, out = UC.decode(s), {}
  for k = 1, dec.n do out[k] = utf8.char(UC.lower_cp(dec.cp[k])) end
  return table.concat(out)
end

function UC.digit_value(c)
  if c >= 48 and c <= 57 then return c - 48 end
  if c >= 0xFF10 and c <= 0xFF19 then return c - 0xFF10 end
  if c >= 0x660 and c <= 0x669 then return c - 0x660 end
  if c >= 0x6F0 and c <= 0x6F9 then return c - 0x6F0 end
  if c >= 0x966 and c <= 0x96F then return c - 0x966 end
  if c >= 0xE50 and c <= 0xE59 then return c - 0xE50 end
  if c >= 0xB2 and c <= 0xB3 then return c - 0xB0 end
  if c == 0xB9 then return 1 end
  return nil
end

---------------------------------------------------------------- punctuation roles (used by the tokenizer)
local function S(str) local t = {}; for _, c in utf8.codes(str) do t[c] = true end; return t end
UC.sent_end = S(".!?…。！？‼⁇⁈⁉")
UC.clause_punct = S(",;:，；：、")
UC.open_quote = S("“‘«„‚‹「『")
UC.close_quote = S("”’»‹」』")
UC.amb_quote = S("\"'")
UC.open_bracket = S("([{（［｛【〔〈《")
UC.close_bracket = S(")]}）］｝】〕〉》")
UC.dash = S("-‐‑‒–—―−")
UC.hyphen = S("-‐‑")
UC.apostrophe = S("'’ʼ")
UC.currency = S("$€£¥₹¢₩₽₿₪₫₺")
UC.bullet = S("•·‣◦▪●○-*–—")

return UC
