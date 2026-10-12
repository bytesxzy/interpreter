-- asi.nlu.index: layered, incrementally updatable retrieval index.
--   1. exact entity postings         entity key -> records that MENTION it (identity, not substring)
--   2. phrase-aware field-weighted lexical postings (BM25F) with positions
--   3. typed assertion store         (relation, subject key) / (relation, object key) -> assertions extracted from records
--   4. metadata / time filters
-- BM25F is ONE component; semantic verification (asi.nlu.verify) decides whether a candidate actually supports the interpreted request.
local U = require("asi.nlu.util")
local TU = require("asi.nlu.textutil")

local X = {}
X.__index = X

X.FIELD_WEIGHT = { title = 2.2, name = 2.2, headline = 2.2, heading = 2.0, section = 1.4, text = 1.0, body = 1.0, summary = 1.2, abstract = 1.2, tags = 1.3 }
local K1, B = 1.2, 0.75

function X.new(opts)
  opts = opts or {}
  local self = setmetatable({}, X)
  self.docs, self.doc_of, self.n, self.live = {}, {}, 0, 0
  self.terms = {}                -- term -> { [doc] = { [field] = tf } }
  self.positions = {}            -- term -> { [doc] = { pos... } }  (field offsets baked into the position)
  self.df = {}
  self.len = {}                  -- field -> { [doc] = length }
  self.total_len, self.field_count = {}, {}
  self.entity_post = {}          -- key -> { [doc] = n }
  self.assertions = {}           -- list (index = assertion id)
  self.by_from, self.by_to, self.by_any = {}, {}, {}
  self.classes = {}              -- subject key -> list of classification assertion ids
  self.meta = {}                 -- field -> value -> { [doc] = true }
  self.revision = 0
  self.weights = opts.field_weight or X.FIELD_WEIGHT
  return self
end

local function fw(self, field) return self.weights[field] or self.weights[field:lower()] or 1.0 end

