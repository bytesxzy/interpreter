-- asi.nlu.spell: conservative typo candidates via a symmetric-delete index (prefix-bounded).
-- It NEVER rewrites input: it returns alternatives with distances; the semantic layer decides whether to use them.
-- Known words are never "corrected". Words shorter than 4 code points get no suggestions.
local U = require("asi.nlu.util")

local Spell = {}
Spell.__index = Spell

local PREFIX = 7

local function len(s) return utf8.len(s) or #s end

local function char_deletes(s, maxd, out, seen)
  out = out or {}
  seen = seen or {}
  local function rec(str, d)
    if d == 0 then return end
    local n = len(str)
    for i = 1, n do
      local a = utf8.offset(str, i)
      local b = utf8.offset(str, i + 1) or (#str + 1)
      local del = str:sub(1, a - 1) .. str:sub(b)
      if not seen[del] then seen[del] = true; out[#out + 1] = del; rec(del, d - 1) end
    end
  end
  seen[s] = true
  out[#out + 1] = s
  rec(s, maxd)
  return out
end

local function max_edit_for(n)
  if n < 4 then return 0 elseif n <= 7 then return 1 else return 2 end
end

function Spell.new(opts)
  opts = opts or {}
  return setmetatable({ words = {}, index = {}, n = 0, kinds = {} }, Spell)
end

function Spell:known(form) return self.words[form] ~= nil end

function Spell:add(form, weight, kind)
  if not form or form == "" then return end
  local cur = self.words[form]
  if cur then
    if weight and weight > cur then self.words[form] = weight end
    if kind and not self.kinds[form] then self.kinds[form] = kind end
    return
  end
  self.words[form] = weight or 1
  self.kinds[form] = kind
  self.n = self.n + 1
  local n = len(form)
  if n < 3 then return end
  local pre = form
  if n > PREFIX then pre = form:sub(1, utf8.offset(form, PREFIX + 1) - 1) end
  for _, d in ipairs(char_deletes(pre, 2)) do
    local bucket = self.index[d]
    if not bucket then bucket = {}; self.index[d] = bucket end
    bucket[#bucket + 1] = form
  end
end

function Spell:add_all(list, weight, kind)
  for _, w in ipairs(list) do self:add(w, weight, kind) end
end

-- returns up to opts.limit candidates {form, dist, weight, kind, transposition, conf}
function Spell:suggest(form, o)
  o = o or {}
  local n = len(form)
  local maxd = o.max_edit or max_edit_for(n)
  if maxd == 0 or self.words[form] then return {} end
  local pre = form
  if n > PREFIX then pre = form:sub(1, utf8.offset(form, PREFIX + 1) - 1) end
  local cands, seen = {}, {}
  for _, d in ipairs(char_deletes(pre, maxd)) do
    local bucket = self.index[d]
    if bucket then
      for _, w in ipairs(bucket) do
        if not seen[w] then
          seen[w] = true
          local dist = U.osa(form, w, maxd)
          if dist <= maxd then
            local c = { form = w, dist = dist, weight = self.words[w], kind = self.kinds[w] }
            c.first_same = form:sub(1, 1) == w:sub(1, 1) -- typos rarely hit the first letter
            cands[#cands + 1] = c
          end
        end
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.first_same ~= b.first_same then return a.first_same end
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.form < b.form
  end)
  local out = {}
  local lim = o.limit or 3
  for i = 1, math.min(lim, #cands) do
    local c = cands[i]
    -- raw (uncalibrated) confidence: unique best at its distance, first letter preserved, longer words
    local rivals = 0
    for j = 1, #cands do if j ~= i and cands[j].dist <= c.dist then rivals = rivals + 1 end end
    local conf = 0.9 - 0.3 * (c.dist - 1) - 0.15 * math.min(rivals, 3) - (c.first_same and 0 or 0.2)
    if n <= 4 then conf = conf - 0.2 end
    c.conf = U.clamp(conf, 0.05, 0.95)
    out[#out + 1] = c
  end
  return out
end

return Spell
