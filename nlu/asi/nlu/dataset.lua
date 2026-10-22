-- asi.nlu.dataset: safe ingestion of local knowledge as DATA.  Nothing here is ever executed or `load`ed.
-- Supported formats (implemented and tested, nothing more is claimed): jsonl, json (array / {records=[...]}), csv, tsv, txt/md (paragraph records),
-- and triple tables (subject/relation/object columns or keys).  PDF, DOCX, HTML and spreadsheets are NOT supported.
-- Records keep their original fields, provenance (source + line/row), checksum, optional date, and a reliability that is "default" unless the
-- data declares one.  Missing metadata is never invented.  Duplicates are detected (exact + bottom-k MinHash near-duplicates), versions are
-- tracked, and updates are incremental (a dataset digest changes whenever any record changes, so caches can key on it).
local U = require("asi.nlu.util")
local TU = require("asi.nlu.textutil")
local UC = require("asi.nlu.unicode")
local Profile = require("asi.nlu.profile")

local D = {}
D.__index = D
D.SCHEMA = "nlu.dataset/1"
D.LIMITS = { max_record_bytes = 262144, max_fields = 256, max_records = 2000000, max_depth = 16, sketch_bucket = 48, sketch_shared = 6 }

local TEXT_NAMES = U.set({ "text", "body", "content", "description", "abstract", "summary", "title", "name", "headline", "note", "notes", "comment", "sentence", "passage", "statement", "claim" })
local ID_NAMES = U.set({ "id", "uid", "key", "record_id", "doc_id", "document_id", "identifier", "uuid", "_id" })
local DATE_NAMES = U.set({ "date", "published", "published_at", "updated", "updated_at", "created", "created_at", "timestamp", "year", "as_of", "valid_from", "effective_date" })
local SUBJECT_NAMES = U.set({ "subject", "head", "entity", "source_entity", "s" })
local RELATION_NAMES = U.set({ "relation", "predicate", "rel", "property", "attribute", "p" })
local OBJECT_NAMES = U.set({ "object", "tail", "value", "target", "target_entity", "o" })
local RELIABILITY_NAMES = U.set({ "reliability", "confidence", "trust", "score_reliability" })
-- wide tables ("country,capital,population"): the column that names the thing each row is about, in order of preference
local ENTITY_COLS = { "name", "title", "entity", "country", "city", "company", "organisation", "organization", "person", "product", "item", "place", "state", "region", "book", "film", "movie", "album",
  "artist", "brand", "team", "player", "club", "university", "school", "species", "planet", "river", "mountain", "language", "author", "politician", "character" }
local SKIP_WIDE = U.set({ "source", "notes", "note", "comment", "comments", "url", "link", "image", "photo", "version", "label", "tags", "tag", "category", "type", "section", "rank", "index", "row", "no", "number" })

