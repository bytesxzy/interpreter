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
  if model.method == "logistic" then return C.apply_features(model, x) end
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
  for _, s in ipairs(samples) do
    local p = s.x
    if model then p = (model.method == "logistic") and C.apply_features(model, s.f) or C.apply(model, s.x) end
    pts[#pts + 1] = { p = p, y = s.y }
  end
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

---------------------------------------------------------------- multi-feature logistic regression (ridge, IRLS; deterministic)
-- samples: { f = {name -> number}, y = 0|1 }.  Features are standardised with the training mean / scale, so weights are comparable.
-- `signs` (optional) = { feature -> +1 | -1 }: monotonicity constraints (a risk feature may never RAISE the predicted probability).  Enforced by an
-- active-set loop: a feature whose fitted weight has the forbidden sign is removed (weight 0) and the model refitted.
function C.fit_logistic(samples, names, lambda, signs)
  if signs then
    local active = {}
    for _, nm in ipairs(names) do active[#active + 1] = nm end
    for _ = 1, #names do
      local m = C.fit_logistic_free(samples, active, lambda)
      local bad
      for j, nm in ipairs(active) do
        local sg = signs[nm]
        if sg and m.weights[j] * sg < -1e-9 then bad = j; break end
      end
      if not bad then
        -- re-express over the full feature list (removed features carry weight 0) so the model is self-describing
        local w, mean, scale = {}, {}, {}
        local pos = {}
        for j, nm in ipairs(active) do pos[nm] = j end
        for j, nm in ipairs(names) do
          local k = pos[nm]
          w[j], mean[j], scale[j] = k and m.weights[k] or 0, k and m.mean[k] or 0, k and m.scale[k] or 1
        end
        m.names, m.weights, m.mean, m.scale, m.constraints = names, w, mean, scale, signs
        return m
      end
      table.remove(active, bad)
    end
  end
  return C.fit_logistic_free(samples, names, lambda)
end

function C.fit_logistic_free(samples, names, lambda)
  lambda = lambda or 1.0
  local d, n = #names, #samples
  local mean, scale = {}, {}
  for j, nm in ipairs(names) do
    local sm = 0
    for _, s in ipairs(samples) do sm = sm + (s.f[nm] or 0) end
    mean[j] = sm / math.max(n, 1)
    local sv = 0
    for _, s in ipairs(samples) do sv = sv + ((s.f[nm] or 0) - mean[j]) ^ 2 end
    scale[j] = math.sqrt(sv / math.max(n, 1))
    if scale[j] < 1e-9 then scale[j] = 1 end
  end
  local w, b = {}, 0
  for j = 1, d do w[j] = 0 end
  local function row(s) local x = {}; for j, nm in ipairs(names) do x[j] = ((s.f[nm] or 0) - mean[j]) / scale[j] end return x end
  local X = {}
  for i, s in ipairs(samples) do X[i] = row(s) end
  for _ = 1, 40 do
    -- gradient and Hessian of the penalised log-likelihood (bias unpenalised); solve the (d+1)x(d+1) system by Gaussian elimination
    local g, H = {}, {}
    for a = 1, d + 1 do g[a] = 0; H[a] = {}; for c = 1, d + 1 do H[a][c] = 0 end end
    for i, s in ipairs(samples) do
      local z = b
      for j = 1, d do z = z + w[j] * X[i][j] end
      local p = sigmoid(z)
      local r, v = s.y - p, math.max(p * (1 - p), 1e-6)
      g[d + 1] = g[d + 1] + r
      for a = 1, d do
        g[a] = g[a] + r * X[i][a]
        for c = 1, d do H[a][c] = H[a][c] + v * X[i][a] * X[i][c] end
        H[a][d + 1] = H[a][d + 1] + v * X[i][a]
        H[d + 1][a] = H[d + 1][a] + v * X[i][a]
      end
      H[d + 1][d + 1] = H[d + 1][d + 1] + v
    end
    for a = 1, d do g[a] = g[a] - lambda * w[a]; H[a][a] = H[a][a] + lambda end
    H[d + 1][d + 1] = H[d + 1][d + 1] + 1e-6
    -- solve H * delta = g
    local M = {}
    for a = 1, d + 1 do M[a] = {}; for c = 1, d + 1 do M[a][c] = H[a][c] end; M[a][d + 2] = g[a] end
    for a = 1, d + 1 do
      local piv = a
      for r2 = a + 1, d + 1 do if math.abs(M[r2][a]) > math.abs(M[piv][a]) then piv = r2 end end
      M[a], M[piv] = M[piv], M[a]
      local diag = M[a][a]
      if math.abs(diag) < 1e-12 then diag = 1e-12 end
      for c = a, d + 2 do M[a][c] = M[a][c] / diag end
      for r2 = 1, d + 1 do
        if r2 ~= a then
          local f = M[r2][a]
          if f ~= 0 then for c = a, d + 2 do M[r2][c] = M[r2][c] - f * M[a][c] end end
        end
      end
    end
    local step = 0
    for a = 1, d do w[a] = w[a] + M[a][d + 2]; step = step + math.abs(M[a][d + 2]) end
    b = b + M[d + 1][d + 2]
    step = step + math.abs(M[d + 1][d + 2])
    if step < 1e-7 then break end
  end
  return { method = "logistic", names = names, mean = mean, scale = scale, weights = w, bias = b, lambda = lambda, n = n }
end

function C.apply_features(model, f)
  local z = model.bias
  for j, nm in ipairs(model.names) do z = z + model.weights[j] * (((f[nm] or 0) - model.mean[j]) / model.scale[j]) end
  return sigmoid(z)
end

-- features of one main interpretation (all derived from computed quantities of the interpretation itself)
function C.features(m)
  local f = { semantic_raw = (m.confidence and m.confidence.semantic_raw) or 0, coverage = (m.confidence and m.confidence.coverage) or 0 }
  f.repaired = (m.repairs and #m.repairs > 0) and 1 or 0
  f.n_repairs = m.repairs and #m.repairs or 0
  f.unknown_lowercase = (m.lexical and m.lexical.unknown_lowercase) or 0
  f.open_relation = (m.relation and tostring(m.relation.id):sub(1, 5) == "open:") and 1 or 0
  f.ambiguous = (m.ambiguity and m.ambiguity.state ~= "resolved") and 1 or 0
  local fuzzy, min_ent, unresolved = 0, 1, 0
  for _, r in pairs(m.roles or {}) do
    for _, c in ipairs(r.candidates or {}) do if c.fuzzy then fuzzy = 1 end end
    if r.candidates and r.candidates[1] and r.status ~= "ambiguous" then min_ent = math.min(min_ent, r.candidates[1].p or 1) end
    if r.needs_antecedent then unresolved = 1 end
  end
  f.fuzzy_entity, f.min_entity, f.unresolved_ref = fuzzy, min_ent, unresolved
  f.no_interpretation = (m.status ~= "ok") and 1 or 0
  return f
end

-- the calibration model shipped with the engine: embedded in the bundle as module asi.nlu.data.cal_interp_v1 (a JSON string), or read from data/ in a checkout
function C.default_model(root)
  local ok, raw = pcall(require, "asi.nlu.data.cal_interp_v1")
  if ok and type(raw) == "string" then
    local model = U.json_decode(raw)
    if model then return model end
  end
  if root then return C.load_file(root .. "/data/calibration/interp_v1.json") end
  return nil
end

function C.load_file(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot read " .. tostring(path) end
  local raw = f:read("a")
  f:close()
  local model, err = U.json_decode(raw)
  if not model then return nil, err end
  return model
end

-- adapter for asi.nlu.record when the model works on whole-interpretation features: the Record then reports `interpretation_correct`
function C.record_adapter(model)
  return { method = model.method, n = model.n, source = model.fit and model.fit.valid_for or "labelled data", model = model, maps = {} }
end

-- adapter for asi.nlu.record: { method, n, source, maps = { <component> = function(raw) -> calibrated } }
function C.for_record(models, meta)
  local maps = {}
  for name, model in pairs(models) do maps[name] = function(raw) return U.round(C.apply(model, raw), 4) end end
  return { method = meta.method, n = meta.n, source = meta.source, maps = maps }
end

return C
