-- asi.nlu.perturb: deterministic, seeded text perturbations that keep the MEANING of a case (so its gold stays valid) while degrading the surface:
-- typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.  Used to generate the noisy-input distribution
-- on which confidence calibration is fitted and robustness is measured.  Entity strings named by the gold are protected from typos / deletions.
local U = require("asi.nlu.util")

local X = {}

local NEIGHBOURS = {
  q = "wa", w = "qes", e = "wrd", r = "etf", t = "ryg", y = "tuh", u = "yij", i = "uok", o = "ipl", p = "ol", a = "qsz", s = "awdx", d = "serfc", f = "drtgv",
  g = "ftyhb", h = "gyujn", j = "huikm", k = "jiol", l = "kop", z = "asx", x = "zsdc", c = "xdfv", v = "cfgb", b = "vghn", n = "bhjm", m = "njk",
}
local FILLERS = { "please", "so", "um", "well", "actually", "just", "kindly", "like" }

X.OPS = { "typo", "filler", "lowercase", "drop_punct", "drop_det" }

-- byte ranges of the gold entity strings inside the text (case-insensitive)
local function protected_ranges(text, protect)
  local ranges, low = {}, text:lower()
  for _, p in ipairs(protect or {}) do
    local q = p:lower()
    if #q >= 2 then
      local from = 1
      while true do
        local a, b = low:find(q, from, true)
        if not a then break end
        ranges[#ranges + 1] = { a, b }
        from = b + 1
      end
    end
  end
  return ranges
end

local function in_ranges(ranges, a, b)
  for _, r in ipairs(ranges) do if a <= r[2] and b >= r[1] then return true end end
  return false
end

local function words(text)
  local out = {}
  for a, w, b in text:gmatch("()([%a][%a'%-]*)()") do out[#out + 1] = { s = a, e = b - 1, w = w } end
  return out
end

local function typo_word(w, rng)
  local n = #w
  if n < 4 then return w end
  local kind = rng:int(1, 4)
  local i = rng:int(2, n - 1)
  if kind == 1 then return w:sub(1, i - 1) .. w:sub(i + 1, i + 1) .. w:sub(i, i) .. w:sub(i + 2)             -- transpose
  elseif kind == 2 then return w:sub(1, i - 1) .. w:sub(i + 1)                                               -- delete
  elseif kind == 3 then return w:sub(1, i) .. w:sub(i, i) .. w:sub(i + 1)                                    -- duplicate
  else
    local c = w:sub(i, i):lower()
    local nb = NEIGHBOURS[c]
    if not nb then return w end
    local k = rng:int(1, #nb)
    return w:sub(1, i - 1) .. nb:sub(k, k) .. w:sub(i + 1)                                                   -- neighbouring key
  end
end

local function replace_range(text, a, b, rep) return text:sub(1, a - 1) .. rep .. text:sub(b + 1) end

-- apply one operator; returns new text (unchanged if the operator found nothing to do)
function X.apply_op(text, op, protect, rng)
  local ranges = protected_ranges(text, protect)
  if op == "lowercase" then return text:lower() end
  if op == "drop_punct" then return (text:gsub("[%?%.!,;]+%s*$", ""):gsub(",", "")) end
  local ws = words(text)
  local cands = {}
  for _, w in ipairs(ws) do
    if not in_ranges(ranges, w.s, w.e) then
      if op == "typo" and #w.w >= 4 then cands[#cands + 1] = w
      elseif op == "drop_det" and (w.w:lower() == "the" or w.w:lower() == "a" or w.w:lower() == "an") then cands[#cands + 1] = w
      elseif op == "filler" then cands[#cands + 1] = w end
    end
  end
  if #cands == 0 then return text end
  local w = cands[rng:int(1, #cands)]
  if op == "typo" then return replace_range(text, w.s, w.e, typo_word(w.w, rng)) end
  if op == "drop_det" then
    local e = w.e
    if text:sub(e + 1, e + 1) == " " then e = e + 1 end
    return replace_range(text, w.s, e, "")
  end
  if op == "filler" then return replace_range(text, w.s, w.s - 1, FILLERS[rng:int(1, #FILLERS)] .. " ") end
  return text
end

-- text -> perturbed text using `n_ops` distinct operators drawn at random
function X.perturb(text, protect, rng, n_ops)
  local ops = {}
  for _, o in ipairs(X.OPS) do ops[#ops + 1] = o end
  local out, applied = text, {}
  for _ = 1, n_ops do
    local i = rng:int(1, #ops)
    local op = table.remove(ops, i)
    local nt = X.apply_op(out, op, protect, rng)
    if nt ~= out then applied[#applied + 1] = op; out = nt end
  end
  return out, applied
end

-- entity strings named by a gold table (the part before the first ':' of from/to/subject/... values, and the items of lists) plus every word of at least
-- four letters that the gold itself embeds (topics of negations / preferences, instruction values): perturbing those would invalidate the gold
function X.protect_list(gold, text)
  local out = {}
  for _, k in ipairs({ "neg", "pos", "pref", "src", "inst", "tc", "ctx" }) do
    local v = gold[k]
    if v and text then
      for w in v:gmatch("%a%a%a%a+") do
        local lw = w:lower()
        for tw in text:lower():gmatch("%a+") do if tw:sub(1, #lw) == lw or lw:sub(1, #tw) == tw and #tw >= 4 then out[#out + 1] = tw end end
      end
    end
  end
  for _, k in ipairs({ "from", "to", "subject", "concept", "target", "focus", "object" }) do
    local v = gold[k]
    if v and v ~= "-" then out[#out + 1] = (v:match("^([^:]+)")) end
  end
  if gold.items then for it in (gold.items .. "|"):gmatch("(.-)|") do if it ~= "" then out[#out + 1] = it end end end
  return out
end

return X