---------------------------------------------------------------- adding / removing documents
-- doc: the dataset record; analysis: result of assertions:extract (may be nil for metadata-only records)
function X:add(rec, analysis)
  if self.doc_of[rec.id] then self:remove(rec.id) end
  self.n = self.n + 1
  local d = self.n
  self.docs[d] = { id = rec.id, rec = rec, terms = {}, entities = {}, assertions = {}, meta = {} }
  self.doc_of[rec.id] = d
  self.live = self.live + 1
  local offset = 0
  local fields = rec.text_fields
  if not fields or #fields == 0 then fields = {} end
  for fi, f in ipairs(fields) do
    local text = rec.field_text and rec.field_text[f] or ""
    local toks = TU.tokens(text)
    local per = {}
    for _, t in ipairs(toks) do
      local term = t.t
      local ft = self.terms[term]
      if not ft then ft = {}; self.terms[term] = ft end
      local dt = ft[d]
      if not dt then dt = {}; ft[d] = dt; self.df[term] = (self.df[term] or 0) + 1; self.docs[d].terms[#self.docs[d].terms + 1] = term end
      dt[f] = (dt[f] or 0) + 1
      local pt = self.positions[term]
      if not pt then pt = {}; self.positions[term] = pt end
      local pl = pt[d]
      if not pl then pl = {}; pt[d] = pl end
      pl[#pl + 1] = offset + t.pos
      per[#per + 1] = t
    end
    offset = offset + 10000
    self.len[f] = self.len[f] or {}
    self.len[f][d] = #toks
    self.total_len[f] = (self.total_len[f] or 0) + #toks
    self.field_count[f] = (self.field_count[f] or 0) + 1
  end
  for k, v in pairs(rec.meta or {}) do
    local sv = tostring(v):lower()
    self.meta[k] = self.meta[k] or {}
    self.meta[k][sv] = self.meta[k][sv] or {}
    self.meta[k][sv][d] = true
    self.docs[d].meta[#self.docs[d].meta + 1] = { k, sv }
  end
  if analysis then
    local seen = {}
    for _, m in ipairs(analysis.mentions) do
      local key = m.key
      if not seen[key] then
        seen[key] = true
        local ep = self.entity_post[key]
        if not ep then ep = {}; self.entity_post[key] = ep end
        ep[d] = (ep[d] or 0) + 1
        self.docs[d].entities[#self.docs[d].entities + 1] = key
      end
    end
    for _, a in ipairs(analysis.assertions) do self:add_assertion(d, a) end
    self.docs[d].reader_directed = analysis.reader_directed
    self.docs[d].aliases = analysis.aliases
  end
  self.revision = self.revision + 1
  return d
end

function X:add_assertion(d, a)
  a.doc = d
  a.record = self.docs[d].id
  local id = #self.assertions + 1
  a.id = id
  self.assertions[id] = a
  self.docs[d].assertions[#self.docs[d].assertions + 1] = id
  local function post(map, key)
    if not key then return end
    local l = map[key]
    if not l then l = {}; map[key] = l end
    l[#l + 1] = id
  end
  if a.is_class then
    if a.from and a.from.key then post(self.classes, a.from.key) end
    return
  end
  local from_keys, to_keys = {}, {}
  if a.from then
    if a.from.key then from_keys[1] = a.from.key end
    for _, c in ipairs(a.from.cands or {}) do from_keys[#from_keys + 1] = c.id end
  end
  if a.to and not a.to.literal then
    if a.to.key then to_keys[1] = a.to.key end
    for _, c in ipairs(a.to.cands or {}) do to_keys[#to_keys + 1] = c.id end
  end
  for _, k in ipairs(from_keys) do post(self.by_from, a.rel .. "|" .. k); post(self.by_any, k) end
  for _, k in ipairs(to_keys) do post(self.by_to, a.rel .. "|" .. k); post(self.by_any, k) end
end

function X:remove(id)
  local d = self.doc_of[id]
  if not d then return false end
  local doc = self.docs[d]
  for _, term in ipairs(doc.terms) do
    if self.terms[term] then
      self.terms[term][d] = nil
      self.positions[term][d] = nil
      self.df[term] = math.max(0, (self.df[term] or 1) - 1)
    end
  end
  for f, lens in pairs(self.len) do
    if lens[d] then
      self.total_len[f] = self.total_len[f] - lens[d]
      self.field_count[f] = self.field_count[f] - 1
      lens[d] = nil
    end
  end
  for _, key in ipairs(doc.entities) do if self.entity_post[key] then self.entity_post[key][d] = nil end end
  for _, m in ipairs(doc.meta) do if self.meta[m[1]] and self.meta[m[1]][m[2]] then self.meta[m[1]][m[2]][d] = nil end end
  for _, aid in ipairs(doc.assertions) do self.assertions[aid].removed = true end
  doc.removed = true
  self.doc_of[id] = nil
  self.live = self.live - 1
  self.revision = self.revision + 1
  return true
end

---------------------------------------------------------------- lookups
function X:record(d) return self.docs[d] and self.docs[d].rec end

-- live assertions of a list of ids
local function live(self, ids)
  local out = {}
  for _, id in ipairs(ids or {}) do
    local a = self.assertions[id]
    if a and not a.removed then out[#out + 1] = a end
  end
  return out
end

function X:assertions_from(rel, key) return live(self, self.by_from[rel .. "|" .. key]) end
function X:assertions_to(rel, key) return live(self, self.by_to[rel .. "|" .. key]) end
function X:assertions_about(key) return live(self, self.by_any[key]) end
function X:classifications(key) return live(self, self.classes[key]) end

function X:docs_mentioning(key)
  local out = {}
  for d in pairs(self.entity_post[key] or {}) do if self.docs[d] and not self.docs[d].removed then out[#out + 1] = d end end
  table.sort(out)
  return out
end

---------------------------------------------------------------- BM25F with optional phrase constraint
local function idf(self, term)
  local df = self.df[term] or 0
  return math.log(1 + (self.live - df + 0.5) / (df + 0.5))
end

-- do the stemmed terms occur consecutively in document d?  (positions carry a field offset, so a phrase never spans two fields)
function X:phrase_in(d, terms)
  if #terms == 0 then return false end
  local first = self.positions[terms[1]] and self.positions[terms[1]][d]
  if not first then return false end
  for _, p in ipairs(first) do
    local ok = true
    for i = 2, #terms do
      local pl = self.positions[terms[i]] and self.positions[terms[i]][d]
      local found = false
      if pl then for _, q in ipairs(pl) do if q == p + i - 1 then found = true break end end end
      if not found then ok = false break end
    end
    if ok then return true end
  end
  return false
end

-- query = { terms = {t...}, phrases = { {t1,t2}, ... } }; returns list {doc, score, matched_terms, phrases} sorted by score desc
function X:search(query, limit)
  local scores, hits = {}, {}
  for _, term in ipairs(query.terms or {}) do
    local postings = self.terms[term]
    if postings then
      local w = idf(self, term)
      for d, per_field in pairs(postings) do
        if not self.docs[d].removed then
          local tfn = 0
          for f, tf in pairs(per_field) do
            local avg = (self.total_len[f] or 1) / math.max(1, self.field_count[f] or 1)
            local len = (self.len[f] and self.len[f][d]) or avg
            tfn = tfn + fw(self, f) * tf / (1 - B + B * len / math.max(avg, 1e-9))
          end
          scores[d] = (scores[d] or 0) + w * tfn / (K1 + tfn)
          hits[d] = hits[d] or {}
          hits[d][#hits[d] + 1] = term
        end
      end
    end
  end
  local out = {}
  for d, s in pairs(scores) do
    local ph = {}
    for _, p in ipairs(query.phrases or {}) do if self:phrase_in(d, p) then ph[#ph + 1] = table.concat(p, " ") end end
    out[#out + 1] = { doc = d, score = s + 1.5 * #ph, lexical = s, matched = hits[d], phrases = ph }
  end
  table.sort(out, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.doc < b.doc end)
  if limit and #out > limit then for i = #out, limit + 1, -1 do out[i] = nil end end
  return out
end

function X:stats()
  return { documents = self.live, terms = (function() local c = 0; for _ in pairs(self.terms) do c = c + 1 end return c end)(),
    assertions = (function() local c = 0; for _, a in ipairs(self.assertions) do if not a.removed then c = c + 1 end end return c end)(),
    entities = (function() local c = 0; for _ in pairs(self.entity_post) do c = c + 1 end return c end)(), revision = self.revision }
end

return X
