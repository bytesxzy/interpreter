-- asi.nlu.lexicon: data-driven linguistic resources, loaded from a line-oriented DSL (data, never executed).
--
--   type <name> < <parent>[, <parent>]
--   class <cat>: w1 w2 ...                               closed-class word lists
--   pron <form>: person=3 number=sg gender=n animate=0   pronoun features
--   rel <id>: from=<type> to=<type> | event=1 (a one-off event or permanent fact: tense never makes it "past") | noun=a; b | noun_from=a; b | verb=lemma/subj=to; ... | prep=of; for | kinds=mod:rel_id; ...
--             | when=<rel> | where=<rel> | label=<text> | derived=<rel> | weight=<n>
--   sense <head>: <id> | pos=n|v|adj | type=<type> | domain=a; b | gloss=... | prior=0.5 | rel=<rel> | cs=1
--   entity <id>: <type> | names=A; B | cs=A; B | domain=a; b | prior=0.5 | attr.k=v
--   entities <type>: A; B; C                              bulk entities, ids derived from names
--   alias <entity-id>: A; B                               extra names (short all-caps aliases are case-sensitive)
--   verb <lemma>: act=retrieve|inform|compare|task|constraint|exclude|include
--   adj <lemma>: dim=age                                  gradable adjectives (comparative/superlative generated)
--   dim <name>: rels=a,b | order=...
--   cue <name>: a; b; c                                   discourse cues (negation, correction, persistence, ...)
--   domain <name>: w1 w2 ...                              domain cue words used for sense priming
--   headcue <type>: inc corp ...                          trailing words that type an unseen proper name
--   resource <name>: a; b                                 resource nouns (dataset/version/file/...), synonym groups
--   wrap <name>: pattern                                   politeness/request wrappers (closed class)
-- Lines starting with '#' are comments. Errors are collected with line numbers; a bad line never aborts a load.
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Morph = require("asi.nlu.morph")

local L = {}
L.__index = L

local KID_SEP = "\1"

---------------------------------------------------------------- construction
function L.new(parent)
  local self = setmetatable({}, L)
  self.parent = parent
  self.types = {}       -- name -> {name, parents={}, anc={set incl. self}}
  self.classes = {}     -- form -> set of cats
  self.class_words = {} -- cat -> set of forms
  self.pron = {}        -- form -> feature table
  self.rels = {}        -- id -> relation
  self.rel_order = {}
  self.senses = {}      -- id -> sense
  self.sense_by_head = {} -- folded head -> list of senses
  self.entities = {}    -- id -> entity
  self.verbs = {}       -- lemma -> {lemma, act}
  self.adjs = {}        -- lemma -> {dim}
  self.adj_forms = {}   -- form -> {lemma, feat}
  self.dims = {}
  self.cues = {}        -- name -> set of folded phrases
  self.cue_phrases = {} -- name -> list of {forms...}
  self.cue_first = {}   -- name -> first form -> list of {forms...}  (cue_at looks up by first word instead of scanning every phrase)
  self.domain_words = {} -- form -> {domain -> 1}
  self.headcues = {}    -- folded last word -> type
  self.resources = {}   -- folded phrase -> canonical resource name
  self.refnouns = {}    -- form -> artifact class (solution | version | correction | ...)
  self.wraps = {}
  self.forms = {}       -- surface form -> list of readings {pos, lemma, feat, ref}
  self.trie = { kids = {} }
  self.errors = {}
  self.sources = {}     -- source name -> {sha256, n_lines}
  self.revision = 0
  return self
end

local function trim(s) return U.trim(s) end

