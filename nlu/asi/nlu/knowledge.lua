-- asi.nlu.knowledge: a searchable knowledge base built from supplied datasets.
--   datasets (asi.nlu.dataset)  ->  assertion extraction (asi.nlu.assertions)  ->  index (asi.nlu.index)  +  a lexicon OVERLAY.
-- The overlay is how unseen terminology becomes usable without rewriting the interpreter: entities discovered in the data are registered with
-- the same keys the interpreter produces for open-set mentions, relations named by structured columns are induced from their names, and every
-- overlay item records the records that justified it.  Nothing is learned from the interpreter's own outputs (no self-reinforcement).
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Lattice = require("asi.nlu.lattice")
local P = require("asi.nlu.parse")
local Lexicon = require("asi.nlu.lexicon")
local Dataset = require("asi.nlu.dataset")
local Index = require("asi.nlu.index")
local Assertions = require("asi.nlu.assertions")
local UC = require("asi.nlu.unicode")

local K = {}
K.__index = K
K.SCHEMA = "nlu.knowledge/1"

function K.new(base_lex, opts)
  opts = opts or {}
  local self = setmetatable({}, K)
  self.base = base_lex
  self.lex = Lexicon.new(base_lex)
  self.lex.spell = self.lex:build_spell(base_lex.spell)
  self.datasets, self.dataset_order = {}, {}
  self.index = Index.new()
  self.meter_budget = opts.record_budget or 400000
  self.vocab = {}            -- mention key -> { text, count, records = {id...}, types = {type -> n}, class_votes = {...} }
  self.aliases = {}          -- folded alias -> { key, evidence = {record ids} }  (an alias is accepted only when the data itself states it)
  self.alias_keys = {}       -- canonical key -> { mention keys that denote it }
  self.rel_induced = {}      -- relation id -> { name, records }
  self.reader_directed = {}  -- record id -> list of flagged sentences
  self.revision = 0
  self.errors = {}
  return self
end

---------------------------------------------------------------- linking short strings (titles, triple cells)
local function fold(s) return UC.fold(s):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") end

