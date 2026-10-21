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
local Profile = require("asi.nlu.profile")
local QA = require("asi.nlu.qa")

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
  self.profiles = {}         -- dataset id -> asi.nlu.profile (what the segments of the dataset ARE: facts, persona statements, examples, turns ...)
  self.policy = {}           -- dataset id -> the user's reading of the dataset (see K:set_policy); empty = the dataset's own structure decides
  self.qa_report = {}        -- record id -> { converted = n, skipped = { reason ... } } for question / answer pairs
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

---------------------------------------------------------------- how the dataset is read: profile + the user's policy
function K:has_turns(profile, rec_id)
  local ra = profile.recs[rec_id]
  if not ra then return false end
  for _, sg in ipairs(ra.segs) do
    local r = Profile.role_of(profile, sg)
    if r == "turn_user" or r == "turn_assistant" then return true end
  end
  return false
end

function K:qa_interp()
  if not self.qa_interpreter or self.qa_interpreter.lex ~= self.lex then
    self.qa_interpreter = require("asi.nlu.interp").new({ lexicon = self.lex })
  end
  return self.qa_interpreter
end

local ALL_ROLES = { "style_spec", "style_example", "anti_example", "persona_declaration", "meta", "turn_user", "turn_other", "turn_system" }
-- policy: { reading = "facts" | nil, include = { role = true }, exclude = { role = true }, records = { [record id] = "knowledge" | "ignore" }, qa = false, persona = { ... } }
function K:effective_policy(did)
  local p = self.policy[did] or {}
  local inc, exc = {}, {}
  if p.reading == "facts" then for _, r in ipairs(ALL_ROLES) do inc[r] = true end end
  for r in pairs(p.include or {}) do inc[r] = true end
  for r in pairs(p.exclude or {}) do exc[r] = true end
  -- record overrides: a reference ("n=2", "about=Germany") names records of any dataset; only the records of this one count here
  local recmap = {}
  for _, rr in ipairs(p.records or {}) do
    for _, id in ipairs(self:resolve_record_ref(rr.ref)) do
      if id:sub(1, #did + 1) == did .. ":" then recmap[id] = rr.action end
    end
  end
  return { reading = p.reading, include = inc, exclude = exc, records = recmap, qa = p.qa, persona = p.persona or {} }
end

-- "n=2" the second record (in the order of the datasets; negative counts from the end), "about=Germany" the records whose text mentions it
function K:resolve_record_ref(ref)
  local ids = {}
  for _, did in ipairs(self.dataset_order) do
    local ds = self.datasets[did]
    for _, id in ipairs(ds.order) do if ds.records[id] then ids[#ids + 1] = id end end
  end
  local n = ref:match("^n=(%-?%d+)$")
  if n then
    n = tonumber(n)
    if n < 0 then n = #ids + 1 + n end
    return ids[n] and { ids[n] } or {}
  end
  local about = ref:match("^about=(.+)$")
  local out = {}
  if about then
    local needle = about:lower()
    for _, id in ipairs(ids) do
      local rec = self:record(id)
      if rec and (rec.text or ""):lower():find(needle, 1, true) then out[#out + 1] = id end
    end
  end
  return out
end

function K:profile(did) return self.profiles[did] end

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
  local profile = self.profiles[rec.dataset]
  local pol = self:effective_policy(rec.dataset)
  local rec_override = pol.records[rec.id]
  for _, f in ipairs(rec.text_fields or {}) do
    local text = rec.field_text[f]
    if text and text ~= "" then
      -- the parts of the field that are not knowledge: style specifications, example utterances, questions, instructions, descriptions of the dataset
      local skip
      if profile and rec_override ~= "knowledge" then
        skip = Profile.skip_ranges(profile, rec.id, f, { include = pol.include, exclude = pol.exclude })
        if rec_override == "ignore" then skip = { { s = 1, e = #text, role = "ignored" } } end
      end
      if skip then analysis.skip = analysis.skip or {}; analysis.skip[f] = skip end
      local r = ex:extract(text, { topic = topic, skip = skip })
      analysis.skipped_sentences = (analysis.skipped_sentences or 0) + (r.skipped or 0)
      for _, a in ipairs(r.assertions) do a.field = f; a.reliability = rec.reliability; analysis.assertions[#analysis.assertions + 1] = a end
      for _, m in ipairs(r.mentions) do m.field = f; analysis.mentions[#analysis.mentions + 1] = m end
      for _, al in ipairs(r.aliases) do analysis.aliases[#analysis.aliases + 1] = al end
      for _, rd in ipairs(r.reader_directed) do rd.field = f; analysis.reader_directed[#analysis.reader_directed + 1] = rd end
      analysis.sentences = analysis.sentences + r.sentences
      if r.limited then analysis.limited = true end
    end
  end
  if topic and topic.key then analysis.mentions[#analysis.mentions + 1] = { key = topic.key, type = topic.type, text = topic.text, field = "title", topic = true } end
  -- instructions the dataset aims at its reader are flagged as such whether or not they were also recognised as a style statement
  if profile then
    local ra = profile.recs[rec.id]
    for _, sg in ipairs(ra and ra.segs or {}) do
      if sg.role == "behavior_directive" then
        local flagged = false
        for _, rd in ipairs(analysis.reader_directed) do if rd.field == sg.field and rd.s <= sg.e and rd.e >= sg.s then flagged = true break end end
        if not flagged then
          analysis.reader_directed[#analysis.reader_directed + 1] = { text = sg.text, reasons = { sg.via }, s = sg.s, e = sg.e, field = sg.field, sent = 0, source = "profile" }
        end
      end
    end
    -- question / answer pairs: the answer is read through the question
    if pol.qa ~= false and (profile.pair_fields or self:has_turns(profile, rec.id)) then
      local pairs_ = Profile.pairs(profile, rec.id)
      if #pairs_ > 0 then
        local interp = self:qa_interp()
        local rep = { converted = 0, skipped = {} }
        for _, pr in ipairs(pairs_) do
          local qt = (rec.field_text[pr.q.field] or ""):sub(pr.q.s, pr.q.e)
          local at = (rec.field_text[pr.a.field] or ""):sub(pr.a.s, pr.a.e)
          local a, why = QA.convert(self, interp, qt, at)
          if a then
            a.field, a.reliability = pr.a.field, rec.reliability
            analysis.assertions[#analysis.assertions + 1] = a
            for _, d in ipairs({ a.from, a.to }) do
              if d and d.key and not d.literal then analysis.mentions[#analysis.mentions + 1] = { key = d.key, type = d.type, text = d.text, field = pr.a.field } end
            end
            rep.converted = rep.converted + 1
          else rep.skipped[#rep.skipped + 1] = why end
        end
        self.qa_report[rec.id] = rep
      end
    end
  end
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
  -- what the records ARE comes first (field names, speaker labels, persona / style statements, examples), then they are read accordingly
  local profile = self.profiles[did]
  if not profile then profile = Profile.new(); self.profiles[did] = profile end
  local fresh = {}
  for _, rec in ipairs(report.records or {}) do
    if self.datasets[did].records[rec.id] == rec then
      if profile.recs[rec.id] then Profile.remove_record(profile, rec.id) end
      fresh[#fresh + 1] = rec
    end
  end
  Profile.add_records(profile, fresh, { lex = self.base })
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
  local kind, shares = Profile.kind(profile)
  report.dataset_kind = kind
  report.roles = Profile.summary(profile).roles
  return report
end

-- the user's reading of a dataset changed ("treat the examples as facts"): the derived state (index, overlay, vocabulary) is rebuilt from the records
-- policy: one reading for every dataset (what the user said applies to "the dataset"), or nil to go back to the structure the data itself shows
function K:set_policy(did, policy)
  self.policy[did] = policy
  return self:rebuild()
end

local function policy_key(p) return p and U.json_encode(p, { sort = true }) or "" end
function K:set_policy_all(policy)
  local changed = false
  for _, did in ipairs(self.dataset_order) do
    if policy_key(self.policy[did]) ~= policy_key(policy) then self.policy[did] = policy; changed = true end
  end
  if changed then self:rebuild() end
  return changed
end

function K:rebuild()
  self.lex = Lexicon.new(self.base)
  self.lex.spell = self.lex:build_spell(self.base.spell)
  self.index = Index.new()
  self.vocab, self.aliases, self.alias_keys, self.rel_induced = {}, {}, {}, {}
  self.reader_directed, self.qa_report = {}, {}
  self.qa_interpreter = nil
  for _, did in ipairs(self.dataset_order) do
    local ds = self.datasets[did]
    local recs = {}
    for _, id in ipairs(ds.order) do
      local rec = ds.records[id]
      if rec then recs[#recs + 1] = rec end
    end
    -- the profile is derived again from the records, then the user's statements about what a record IS are applied to it
    local pr = Profile.new()
    Profile.add_records(pr, recs, { lex = self.base })
    self.profiles[did] = pr
    local pol = self:effective_policy(did)
    for id, action in pairs(pol.records) do
      if action == "style_example" then Profile.force_role(pr, self:record(id), "style_example") end
    end
    for _, rec in ipairs(recs) do self:index_record(rec) end
  end
  self.revision = self.revision + 1
  return self:refresh_overlay()
end

function K:remove(record_id)
  local did = record_id:match("^([^:]+):")
  local ds = did and self.datasets[did]
  if not ds then return false end
  ds:remove(record_id)
  self.index:remove(record_id)
  if self.profiles[did] then Profile.remove_record(self.profiles[did], record_id) end
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
  for _, did in ipairs(self.dataset_order) do
    local pol = self.policy[did]
    if pol then parts[#parts + 1] = did .. "=" .. U.json_encode(pol, { sort = true }) end
  end
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
