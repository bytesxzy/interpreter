-- asi.nlu.memory: layered, namespaced, auditable conversation memory.
--   working   = the current request + recent turns + active standing constraints        (derived at selection time)
--   episodic  = every utterance / decision / correction with turn + exact source text
--   semantic  = facts asserted in conversation (triples) WITH provenance, hedges kept as speculative
--   task      = standing instructions, prohibitions, preferences, focus (slot-keyed, supersedable, revocable)
--   retrieval = inverted index over items (+ entity postings)  -> references, never a dump of history
--   persistent= canonical-JSON serialisation with schema version and checksum (only when save()/load() are called)
-- No cross-namespace reads exist in the API: every item carries its namespace and every query is scoped to one namespace.
local U = require("asi.nlu.util")

local M = {}
M.__index = M
M.SCHEMA = "nlu.memory/1"

local PROTECTED_KINDS = U.set({ "instruction", "prohibition", "correction", "preference", "decision", "focus" })
local STOP = U.set({ "the", "a", "an", "of", "and", "or", "to", "in", "on", "at", "by", "for", "with", "is", "are", "was", "were", "be", "it", "its",
  "as", "that", "this", "which", "what", "who", "how", "do", "does", "did", "i", "you", "we", "me", "my", "your", "please", "can", "could" })

-- which slots apply to which kinds of request (everything else is "any")
local SLOT_SCOPE = { dataset = "evidence", source = "evidence", version = "evidence", year = "evidence", file = "evidence", statement = "evidence",
  figures = "evidence", model = "any", format = "style", language = "style", tone = "style" }

---------------------------------------------------------------- construction
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, M)
  self.schema = M.SCHEMA
  self.ns = opts.ns or { user = "anonymous", project = "default", conversation = "c0" }
  self.transient = opts.transient or false
  self.max_items = opts.max_items or 20000
  self.decay = opts.decay or 0.85
  self.turn, self.revision, self.next_id, self.seq = 0, 0, 1, 0
  self.items, self.order = {}, {}
  self.entities = {}
  self.slots = {}
  self.focus = nil
  self.comparison = nil
  self.artifacts = {}
  self.index = { terms = {}, df = {}, len = {}, n = 0, total_len = 0 }
  self.by_entity = {}   -- entity key -> item ids (identity postings; relevance never rests on shared words alone)
  self.standing = {}    -- id -> true for active instructions / prohibitions / preferences / corrections
  self.facts_by = {}    -- "rel|from" -> item ids (conflict detection without scanning history)
  self.evictions = {}
  return self
end

function M:ns_key() return table.concat({ self.ns.user, self.ns.project, self.ns.conversation }, "|") end

---------------------------------------------------------------- items + index
local TU = require("asi.nlu.textutil")
local stem = TU.stem
M.stem = stem

