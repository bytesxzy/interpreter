-- asi.nlu.util: deterministic helpers shared by every NLU module.
-- No clock, no global randomness, no I/O except where a function says so.
local U = {}

---------------------------------------------------------------- tables
function U.sorted_keys(t, cmp)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, cmp or function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return ks
end

function U.spairs(t, cmp)
  local ks, i = U.sorted_keys(t, cmp), 0
  return function()
    i = i + 1
    local k = ks[i]
    if k ~= nil then return k, t[k] end
  end
end

function U.copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local r = {}
  seen[v] = r
  for k, x in pairs(v) do r[U.copy(k, seen)] = U.copy(x, seen) end
  return setmetatable(r, getmetatable(v))
end

function U.shallow(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

function U.append(dst, src)
  for i = 1, #src do dst[#dst + 1] = src[i] end
  return dst
end

function U.set(list)
  local s = {}
  for i = 1, #list do s[list[i]] = true end
  return s
end

function U.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function U.clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
function U.round(x, n) local m = 10 ^ (n or 0); return math.floor(x * m + 0.5) / m end

function U.index_of(list, v)
  for i = 1, #list do if list[i] == v then return i end end
end

function U.map(list, f) local r = {}; for i = 1, #list do r[i] = f(list[i], i) end; return r end
function U.filter(list, f) local r = {}; for i = 1, #list do if f(list[i], i) then r[#r + 1] = list[i] end end; return r end

function U.deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not U.deep_equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

---------------------------------------------------------------- strings
function U.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function U.startswith(s, p) return s:sub(1, #p) == p end
function U.endswith(s, p) return p == "" or s:sub(-#p) == p end

function U.split(s, sep, plain)
  local out, pos = {}, 1
  if s == "" then return out end
  while true do
    local a, b = s:find(sep, pos, plain ~= false)
    if not a then out[#out + 1] = s:sub(pos); break end
    out[#out + 1] = s:sub(pos, a - 1)
    pos = b + 1
  end
  return out
end

---------------------------------------------------------------- hashing
local K256 = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local M32 = 0xffffffff
local function rrot(x, n) return ((x >> n) | (x << (32 - n))) & M32 end

function U.sha256(msg)
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack(">I8", len * 8)
  local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local w = {}
  for i = 1, #msg, 64 do
    w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15], w[16] =
      string.unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", msg, i)
    for t = 17, 64 do
      local x, y = w[t - 15], w[t - 2]
      local s0 = rrot(x, 7) ~ rrot(x, 18) ~ (x >> 3)
      local s1 = rrot(y, 17) ~ rrot(y, 19) ~ (y >> 10)
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & M32
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for t = 1, 64 do
      local S1 = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
      local ch = (e & f) ~ ((~e) & M32 & g)
      local t1 = (h + S1 + ch + K256[t] + w[t]) & M32
      local S0 = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local t2 = (S0 + maj) & M32
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) & M32, c, b, a, (t1 + t2) & M32
    end
    H[1] = (H[1] + a) & M32; H[2] = (H[2] + b) & M32; H[3] = (H[3] + c) & M32; H[4] = (H[4] + d) & M32
    H[5] = (H[5] + e) & M32; H[6] = (H[6] + f) & M32; H[7] = (H[7] + g) & M32; H[8] = (H[8] + h) & M32
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8])
end

-- FNV-1a 64 (wrapping integer arithmetic): cheap cache/identity keys, NOT cryptographic.
function U.hash64(s)
  local h = -3750763034362895579 -- 0xcbf29ce484222325 as signed
  for i = 1, #s do h = (h ~ s:byte(i)) * 0x100000001b3 end
  return string.format("%016x", h)
end

-- 128-bit non-cryptographic change-detection hash (two independent FNV-style lanes, one pass).  Used for per-record checksums, where the only requirement
-- is that any edit changes the value; integrity claims (manifests, record integrity, dataset digests) use SHA-256.
function U.hash128(s)
  local a, b = -3750763034362895579, 0x6a09e667f3bcc908
  for i = 1, #s do
    local c = s:byte(i)
    a = (a ~ c) * 0x100000001b3
    b = (b ~ (c + 0x9e)) * 0x1000193 + (a >> 29)
  end
  return string.format("%016x%016x", a, b)
end

---------------------------------------------------------------- deterministic PRNG (splitmix64)
local Rng = {}
Rng.__index = Rng
function U.rng(seed)
  return setmetatable({ s = math.tointeger(seed) or 0x1234567 }, Rng)
end
function Rng:u64()
  self.s = self.s + (-7046029254386353131) -- 0x9E3779B97F4A7C15
  local z = self.s
  z = (z ~ (z >> 30)) * (-4658895280553007687) -- 0xBF58476D1CE4E5B9
  z = (z ~ (z >> 27)) * (-7723592293110705685) -- 0x94D049BB133111EB
  return z ~ (z >> 31)
end
function Rng:float() return (self:u64() >> 11) * (1.0 / 9007199254740992.0) end
function Rng:int(lo, hi) return lo + (self:u64() >> 1) % (hi - lo + 1) end
function Rng:pick(list) return list[self:int(1, #list)] end
function Rng:chance(p) return self:float() < p end
function Rng:shuffle(list)
  for i = #list, 2, -1 do
    local j = self:int(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

---------------------------------------------------------------- byte-level text safety
-- Replace every maximal run of bytes that is not part of a valid UTF-8 sequence by ONE U+FFFD.  Deterministic; valid text comes back unchanged
-- (second result: whether anything was replaced).  The raw bytes stay recoverable through U.hex when a caller needs the lossless form.
function U.scrub_utf8(s)
  if utf8.len(s) then return s, false end
  local out, pos, n = {}, 1, #s
  while pos <= n do
    local ok, bad = utf8.len(s, pos)
    if ok then out[#out + 1] = s:sub(pos); break end
    if bad > pos then out[#out + 1] = s:sub(pos, bad - 1) end
    out[#out + 1] = "\u{FFFD}"
    local j = bad + 1
    while j <= n and not utf8.len(s, j, j) do j = j + 1 end
    pos = j
  end
  return table.concat(out), true
end

function U.hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- Deep copy in which every string (and string key) is made valid UTF-8; sharing and metatables are preserved.
function U.scrub_tree(v, seen)
  local tv = type(v)
  if tv == "string" then return (U.scrub_utf8(v)) end
  if tv ~= "table" or v == U.NULL then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local r = {}
  seen[v] = r
  for k, x in pairs(v) do r[type(k) == "string" and (U.scrub_utf8(k)) or k] = U.scrub_tree(x, seen) end
  return setmetatable(r, getmetatable(v))
end

---------------------------------------------------------------- JSON (strict, bounded, data-only)
U.NULL = setmetatable({}, { __tostring = function() return "null" end })
U.OBJ = { __jsontype = "object" } -- marker metatable for empty objects

local esc = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function enc_str(s, strict)
  if strict and not utf8.len(s) then error("json_encode: invalid UTF-8 in string", 0) end
  return '"' .. s:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 then return false end
    n = n + 1
  end
  if n == 0 then return getmetatable(t) ~= U.OBJ end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local function enc(v, out, opts, depth, indent)
  local tv = type(v)
  if v == nil or v == U.NULL then out[#out + 1] = "null"
  elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      if opts.nan_null then out[#out + 1] = "null" else error("json_encode: non-finite number", 0) end
    elseif math.type(v) == "integer" then out[#out + 1] = string.format("%d", v)
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v) -- 1.0 and 1 are the same JSON number (canonical form)
    else out[#out + 1] = string.format("%.17g", v) end
  elseif tv == "string" then out[#out + 1] = enc_str(v, opts.strict_utf8 ~= false)
  elseif tv == "table" then
    if depth > (opts.max_depth or 100) then error("json_encode: depth limit", 0) end
    local nl, ind2 = "", ""
    if opts.pretty then nl = "\n"; ind2 = indent .. "  " end
    if is_array(v) then
      if #v == 0 then out[#out + 1] = "[]"; return end
      out[#out + 1] = "[" .. nl
      for i = 1, #v do
        out[#out + 1] = ind2
        enc(v[i], out, opts, depth + 1, ind2)
        if i < #v then out[#out + 1] = "," .. nl end
      end
      out[#out + 1] = nl .. indent .. "]"
    else
      local ks = U.sorted_keys(v, function(a, b) return tostring(a) < tostring(b) end)
      local first = true
      out[#out + 1] = "{" .. nl
      for _, k in ipairs(ks) do
        if v[k] ~= nil and type(v[k]) ~= "function" then
          if not first then out[#out + 1] = "," .. nl end
          first = false
          out[#out + 1] = ind2 .. enc_str(tostring(k), false) .. (opts.pretty and ": " or ":")
          enc(v[k], out, opts, depth + 1, ind2)
        end
      end
      if first then out[#out] = "{}" else out[#out + 1] = nl .. indent .. "}" end
    end
  else error("json_encode: unsupported type " .. tv, 0) end
end

-- Canonical (sorted-key) encoder. Errors on NaN/Inf and invalid UTF-8 unless told otherwise.
function U.json_encode(v, opts)
  local out = {}
  enc(v, out, opts or {}, 0, "")
  return table.concat(out)
end

local function jerr(s, i, msg) error({ json = true, pos = i, msg = msg }, 0) end

function U.json_decode(s, opts)
  opts = opts or {}
  local max_depth, max_len = opts.max_depth or 64, opts.max_bytes or 256 * 1024 * 1024
  if #s > max_len then return nil, "json: input too large" end
  if opts.require_utf8 ~= false and not utf8.len(s) then return nil, "json: invalid UTF-8" end
  local pos = 1
  local byte, find, sub = string.byte, string.find, string.sub

  local function ws() pos = find(s, "[^ \t\r\n]", pos) or (#s + 1) end

  local parse_value
  local function parse_string()
    local out, i = {}, pos + 1
    while true do
      local j = find(s, '["\\%c]', i)
      if not j then jerr(s, i, "unterminated string") end
      if j > i then out[#out + 1] = sub(s, i, j - 1) end
      local c = byte(s, j)
      if c == 34 then pos = j + 1; return table.concat(out) end
      if c ~= 92 then jerr(s, j, "control character in string") end
      local e = sub(s, j + 1, j + 1)
      local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if map[e] then out[#out + 1] = map[e]; i = j + 2
      elseif e == "u" then
        local hex = sub(s, j + 2, j + 5)
        if not hex:match("^%x%x%x%x$") then jerr(s, j, "bad \\u escape") end
        local cp = tonumber(hex, 16)
        i = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = sub(s, i, i + 5)
          if not lo:match("^\\u[dD][c-fC-F]%x%x$") then jerr(s, j, "lone high surrogate") end
          cp = 0x10000 + ((cp - 0xD800) << 10) + (tonumber(sub(lo, 3), 16) - 0xDC00)
          i = i + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then jerr(s, j, "lone low surrogate") end
        out[#out + 1] = utf8.char(cp)
      else jerr(s, j, "bad escape") end
    end
  end

  local function parse_number()
    local a, b = find(s, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    local txt = a and sub(s, a, b)
    if not txt or not txt:match("^-?%d+$") and not txt:match("^-?%d+%.%d+$") and not txt:match("^-?%d+%.?%d*[eE][+-]?%d+$") then
      jerr(s, pos, "bad number")
    end
    if txt:match("^-?0%d") then jerr(s, pos, "leading zero") end
    pos = b + 1
    return math.tointeger(tonumber(txt)) or tonumber(txt)
  end

  function parse_value(depth)
    if depth > max_depth then jerr(s, pos, "depth limit") end
    ws()
    local c = byte(s, pos)
    if c == 123 then -- {
      pos = pos + 1
      local obj = setmetatable({}, U.OBJ)
      ws()
      if byte(s, pos) == 125 then pos = pos + 1; return obj end
      while true do
        ws()
        if byte(s, pos) ~= 34 then jerr(s, pos, "object key expected") end
        local k = parse_string()
        ws()
        if byte(s, pos) ~= 58 then jerr(s, pos, "':' expected") end
        pos = pos + 1
        local v = parse_value(depth + 1)
        if rawget(obj, k) ~= nil and opts.dup_keys ~= "last" then jerr(s, pos, "duplicate key " .. k) end
        if v ~= U.NULL then obj[k] = v end
        ws()
        local d = byte(s, pos)
        pos = pos + 1
        if d == 125 then return obj end
        if d ~= 44 then jerr(s, pos - 1, "',' or '}' expected") end
      end
    elseif c == 91 then -- [
      pos = pos + 1
      local arr = {}
      ws()
      if byte(s, pos) == 93 then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value(depth + 1)
        ws()
        local d = byte(s, pos)
        pos = pos + 1
        if d == 93 then return arr end
        if d ~= 44 then jerr(s, pos - 1, "',' or ']' expected") end
      end
    elseif c == 34 then return parse_string()
    elseif c == 116 and sub(s, pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif c == 102 and sub(s, pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif c == 110 and sub(s, pos, pos + 3) == "null" then pos = pos + 4; return U.NULL
    elseif c and (c == 45 or (c >= 48 and c <= 57)) then return parse_number()
    end
    jerr(s, pos, "unexpected character")
  end

  local ok, res = pcall(function()
    local v = parse_value(0)
    ws()
    if pos <= #s then jerr(s, pos, "trailing data") end
    return v
  end)
  if ok then return res end
  if type(res) == "table" and res.json then return nil, string.format("json: %s at byte %d", res.msg, res.pos) end
  return nil, "json: " .. tostring(res)
end

---------------------------------------------------------------- work meter (integer, deterministic)
local Meter = {}
Meter.__index = Meter
function U.meter(budget)
  return setmetatable({ budget = budget or math.huge, total = 0, c = {}, over = false }, Meter)
end
-- returns false once the budget is exhausted so hot loops can bail out explicitly
function Meter:tick(name, n)
  n = n or 1
  self.total = self.total + n
  self.c[name] = (self.c[name] or 0) + n
  if self.total > self.budget then self.over = true end
  return not self.over
end
function Meter:snapshot()
  local c = {}
  for k, v in pairs(self.c) do c[k] = v end
  return { total = self.total, by_stage = c, budget = self.budget ~= math.huge and self.budget or nil, exceeded = self.over }
end

---------------------------------------------------------------- statistics
function U.wilson(k, n, z)
  z = z or 1.96
  if n == 0 then return 0, 1 end
  local p = k / n
  local d = 1 + z * z / n
  local c = p + z * z / (2 * n)
  local a = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
  return math.max(0, (c - a) / d), math.min(1, (c + a) / d)
end

function U.mean(xs) local s = 0; for i = 1, #xs do s = s + xs[i] end; return #xs > 0 and s / #xs or 0 end

function U.percentile(sorted, p)
  if #sorted == 0 then return 0 end
  local idx = U.clamp(math.floor(p * (#sorted - 1) + 0.5) + 1, 1, #sorted)
  return sorted[idx]
end

-- Paired bootstrap of error_reduction = base_err / new_err over per-case 0/1 error vectors.
-- Resamples with new_err == 0 yield +inf (reported as lower bound only).
function U.bootstrap_ratio(base_err, new_err, iters, seed)
  local n, rng = #base_err, U.rng(seed or 7)
  local ratios, inf = {}, 0
  for _ = 1, iters or 1000 do
    local b, w = 0, 0
    for _ = 1, n do
      local i = rng:int(1, n)
      b = b + base_err[i]; w = w + new_err[i]
    end
    if b > 0 then
      if w == 0 then inf = inf + 1; ratios[#ratios + 1] = math.huge else ratios[#ratios + 1] = b / w end
    end
  end
  table.sort(ratios)
  return { lo = U.percentile(ratios, 0.025), hi = U.percentile(ratios, 0.975), n = #ratios, inf = inf }
end

---------------------------------------------------------------- bounded edit distance (OSA / Damerau)
-- a, b: strings (UTF-8) or arrays of codepoints. Returns distance, or maxd + 1 if above maxd.
local function cps(x)
  if type(x) == "table" then return x end
  local r = {}
  for _, c in utf8.codes(x, true) do r[#r + 1] = c end
  return r
end
function U.osa(a, b, maxd)
  a, b = cps(a), cps(b)
  local la, lb = #a, #b
  maxd = maxd or math.max(la, lb)
  if math.abs(la - lb) > maxd then return maxd + 1 end
  local prev2, prev, cur = {}, {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    local rowmin = i
    for j = 1, lb do
      local cost = (a[i] == b[j]) and 0 or 1
      local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      if i > 1 and j > 1 and a[i] == b[j - 1] and a[i - 1] == b[j] then v = math.min(v, prev2[j - 2] + 1) end
      cur[j] = v
      if v < rowmin then rowmin = v end
    end
    if rowmin > maxd then return maxd + 1 end
    prev2, prev, cur = prev, cur, prev2
  end
  local d = prev[lb]
  return d > maxd and maxd + 1 or d
end

---------------------------------------------------------------- tiny schema validator
-- spec: {type="string"|"number"|"integer"|"boolean"|"table"|"array"|"object"|"enum"|"any",
--        required=bool, min=, max=, of=spec (array), fields={name=spec}, extra=bool, values={...} (enum)}
function U.validate(spec, v, path, errs)
  path, errs = path or "$", errs or {}
  local function bad(msg) errs[#errs + 1] = path .. ": " .. msg end
  if v == nil then
    if spec.required then bad("required field missing") end
    return #errs == 0, errs
  end
  local t = spec.type or "any"
  if t == "any" then return #errs == 0, errs end
  if t == "string" then
    if type(v) ~= "string" then bad("expected string") else
      if spec.max and #v > spec.max then bad("string too long") end
      if spec.min and #v < spec.min then bad("string too short") end
    end
  elseif t == "number" or t == "integer" then
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then bad("expected finite number")
    else
      if t == "integer" and math.type(v) ~= "integer" and v ~= math.floor(v) then bad("expected integer") end
      if spec.min and v < spec.min then bad("below minimum " .. spec.min) end
      if spec.max and v > spec.max then bad("above maximum " .. spec.max) end
    end
  elseif t == "boolean" then
    if type(v) ~= "boolean" then bad("expected boolean") end
  elseif t == "enum" then
    local ok = false
    for _, x in ipairs(spec.values) do if x == v then ok = true break end end
    if not ok then bad("not in enum {" .. table.concat(spec.values, ",") .. "}") end
  elseif t == "table" then
    if type(v) ~= "table" then bad("expected table") end
  elseif t == "array" then
    if type(v) ~= "table" then bad("expected array")
    else
      if spec.max and #v > spec.max then bad("array too long (" .. #v .. ")") end
      if spec.of then for i = 1, #v do U.validate(spec.of, v[i], path .. "[" .. i .. "]", errs) end end
    end
  elseif t == "object" then
    if type(v) ~= "table" then bad("expected object")
    else
      for name, fs in pairs(spec.fields or {}) do U.validate(fs, v[name], path .. "." .. name, errs) end
      if spec.extra == false then
        for k in pairs(v) do if not (spec.fields or {})[k] then bad("unexpected field " .. tostring(k)) end end
      end
    end
  end
  return #errs == 0, errs
end

return U