local function split_fields(s)
  local fields, flags = {}, {}
  for part in (s .. "|"):gmatch("(.-)|") do
    part = trim(part)
    if part ~= "" then
      local k, v = part:match("^([%w_%.]+)%s*=%s*(.*)$")
      if k then fields[k] = v else flags[#flags + 1] = part end
    end
  end
  return fields, flags
end

local function list(v, sep)
  local out = {}
  if not v then return out end
  sep = sep or ";"
  for item in (v .. sep):gmatch("(.-)" .. (sep == "|" and "%|" or sep)) do
    item = trim(item)
    if item ~= "" then out[#out + 1] = item end
  end
  return out
end

---------------------------------------------------------------- phrase keys + trie
-- unit-form key sequence of a phrase, tokenised by the SAME lexer as queries (consistent segmentation)
function L.keys_of(phrase)
  local an = Lex.analyze(phrase, { temporal = false })
  local keys, raws = {}, {}
  for _, u in ipairs(an.units) do
    keys[#keys + 1] = { form = u.form, pre = u.pre, raw = u.raw }
  end
  return keys, an
end

local function kid_key(form, pre) if pre then return form .. KID_SEP .. pre end return form end

function L:trie_insert(phrase, entry)
  local keys = L.keys_of(phrase)
  if #keys == 0 then return false end
  local node = self.trie
  for idx, k in ipairs(keys) do
    local kk = kid_key(k.form, idx > 1 and k.pre or nil)
    local nxt = node.kids[kk]
    if not nxt then nxt = { kids = {} }; node.kids[kk] = nxt end
    node = nxt
  end
  entry.nwords = #keys
  node.entries = node.entries or {}
  node.entries[#node.entries + 1] = entry
  return true
end

local HARD = U.set({ "sent", "comma", "semi", "colon", "paren_open", "paren_close", "quote_open", "quote_close", "quote", "dash", "other",
  "control", "invalid", "symbol", "emoji" })

-- all trie matches starting at unit i (this lexicon and its parents): {j=last_unit, entries={...}}
function L:match_at(units, i)
  local out = {}
  local lex = self
  while lex do
    local node = lex.trie
    for k = i, #units do
      local u = units[k]
      local kk
      if k == i then kk = u.form
      else
        if u.pre then
          -- punctuation barrier: only phrases that literally contain this barrier may continue
          kk = u.form .. KID_SEP .. u.pre
        else kk = u.form end
      end
      local nxt = node.kids[kk]
      if not nxt then break end
      node = nxt
      if node.entries then out[#out + 1] = { j = k, entries = node.entries, lex = lex } end
    end
    lex = lex.parent
  end
  return out
end

---------------------------------------------------------------- types
function L:type_info(name)
  local t = self.types[name]
  if t then return t end
  if self.parent then return self.parent:type_info(name) end
end

function L:has_type(name) return self:type_info(name) ~= nil end

function L:isa(t, anc)
  if t == anc then return true end
  local info = self:type_info(t)
  return info ~= nil and info.anc[anc] == true
end

-- graded compatibility of a (possibly unknown) type with an expectation, in [-1, 1]
--   1.0 subtype/equal | 0.55 expectation is a subtype of the known type (known is vaguer)
--   0.25 unknown | -0.45 distinct siblings under a shared non-root ancestor | -1 disjoint branches
function L:compat(t, expected)
  if not expected then return 0.25 end
  if not t then return 0.25 end
  if expected:find("|", 1, true) then -- union expectation: best alternative
    local best = -1
    for alt in expected:gmatch("[^|]+") do best = math.max(best, self:compat(t, alt)) end
    return best
  end
  if t:find("|", 1, true) then
    local best = -1
    for alt in t:gmatch("[^|]+") do best = math.max(best, self:compat(alt, expected)) end
    return best
  end
  if t == expected then return 1.0 end
  if self:isa(t, expected) then return 0.95 end
  if self:isa(expected, t) then return 0.55 end
  local a, b = self:type_info(t), self:type_info(expected)
  if not a or not b then return 0.2 end
  for anc in pairs(a.anc) do
    if anc ~= "entity" and anc ~= t and b.anc[anc] then return -0.45 end
  end
  return -1.0
end

function L:ancestors(t)
  local info = self:type_info(t)
  local out = {}
  if info then for a in pairs(info.anc) do out[#out + 1] = a end end
  table.sort(out)
  return out
end

---------------------------------------------------------------- loading
local function add_err(self, source, ln, msg)
  self.errors[#self.errors + 1] = string.format("%s:%d: %s", source, ln, msg)
end

function L:add_type(name, parents)
  local info = self.types[name]
  if not info then info = { name = name, parents = {}, anc = { [name] = true } }; self.types[name] = info end
  for _, p in ipairs(parents or {}) do
    info.parents[#info.parents + 1] = p
    info.anc[p] = true
    local pi = self:type_info(p)
    if pi then for a in pairs(pi.anc) do info.anc[a] = true end end
  end
end

function L:add_form(form, reading)
  local list_ = self.forms[form]
  if not list_ then list_ = {}; self.forms[form] = list_ end
  list_[#list_ + 1] = reading
end

function L:add_rel(r)
  local ex = self.rels[r.id]
  if not ex then self.rel_order[#self.rel_order + 1] = r.id end
  self.rels[r.id] = r
  self.revision = self.revision + 1
  -- relational nouns (with plural forms) and verbs -> trie
  local function noun_entries(noun, role, rolesuffix)
    for _, f in ipairs(Morph.noun_forms(noun)) do
      self:trie_insert(f.form, { kind = "relnoun", rel = r.id, role = role, num = f.feat, lemma = noun, rolesuffix = rolesuffix })
    end
  end
  for _, n in ipairs(r.nouns_to) do noun_entries(n, "to") end
  -- "CEO position", "prime minister role": the post a person holds, named after the role noun (see the `rolesuffix=1` field of person-valued relations)
  for _, n in ipairs(r.role_nouns or {}) do noun_entries(n, "to", true) end
  for _, n in ipairs(r.nouns_from) do noun_entries(n, "from") end
  for _, v in ipairs(r.verbs) do
    for _, f in ipairs(Morph.verb_forms(v.lemma)) do
      self:trie_insert(f.form, { kind = "relverb", rel = r.id, subj = v.subj, vform = f.feat, lemma = v.lemma, prep = v.prep, support = v.support, as_only = v.as_only })
    end
  end
end

local function words_of(s) local t = {}; for w in s:gmatch("%S+") do t[#t + 1] = w end; return t end

function L:load(text, source)
  source = source or "inline"
  local n_dir = 0
  local ln = 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    ln = ln + 1
    local l = trim(line)
    if l ~= "" and l:sub(1, 1) ~= "#" then
      local dir, rest = l:match("^(%a+)%s+(.*)$")
      if not dir then add_err(self, source, ln, "unparseable line")
      else
        local ok, err = pcall(self.directive, self, dir, rest, source, ln)
        if not ok then add_err(self, source, ln, tostring(err)) else n_dir = n_dir + 1 end
      end
    end
  end
  self.sources[source] = { sha256 = U.sha256(text), lines = ln }
  self.revision = self.revision + 1
  return n_dir, self.errors
end

local function split_head(rest)
  local head, tail = rest:match("^(.-)%s*:%s*(.*)$")
  if not head then error("missing ':'") end
  return trim(head), tail
end

local DIRECTIVES = {}

function DIRECTIVES.type(self, rest)
  local name, parents = rest:match("^([%w_]+)%s*<%s*(.+)$")
  if not name then name = rest:match("^([%w_]+)$"); parents = "" end
  if not name then error("bad type line") end
  local ps = {}
  for p in parents:gmatch("[%w_]+") do ps[#ps + 1] = p end
  for _, p in ipairs(ps) do if not self:has_type(p) then error("unknown parent type " .. p) end end
  self:add_type(name, ps)
end

function DIRECTIVES.class(self, rest)
  local cat, tail = split_head(rest)
  self.class_words[cat] = self.class_words[cat] or {}
  for _, w in ipairs(words_of(tail)) do
    local f = w:lower()
    self.classes[f] = self.classes[f] or {}
    self.classes[f][cat] = true
    self.class_words[cat][f] = true
  end
end

function DIRECTIVES.pron(self, rest)
  local form, tail = split_head(rest)
  local feats = {}
  for k, v in tail:gmatch("(%w+)=(%S+)") do feats[k] = v end
  self.pron[form:lower()] = feats
end

function DIRECTIVES.rel(self, rest)
  local id, tail = split_head(rest)
  tail = tail:gsub("^%s*from=(%S+)%s+to=(%S+)", "from=%1 | to=%2") -- signature shares one field: "from=A to=B"
  local f = split_fields(tail)
  if not f.from or not f.to then error("rel needs from= and to=") end
  f.from, f.to = f.from:gsub(",", "|"), f.to:gsub(",", "|") -- union types are written a,b in the DSL ('|' separates fields)
  f.from = f.from:gsub("%s+", ""); f.to = f.to:gsub("%s+", "")
  for _, t in ipairs({ f.from, f.to }) do
    for alt in t:gmatch("[%w_]+") do if not self:has_type(alt) then error("unknown type " .. alt .. " in rel " .. id) end end
  end
  local r = { id = id, from = f.from, to = f.to, label = f.label or id:gsub("_", " "), nouns_to = list(f.noun), nouns_from = list(f.noun_from),
    verbs = {}, preps = list(f.prep), kinds = {}, when = f.when, where = f.where, how_many = f.how_many, derived = f.derived,
    weight = tonumber(f.weight) or 1.0, source = f.source or "seed", symmetric = f.symmetric == "1", attr = f.attr == "1", event = f.event == "1",
    locus = f.locus == "1", isa = f.isa, support = {} }
  if f.rolesuffix == "1" then
    r.role_nouns = {}
    for _, n in ipairs(r.nouns_to) do
      for _, sfx in ipairs({ "position", "role", "post", "job", "seat", "title", "office" }) do r.role_nouns[#r.role_nouns + 1] = n .. " " .. sfx end
    end
  end
  -- verb entries:  lemma/subj=to|from[/prep=in]   (prep => stative "X is VERB-ed PREP Y": X fills subj role, Y the other)
  for _, v in ipairs(list(f.verb)) do
    local lemma, attrs = v:match("^([^/]+)/(.*)$")
    if not lemma then error("verb entry needs /subj=to|from : " .. v) end
    local ent = { lemma = trim(lemma) }
    for k, val in attrs:gmatch("(%a+)=([%w_]+)") do ent[k] = val end
    if ent.subj ~= "to" and ent.subj ~= "from" then error("verb entry needs subj=to|from : " .. v) end
    r.verbs[#r.verbs + 1] = ent
  end
  -- support verbs ("Sweden USES the krona", "Acme KEEPS its headquarters in Oslo"): verbs that carry the relation with the holder as subject.
  -- `have` is an auxiliary and is handled by the support-construction frames, so it is recorded but not entered as a relation verb.
  for _, sv in ipairs(list(f.support)) do
    local lemma = trim(sv)
    r.support[#r.support + 1] = lemma
    if lemma == "have" then r.support_have = true else r.verbs[#r.verbs + 1] = { lemma = lemma, subj = "from", support = true } end
  end
  -- "as" verbs ("Acme APPOINTED Jane Doe as CEO", "France RECOGNIZES Paris as its capital"): the verb names the relation only together with "as <relational
  -- noun>"; on its own ("Acme employs Jane Doe", "voters elected X") it says nothing about this relation, so these entries never drive a plain verb frame
  r.as_verbs = {}
  for _, sv in ipairs(list(f.as)) do
    local lemma = trim(sv)
    r.as_verbs[#r.as_verbs + 1] = lemma
    r.verbs[#r.verbs + 1] = { lemma = lemma, subj = "from", support = true, as_only = true }
  end
  for _, k in ipairs(list(f.kinds)) do
    local mod, rid = k:match("^(.-):(.+)$")
    if mod then r.kinds[trim(mod):lower()] = trim(rid) end
  end
  self:add_rel(r)
end

function DIRECTIVES.sense(self, rest)
  local head, tail = split_head(rest)
  local id, after = tail:match("^([^|]+)(.*)$")
  id = trim(id)
  local f, flags = split_fields((after or ""):gsub("^|", ""))
  local s = { id = id, head = head, pos = f.pos or "n", type = f.type, gloss = f.gloss, prior = tonumber(f.prior) or 0.5,
    rel = f.rel, cs = f.cs == "1", domain = {}, source = f.source or "seed", kind = f.kind }
  for _, d in ipairs(list(f.domain)) do s.domain[d] = true end
  if s.type and not self:has_type(s.type) then error("unknown type " .. s.type) end
  self.senses[id] = s
  local key = table.concat(U.map((L.keys_of(head)), function(k) return k.form end), " ")
  s.key = key
  self.sense_by_head[key] = self.sense_by_head[key] or {}
  table.insert(self.sense_by_head[key], s)
  -- trie: single words get noun inflections; multiword heads are inserted as written (+ plural of last word)
  local variants = Morph.noun_forms(head)
  if s.pos == "adj" then variants = { { form = head, feat = "base" } } end
  for _, v in ipairs(variants) do
    self:trie_insert(v.form, { kind = "sense", sense = s, num = v.feat })
  end
  self.revision = self.revision + 1
end

local function is_short_caps(name) return name:find("^%u[%u%.]*$") ~= nil and #name:gsub("%.", "") <= 4 and #name:gsub("%.", "") >= 2 end

function L:add_entity(e)
  e.domain = e.domain or {}
  self.entities[e.id] = e
  for i, n in ipairs(e.names) do
    local nm = type(n) == "table" and n or { text = n, cs = false }
    if type(n) == "string" then
      nm = { text = n, cs = is_short_caps(n) }
      e.names[i] = nm
    end
    self:trie_insert(nm.text, { kind = "entity", id = e.id, name = nm.text, cs = nm.cs, primary = i == 1, etype = e.type })
  end
  self.revision = self.revision + 1
end

local function slug(s) return (s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")) end

function DIRECTIVES.entity(self, rest)
  local id, tail = split_head(rest)
  local etype, after = tail:match("^([%w_]+)(.*)$")
  if not etype or not self:has_type(etype) then error("unknown entity type " .. tostring(etype)) end
  local f = split_fields((after or ""):gsub("^%s*|", ""))
  local e = { id = id, type = etype, names = {}, domain = {}, prior = tonumber(f.prior) or 0.5, attr = {}, source = f.source or "seed" }
  local cs = {}
  for _, c in ipairs(list(f.cs)) do cs[c] = true end
  for _, n in ipairs(list(f.names)) do e.names[#e.names + 1] = { text = n, cs = cs[n] or is_short_caps(n) } end
  if #e.names == 0 then error("entity without names") end
  for _, d in ipairs(list(f.domain)) do e.domain[d] = true end
  for k, v in pairs(f) do local a = k:match("^attr%.(.+)$"); if a then e.attr[a] = v end end
  self:add_entity(e)
end

-- bulk entities get the default domains of their type, so bulk and hand-written entries compete on equal terms
local TYPE_DOMAINS = { country = { "geography", "politics" }, subnational = { "geography", "politics" }, city = { "geography" },
  continent = { "geography" }, ocean = { "geography" } }

function DIRECTIVES.entities(self, rest)
  local etype, tail = split_head(rest)
  if not self:has_type(etype) then error("unknown entity type " .. etype) end
  for _, n in ipairs(list(tail)) do
    local dom = {}
    for _, d in ipairs(TYPE_DOMAINS[etype] or {}) do dom[d] = true end
    self:add_entity({ id = etype .. "." .. slug(n), type = etype, names = { { text = n, cs = is_short_caps(n) } }, domain = dom, prior = 0.5,
      attr = {}, source = "seed" })
  end
end

function DIRECTIVES.alias(self, rest)
  local id, tail = split_head(rest)
  local e = self.entities[id]
  if not e then error("alias for unknown entity " .. id) end
  for _, n in ipairs(list(tail)) do
    local nm = { text = n, cs = is_short_caps(n) }
    e.names[#e.names + 1] = nm
    self:trie_insert(nm.text, { kind = "entity", id = e.id, name = nm.text, cs = nm.cs, primary = false, etype = e.type })
  end
end

function DIRECTIVES.verb(self, rest)
  local lemma, tail = split_head(rest)
  local f = split_fields(tail)
  local v = { lemma = lemma, act = f.act }
  self.verbs[lemma] = v
  for _, fm in ipairs(Morph.verb_forms(lemma)) do
    self:add_form(fm.form, { pos = "verb", lemma = lemma, feat = fm.feat, act = f.act })
    -- a multiword verb ("track down", "take a look at") is one span in the lattice
    if lemma:find(" ", 1, true) then self:trie_insert(fm.form, { kind = "actverb", lemma = lemma, feat = fm.feat, act = f.act }) end
  end
end

function DIRECTIVES.adj(self, rest)
  local lemma, tail = split_head(rest)
  local f = split_fields(tail)
  self.adjs[lemma] = { lemma = lemma, dim = f.dim }
  for _, fm in ipairs(Morph.adj_forms(lemma)) do
    self:add_form(fm.form, { pos = "adj", lemma = lemma, feat = fm.feat, dim = f.dim })
  end
end

function DIRECTIVES.dim(self, rest)
  local name, tail = split_head(rest)
  local f = split_fields(tail)
  self.dims[name] = { name = name, rels = list(f.rels, ","), order = f.order }
end

function DIRECTIVES.cue(self, rest)
  local name, tail = split_head(rest)
  self.cues[name] = self.cues[name] or {}
  self.cue_phrases[name] = self.cue_phrases[name] or {}
  for _, p in ipairs(list(tail)) do
    local keys = L.keys_of(p)
    local forms = U.map(keys, function(k) return k.form end)
    self.cues[name][table.concat(forms, " ")] = true
    self.cue_phrases[name][#self.cue_phrases[name] + 1] = forms
    self.cue_first[name] = self.cue_first[name] or {}
    local bucket = self.cue_first[name][forms[1]]
    if not bucket then bucket = {}; self.cue_first[name][forms[1]] = bucket end
    bucket[#bucket + 1] = forms
  end
end

function DIRECTIVES.domain(self, rest)
  local name, tail = split_head(rest)
  for _, w in ipairs(words_of(tail)) do
    local f = w:lower()
    -- cue words apply to their inflected forms too ("university" cues "universities")
    local forms = { f }
    if not f:find("[^%a]") then for _, nf in ipairs(Morph.noun_forms(f)) do forms[#forms + 1] = nf.form end end
    for _, form in ipairs(forms) do
      self.domain_words[form] = self.domain_words[form] or {}
      self.domain_words[form][name] = true
    end
  end
end

function DIRECTIVES.headcue(self, rest)
  local t, tail = split_head(rest)
  if not self:has_type(t) then error("unknown type " .. t) end
  for _, w in ipairs(words_of(tail)) do self.headcues[w:lower()] = t end
end

function DIRECTIVES.resource(self, rest)
  local name, tail = split_head(rest)
  for _, p in ipairs(list(tail)) do
    local keys = L.keys_of(p)
    self.resources[table.concat(U.map(keys, function(k) return k.form end), " ")] = name
  end
  self.resources[name] = name
end

-- nouns that denote conversational artifacts ("the second solution", "the revised version", "my earlier correction")
function DIRECTIVES.refnoun(self, rest)
  local class, tail = split_head(rest)
  for _, w in ipairs(list(tail)) do
    local f = w:lower()
    local forms = { f }
    for _, nf in ipairs(Morph.noun_forms(f)) do forms[#forms + 1] = nf.form end
    for _, form in ipairs(forms) do
      self.refnouns[form] = self.refnouns[form] or {}
      self.refnouns[form][class] = true
    end
  end
end

function DIRECTIVES.wrap(self, rest)
  local name, tail = split_head(rest)
  local f, _ = split_fields(tail)
  local pat = {}
  for tok in (f.pattern or tail):gmatch("%S+") do pat[#pat + 1] = tok end
  self.wraps[#self.wraps + 1] = { name = name, pattern = pat, mode = f.mode }
end

function L:directive(dir, rest, source, ln)
  local fn = DIRECTIVES[dir]
  if not fn then error("unknown directive '" .. dir .. "'") end
  fn(self, rest, source, ln)
end

---------------------------------------------------------------- queries
-- An OPEN relation stands for a relation word the lexicon does not know ("paint", "mascot"): it is represented faithfully under its own name
-- ("open:paint") instead of being mapped onto a familiar relation.  Created on demand, never listed among the lexicon's relations.
L.OPEN_PREFIX = "open:"
function L:open_relation(lemma)
  lemma = lemma:gsub("e$", "")   -- "dance" / "danc(ed)" name the same open relation
  local root = self
  while root.parent do root = root.parent end
  root.open_rels = root.open_rels or {}
  local id = L.OPEN_PREFIX .. lemma
  local r = root.open_rels[id]
  if not r then
    r = { id = id, from = "entity", to = "entity", label = lemma .. " (open relation)", nouns_to = {}, nouns_from = {}, verbs = {}, preps = {}, kinds = {}, weight = 0.5,
      source = "open", open = true }
    root.open_rels[id] = r
  end
  return r
end

function L:get_rel(id)
  local r = self.rels[id]
  if r then return r end
  if self.parent then
    r = self.parent:get_rel(id)
    if r then return r end
  end
  local lemma = id:match("^open:(.+)$")
  if lemma then return self:open_relation(lemma) end
end

-- relations that are specialisations of `id` (declared `isa=id`): evidence for them also answers a question about the general relation
function L:specializations(id)
  local out = {}
  local lex = self
  while lex do
    for _, rid in ipairs(lex.rel_order) do
      local r = lex.rels[rid]
      if r.isa == id then out[#out + 1] = rid end
    end
    lex = lex.parent
  end
  return out
end

-- a relation designated by a dataset column / predicate string: id, label or one of its nouns ("Capital", "capital of", "CEO", "has_capital")
function L:rel_by_name(name)
  local key = name:lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
  local r = self:get_rel(key)
  if r then return r end
  local plain = name:lower():gsub("[_%-]+", " "):gsub("^%s*has%s+", ""):gsub("%s+of%s*$", ""):gsub("%s+by%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- passive-style column names ("founded_by", "acquired_by"): the relation whose verb has the subject in the `to` role
  local pv = key:match("^(.-)_by$")
  if pv then
    local cands = { pv, (pv:gsub("ed$", "")), (pv:gsub("d$", "")), (pv:gsub("ied$", "y")) }
    local lex = self
    while lex do
      for _, id in ipairs(lex.rel_order) do
        local rel = lex.rels[id]
        for _, v in ipairs(rel.verbs or {}) do
          if v.subj == "to" and not v.prep then for _, c in ipairs(cands) do if v.lemma == c then return rel end end end
        end
      end
      lex = lex.parent
    end
  end
  local lex = self
  while lex do
    for _, id in ipairs(lex.rel_order) do
      local rel = lex.rels[id]
      local label = (rel.label or ""):lower()
      if label == plain then return rel end
      for _, n in ipairs(rel.nouns_to or {}) do if n:lower() == plain then return rel end end
      for _, n in ipairs(rel.nouns_from or {}) do if n:lower() == plain then return rel end end
    end
    lex = lex.parent
  end
  return nil
end

function L:get_entity(id)
  local e = self.entities[id]
  if e then return e end
  if self.parent then return self.parent:get_entity(id) end
end

function L:get_sense(id)
  local s = self.senses[id]
  if s then return s end
  if self.parent then return self.parent:get_sense(id) end
end

function L:cats(form)
  local c = self.classes[form]
  if c then return c end
  if self.parent then return self.parent:cats(form) end
  return nil
end

function L:is_cat(form, cat)
  local c = self:cats(form)
  return c ~= nil and c[cat] == true
end

function L:pron_feats(form)
  return self.pron[form] or (self.parent and self.parent:pron_feats(form))
end

function L:readings(form)
  local out = {}
  local lex = self
  while lex do
    for _, r in ipairs(lex.forms[form] or {}) do out[#out + 1] = r end
    lex = lex.parent
  end
  return out
end

function L:has_cue(name, phrase_key)
  local lex = self
  while lex do
    if lex.cues[name] and lex.cues[name][phrase_key] then return true end
    lex = lex.parent
  end
  return false
end

function L:cue_list(name)
  local out = {}
  local lex = self
  while lex do
    for _, forms in ipairs(lex.cue_phrases[name] or {}) do out[#out + 1] = forms end
    lex = lex.parent
  end
  return out
end

-- does the unit sequence starting at i begin with any cue phrase of this kind? returns length matched
function L:cue_at(name, units, i)
  local u0 = units[i]
  if not u0 then return nil end
  local best
  local lex = self
  while lex do
    local first = lex.cue_first[name]
    local bucket = first and first[u0.form]
    if bucket then
      for _, forms in ipairs(bucket) do
        local ok = true
        for k = 2, #forms do
          local u = units[i + k - 1]
          if not u or u.form ~= forms[k] then ok = false break end
        end
        if ok and (not best or #forms > best) then best = #forms end
      end
    end
    lex = lex.parent
  end
  return best
end

function L:domains_of(form)
  local lex, out = self, {}
  while lex do
    local d = lex.domain_words[form]
    if d then for k in pairs(d) do out[k] = true end end
    lex = lex.parent
  end
  return out
end

-- is `phrase` (folded) listed under the cue kind `name` in this lexicon or an ancestor?
function L:is_cue(name, phrase)
  local lex = self
  while lex do
    if lex.cues[name] and lex.cues[name][phrase] then return true end
    lex = lex.parent
  end
  return false
end

-- artifact classes a noun can denote (set), merged along the overlay chain
function L:refclasses(form)
  local out, lex = {}, self
  while lex do
    for c in pairs(lex.refnouns[form] or {}) do out[c] = true end
    lex = lex.parent
  end
  return out
end

function L:headcue(form)
  return self.headcues[form] or (self.parent and self.parent:headcue(form))
end

function L:resource(key)
  local r = self.resources[key] or (self.parent and self.parent:resource(key))
  if r or type(key) ~= "string" then return r end
  -- plural forms of a resource noun ("datasets", "versions", "files", "analyses" are not resources, "libraries" is not either)
  if #key > 3 and key:sub(-1) == "s" and key:sub(-2) ~= "ss" then
    local stem = key:sub(1, -2)
    r = self.resources[stem] or (self.parent and self.parent:resource(stem))
    if r then return r end
    if key:sub(-2) == "es" then
      stem = key:sub(1, -3)
      r = self.resources[stem] or (self.parent and self.parent:resource(stem))
    end
  end
  return r
end

function L:adj_reading(form)
  for _, r in ipairs(self:readings(form)) do if r.pos == "adj" then return r end end
end

function L:dim(name) return self.dims[name] or (self.parent and self.parent:dim(name)) end

function L:all_rels()
  local out, seen = {}, {}
  local lex = self
  local chain = {}
  while lex do table.insert(chain, 1, lex); lex = lex.parent end
  for _, x in ipairs(chain) do
    for _, id in ipairs(x.rel_order) do if not seen[id] then seen[id] = true; out[#out + 1] = x.rels[id] end end
  end
  return out
end

---------------------------------------------------------------- typo vocabulary derived from the loaded resources
-- Every word the lexicon knows (class words, verb/adjective forms, every unit of every phrase) feeds a symmetric-delete index.
-- Entity-name words are tagged kind="entity" so unknown capitalised words prefer entity neighbours.
function L:build_spell(parent_spell)
  local Spell = require("asi.nlu.spell")
  local sp = Spell.new()
  if parent_spell then sp:chain(parent_spell) end
  for form in pairs(self.classes) do if not form:find("%s") and not form:find("'") then sp:add(form, 5, "lex") end end
  for form in pairs(self.forms) do if not form:find("%s") then sp:add(form, 3, "lex") end end
  local function walk(node)
    for key, kid in pairs(node.kids) do
      local form = key:match("^([^\1]*)")
      local kind = "lex"
      if kid.entries then for _, e in ipairs(kid.entries) do if e.kind == "entity" then kind = "entity" end end end
      if #form >= 3 and not form:find("[%d']") then sp:add(form, kind == "entity" and 4 or 3, kind) end
      walk(kid)
    end
  end
  walk(self.trie)
  self.spell = sp
  return sp
end

-- closed-class words (wh-words, auxiliaries, determiners, prepositions, pronouns, conjunctions): the words whose misspelling destroys syntax.  Kept in a
-- separate index so that a typo is read as a function word only through the explicit, penalised repair pass (asi.nlu.parse repair_cover).
local FUNCTION_CLASSES = { "wh", "aux_do", "aux_be", "aux_have", "modal", "det", "prep", "pron", "pron_poss", "conj", "polite" }
function L:function_spell()
  local root = self
  while root.parent do root = root.parent end
  if root._fn_spell and root._fn_spell_rev == root.revision then return root._fn_spell end
  local Spell = require("asi.nlu.spell")
  local sp = Spell.new()
  for _, cls in ipairs(FUNCTION_CLASSES) do
    local words = {}
    for form in pairs(root.class_words[cls] or {}) do words[#words + 1] = form end
    table.sort(words)
    for _, form in ipairs(words) do if #form >= 3 and not form:find("[%s']") then sp:add(form, 5, cls) end end
  end
  root._fn_spell, root._fn_spell_rev = sp, root.revision
  return sp
end

---------------------------------------------------------------- relation induction from dataset schema names
-- "founded_by" -> passive verb (found, subj=to); "ceo_of" -> noun "ceo"; "headquarters_location" -> noun; "has_capital" -> noun "capital"
function L:induce_relation(name, spec)
  spec = spec or {}
  local rid = spec.id or name
  if self.rels[rid] and not spec.force then return self.rels[rid], false end
  if not spec.id and self:get_rel(name) and not spec.force then return self:get_rel(name), false end
  local parts = {}
  for p in name:gsub("(%l)(%u)", "%1_%2"):lower():gmatch("[%a%d]+") do parts[#parts + 1] = p end
  local drop = { has = true, is = true, was = true, have = true, a = true, the = true }
  while #parts > 1 and drop[parts[1]] do table.remove(parts, 1) end
  local preps = { of = true, by = true, in_ = true, to = true, for_ = true, at = true, from = true, with = true }
  local r = { id = rid, from = spec.from or "entity", to = spec.to or "entity", label = (name:gsub("_", " ")), nouns_to = {}, nouns_from = {},
    verbs = {}, preps = {}, kinds = {}, weight = 0.7, source = "induced" }
  local last = parts[#parts]
  if #parts >= 2 and (last == "by") then
    local v = parts[#parts - 1]
    local base = v:gsub("ed$", ""):gsub("ied$", "y")
    local cands = { v:gsub("ed$", ""), v:gsub("d$", ""), (v:gsub("ied$", "y")) }
    local lemma = cands[1]
    if v:find("ed$") then
      if self.verbs[cands[2]] or self:readings(cands[2])[1] then lemma = cands[2] end
      if #v > 5 and v:sub(-3, -3) == v:sub(-4, -4) then lemma = v:sub(1, -4) end
    end
    r.verbs[#r.verbs + 1] = { lemma = lemma, subj = "to" }
    r.nouns_to[#r.nouns_to + 1] = (v:gsub("ed$", "er"):gsub("eder$", "er"))
  elseif #parts >= 2 and preps[last] then
    r.nouns_to[#r.nouns_to + 1] = table.concat(parts, " ", 1, #parts - 1)
  else
    r.nouns_to[#r.nouns_to + 1] = table.concat(parts, " ")
    if #parts >= 2 then r.nouns_to[#r.nouns_to + 1] = parts[#parts] end
  end
  for k, v in pairs(spec) do if k ~= "force" and k ~= "id" and r[k] == nil then r[k] = v end end
  if spec.nouns then for _, n in ipairs(spec.nouns) do r.nouns_to[#r.nouns_to + 1] = n end end
  if spec.verbs then for _, v in ipairs(spec.verbs) do r.verbs[#r.verbs + 1] = v end end
  self:add_rel(r)
  return r, true
end

return L
