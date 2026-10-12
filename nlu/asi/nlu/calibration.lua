-- asi.nlu.calibration: fit and evaluate probability calibration of raw confidence scores (pure Lua, deterministic).
--   samples: list of { x = raw score in [0,1], y = 1|0 (the prediction was right) }
-- Methods: isotonic regression (pool-adjacent-violators, monotone step function) and temperature scaling of the logit.  Nothing is hand-set: a
-- calibrated value is the empirical accuracy of that score range on labelled data, and `evaluate` reports ECE / Brier / log-loss on data that was
-- NOT used to fit.  A model is valid only for the distribution it was fitted on; `model.fit` records that distribution.
local U = require("asi.nlu.util")

local C = {}

local EPS = 1e-6
local function clamp(p) if p < EPS then return EPS elseif p > 1 - EPS then return 1 - EPS end return p end

---------------------------------------------------------------- isotonic regression (PAV)
function C.fit_isotonic(samples)
  local pts = {}
  for _, s in ipairs(samples) do pts[#pts + 1] = { x = s.x, y = s.y } end
  table.sort(pts, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
  -- merge equal x first so the step function is well defined
  local blocks = {}
  for _, p in ipairs(pts) do
    local last = blocks[#blocks]
    if last and last.hi == p.x then last.sum = last.sum + p.y; last.n = last.n + 1
    else blocks[#blocks + 1] = { lo = p.x, hi = p.x, sum = p.y, n = 1 } end
  end
  -- pool adjacent violators
  local stack = {}
  for _, b in ipairs(blocks) do
    stack[#stack + 1] = b
    while #stack >= 2 do
      local a, c = stack[#stack - 1], stack[#stack]
      if a.sum / a.n > c.sum / c.n then
        a.sum, a.n, a.hi = a.sum + c.sum, a.n + c.n, c.hi
        stack[#stack] = nil
      else break end
    end
  end
  local steps = {}
  for _, b in ipairs(stack) do steps[#steps + 1] = { lo = b.lo, hi = b.hi, value = b.sum / b.n, n = b.n } end
  return { method = "isotonic", steps = steps, n = #samples }
end

local function apply_isotonic(model, x)
  local steps = model.steps
  if #steps == 0 then return x end
  if x <= steps[1].lo then return steps[1].value end
  for i, s in ipairs(steps) do
    if x <= s.hi then return s.value end
    local nx = steps[i + 1]
    if nx and x < nx.lo then
      -- between two blocks: interpolate linearly between the adjacent block values (keeps the map monotone and continuous)
      local t = (x - s.hi) / (nx.lo - s.hi)
      return s.value + t * (nx.value - s.value)
    end
  end
  return steps[#steps].value
end

---------------------------------------------------------------- temperature scaling
local function logit(p) p = clamp(p); return math.log(p / (1 - p)) end
local function sigmoid(z) return 1 / (1 + math.exp(-z)) end

function C.logloss(samples, f)
  local s = 0
  for _, d in ipairs(samples) do
    local p = clamp(f(d.x))
    s = s - (d.y * math.log(p) + (1 - d.y) * math.log(1 - p))
  end
  return s / math.max(1, #samples)
end

-- p' = sigmoid(a * logit(p) + b); fitted by a coarse-to-fine grid search on log-loss (deterministic, no gradients, no randomness)
function C.fit_platt(samples)
  local best = { a = 1, b = 0, loss = math.huge }
  local function try(a, b)
    local l = C.logloss(samples, function(x) return sigmoid(a * logit(x) + b) end)
    if l < best.loss then best = { a = a, b = b, loss = l } end
  end
  for ai = 1, 60 do for bi = -30, 30 do try(ai * 0.05, bi * 0.2) end end
  local a0, b0 = best.a, best.b
  for ai = -20, 20 do for bi = -20, 20 do if a0 + ai * 0.005 > 0 then try(a0 + ai * 0.005, b0 + bi * 0.01) end end end
  return { method = "platt", a = best.a, b = best.b, n = #samples, train_logloss = best.loss }
end

---------------------------------------------------------------- application
function C.apply(model, x)
  if model.method == "isotonic" then return apply_isotonic(model, x)
  elseif model.method == "platt" then return sigmoid(model.a * logit(x) + model.b)
  elseif model.method == "identity" then return x end
  error("unknown calibration method " .. tostring(model.method))
end

function C.identity() return { method = "identity", n = 0 } end

---------------------------------------------------------------- evaluation
-- reliability table with equal-mass bins (so every bin has data); ECE = mass-weighted |accuracy - mean confidence|
function C.evaluate(samples, model, nbins)
  nbins = nbins or 10
  local pts = {}
  for _, s in ipairs(samples) do pts[#pts + 1] = { p = model and C.apply(model, s.x) or s.x, y = s.y } end
  table.sort(pts, function(a, b) if a.p ~= b.p then return a.p < b.p end return a.y < b.y end)
  local n = #pts
  local out = { n = n, bins = {}, brier = 0, logloss = 0, accuracy = 0 }
  if n == 0 then return out end
  local ece, mce = 0, 0
  for i = 1, nbins do
    local lo, hi = math.floor((i - 1) * n / nbins) + 1, math.floor(i * n / nbins)
    if hi >= lo then
      local sp, sy = 0, 0
      for j = lo, hi do sp = sp + pts[j].p; sy = sy + pts[j].y end
      local cnt = hi - lo + 1
      local conf, acc = sp / cnt, sy / cnt
      local gap = math.abs(acc - conf)
      ece = ece + gap * cnt / n
      if gap > mce then mce = gap end
      out.bins[#out.bins + 1] = { n = cnt, mean_confidence = U.round(conf, 4), accuracy = U.round(acc, 4), lo = U.round(pts[lo].p, 4), hi = U.round(pts[hi].p, 4) }
    end
  end
  local sy = 0
  for _, d in ipairs(pts) do
    sy = sy + d.y
    out.brier = out.brier + (d.p - d.y) ^ 2
    local p = clamp(d.p)
    out.logloss = out.logloss - (d.y * math.log(p) + (1 - d.y) * math.log(1 - p))
  end
  out.brier, out.logloss, out.accuracy = out.brier / n, out.logloss / n, sy / n
  out.ece, out.mce = ece, mce
  return out
end

-- area under the ROC curve of the score as a ranker of correct vs incorrect predictions (ties count half); nil if one class is empty
function C.auroc(samples)
  local pos, neg = {}, {}
  for _, s in ipairs(samples) do if s.y == 1 then pos[#pos + 1] = s.x else neg[#neg + 1] = s.x end end
  if #pos == 0 or #neg == 0 then return nil end
  local all = {}
  for _, s in ipairs(samples) do all[#all + 1] = s end
  table.sort(all, function(a, b) return a.x < b.x end)
  local rank_sum, i = 0, 1
  while i <= #all do
    local j = i
    while j < #all and all[j + 1].x == all[i].x do j = j + 1 end
    local avg = (i + j) / 2
    for k = i, j do if all[k].y == 1 then rank_sum = rank_sum + avg end end
    i = j + 1
  end
  return (rank_sum - #pos * (#pos + 1) / 2) / (#pos * #neg)
end

-- stable digest of a sample list, recorded in the model so the fit set is identifiable
function C.digest(samples)
  local parts = {}
  for _, s in ipairs(samples) do parts[#parts + 1] = string.format("%.6f:%d", s.x, s.y) end
  return U.sha256(table.concat(parts, ";"))
end

-- adapter for asi.nlu.record: { method, n, source, maps = { <component> = function(raw) -> calibrated } }
function C.for_record(models, meta)
  local maps = {}
  for name, model in pairs(models) do maps[name] = function(raw) return U.round(C.apply(model, raw), 4) end end
  return { method = meta.method, n = meta.n, source = meta.source, maps = maps }
end

return C
