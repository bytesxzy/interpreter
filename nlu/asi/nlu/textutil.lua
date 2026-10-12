-- asi.nlu.textutil: index-side tokenisation shared by memory and dataset retrieval.
-- This is NOT the interpreter's lexer (asi.nlu.lex keeps offsets, case and ambiguity for understanding); it produces folded, lightly stemmed
-- terms with positions for retrieval.  Non-ASCII bytes are treated as word characters and folded with the documented unicode subset.
local UC = require("asi.nlu.unicode")

local TU = {}

TU.STOP = {}
for w in ([[the a an of and or to in on at by for with is are was were be been being it its as that this which what who whom how do does did
  i you we me my your our please can could would should will shall may might from into than then there their they them he she his her not no]]):gmatch("%S+") do
  TU.STOP[w] = true
end

-- deterministic light stemmer: inflection only (decided/decide/deciding -> decid), applied identically to documents and queries
function TU.stem(w)
  if #w <= 3 then return w end
  local s = w
  if s:match("ies$") and #s > 4 then s = s:sub(1, -4) .. "y"
  elseif s:match("ied$") and #s > 4 then s = s:sub(1, -4) .. "y"
  elseif s:match("ing$") and #s > 5 then s = s:sub(1, -4)
  elseif s:match("ed$") and #s > 4 then s = s:sub(1, -3)
  elseif s:match("es$") and #s > 4 then s = s:sub(1, -3)
  elseif s:match("s$") and not s:match("ss$") and #s > 3 then s = s:sub(1, -2) end
  s = s:gsub("e$", "")
  return s
end

-- tokens(text, {keep_stop, raw}) -> list of {t = term, w = folded word, pos = ordinal, s = byte start, e = byte end}
function TU.tokens(text, opts)
  opts = opts or {}
  local out = {}
  local pos = 0
  local i, n = 1, #text
  while i <= n do
    local s, e = text:find("[%w\128-\255][%w\128-\255]*", i)
    if not s then break end
    local w = text:sub(s, e)
    if w:find("[\128-\255]") then w = UC.fold(w) else w = w:lower() end
    -- possessive / clitic: "France's" -> "france"
    local nxt = text:sub(e + 1, e + 2)
    if nxt == "'s" or nxt == "\226\128\153" then end
    pos = pos + 1
    if opts.keep_stop or not TU.STOP[w] then
      out[#out + 1] = { t = opts.raw and w or TU.stem(w), w = w, pos = pos, s = s, e = e }
    end
    i = e + 1
  end
  return out
end

function TU.terms(text, opts)
  local out = {}
  for _, t in ipairs(TU.tokens(text, opts)) do out[#out + 1] = t.t end
  return out
end

return TU