---------------------------------------------------------------- CSV / TSV (RFC 4180 subset: quotes, doubled quotes, embedded delimiters / newlines)
function D.parse_delimited(text, delim)
  delim = delim or ","
  local rows, row, field, i, n = {}, {}, {}, 1, #text
  local in_q, at_field_start = false, true
  local errs = {}
  local function push_field() row[#row + 1] = table.concat(field); field = {}; at_field_start = true end
  local function push_row()
    push_field()
    if not (#row == 1 and row[1] == "") then rows[#rows + 1] = row end
    row = {}
  end
  while i <= n do
    local c = text:sub(i, i)
    if in_q then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then field[#field + 1] = '"'; i = i + 1 else in_q = false end
      else field[#field + 1] = c end
    else
      if c == '"' and at_field_start then in_q = true; at_field_start = false
      elseif c == delim then push_field()
      elseif c == "\r" then if text:sub(i + 1, i + 1) == "\n" then i = i + 1 end push_row()
      elseif c == "\n" then push_row()
      else field[#field + 1] = c; at_field_start = false end
    end
    i = i + 1
  end
  if in_q then errs[#errs + 1] = "unterminated quoted field at end of input" end
  if #field > 0 or #row > 0 then push_row() end
  return rows, errs
end

---------------------------------------------------------------- schema induction (documented heuristics, never silent)
local function is_numberish(s) return tonumber(s) ~= nil end
local function looks_date(s)
  if type(s) ~= "string" then return false end
  return s:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil or s:match("^%d%d%d%d/%d%d/%d%d") ~= nil or s:match("^%d%d%d%d$") ~= nil
end

-- rows: list of flat tables {field = scalar}; returns a schema description
function D.induce_schema(rows)
  local stats, order = {}, {}
  for _, r in ipairs(rows) do
    for k, v in pairs(r) do
      local st = stats[k]
      if not st then st = { n = 0, strings = 0, numbers = 0, dates = 0, total_len = 0, total_words = 0, distinct = {}, nd = 0 }; stats[k] = st; order[#order + 1] = k end
      st.n = st.n + 1
      if type(v) == "number" then st.numbers = st.numbers + 1
      elseif type(v) == "string" then
        st.strings = st.strings + 1; st.total_len = st.total_len + #v
        st.total_words = st.total_words + select(2, v:gsub("%S+", ""))
        if looks_date(v) then st.dates = st.dates + 1 end
        if is_numberish(v) then st.numbers = st.numbers + 1 end
      end
      if st.nd < 200 and not st.distinct[tostring(v)] then st.distinct[tostring(v)] = true; st.nd = st.nd + 1 end
    end
  end
  table.sort(order)
  local schema = { fields = {}, text_fields = {}, meta_fields = {}, notes = {} }
  local n = #rows
  -- columns whose NAME says what they hold (prompt / response / system / tone / persona ...) are text even when their values are short or repeated
  local froles = Profile.resolve_field_roles(order)
  for _, k in ipairs(order) do
    local st = stats[k]
    local lk = k:lower()
    local kind = "unknown"
    local avg = st.strings > 0 and st.total_len / st.strings or 0
    -- a column of sentences is text however few or repeated its values are (a two-row file has "few distinct values" in every column)
    local avg_words = st.strings > 0 and st.total_words / st.strings or 0
    local frole = froles[k]
    if ID_NAMES[lk] and st.nd == st.n then kind = "id"
    elseif frole and frole ~= "speaker" and st.strings >= st.n * 0.5 then kind = "text"
    elseif DATE_NAMES[lk] and st.dates + st.numbers >= st.n * 0.8 then kind = "date"
    elseif st.dates >= st.n * 0.8 and st.strings > 0 then kind = "date"
    elseif st.numbers >= st.n * 0.9 then kind = "number"
    elseif TEXT_NAMES[lk] or avg > 60 or (avg_words >= 5 and st.numbers == 0) then kind = "text"
    elseif st.nd <= math.max(10, n // 5) then kind = "category"
    elseif st.strings > 0 then kind = "text" end
    if SUBJECT_NAMES[lk] or RELATION_NAMES[lk] or OBJECT_NAMES[lk] then schema.triple_hint = schema.triple_hint or {} end
    schema.fields[k] = kind
  end
  -- triples need all three roles present
  local sub, rel, obj
  for _, k in ipairs(order) do
    local lk = k:lower()
    if SUBJECT_NAMES[lk] and not sub and #lk > 1 then sub = k end
    if RELATION_NAMES[lk] and not rel and #lk > 1 then rel = k end
    if OBJECT_NAMES[lk] and not obj and #lk > 1 then obj = k end
  end
  if sub and rel and obj then schema.triple = { subject = sub, relation = rel, object = obj } end
  for _, k in ipairs(order) do
    local kind = schema.fields[k]
    if kind == "id" and not schema.id_field then schema.id_field = k
    elseif kind == "date" and not schema.date_field then schema.date_field = k
    elseif kind == "text" then schema.text_fields[#schema.text_fields + 1] = k
    else schema.meta_fields[#schema.meta_fields + 1] = k end
    if RELIABILITY_NAMES[k:lower()] and stats[k].numbers >= stats[k].n * 0.9 then schema.reliability_field = k end
  end
  -- a wide table: one entity per row, every other short column an attribute of it, the column name naming the relation ("country,capital,population")
  if not schema.triple then
    local entity
    for _, cand in ipairs(ENTITY_COLS) do
      for _, k in ipairs(order) do
        local kd = schema.fields[k]
        if k:lower() == cand and (kd == "text" or kd == "category" or kd == "unknown") and stats[k].nd >= stats[k].n * 0.9 and not froles[k] then entity = k break end
      end
      if entity then break end
    end
    if entity then
      local cols, running_text = {}, false
      for _, k in ipairs(order) do
        local kd, st = schema.fields[k], stats[k]
        local avg_len = st.strings > 0 and st.total_len / st.strings or 0
        local avg_w = st.strings > 0 and st.total_words / st.strings or 0
        if k ~= entity and kd ~= "id" and kd ~= "date" and not RELIABILITY_NAMES[k:lower()] then
          if avg_w >= 5 or avg_len > 60 or froles[k] then running_text = true
          elseif not SKIP_WIDE[k:lower()] and (kd == "number" or kd == "category" or kd == "unknown" or kd == "text") then cols[#cols + 1] = k end
        end
      end
      if #cols >= 1 and not running_text then
        schema.wide = { subject = entity, columns = cols }
        local drop = U.set(cols)
        drop[entity] = true
        local keep_text, keep_meta = {}, {}
        for _, k in ipairs(schema.text_fields) do if not drop[k] then keep_text[#keep_text + 1] = k end end
        for _, k in ipairs(schema.meta_fields) do keep_meta[#keep_meta + 1] = k end
        for k in pairs(drop) do keep_meta[#keep_meta + 1] = k end
        table.sort(keep_meta)
        schema.text_fields, schema.meta_fields = keep_text, keep_meta
        schema.notes[#schema.notes + 1] = "wide table: '" .. entity .. "' names the thing each row is about, the columns " .. table.concat(cols, ", ") .. " are its attributes (the column name is the relation)"
      end
    end
  end
  if schema.triple then
    -- triple columns are structured assertions, not free text
    local trip = U.set({ schema.triple.subject, schema.triple.relation, schema.triple.object })
    local keep = {}
    for _, k in ipairs(schema.text_fields) do if not trip[k] then keep[#keep + 1] = k end end
    schema.text_fields = keep
  end
  if not schema.id_field then schema.notes[#schema.notes + 1] = "no id column detected: record ids are generated and flagged id_generated" end
  if #schema.text_fields == 0 and not schema.triple then schema.notes[#schema.notes + 1] = "no text column detected: records are metadata-only" end
  return schema
end

---------------------------------------------------------------- construction
function D.new(opts)
  opts = opts or {}
  local self = setmetatable({}, D)
  self.schema_version = D.SCHEMA
  self.id = opts.id or "dataset"
  self.version = opts.version or "v1"
  self.label = opts.label                 -- e.g. { year = 2020, name = "supplied 2020 dataset" }  (declared, never guessed)
  self.revision = 0
  self.records, self.order = {}, {}
  self.by_checksum, self.sketch_index = {}, {}
  self.history = {}
  self.errors = {}
  self.formats = {}
  return self
end

---------------------------------------------------------------- normalisation of one raw record
local function flat_scalar(v)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return v end
  return nil
end

-- a list of chat messages ({role, content}, {from, value}, ...) becomes one transcript: "Role: content" per message, continuation lines indented
local SPEAKER_KEYS = { "role", "from", "speaker", "author", "sender" }
local CONTENT_KEYS = { "content", "value", "text", "message" }
local function chat_lines(list)
  local lines = {}
  for _, m in ipairs(list) do
    if type(m) ~= "table" or #m > 0 then return nil end
    local who, what
    for _, k in ipairs(SPEAKER_KEYS) do if type(m[k]) == "string" and m[k] ~= "" then who = m[k]; break end end
    for _, k in ipairs(CONTENT_KEYS) do
      if type(m[k]) == "string" then what = m[k]; break end
      if type(m[k]) == "table" and #m[k] > 0 then
        local parts = {}
        for _, x in ipairs(m[k]) do if type(x) == "table" and type(x.text) == "string" then parts[#parts + 1] = x.text elseif type(x) == "string" then parts[#parts + 1] = x end end
        if #parts > 0 then what = table.concat(parts, "\n"); break end
      end
    end
    if not who or not what then return nil end
    lines[#lines + 1] = who:gsub("[:\n]", " ") .. ": " .. what:gsub("\n", "\n  ")
  end
  if #lines == 0 then return nil end
  return table.concat(lines, "\n")
end

-- shallow flattening: nested objects -> dotted keys (depth <= 3), arrays of scalars -> "a; b; c", arrays of chat messages -> one transcript.
-- Other arrays of objects are NOT indexed (reported).
local function flatten(raw, notes)
  local out = {}
  local function walk(prefix, v, depth)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then out[prefix] = v
    elseif t == "table" and v ~= U.NULL then
      if #v > 0 then
        local chat = (type(v[1]) == "table") and chat_lines(v) or nil
        if chat then out[prefix] = chat; notes.chat = (notes.chat or 0) + 1
        else
          local scal = {}
          for _, x in ipairs(v) do
            if type(x) == "string" or type(x) == "number" or type(x) == "boolean" then scal[#scal + 1] = tostring(x)
            else notes.nested = (notes.nested or 0) + 1 end
          end
          if #scal > 0 then out[prefix] = table.concat(scal, "; ") end
        end
      elseif depth < 3 then
        for k, x in pairs(v) do walk(prefix .. "." .. tostring(k), x, depth + 1) end
      else notes.nested = (notes.nested or 0) + 1 end
    end
  end
  for k, v in pairs(raw) do walk(tostring(k), v, 1) end
  return out
end

-- shingle sketch (bottom-k MinHash over word 4-grams) for near-duplicate detection
local function sketch_of(text)
  local toks = TU.tokens(text, { raw = true, keep_stop = true })
  if #toks < 6 then return nil end
  local hs = {}
  for i = 1, #toks - 3 do
    local g = toks[i].w .. " " .. toks[i + 1].w .. " " .. toks[i + 2].w .. " " .. toks[i + 3].w
    hs[#hs + 1] = U.hash64(g)
  end
  table.sort(hs)
  local out, seen = {}, {}
  for _, h in ipairs(hs) do
    if not seen[h] then seen[h] = true; out[#out + 1] = h end
    if #out >= 16 then break end
  end
  return out
end

local function sketch_sim(a, b)
  local sa = {}
  for _, h in ipairs(a) do sa[h] = true end
  local inter = 0
  for _, h in ipairs(b) do if sa[h] then inter = inter + 1 end end
  local union = #a + #b - inter
  return union > 0 and inter / union or 0
end

local function norm_text_key(text)
  local toks = TU.tokens(text, { raw = true, keep_stop = true })
  local w = {}
  for i, t in ipairs(toks) do w[i] = t.w end
  return table.concat(w, " ")
end

local function year_of(v)
  if type(v) == "number" and v >= 1000 and v <= 2999 then return math.floor(v) end
  if type(v) == "string" then
    local y = v:match("^(%d%d%d%d)")
    if y then return tonumber(y) end
  end
end

-- raw: flat table of fields; opts: mapping.  Returns record or nil, err
function D:normalise(raw, map, source)
  local fields, nfields, bytes = {}, 0, 0
  for k, v in pairs(raw) do
    local sv = flat_scalar(v)
    if sv ~= nil then
      nfields = nfields + 1
      fields[tostring(k)] = sv
      bytes = bytes + #tostring(k) + #tostring(sv)
    end
  end
  if nfields > D.LIMITS.max_fields then return nil, "too many fields (" .. nfields .. ")" end
  if bytes > D.LIMITS.max_record_bytes then return nil, "record too large (" .. bytes .. " bytes)" end
  for k, v in pairs(fields) do
    if type(v) == "string" and not utf8.len(v) then return nil, "field '" .. k .. "' is not valid UTF-8" end
  end
  local rec = { dataset = self.id, version = self.version, fields = fields, source = source, meta = {}, flags = {} }
  -- identifier
  local idv = map.id_field and fields[map.id_field]
  if idv ~= nil and tostring(idv) ~= "" then rec.local_id = tostring(idv)
  else
    rec.local_id = (source.name or "rec") .. "#" .. tostring(source.row or source.line or (#self.order + 1))
    rec.flags.id_generated = true
  end
  rec.id = self.id .. ":" .. rec.local_id
  -- text (declared order, never reordered)
  local parts, names = {}, {}
  for _, f in ipairs(map.text_fields or {}) do
    local v = fields[f]
    if type(v) == "string" and v ~= "" then parts[#parts + 1] = v; names[#names + 1] = f end
  end
  rec.text = table.concat(parts, "\n")
  rec.text_fields = names
  rec.field_text = {}
  for i, f in ipairs(names) do rec.field_text[f] = parts[i] end
  for _, f in ipairs(map.meta_fields or {}) do if fields[f] ~= nil then rec.meta[f] = fields[f] end end
  -- time: declared field only
  if map.date_field and fields[map.date_field] ~= nil then
    local dv = fields[map.date_field]
    rec.date_text = tostring(dv)
    rec.year = year_of(dv)
    local y, mo, d = tostring(dv):match("^(%d%d%d%d)[%-/](%d%d)[%-/](%d%d)")
    if y then rec.date = tonumber(y) * 10000 + tonumber(mo) * 100 + tonumber(d) end
  end
  rec.dataset_year = map.dataset_year_field and year_of(fields[map.dataset_year_field]) or (self.label and self.label.year) or nil
  -- reliability: declared or default (and labelled as such)
  local rf = map.reliability_field and tonumber(fields[map.reliability_field])
  if rf then rec.reliability, rec.reliability_source = U.clamp(rf, 0, 1), "declared"
  else rec.reliability, rec.reliability_source = map.default_reliability or 0.5, "default" end
  -- wide table row: subject + (column, cell) pairs
  if map.wide and fields[map.wide.subject] ~= nil and tostring(fields[map.wide.subject]) ~= "" then
    local cells = {}
    for _, col in ipairs(map.wide.columns) do
      local v = fields[col]
      if v ~= nil and tostring(v) ~= "" then cells[#cells + 1] = { col = col, value = v } end
    end
    if #cells > 0 then
      rec.wide = { subject_col = map.wide.subject, subject = tostring(fields[map.wide.subject]), cells = cells }
      if rec.text == "" then
        local parts = {}
        for _, c in ipairs(cells) do parts[#parts + 1] = c.col .. ": " .. tostring(c.value) end
        rec.text = rec.wide.subject .. " (" .. table.concat(parts, "; ") .. ")"
        rec.flags.text_synthesised = true
      end
    end
  end
  -- structured triple
  if map.triple then
    local s, r, o = fields[map.triple.subject], fields[map.triple.relation], fields[map.triple.object]
    if s ~= nil and r ~= nil and o ~= nil and tostring(s) ~= "" and tostring(r) ~= "" and tostring(o) ~= "" then
      rec.triple = { subject = tostring(s), relation = tostring(r), object = tostring(o) }
      if map.triple.polarity and fields[map.triple.polarity] ~= nil then
        local pv = tostring(fields[map.triple.polarity]):lower()
        rec.triple.polarity = (pv == "false" or pv == "0" or pv == "negative" or pv == "no") and "negative" or "positive"
      end
      if rec.text == "" then rec.text = string.format("%s %s %s.", rec.triple.subject, rec.triple.relation:gsub("_", " "), rec.triple.object) ; rec.flags.text_synthesised = true end
    else
      rec.flags.incomplete_triple = true
    end
  end
  -- checksum of the ORIGINAL fields (canonical JSON), so any change is detectable
  rec.checksum = U.hash128(U.json_encode(fields, { nan_null = true }))
  rec.text_key = norm_text_key(rec.text)
  return rec
end

---------------------------------------------------------------- adding records (incremental, versioned, de-duplicating)
-- returns report { added, updated, unchanged, duplicates = {{id, of}}, rejected = {{index, reason}} }
function D:add_normalised(list, report)
  for idx, rec in ipairs(list) do
    if #self.order >= D.LIMITS.max_records then
      report.rejected[#report.rejected + 1] = { index = idx, reason = "dataset record limit reached" }
    else
      local old = self.records[rec.id]
      if old and old.checksum == rec.checksum then
        report.unchanged = report.unchanged + 1
      else
        if old then
          report.updated = report.updated + 1
          rec.supersedes = old.checksum
          rec.updates = (old.updates or 0) + 1
          self:drop_derived(old)
        else
          report.added = report.added + 1
          self.order[#self.order + 1] = rec.id
        end
        rec.added_in = old and old.added_in or (self.revision + 1)
        rec.revised_in = self.revision + 1
        self.records[rec.id] = rec
        -- duplicate detection
        if rec.text_key ~= "" then
          local twin = self.by_checksum[rec.text_key]
          if twin and twin ~= rec.id and self.records[twin] then
            rec.duplicate_of = twin
            rec.flags.exact_duplicate = true
            report.duplicates[#report.duplicates + 1] = { id = rec.id, of = twin, kind = "exact" }
          else
            self.by_checksum[rec.text_key] = rec.id
            local sk = sketch_of(rec.text)
            rec.sketch = sk
            if sk then
              local best, best_sim
              local cand_ids = {}
              -- A shingle shared by very many records (boilerplate such as "... is mentioned in many reports") carries no duplicate evidence and would make
              -- ingestion quadratic: buckets beyond D.LIMITS.sketch_bucket are skipped, and a candidate must share at least D.LIMITS.sketch_shared hashes.
              for _, h in ipairs(sk) do
                local bucket = self.sketch_index[h]
                if bucket and #bucket <= D.LIMITS.sketch_bucket then
                  for _, oid in ipairs(bucket) do cand_ids[oid] = (cand_ids[oid] or 0) + 1 end
                end
              end
              for oid, shared in pairs(cand_ids) do
                local o = self.records[oid]
                if shared >= D.LIMITS.sketch_shared and oid ~= rec.id and o and o.sketch and not o.duplicate_of then
                  local sim = sketch_sim(sk, o.sketch)
                  if sim >= 0.8 and (not best_sim or sim > best_sim or (sim == best_sim and oid < best)) then best, best_sim = oid, sim end
                end
              end
              if best then
                rec.duplicate_of = best
                rec.flags.near_duplicate = true
                rec.dup_similarity = best_sim
                report.duplicates[#report.duplicates + 1] = { id = rec.id, of = best, kind = "near", similarity = best_sim }
              else
                for _, h in ipairs(sk) do
                  local l = self.sketch_index[h]
                  if not l then l = {}; self.sketch_index[h] = l end
                  l[#l + 1] = rec.id
                end
              end
            end
          end
        end
      end
    end
  end
end

function D:drop_derived(old)
  if old.text_key and self.by_checksum[old.text_key] == old.id then self.by_checksum[old.text_key] = nil end
  for _, h in ipairs(old.sketch or {}) do
    local l = self.sketch_index[h]
    if l then for i = #l, 1, -1 do if l[i] == old.id then table.remove(l, i) end end end
  end
end

function D:remove(id)
  local rec = self.records[id]
  if not rec then return false end
  self:drop_derived(rec)
  self.records[id] = nil
  for i, oid in ipairs(self.order) do if oid == id then table.remove(self.order, i) break end end
  self.revision = self.revision + 1
  self.history[#self.history + 1] = { revision = self.revision, op = "remove", ids = { id } }
  self.removed = self.removed or {}
  self.removed[#self.removed + 1] = id
  return true
end

-- stable digest over (id, checksum) pairs: changes whenever any record is added, changed or removed
function D:digest()
  -- cached per revision: every mutation (ingest / remove) bumps `revision`, so the cached digest can never be stale
  if self._digest and self._digest_rev == self.revision then return self._digest end
  local d = self:compute_digest()
  self._digest, self._digest_rev = d, self.revision
  return d
end

function D:compute_digest()
  local parts = {}
  local ids = U.copy(self.order)
  table.sort(ids)
  for _, id in ipairs(ids) do parts[#parts + 1] = id .. "=" .. self.records[id].checksum end
  return U.sha256(self.id .. "|" .. self.version .. "|" .. table.concat(parts, "\n"))
end

---------------------------------------------------------------- ingestion front ends
local function parse_json_records(text)
  local doc, err = U.json_decode(text, { max_depth = D.LIMITS.max_depth })
  if doc == nil then return nil, err end
  local list = doc
  if type(doc) == "table" and not (#doc > 0) then
    list = doc.records or doc.data or doc.items or doc.documents
    -- one object with scalar fields (a character card, a config) is one record
    if type(list) ~= "table" then
      local scalar = false
      for _, v in pairs(doc) do if type(v) == "string" then scalar = true end end
      if scalar then list = { doc } else return nil, "json: expected an array of records or an object with a 'records' array" end
    end
  end
  return list
end

-- format: jsonl | json | csv | tsv | txt | md  (inferred from opts.name extension when absent)
-- opts: { name, format, mapping = {id_field, text_fields, meta_fields, date_field, triple, reliability_field, default_reliability} }
function D:ingest(text, opts)
  opts = opts or {}
  local name = opts.name or "input"
  local fmt = opts.format
  if not fmt then fmt = (name:match("%.(%w+)$") or "txt"):lower() end
  if fmt == "ndjson" then fmt = "jsonl" end
  if fmt == "markdown" then fmt = "md" end
  -- configuration and prompt files are text: "name: Aria / tone: calm" lines are read as labelled lines
  if fmt == "yaml" or fmt == "yml" or fmt == "toml" or fmt == "ini" or fmt == "cfg" or fmt == "conf" or fmt == "prompt" or fmt == "text" or fmt == "rst" or fmt == "log" then fmt = "txt" end
  local report = { format = fmt, name = name, added = 0, updated = 0, unchanged = 0, duplicates = {}, rejected = {}, notes = {} }
  if type(text) ~= "string" then report.rejected[1] = { reason = "input is not a string" }; return report end
  if not utf8.len(text) then
    report.rejected[1] = { reason = "input is not valid UTF-8; nothing ingested" }
    return report
  end
  local raws = {}   -- list of { fields = flat table, source = {...} }
  if fmt == "jsonl" then
    local line = 0
    for l in (text .. "\n"):gmatch("(.-)\r?\n") do
      line = line + 1
      if l:match("%S") then
        local v, err = U.json_decode(l, { max_depth = D.LIMITS.max_depth })
        if type(v) == "table" and #v == 0 then raws[#raws + 1] = { fields = v, source = { name = name, line = line } }
        else report.rejected[#report.rejected + 1] = { index = line, reason = "line " .. line .. ": " .. tostring(err or "not a JSON object") } end
      end
    end
  elseif fmt == "json" then
    local list, err = parse_json_records(text)
    if not list then report.rejected[1] = { reason = tostring(err) }; return report end
    for i, v in ipairs(list) do
      if type(v) == "table" and #v == 0 then raws[#raws + 1] = { fields = v, source = { name = name, row = i } }
      else report.rejected[#report.rejected + 1] = { index = i, reason = "record " .. i .. " is not an object" } end
    end
  elseif fmt == "csv" or fmt == "tsv" then
    local rows, errs = D.parse_delimited(text, fmt == "tsv" and "\t" or ",")
    for _, e in ipairs(errs) do report.notes[#report.notes + 1] = e end
    if #rows < 1 then report.rejected[1] = { reason = "empty table" }; return report end
    local header = rows[1]
    local seen = {}
    for i, h in ipairs(header) do
      h = U.trim(h)
      if h == "" or seen[h] then report.rejected[1] = { reason = "header column " .. i .. " is empty or duplicated" }; return report end
      seen[h] = true; header[i] = h
    end
    for r = 2, #rows do
      local row = rows[r]
      if #row ~= #header then
        report.rejected[#report.rejected + 1] = { index = r, reason = string.format("row %d has %d fields, expected %d", r, #row, #header) }
      else
        local f = {}
        for i, h in ipairs(header) do
          local v = row[i]
          if v ~= "" then f[h] = v end
        end
        raws[#raws + 1] = { fields = f, source = { name = name, row = r } }
      end
    end
  elseif fmt == "txt" or fmt == "md" then
    -- paragraph records; markdown headings become the `section` of the paragraphs that follow
    local section, section_path
    local pipe_table = false
    local stack = {}
    local para, pn = {}, 0
    -- a paragraph whose lines are speaker turns ("User: ...", "Aria: ...") or list items keeps its line layout: the lines ARE the structure
    local function structured(lines)
      -- a line that ends on "for example" / "like this" / "e.g." points at the lines below it, which are its sample
      for i = 1, #lines - 1 do
        local tail = lines[i]:lower():gsub("[%s%p]+$", "")
        if tail:match("for example$") or tail:match("for instance$") or tail:match("like this$") or tail:match("like so$") or tail:match("%f[%a]e%.?g$") then return true end
      end
      local marked = 0
      for _, l0 in ipairs(lines) do
        local l = l0:gsub("%*%*", ""):gsub("__", "")          -- "**Tone:** sarcastic"
        local label = l:match("^([%a][%w _%.%-']*):%s+%S")
        if l:match("^[%-%*•]%s+%S") or l:match("^%d+[%.%)]%s+%S") or (label and #label <= 28) then marked = marked + 1 end
      end
      return marked >= 2
    end
    local function pipe_cells(l)
      local cells = {}
      local body = l:gsub("^%s*|", ""):gsub("|%s*$", "")
      for c in (body .. "|"):gmatch("(.-)|") do cells[#cells + 1] = U.trim(c) end
      return cells
    end
    local function flush()
      -- a markdown pipe table: header row, separator row, one record per row
      if #para >= 3 and para[1]:match("^|") and para[2]:match("^|[%s%-:|]+$") then
        local header = pipe_cells(para[1])
        local ok = #header >= 2
        local seen = {}
        for i, h in ipairs(header) do if h == "" or seen[h] then ok = false end; seen[h] = true end
        if ok then
          for r = 3, #para do
            local cells = pipe_cells(para[r])
            if #cells == #header then
              local f = {}
              for i, h in ipairs(header) do if cells[i] ~= "" then f[h] = cells[i] end end
              f.section = section
              pn = pn + 1
              raws[#raws + 1] = { fields = f, source = { name = name, row = pn } }
            else report.rejected[#report.rejected + 1] = { index = pn, reason = "table row has " .. #cells .. " cells, expected " .. #header } end
          end
          para = {}
          pipe_table = true
          return
        end
      end
      if #para > 0 then
        pn = pn + 1
        raws[#raws + 1] = { fields = { id = name .. "#p" .. pn, text = table.concat(para, structured(para) and "\n" or " "), section = section, section_path = section_path }, source = { name = name, row = pn } }
        para = {}
      end
    end
    for l in (text .. "\n"):gmatch("(.-)\r?\n") do
      local hashes, h = nil, nil
      if fmt == "md" then hashes, h = l:match("^(#+)%s+(.-)%s*$") end
      if h then
        flush(); section = h
        local depth = #hashes
        for d = depth, #stack do stack[d] = nil end
        stack[depth] = h
        local path = {}
        for d = 1, depth do if stack[d] then path[#path + 1] = stack[d] end end
        section_path = table.concat(path, " / ")
      elseif l:match("^%s*$") then flush()
      else para[#para + 1] = U.trim(l) end
    end
    flush()
    if not pipe_table then opts.mapping = opts.mapping or { id_field = "id", text_fields = { "text" }, meta_fields = { "section", "section_path" } } end
  else
    report.rejected[1] = { reason = "unsupported format '" .. tostring(fmt) .. "' (supported: jsonl, json, csv, tsv, txt, md)" }
    return report
  end
  -- mapping: declared or induced (induction is reported, not silent)
  local fnotes0 = {}
  for _, r in ipairs(raws) do r.flat = flatten(r.fields, fnotes0) end
  if fnotes0.nested then report.notes[#report.notes + 1] = fnotes0.nested .. " nested value(s) (arrays of objects / deep objects) were not indexed" end
  local map = opts.mapping
  if not map then
    local flat = {}
    for _, r in ipairs(raws) do flat[#flat + 1] = r.flat end
    map = D.induce_schema(flat)
    report.induced_schema = { id_field = map.id_field, text_fields = map.text_fields, meta_fields = map.meta_fields, date_field = map.date_field, triple = map.triple, wide = map.wide, notes = map.notes }
  end
  local good = {}
  local fnotes = {}
  for i, r in ipairs(raws) do
    local rec, err = self:normalise(r.flat or r.fields, map, r.source)
    if rec then good[#good + 1] = rec
    else report.rejected[#report.rejected + 1] = { index = i, reason = err, source = r.source } end
  end
  self:add_normalised(good, report)
  self.revision = self.revision + 1
  self.formats[fmt] = (self.formats[fmt] or 0) + 1
  local ids = {}
  for _, rec in ipairs(good) do ids[#ids + 1] = rec.id end
  self.history[#self.history + 1] = { revision = self.revision, op = "ingest", name = name, format = fmt, added = report.added, updated = report.updated,
    unchanged = report.unchanged, rejected = #report.rejected, ids_sha256 = U.sha256(table.concat(ids, "\n")) }
  report.revision = self.revision
  report.records = good
  return report
end

-- records that count as independent evidence (duplicates are kept but do not corroborate)
function D:active_records()
  local out = {}
  for _, id in ipairs(self.order) do
    local r = self.records[id]
    if r and not r.duplicate_of then out[#out + 1] = r end
  end
  return out
end

return D