local function tokens_of(text)
  local out = {}
  for _, t in ipairs(TU.tokens(text)) do if not STOP[t.w] then out[#out + 1] = t.t end end
  return out
end

function M:begin_turn(speaker)
  self.turn = self.turn + 1
  self.turn_entities = {}
  self.speaker = speaker or "user"
  self.revision = self.revision + 1
  return self.turn
end

local DEFAULT_RELIABILITY = { user = 1.0, system = 1.0, assistant = 0.6, doc = 0.5 }

function M:add(item)
  item.id = "m" .. self.next_id
  self.next_id = self.next_id + 1
  item.ns = item.ns or self:ns_key()
  item.turn = item.turn or self.turn
  item.speaker = item.speaker or self.speaker or "user"
  item.status = item.status or "active"
  item.reliability = item.reliability or DEFAULT_RELIABILITY[item.speaker] or 0.5
  item.provenance = item.provenance or { turn = item.turn, speaker = item.speaker }
  item.entities = item.entities or {}
  self.items[item.id] = item
  self.order[#self.order + 1] = item.id
  self.revision = self.revision + 1
  -- retrieval index
  local toks = tokens_of(item.text or "")
  local tf = {}
  for _, t in ipairs(toks) do tf[t] = (tf[t] or 0) + 1 end
  item._tf = tf
  for t, c in pairs(tf) do
    local post = self.index.terms[t]
    if not post then post = {}; self.index.terms[t] = post end
    post[item.id] = c
    self.index.df[t] = (self.index.df[t] or 0) + 1
  end
  for _, k in ipairs(item.entities) do
    local l = self.by_entity[k]
    if not l then l = {}; self.by_entity[k] = l end
    l[#l + 1] = item.id
    if #l > 400 then table.remove(l, 1) end
  end
  if PROTECTED_KINDS[item.kind] and item.kind ~= "decision" and item.kind ~= "focus" and item.status == "active" then self.standing[item.id] = true end
  self.index.len[item.id] = #toks
  self.index.n = self.index.n + 1
  self.index.total_len = self.index.total_len + #toks
  self:enforce_capacity()
  return item
end

-- BM25 of a query (term list) against one item
function M:bm25(terms, item)
  local ix = self.index
  if ix.n == 0 or not item._tf then return 0 end
  local avg = ix.total_len / math.max(1, ix.n)
  local k1, b = 1.2, 0.75
  local s = 0
  for _, t in ipairs(terms) do
    local f = item._tf[t]
    if f then
      local df = ix.df[t] or 0
      local idf = math.log(1 + (ix.n - df + 0.5) / (df + 0.5))
      s = s + idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * (ix.len[item.id] or 1) / avg))
    end
  end
  return s
end

function M:enforce_capacity()
  if #self.order <= self.max_items then return end
  -- evict the oldest unprotected, non-active-standing items first; never silently drop protected ones
  local keep = {}
  local excess = #self.order - self.max_items
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if excess > 0 and it and not PROTECTED_KINDS[it.kind] and it.kind ~= "artifact" then
      self:drop(id, "capacity")
      excess = excess - 1
    else keep[#keep + 1] = id end
  end
  self.order = keep
end

function M:drop(id, reason)
  local it = self.items[id]
  if not it then return end
  for t in pairs(it._tf or {}) do
    if self.index.terms[t] then self.index.terms[t][id] = nil end
    self.index.df[t] = math.max(0, (self.index.df[t] or 1) - 1)
  end
  self.standing[id] = nil
  self.index.total_len = self.index.total_len - (self.index.len[id] or 0)
  self.index.n = self.index.n - 1
  self.index.len[id] = nil
  self.items[id] = nil
  self.evictions[#self.evictions + 1] = { id = id, turn = it.turn, kind = it.kind, reason = reason }
end

---------------------------------------------------------------- entities and focus
local function ref_key(r)
  if not r or r.deictic then return nil end
  if r.antecedent and r.antecedent.key then return r.antecedent.key end
  if r.resolved_id and (r.status == "resolved" or r.status == "unseen" or r.status == nil) then return r.resolved_id end
  return nil
end
M.ref_key = ref_key

function M:mention(key, info)
  if not key then return end
  local e = self.entities[key]
  if not e then
    e = { key = key, names = {}, type = info.type, mentions = {}, first_turn = self.turn, by_user = false }
    self.entities[key] = e
  end
  if info.type and not e.type then e.type = info.type end
  if info.itype and not e.type and not e.itype then e.itype = info.itype end
  if info.pname and not e.type then e.pname = true end
  if info.name and not e.names[info.name:lower()] then e.names[info.name:lower()] = info.name end
  if info.speaker == "user" then e.by_user = true end
  if info.speaker then e.by_speaker = e.by_speaker or {}; e.by_speaker[info.speaker] = true end
  if info.plural then e.plural = true end
  -- an entity is "weak" while its only evidence is a sentence-initial capital; any stronger mention clears the flag
  if e.weak == nil then e.weak = info.weak or false elseif not info.weak then e.weak = false end
  self.seq = self.seq + 1
  e.last_turn, e.last_seq = self.turn, self.seq
  if self.turn_entities then self.turn_entities[key] = true end
  local ms = e.mentions
  ms[#ms + 1] = { turn = self.turn, seq = self.seq, w = info.w or 0.25, role = info.role, speaker = info.speaker, sent = info.sent, text = info.name }
  if #ms > 40 then table.remove(ms, 1) end
  return e
end

-- classifying nouns the discourse attached to an entity ("Brindle Analytics, a small robotics business" -> business)
function M:describe(key, head, text, speaker)
  local e = self.entities[key]
  if not e or not head then return end
  e.descriptors = e.descriptors or {}
  local st = stem(head)
  if not e.descriptors[st] then e.descriptors[st] = { head = head, text = text, turn = self.turn, speaker = speaker } end
end

-- salience = sum of mention weights decayed by turn distance (and a small sentence-order tie-break)
function M:salience(e, now_turn)
  now_turn = now_turn or self.turn
  local s = 0
  for _, m in ipairs(e.mentions) do s = s + m.w * (self.decay ^ math.max(0, now_turn - m.turn)) end
  return s
end

---------------------------------------------------------------- artifacts (solutions, versions, options ...)
local ARTIFACT_NOUN = { solution = "solution", approach = "solution", option = "solution", method = "solution", attempt = "solution", proposal = "solution",
  candidate = "solution", plan = "solution", version = "version", edition = "version", draft = "version", revision = "version", iteration = "version",
  variant = "version" }
local ORDINAL_WORD = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
  first = 1, second = 2, third = 3, fourth = 4, fifth = 5 }

-- artifact classes a noun denotes (set).  The interpreter installs the lexicon's `refnoun` data as self.refclasses; the built-in map is the fallback.
function M:classes_of(word)
  word = word:lower()
  local cands = { word }
  if word:sub(-3) == "ies" then cands[#cands + 1] = word:sub(1, -4) .. "y" end
  if word:sub(-2) == "es" then cands[#cands + 1] = word:sub(1, -3) end
  if word:sub(-1) == "s" then cands[#cands + 1] = word:sub(1, -2) end
  for _, w in ipairs(cands) do
    local out
    if self.refclasses then out = self.refclasses(w) else out = ARTIFACT_NOUN[w] and { [ARTIFACT_NOUN[w]] = true } or {} end
    out = U.copy(out)
    out.correction = nil -- corrections are memory items, not enumerable artifacts
    out.message = nil
    if next(out) then return out end
  end
  return {}
end

function M:register_artifact(class, ordinal, label, text, item)
  local list = self.artifacts[class]
  if not list then list = {}; self.artifacts[class] = list end
  list[#list + 1] = { class = class, ordinal = ordinal, label = label, text = text, item = item and item.id, turn = self.turn, speaker = self.speaker }
end

-- find labelled or numbered alternatives in assistant/user text:  "Solution 2: ...",  "Option B - ...",  "Here are two approaches:\n1. ...\n2. ..."
function M:extract_artifacts(text, item)
  local n = 0
  local current_class
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local noun, label = line:match("^%s*[%*#%-]*%s*(%a+)%s+(%w+)%s*[:%.%)%-—]")
    local classes = noun and self:classes_of(noun) or {}
    if next(classes) and label then
      local ord = tonumber(label) or ORDINAL_WORD[label:lower()] or (label:match("^%u$") and (label:byte() - 64)) or nil
      if ord then
        for cls in pairs(classes) do self:register_artifact(cls, ord, noun .. " " .. label, line, item); n = n + 1 end
      end
    else
      local num, rest = line:match("^%s*(%d+)[%.%)]%s+(.*)$")
      if num and current_class then
        for cls in pairs(current_class) do self:register_artifact(cls, tonumber(num), cls .. " " .. num, rest, item); n = n + 1 end
      else
        local lower = line:lower()
        if lower:match(":%s*$") then
          current_class = nil
          for w in lower:gmatch("%a+") do
            local c = self:classes_of(w)
            if next(c) then current_class = c end
          end
        end
      end
    end
  end
  return n
end

-- An enumeration of entities in a turn: "1. Oslo 2. Stockholm 3. Helsinki", "Tallinn, Riga and Klaipeda", "Marie Curie and Albert Einstein".
-- items = { {key=, text=, type=, s=, e=}, ... } (entity mentions of the turn with byte offsets); returns the members of the list, or nil
function M.detect_enumeration(text, items)
  if #items < 2 then return nil end
  table.sort(items, function(a, b) return a.s < b.s end)
  -- (1) numbered items: markers 1. 2. 3. ... each followed by one item
  local nums = {}
  for pos, num in text:gmatch("()%f[%d](%d+)[%.%)]%s") do nums[#nums + 1] = { pos = pos, n = tonumber(num) } end
  if #nums >= 2 then
    local ok = true
    for i, x in ipairs(nums) do if x.n ~= i then ok = false end end
    if ok then
      local out = {}
      for i, x in ipairs(nums) do
        local hi = nums[i + 1] and nums[i + 1].pos or (#text + 1)
        for _, it in ipairs(items) do if it.s >= x.pos and it.s < hi then out[#out + 1] = it; break end end
      end
      if #out >= 2 then return out end
    end
  end
  -- (2) a run of items separated only by commas / "and" / "or" that makes up most of the message
  local lead = text:match("^[^:]*:%s*()") or 1
  local body = text:sub(lead):gsub("[%.%!%?%s]+$", "")
  local best
  local run = { items[1] }
  local function close()
    if #run >= 2 and (not best or #run > #best) then
      local span = run[#run].e - run[1].s + 1
      if span >= 0.5 * #body then best = run end
    end
  end
  for i = 2, #items do
    local a, b = items[i - 1], items[i]
    local between = text:sub(a.e + 1, b.s - 1):lower()
    if between:match("^[%s,;&]*$") and between:find("[,;&]") or between:match("^[%s,]*and[%s,]*$") or between:match("^[%s,]*or[%s,]*$") or between:match("^[%s,]*as well as[%s,]*$") then
      run[#run + 1] = b
    else close(); run = { b } end
  end
  close()
  return best
end

function M:note_enumeration(members)
  for i, m in ipairs(members) do
    local list = self.artifacts["entity"]
    if not list then list = {}; self.artifacts["entity"] = list end
    list[#list + 1] = { class = "entity", ordinal = i, label = m.text, text = m.text, turn = self.turn, speaker = self.speaker, key = m.key, etype = m.type, size = #members }
  end
end

-- the member of the latest entity enumeration an ordinal ("second", 2) or "last" / "first" refers to
function M:find_entity_ordinal(ordinal)
  local list = self.artifacts["entity"] or {}
  local latest = -1
  for _, a in ipairs(list) do if a.turn > latest then latest = a.turn end end
  local members = {}
  for _, a in ipairs(list) do if a.turn == latest then members[#members + 1] = a end end
  table.sort(members, function(x, y) return x.ordinal < y.ordinal end)
  if #members == 0 then return nil, 0 end
  if ordinal == "last" then return members[#members], #members end
  return members[tonumber(ordinal)], #members
end

function M:find_artifact(class, ordinal, label_word)
  local list = self.artifacts[class] or {}
  if ordinal then
    -- the latest enumeration wins: take artifacts from the most recent turn that produced this class
    local best
    for i = #list, 1, -1 do
      if list[i].ordinal == ordinal and (not best or list[i].turn >= best.turn) then best = list[i]; break end
    end
    return best
  end
  if label_word then
    for i = #list, 1, -1 do if (list[i].text or ""):lower():find(label_word, 1, true) then return list[i] end end
  end
  return nil
end

---------------------------------------------------------------- slots: supersession, revocation
function M:slot_state(slot)
  local s = self.slots[slot]
  if not s then s = { active = nil, history = {} }; self.slots[slot] = s end
  return s
end

function M:supersede(old_id, by, reason)
  local old = self.items[old_id]
  if not old or old.status ~= "active" then return end
  old.status, old.superseded_by, old.superseded_reason, old.superseded_turn = "superseded", by.id, reason, self.turn
  self.standing[old_id] = nil
  by.supersedes = by.supersedes or {}
  table.insert(by.supersedes, old_id)
  self.revision = self.revision + 1
end

function M:revoke(id, by_turn_text)
  local it = self.items[id]
  if it and it.status == "active" then
    it.status, it.revoked_turn, it.revoked_by = "revoked", self.turn, by_turn_text
    self.standing[id] = nil
    local s = it.slot and self.slots[it.slot]
    if s and s.active == id then s.active = nil end
    self.revision = self.revision + 1
    return it
  end
end

function M:active_items(kind)
  local out = {}
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if it and it.status == "active" and (not kind or it.kind == kind) then out[#out + 1] = it end
  end
  return out
end

---------------------------------------------------------------- observation
local function value_of(ins)
  if not ins or not ins.value then return nil end
  return ins.value.year or ins.value.word or ins.value.label
end

local function collect_refs(interp)
  local out = {}
  local function add(ref, role, w)
    if ref and not ref.deictic then out[#out + 1] = { ref = ref, role = role, w = w } end
  end
  for role, r in pairs(interp.roles or {}) do if not r.asked then add(r, "arg:" .. role, 0.5) end end
  add(interp.subject, "subject", 0.5)
  add(interp.concept, "concept", 0.4)
  add(interp.target, "target", 0.3)
  add(interp.focus, "focus", 1.0)
  add(interp.object, "object", 0.4)
  for _, it in ipairs(interp.items or {}) do add(it, "item", 0.7) end
  if interp.statement then add(interp.statement.subject, "stmt_subject", 0.7); add(interp.statement.object, "stmt_object", 0.4) end
  if interp.clause then add(interp.clause.subject, "clause_subject", 0.4); add(interp.clause.object, "clause_object", 0.3) end
  for _, st in ipairs((interp.query and interp.query.steps) or {}) do add(st.known, "chain_arg", 0.4) end
  return out
end

-- record one interpreted sentence. meta: {speaker, sent_text, hedged, additive, scoped, revoke_cue}
function M:observe_sentence(interp, meta)
  meta = meta or {}
  local speaker = meta.speaker or self.speaker or "user"
  if interp.status ~= "ok" then return nil end
  local text = interp.sentence and interp.sentence.text or ""
  local keys = {}
  for _, e in ipairs(collect_refs(interp)) do
    local r = e.ref
    local key = ref_key(r)
    local w = e.w
    if r.antecedent and r.antecedent.key then w = 0.35 end -- re-mention through a pronoun
    if key then
      local en = self:mention(key, { type = r.type or (r.antecedent and r.antecedent.type), itype = r.itype, pname = r.pname, name = (r.antecedent and r.antecedent.text) or r.text, w = w,
        role = e.role, speaker = speaker, plural = r.plural, sent = meta.sent, weak = r.weak_name })
      keys[#keys + 1] = key
      if e.role == "focus" then self.focus = { key = key, turn = self.turn, text = r.text } end
    end
  end
  -- topic shift: the entity a request is about (description subject, looked-up entity) becomes the discourse focus
  if not self.focus or self.focus.turn <= self.turn then
    local topic, ttext
    if interp.focus then topic, ttext = ref_key(interp.focus), interp.focus.text
    elseif interp.intent == "entity_description" and interp.subject then topic, ttext = ref_key(interp.subject), interp.subject.text
    elseif interp.intent == "factual_lookup" and interp.query and interp.roles then
      local kr = interp.roles[interp.query.known_role or "from"]
      topic, ttext = ref_key(kr), kr and kr.text
    end
    -- a name whose only evidence is a sentence-initial capital ("Let me think ...") never becomes the focus of the conversation
    local ten = topic and self.entities[topic]
    if topic and speaker == "user" and not (ten and ten.weak) then self.focus = { key = topic, turn = self.turn, text = ttext } end
  end
  -- the last relational question the user asked: elliptical follow-ups ("What about Jupiter?", "Same question for Y", "Sorry, I meant Z") re-ask it about another argument
  if speaker == "user" and interp.intent == "factual_lookup" and interp.relation and interp.query and interp.query.known_role and interp.query.ask
    and (interp.speech_act == "question" or interp.speech_act == "request") and not meta.hedged then
    self.last_query = { rel = interp.relation.id, known_role = interp.query.known_role, ask = interp.query.ask, answer_type = interp.query.answer_type, turn = self.turn, text = text }
  end
  if interp.intent == "comparison" and interp.items then
    local ks = {}
    for _, it in ipairs(interp.items) do local k = ref_key(it); if k then ks[#ks + 1] = k end end
    if #ks >= 2 then self.comparison = { keys = ks, turn = self.turn, dimension = interp.dimension } end
  end
  local created
  -- standing instructions / prohibitions / preferences ----------------------------------------------------------------
  if speaker == "user" and (interp.speech_act == "instruction" or interp.intent == "instruction_update" or interp.intent == "correction") then
    local ins = interp.instruction or {}
    local cons = interp.constraints or {}
    if ins.act == "exclude" or (ins.kind == "exclusion") or (#(cons.negative or {}) > 0 and not ins.slot) then
      created = self:add({ layer = "task", kind = "prohibition", text = text, entities = keys, speaker = speaker,
        target = (cons.negative[1] and cons.negative[1].target) or nil, standing = true, polarity = "negative" })
    elseif ins.kind == "preference" or (#(cons.preferences or {}) > 0 and not ins.slot) then
      created = self:add({ layer = "task", kind = "preference", text = text, entities = keys, speaker = speaker, standing = true,
        target = (cons.preferences[1] and cons.preferences[1].target) or nil })
    elseif ins.slot then
      local value = value_of(ins)
      local item = { layer = "task", kind = ins.correction and "correction" or "instruction", text = text, entities = keys, speaker = speaker, slot = ins.slot,
        value = value, value_label = ins.value and ins.value.label, standing = not meta.scoped, persist = ins.persist, correction = ins.correction, verb = ins.verb }
      created = self:add(item)
      local st = self:slot_state(ins.slot)
      if st.active and self.items[st.active] and not meta.additive then
        self:supersede(st.active, created, ins.correction and "explicit correction" or "newer instruction for the same slot")
      end
      st.active = created.id
      st.history[#st.history + 1] = created.id
    end
  end
  -- revocation ("never mind the dataset instruction", "scratch that") -- only with an identifiable target ---------------------------------
  if meta.revoke and speaker == "user" then
    local rv, target = meta.revoke, nil
    if rv.slot then
      local st = self.slots[rv.slot]
      target = st and st.active
    elseif rv.class or rv.bare then
      -- the most recent standing user item; a bare "never mind" can only refer to the immediately preceding turn
      local best_key
      for id in pairs(self.standing) do
        local it = self.items[id]
        if it and it.status == "active" and it.speaker == "user" and it.turn < self.turn and (rv.class or it.turn == self.turn - 1) then
          local k = it.turn * 1000000 + (tonumber(id:sub(2)) or 0)
          if not best_key or k > best_key then best_key, target = k, id end
        end
      end
    end
    if target and created and target == created.id then target = nil end   -- "Disregard what I said, and go with X": the new instruction survives its own retraction
    if target then self:revoke(target, text) end
  end
  -- semantic memory: relational assertions, hedges kept speculative ---------------------------------------------------------
  if interp.intent == "statement" and interp.relation and interp.roles and (interp.roles.from or interp.roles.to) then
    created = self:add({ layer = "semantic", kind = "fact", text = text, entities = keys, speaker = speaker, rel = interp.relation.id,
      from = ref_key(interp.roles.from), to = ref_key(interp.roles.to), polarity = interp.polarity,
      status = meta.hedged and "speculative" or "active", reliability = (meta.hedged and 0.3 or nil) })
    local fk = tostring(created.rel) .. "|" .. tostring(created.from)
    if not meta.hedged and created.from then
      for _, id in ipairs(self.facts_by[fk] or {}) do
        local o = self.items[id]
        if o and o.kind == "fact" and o.status == "active" and o.to ~= created.to then
          created.conflicts = created.conflicts or {}; table.insert(created.conflicts, o.id)
          o.conflicts = o.conflicts or {}; table.insert(o.conflicts, created.id)
        end
      end
    end
    self.facts_by[fk] = self.facts_by[fk] or {}
    table.insert(self.facts_by[fk], created.id)
  end
  return created
end

-- a stated decision (protected: never evicted, retrievable without repeating its wording)
function M:note_decision(text, meta)
  meta = meta or {}
  return self:add({ layer = "task", kind = "decision", text = text, speaker = meta.speaker or self.speaker or "user", entities = meta.entities or {}, standing = false })
end

-- store the raw utterance (episodic layer) and its artifacts
function M:note_utterance(text, speaker, meta)
  speaker = speaker or self.speaker or "user"
  local ents = {}
  for k in pairs(self.turn_entities or {}) do ents[#ents + 1] = k end
  table.sort(ents)
  local item = self:add({ layer = "episodic", kind = "utterance", text = text, speaker = speaker, entities = ents })
  item.n_bytes = #text
  self:extract_artifacts(text, item)
  return item
end

---------------------------------------------------------------- relevance-ranked selection (auditable)
local function applicable_scope(interp)
  local scopes = { any = true }
  if interp.requires_external_evidence or interp.intent == "task" or interp.intent == "search" or interp.intent == "comparison" then scopes.evidence = true end
  if interp.status == "ok" and interp.intent ~= "instruction_update" and interp.intent ~= "statement" then scopes.style = true end
  return scopes
end

function M:slot_applicable(slot, interp)
  local scopes = applicable_scope(interp)
  local sc = SLOT_SCOPE[slot] or "any"
  return scopes[sc] == true
end

-- query terms from the interpretation (entity names, relation words, concept text) -- never the raw string alone
local function query_terms(interp)
  local terms, seen = {}, {}
  local function add(s)
    for _, t in ipairs(tokens_of(s or "")) do if not seen[t] then seen[t] = true; terms[#terms + 1] = t end end
  end
  for _, e in ipairs(collect_refs(interp)) do
    add(e.ref.text)
    if e.ref.antecedent then add(e.ref.antecedent.text) end
  end
  if interp.relation then add(interp.relation.label) end
  return terms
end

-- Candidate generation is index-driven (standing constraints + entity-identity postings + informative-term postings + a short
-- recency window), never a scan of the whole history; every candidate is then scored by named factors.
function M:select(interp, opts)
  opts = opts or {}
  local max_items, min_score = opts.max_items or 12, opts.min_score or 1.0
  local keys = {}
  for _, e in ipairs(collect_refs(interp)) do
    local k = ref_key(e.ref)
    if k then keys[k] = true end
    if e.ref.antecedent and e.ref.antecedent.key then keys[e.ref.antecedent.key] = true end
  end
  local terms = query_terms(interp)
  -- the request's own content words are a (capped) lexical signal; they can rank candidates but never select one alone
  local seen_t = {}
  for _, t in ipairs(terms) do seen_t[t] = true end
  for _, t in ipairs(tokens_of(interp.sentence and interp.sentence.text or "")) do if not seen_t[t] then seen_t[t] = true; terms[#terms + 1] = t end end
  local cand, n_cand = {}, 0
  local function want(id) if not cand[id] and self.items[id] then cand[id] = true; n_cand = n_cand + 1 end end
  for id in pairs(self.standing) do want(id) end
  for k in pairs(keys) do for _, id in ipairs(self.by_entity[k] or {}) do want(id) end end
  for _, t in ipairs(terms) do
    local df = self.index.df[t] or 0
    if df > 0 and df <= 200 then for id in pairs(self.index.terms[t]) do want(id) end end
  end
  for i = math.max(1, #self.order - 5), #self.order do want(self.order[i]) end
  -- superseded / revoked items of the slots in play stay visible in the audit (why the older value is not used)
  local excluded = {}
  for slot, st in pairs(self.slots) do
    for _, id in ipairs(st.history) do
      local it = self.items[id]
      if it and (it.status == "superseded" or it.status == "revoked") then
        excluded[#excluded + 1] = { item = it, reason = it.status .. (it.superseded_by and (" by " .. it.superseded_by) or "") .. " (slot '" .. slot .. "')" }
      end
    end
  end
  local cands = {}
  for id in pairs(cand) do
    local it = self.items[id]
    if it.ns ~= self:ns_key() then
      excluded[#excluded + 1] = { item = it, reason = "different namespace" }
    elseif it.status == "superseded" or it.status == "revoked" then
      -- already reported through the slot history when applicable
      if not it.slot then excluded[#excluded + 1] = { item = it, reason = it.status .. (it.superseded_by and (" by " .. it.superseded_by) or "") } end
    elseif it.turn >= self.turn and it.kind == "utterance" then
      -- the current turn is the request itself, not memory
    else
      local st, so, f = 0, 0, {}   -- structural evidence (identity, standing constraints, typed references) vs soft evidence (recency, words)
      if it.kind == "decision" and opts.decision_ref then st = st + 1.5; f.decision_reference = true end
      if it.kind == "instruction" or it.kind == "correction" or it.kind == "preference" then
        if self:slot_applicable(it.slot or "any", interp) or (not it.slot and it.kind == "preference") then
          st = st + (it.standing and 3.0 or 2.0); f.standing_constraint = true
        end
      elseif it.kind == "prohibition" then
        if interp.intent ~= "instruction_update" and interp.intent ~= "statement" then st = st + 2.5; f.standing_prohibition = true end
      end
      local shared = 0
      for _, k in ipairs(it.entities or {}) do if keys[k] then shared = shared + 1 end end
      if shared > 0 then st = st + 2.0 * math.min(shared, 2); f.entity_identity = shared end
      if shared > 0 and it.rel and interp.relation and it.rel == interp.relation.id then st = st + 1.0; f.relation_match = true end
      local dependent = #(interp.dependencies or {}) > 0
      local recent_dep = false -- pronoun / comparison-set requests lean on the last couple of turns; back-references reach further and say so
      for _, d in ipairs(interp.dependencies or {}) do if d.kind == "pronoun" or d.kind == "comparison_set" then recent_dep = true end end
      if self.focus and it.entities and dependent then
        for _, k in ipairs(it.entities) do if k == self.focus.key then st = st + 0.8; f.focus_continuity = true break end end
      end
      if recent_dep and it.turn >= self.turn - 2 and (it.kind == "utterance" or it.kind == "fact") then st = st + 1.2; f.recent_window = true end
      if it.kind == "utterance" or it.kind == "fact" or it.kind == "decision" then
        local rec = 0.6 * (self.decay ^ (self.turn - it.turn))
        if rec > 0.05 then so = so + rec; f.recency = U.round(rec, 3) end
      end
      local lex = self:bm25(terms, it)
      if lex > 0 then local nl = math.min(1, lex / 6) * 0.6; so = so + nl; f.lexical = U.round(nl, 3) end
      so = so + 0.3 * (it.reliability or 0.5)
      if it.status == "speculative" then so = so - 0.7; f.speculative = true end
      local s = st + so
      f.structural = U.round(st, 3)
      cands[#cands + 1] = { item = it, score = s, factors = f }
    end
  end
  table.sort(cands, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.item.turn > b.item.turn end)
  local selected = {}
  for _, c in ipairs(cands) do
    local structural = c.factors.structural or 0
    if structural >= 0.8 and c.score >= min_score and #selected < max_items then selected[#selected + 1] = c
    else
      local why = structural < 0.8 and string.format("no structural link to the request (identity / standing constraint / typed reference); soft score %.2f", c.score)
        or (c.score < min_score and string.format("relevance %.2f below threshold %.2f", c.score, min_score) or "over item budget")
      excluded[#excluded + 1] = { item = c.item, reason = why, score = c.score }
    end
  end
  return { selected = selected, excluded = excluded, n_candidates = n_cand, n_items = self.index.n }
end

-- the standing constraints that are in force for this request (slot-keyed values, exclusions, preferences), with provenance
function M:active_constraints(interp)
  local out = {}
  for slot, st in pairs(self.slots) do
    local it = st.active and self.items[st.active]
    if it and it.status == "active" and self:slot_applicable(slot, interp) then
      out[#out + 1] = { kind = it.kind, slot = slot, value = it.value, label = it.value_label, item = it.id, turn = it.turn, text = it.text, standing = it.standing or false,
        supersedes = it.supersedes, correction = it.correction or false }
    end
  end
  for id in pairs(self.standing) do
    local it = self.items[id]
    if it and it.status == "active" and (it.kind == "prohibition" or (it.kind == "preference" and not it.slot)) then
      out[#out + 1] = { kind = it.kind, item = it.id, turn = it.turn, text = it.text, target = it.target, standing = true }
    end
  end
  table.sort(out, function(a, b) if a.turn ~= b.turn then return a.turn < b.turn end return a.item < b.item end)
  return out
end

---------------------------------------------------------------- context dependency classification
-- coref: result of Coref.resolve for the same interpretation (may be nil)
function M:classify_dependency(interp, coref)
  local classes, unresolved = {}, false
  local function add(c) classes[#classes + 1] = c end
  local covered = {}
  for _, r in ipairs((coref and coref.references) or {}) do
    covered[r.mention] = true
    if r.status == "resolved" then
      local d = r.distance_turns or 0
      if r.kind == "correction_ref" then add("user_correction")
      elseif d == 0 then add("self_contained")
      elseif d <= 2 then add("recent_message")
      else add("earlier_project_context") end
    else add("ambiguous_missing_context"); unresolved = true end
  end
  -- dependencies no resolver looked at (e.g. coreference switched off) stay unresolved rather than silently self-contained
  for _, d in ipairs(interp.dependencies or {}) do
    if d.kind == "previous_question" then
      if (self.turn - (d.turn or self.turn)) <= 2 then add("recent_message") else add("earlier_project_context") end
    elseif d.kind == "conversation_history" then
      if coref and coref.recall_found then add("earlier_project_context") else add("ambiguous_missing_context"); unresolved = true end
    elseif not covered[d.text] and d.kind ~= "comparison_set" then add("ambiguous_missing_context"); unresolved = true end
  end
  local has_dataset = false
  for _, s in ipairs((interp.constraints and interp.constraints.source) or {}) do if s.cue then has_dataset = true end end
  if has_dataset then add("external_dataset") end
  local seen, uniq = {}, {}
  for _, c in ipairs(classes) do if not seen[c] then seen[c] = true; uniq[#uniq + 1] = c end end
  if #uniq == 0 then uniq[1] = "self_contained" end
  local PREC = { ambiguous_missing_context = 6, user_correction = 5, earlier_project_context = 4, recent_message = 3, external_dataset = 2, self_contained = 1 }
  table.sort(uniq, function(a, b) return PREC[a] > PREC[b] end)
  return { primary = uniq[1], all = uniq, unresolved = unresolved }
end

---------------------------------------------------------------- summaries that keep protected content
-- digest of turns [from, to]: entities, facts, open tasks, EXACT exclusion/instruction text, corrections, dates, numbers, hedges, source refs.
function M:summarize(from_turn, to_turn)
  from_turn, to_turn = from_turn or 1, to_turn or self.turn
  local d = { from_turn = from_turn, to_turn = to_turn, entities = {}, facts = {}, exclusions = {}, instructions = {}, corrections = {}, hedged = {},
    numbers = {}, dates = {}, source_refs = {} }
  local raw = {}
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if it and it.turn >= from_turn and it.turn <= to_turn then
      raw[#raw + 1] = id .. ":" .. (it.text or "")
      local ref = { item = id, turn = it.turn }
      if it.kind == "prohibition" then d.exclusions[#d.exclusions + 1] = { text = it.text, status = it.status, ref = ref }
      elseif it.kind == "instruction" or it.kind == "preference" then d.instructions[#d.instructions + 1] = { text = it.text, slot = it.slot, value = it.value, status = it.status, superseded_by = it.superseded_by, ref = ref }
      elseif it.kind == "correction" then d.corrections[#d.corrections + 1] = { text = it.text, slot = it.slot, value = it.value, supersedes = it.supersedes, ref = ref }
      elseif it.kind == "fact" then
        local entry = { rel = it.rel, from = it.from, to = it.to, text = it.text, status = it.status, ref = ref }
        if it.status == "speculative" then d.hedged[#d.hedged + 1] = entry else d.facts[#d.facts + 1] = entry end
      end
      if it.kind == "utterance" then
        for n in (it.text or ""):gmatch("%d[%d,%.]*%d?") do d.numbers[#d.numbers + 1] = { value = n, ref = ref } end
        for y in (it.text or ""):gmatch("%f[%d]([12]%d%d%d)%f[%D]") do d.dates[#d.dates + 1] = { year = y, ref = ref } end
      end
      d.source_refs[#d.source_refs + 1] = ref
    end
  end
  for key, e in pairs(self.entities) do
    if e.last_turn and e.last_turn >= from_turn and e.first_turn <= to_turn then
      d.entities[#d.entities + 1] = { key = key, type = e.type, first_turn = e.first_turn, last_turn = e.last_turn, mentions = #e.mentions }
    end
  end
  table.sort(d.entities, function(a, b) return a.key < b.key end)
  d.raw_sha256 = U.sha256(table.concat(raw, "\n"))
  d.kind = "summary"
  d.note = "compressed evidence: summary entries cite source items; the original text remains retrievable via expand()"
  return d
end

-- audit that a summary lost none of the protected content found in the original turns
function M:loss_audit(summary)
  local missing = {}
  local function present(list, id) for _, e in ipairs(list) do if e.ref and e.ref.item == id then return true end end return false end
  for _, id in ipairs(self.order) do
    local it = self.items[id]
    if it and it.turn >= summary.from_turn and it.turn <= summary.to_turn then
      if it.kind == "prohibition" and not present(summary.exclusions, id) then missing[#missing + 1] = { id = id, why = "exclusion dropped" } end
      if (it.kind == "instruction" or it.kind == "preference") and not present(summary.instructions, id) then missing[#missing + 1] = { id = id, why = "instruction dropped" } end
      if it.kind == "correction" and not present(summary.corrections, id) then missing[#missing + 1] = { id = id, why = "correction dropped" } end
      if it.kind == "fact" and not (present(summary.facts, id) or present(summary.hedged, id)) then missing[#missing + 1] = { id = id, why = "fact dropped" } end
      if it.kind == "fact" and it.status == "speculative" and present(summary.facts, id) then missing[#missing + 1] = { id = id, why = "speculation promoted to fact" } end
    end
  end
  return missing
end

function M:expand(ref) local it = self.items[ref.item]; return it and it.text, it end

---------------------------------------------------------------- retention and deletion
-- forget{ item=id | kind= | entity= | before_turn= }  -- protected kinds need force=true
function M:forget(filter)
  local removed = 0
  for _, id in ipairs(U.copy(self.order)) do
    local it = self.items[id]
    if it then
      local hit = (filter.item and filter.item == id) or (filter.kind and filter.kind == it.kind) or (filter.before_turn and it.turn < filter.before_turn)
      if filter.entity then
        hit = false
        for _, k in ipairs(it.entities or {}) do if k == filter.entity then hit = true end end
      end
      if hit and (not PROTECTED_KINDS[it.kind] or filter.force) then self:drop(id, "forget"); removed = removed + 1 end
    end
  end
  local keep = {}
  for _, id in ipairs(self.order) do if self.items[id] then keep[#keep + 1] = id end end
  self.order = keep
  if filter.entity then self.entities[filter.entity] = nil end
  self.revision = self.revision + 1
  return removed
end

---------------------------------------------------------------- persistence (explicit, checksummed)
function M:serialize()
  local items = {}
  for _, id in ipairs(self.order) do
    local it = U.shallow(self.items[id])
    it._tf = nil
    items[#items + 1] = it
  end
  local body = { schema = M.SCHEMA, ns = self.ns, turn = self.turn, revision = self.revision, next_id = self.next_id, items = items,
    entities = self.entities, slots = self.slots, focus = self.focus, comparison = self.comparison, artifacts = self.artifacts, evictions = self.evictions,
    last_query = self.last_query }
  local json = U.json_encode(body, { nan_null = true })
  return U.json_encode({ meta = { schema = M.SCHEMA, sha256 = U.sha256(json), bytes = #json }, body = U.json_decode(json) })
end

function M.deserialize(s, opts)
  opts = opts or {}
  local doc, err = U.json_decode(s)
  if not doc then return nil, "memory: " .. tostring(err) end
  if type(doc) ~= "table" or not doc.meta or doc.meta.schema ~= M.SCHEMA or not doc.body then return nil, "memory: unknown schema" end
  local check = U.sha256(U.json_encode(doc.body, { nan_null = true }))
  if check ~= doc.meta.sha256 then return nil, "memory: checksum mismatch (file modified or corrupted)" end
  local b = doc.body
  if opts.ns and (b.ns.user ~= opts.ns.user) then return nil, "memory: namespace owner mismatch (refusing cross-user load)" end
  local self = M.new({ ns = b.ns })
  self.turn, self.revision, self.next_id = b.turn, b.revision, b.next_id
  self.entities, self.slots, self.focus, self.comparison = b.entities or {}, b.slots or {}, b.focus, b.comparison
  self.artifacts, self.evictions = b.artifacts or {}, b.evictions or {}
  self.last_query = b.last_query
  for _, it in ipairs(b.items or {}) do
    self.items[it.id] = it
    self.order[#self.order + 1] = it.id
    local toks = tokens_of(it.text or "")
    local tf = {}
    for _, t in ipairs(toks) do tf[t] = (tf[t] or 0) + 1 end
    it._tf = tf
    for t, c in pairs(tf) do self.index.terms[t] = self.index.terms[t] or {}; self.index.terms[t][it.id] = c end
    self.index.len[it.id] = #toks; self.index.n = self.index.n + 1; self.index.total_len = self.index.total_len + #toks
  end
  return self
end

function M:save(path)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(self:serialize()); f:close()
  return true
end

function M.load(path, opts)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open " .. path end
  local s = f:read("*a"); f:close()
  return M.deserialize(s, opts)
end

---------------------------------------------------------------- store: namespace isolation + authorisation
local Store = {}
Store.__index = Store
function M.store() return setmetatable({ mems = {} }, Store) end

-- principal = {user=...}; a memory is only reachable by its owner (no similarity-based cross-user retrieval exists)
function Store:open(ns, principal)
  if not principal or principal.user ~= ns.user then return nil, "access denied: principal is not the namespace owner" end
  local key = table.concat({ ns.user, ns.project, ns.conversation }, "|")
  local m = self.mems[key]
  if not m then m = M.new({ ns = ns }); self.mems[key] = m end
  return m
end

return M