function K:link_text(text, expected)
  local an = Lex.analyze(text, {})
  if an.status == "rejected" or #an.units == 0 then return { text = text, key = "mention:" .. fold(text), status = "unseen", unverified_link = true } end
  local lat = Lattice.build(an, self.lex, {})
  local cover = lat:covers(1, 1, #an.units)[1]
  if cover then
    local S = P.new_state(an, self.lex, lat, cover, { flags = {} })
    S.sentence = an.sentences[1]
    for _, np in ipairs(P.parse_np(S, 1)) do
      if np.nxt > #S.chunks then
        local d = Assertions.describe_np(S, { flags = {} }, np, expected, "link")
        if d.key or d.literal or d.cands then return d end
      end
    end
  end
  return { text = text, key = "mention:" .. fold(text), status = "unseen", unverified_link = true }
end

---------------------------------------------------------------- per-record indexing
local function topic_of(self, rec)
  for _, f in ipairs(rec.text_fields or {}) do
    local lf = f:lower()
    if lf == "title" or lf == "name" or lf == "headline" or lf == "heading" then
      local d = self:link_text(rec.field_text[f])
      if d.key and not d.unverified_link then return d end
    end
  end
end

function K:index_record(rec)
  local analysis = { assertions = {}, mentions = {}, aliases = {}, reader_directed = {}, sentences = 0 }
  if rec.duplicate_of then
    -- duplicates stay searchable but never corroborate: no assertions, flagged
    self.index:add(rec, analysis)
    return analysis
  end
  local meter = U.meter(self.meter_budget)
  local ex = Assertions.new(self.lex, { meter = meter })
  local topic = topic_of(self, rec)
  for _, f in ipairs(rec.text_fields or {}) do
    local text = rec.field_text[f]
    if text and text ~= "" then
      local r = ex:extract(text, { topic = topic })
      for _, a in ipairs(r.assertions) do a.field = f; a.reliability = rec.reliability; analysis.assertions[#analysis.assertions + 1] = a end
      for _, m in ipairs(r.mentions) do m.field = f; analysis.mentions[#analysis.mentions + 1] = m end
      for _, al in ipairs(r.aliases) do analysis.aliases[#analysis.aliases + 1] = al end
      for _, rd in ipairs(r.reader_directed) do rd.field = f; analysis.reader_directed[#analysis.reader_directed + 1] = rd end
      analysis.sentences = analysis.sentences + r.sentences
      if r.limited then analysis.limited = true end
    end
  end
  if topic and topic.key then analysis.mentions[#analysis.mentions + 1] = { key = topic.key, type = topic.type, text = topic.text, field = "title", topic = true } end
  -- structured triple rows are explicit assertions (highest precision, still tagged with their provenance)
  if rec.triple then
    local t = rec.triple
    local rel = self.lex:rel_by_name(t.relation)
    local induced = false
    if not rel then
      local norm = t.relation:lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
      -- a relation named only by the data lives in the same "open:" namespace as relations inferred from unknown words in text or questions
      rel = self.lex:induce_relation(norm, { id = "open:" .. norm:gsub("e$", ""), source = "induced" })
      induced = true
      self.rel_induced[rel.id] = self.rel_induced[rel.id] or { name = t.relation, records = {} }
      table.insert(self.rel_induced[rel.id].records, rec.id)
    end
    local from = self:link_text(t.subject, rel.from)
    local to = self:link_text(t.object, rel.to)
    analysis.assertions[#analysis.assertions + 1] = { rel = rel.id, from = from, to = to, polarity = t.polarity or "positive", modality = "asserted", tense = "present",
      pattern = "structured_triple", structured = true, induced_relation = induced or nil, text = rec.text, sent = 0, s = 1, e = #rec.text, reliability = rec.reliability }
    for _, d in ipairs({ from, to }) do
      if d.key and not d.literal then analysis.mentions[#analysis.mentions + 1] = { key = d.key, type = d.type, text = d.text, field = "triple" } end
    end
  end
  -- vocabulary + alias evidence
  for _, m in ipairs(analysis.mentions) do
    if m.key and m.key:sub(1, 8) == "mention:" and not m.weak then
      local v = self.vocab[m.key]
      if not v then v = { text = m.text, count = 0, records = {}, seen = {}, types = {}, class_votes = {} }; self.vocab[m.key] = v end
      v.count = v.count + 1
      if not v.seen[rec.id] then v.seen[rec.id] = true; v.records[#v.records + 1] = rec.id end
      if m.type then v.types[m.type] = (v.types[m.type] or 0) + 1 end
    end
  end
  for _, a in ipairs(analysis.assertions) do
    if a.is_class and a.from and a.from.key and self.vocab[a.from.key] and a.class_type then
      local v = self.vocab[a.from.key]
      v.class_votes[a.class_type] = (v.class_votes[a.class_type] or 0) + 1
    end
    -- role-signature type evidence for unseen participants
    if not a.is_class and a.rel then
      local rel = self.lex:get_rel(a.rel)
      for _, role in ipairs({ "from", "to" }) do
        local d = a[role]
        if rel and d and d.key and d.key:sub(1, 8) == "mention:" and self.vocab[d.key] and not d.literal then
          local v = self.vocab[d.key]
          v.sig_votes = v.sig_votes or {}
          v.sig_votes[rel[role]] = (v.sig_votes[rel[role]] or 0) + 1
        end
      end
    end
  end
  for _, al in ipairs(analysis.aliases) do
    local fa = fold(al.alias)
    local e = self.aliases[fa]
    if not e then e = { key = al.key, evidence = {} }; self.aliases[fa] = e end
    if e.key == al.key then
      e.evidence[#e.evidence + 1] = rec.id
      local list = self.alias_keys[al.key]
      if not list then list = {}; self.alias_keys[al.key] = list end
      local mk = "mention:" .. fa
      local dup = false
      for _, x in ipairs(list) do if x == mk then dup = true end end
      if not dup then list[#list + 1] = mk end
    else e.conflict = true end
  end
  if #analysis.reader_directed > 0 then self.reader_directed[rec.id] = analysis.reader_directed end
  self.index:add(rec, analysis)
  return analysis
end

---------------------------------------------------------------- overlay: dataset-discovered entities
local function best_vote(votes)
  local best, bn
  for t, n in pairs(votes or {}) do if not bn or n > bn or (n == bn and t < best) then best, bn = t, n end end
  return best, bn
end

function K:refresh_overlay()
  local added = 0
  for key, v in pairs(self.vocab) do
    if not self.lex.entities[key] and not self.base:get_entity(key) then
      local ty = best_vote(v.class_votes) or best_vote(v.types) or best_vote(v.sig_votes) or "entity"
      if not self.lex:has_type(ty) then ty = "entity" end
      local names = { { text = v.text, cs = false } }
      self.lex:add_entity({ id = key, type = ty, names = names, domain = {}, prior = 0.4, attr = {}, source = "dataset",
        evidence = { records = #v.records, mentions = v.count } })
      added = added + 1
    end
  end
  for fa, al in pairs(self.aliases) do
    if not al.conflict and not al.registered then
      local target = self.lex:get_entity(al.key)
      if target then
        self.lex:add_entity({ id = "alias:" .. fa, type = target.type, names = { { text = fa, cs = false } }, domain = target.domain, prior = 0.4, attr = {}, source = "dataset_alias",
          alias_of = al.key, evidence = al.evidence })
        al.registered = true
        added = added + 1
      end
    end
  end
  if added > 0 then self.lex.spell = self.lex:build_spell(self.base.spell) end
  return added
end

---------------------------------------------------------------- public API
-- opts: { dataset = id, version, label = {year=}, format, name, mapping }
function K:ingest(text, opts)
  opts = opts or {}
  local did = opts.dataset or "dataset"
  local ds = self.datasets[did]
  if not ds then
    ds = Dataset.new({ id = did, version = opts.version, label = opts.label })
    self.datasets[did] = ds
    self.dataset_order[#self.dataset_order + 1] = did
  end
  local report = ds:ingest(text, opts)
  local n_assert, n_flag = 0, 0
  for _, rec in ipairs(report.records or {}) do
    if self.datasets[did].records[rec.id] == rec then
      local an = self:index_record(rec)
      n_assert = n_assert + #an.assertions
      n_flag = n_flag + #an.reader_directed
    end
  end
  self.revision = self.revision + 1
  report.assertions = n_assert
  report.reader_directed = n_flag
  report.overlay_added = self:refresh_overlay()
  report.records = nil   -- the per-record table stays inside the dataset
  return report
end

function K:remove(record_id)
  local did = record_id:match("^([^:]+):")
  local ds = did and self.datasets[did]
  if not ds then return false end
  ds:remove(record_id)
  self.index:remove(record_id)
  self.revision = self.revision + 1
  return true
end

-- every key under which the data may refer to the same thing (canonical key + evidence-backed aliases)
function K:variants(key)
  local out = { key }
  for _, k in ipairs(self.alias_keys[key] or {}) do out[#out + 1] = k end
  return out
end

function K:canonical(key)
  local e = self.lex:get_entity(key)
  if e and e.alias_of then return e.alias_of end
  if key:sub(1, 8) == "mention:" then
    local al = self.aliases[key:sub(9)]
    if al and not al.conflict then return al.key end
  end
  return key
end

-- a stable key for caches: changes whenever any dataset record, the overlay, or the schema version changes
function K:digest()
  local parts = { K.SCHEMA }
  for _, did in ipairs(self.dataset_order) do parts[#parts + 1] = self.datasets[did]:digest() end
  parts[#parts + 1] = tostring(self.index.revision)
  return U.sha256(table.concat(parts, "|"))
end

function K:record(id)
  local did = id:match("^([^:]+):")
  return did and self.datasets[did] and self.datasets[did].records[id]
end

-- is `ds` the dataset a constraint such as "the 2020 dataset" refers to?
function K:dataset_label_of(rec)
  local ds = self.datasets[rec.dataset]
  return ds and ds.label or nil
end

-- terminology report: unfamiliar terms in the supplied data, what the data says about them, and whether their meaning is ambiguous
function K:terminology(limit)
  local out = {}
  for key, v in pairs(self.vocab) do
    local entry = { key = key, text = v.text, mentions = v.count, records = #v.records, kind = "entity" }
    entry.types = {}
    for t, n in pairs(v.class_votes) do entry.types[#entry.types + 1] = { type = t, evidence = "classification", n = n } end
    for t, n in pairs(v.types) do entry.types[#entry.types + 1] = { type = t, evidence = "mention", n = n } end
    table.sort(entry.types, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.type < b.type end)
    entry.ambiguous = (best_vote(v.class_votes) ~= nil) and (function() local c = 0; for _ in pairs(v.class_votes) do c = c + 1 end return c > 1 end)() or nil
    local defs = {}
    for _, a in ipairs(self.index:classifications(key)) do defs[#defs + 1] = { class = a.class_text, record = a.record, text = a.text } end
    entry.definitions = defs
    out[#out + 1] = entry
  end
  table.sort(out, function(a, b) if a.mentions ~= b.mentions then return a.mentions > b.mentions end return a.key < b.key end)
  if limit and #out > limit then for i = #out, limit + 1, -1 do out[i] = nil end end
  return out
end

function K:stats()
  local s = self.index:stats()
  s.datasets = #self.dataset_order
  s.vocabulary = (function() local c = 0; for _ in pairs(self.vocab) do c = c + 1 end return c end)()
  s.induced_relations = (function() local c = 0; for _ in pairs(self.rel_induced) do c = c + 1 end return c end)()
  s.reader_directed_records = (function() local c = 0; for _ in pairs(self.reader_directed) do c = c + 1 end return c end)()
  s.digest = self:digest()
  return s
end

return K
