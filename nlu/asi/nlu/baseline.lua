-- asi.nlu.baseline: a DOCUMENTED NAIVE keyword router, used only as a comparison point.
-- No existing natural-language interpreter was available to me, so this is a strawman I wrote on purpose:
--   * words are whitespace/punctuation tokens, lower-cased; phrases are n-gram string matches (no lattice, no case-sensitivity)
--   * the FIRST relation keyword found wins, wherever it is and whatever it modifies ("capital punishment" -> capital)
--   * entities: first alphabetical-id name match; no types, no context, no ambiguity ("Mercury" is always resolved)
--   * no negation scope, no temporal operators, no coreference, no voice/direction analysis
--   * ambiguity is never reported.
-- It uses the SAME lexicon data as the real interpreter so the comparison isolates the interpretation machinery.
local U = require("asi.nlu.util")
local Morph = require("asi.nlu.morph")

local B = {}

local cache = setmetatable({}, { __mode = "k" })

local function words_of(text)
  local out = {}
  for w in text:lower():gmatch("[%w']+") do out[#out + 1] = w end
  return out
end

local function index_for(lex)
  if cache[lex] then return cache[lex] end
  local idx = { ents = {}, rels = {}, types = {} }
  local chain = {}
  local l = lex
  while l do table.insert(chain, 1, l); l = l.parent end
  for _, lx in ipairs(chain) do
    for id, e in pairs(lx.entities) do
      for _, nm in ipairs(e.names) do
        local key = table.concat(words_of(nm.text), " ")
        if key ~= "" then
          idx.ents[key] = idx.ents[key] or {}
          table.insert(idx.ents[key], { id = id, type = e.type })
        end
      end
    end
    for _, r in ipairs(lx:all_rels()) do
      local function add(phrase, role)
        for _, f in ipairs(Morph.noun_forms(phrase)) do
          local key = table.concat(words_of(f.form), " ")
          idx.rels[key] = idx.rels[key] or { rel = r, role = role }
        end
      end
      for _, n in ipairs(r.nouns_to) do add(n, "to") end
      for _, n in ipairs(r.nouns_from) do add(n, "from") end
      for _, v in ipairs(r.verbs) do
        for _, f in ipairs(Morph.verb_forms(v.lemma)) do
          local key = table.concat(words_of(f.form), " ")
          idx.rels[key] = idx.rels[key] or { rel = r, role = (v.subj == "to") and "to" or "from", verb = true }
        end
      end
    end
    for _, s in pairs(lx.senses) do
      if s.kind == "typenoun" then
        for _, f in ipairs(Morph.noun_forms(s.head)) do idx.types[table.concat(words_of(f.form), " ")] = s.type end
      end
    end
  end
  for k, list in pairs(idx.ents) do table.sort(list, function(a, b) return a.id < b.id end) end
  cache[lex] = idx
  return idx
end

function B.interpret(text, lex)
  local idx = index_for(lex)
  local w = words_of(text)
  local out = { schema = "nlu.sem/1", status = "ok", baseline = true, constraints = { positive = {}, negative = {}, preferences = {}, restrictions = {}, temporal = {}, geographic = {}, source = {} },
    hypotheses = {}, ambiguity = { state = "resolved", points = {} }, roles = {}, unexplained = {}, dependencies = {} }
  -- leftmost-longest entity
  local ent, ent_pos
  for i = 1, #w do
    for n = math.min(4, #w - i + 1), 1, -1 do
      local key = table.concat(w, " ", i, i + n - 1)
      if idx.ents[key] and not (n == 1 and #key <= 2) then ent = { key = key, list = idx.ents[key], n = n }; ent_pos = i; break end
    end
    if ent then break end
  end
  -- leftmost relation keyword (first wins, anywhere)
  local rel, rel_pos
  for i = 1, #w do
    for n = math.min(3, #w - i + 1), 1, -1 do
      local key = table.concat(w, " ", i, i + n - 1)
      if idx.rels[key] then rel = idx.rels[key]; rel_pos = i; break end
    end
    if rel then break end
  end
  local first = w[1] or ""
  local qwords = { what = true, who = true, which = true, when = true, where = true, how = true, why = true, whom = true, whose = true }
  local auxq = { is = true, are = true, does = true, did = true, do_ = true, was = true, were = true, can = true, could = true, will = true, has = true, have = true }
  local act = "statement"
  if qwords[first] or (text:find("%?%s*$")) then act = "question" end
  if auxq[first] then act = "question" end
  local imperative = { find = "search", list = "search", show = "search", get = "search", search = "search", give = "search", name = "lookup",
    compare = "comparison", use = "instruction_update", switch = "instruction_update", set = "instruction_update", choose = "instruction_update",
    prioritize = "instruction_update", exclude = "instruction_update", explain = "explanation", describe = "description", define = "definition", tell = "description" }
  local intent
  if imperative[first] then act = "request"; intent = imperative[first] end
  if not intent then
    if first == "why" then intent = "causal_explanation"
    elseif first == "how" and not rel then intent = "explanation"
    elseif auxq[first] then intent = "verification"
    elseif rel then intent = "factual_lookup"
    elseif first == "what" or first == "who" then intent = ent and "description" or "definition"
    elseif ent then intent = "factual_lookup"
    else intent = "unknown" end
  end
  if intent == "search" and rel and ent and false then intent = "factual_lookup" end
  if imperative[first] == "search" and rel and not text:lower():find("compan") then intent = "factual_lookup" end
  out.speech_act, out.intent = act, intent
  if rel then
    local r = rel.rel
    out.relation = { id = r.id, label = r.label, from_type = r.from, to_type = r.to }
    local known_role = (rel.role == "to") and "from" or "to"
    local ask_role = rel.role
    if rel.verb then known_role, ask_role = "from", "to" end
    out.query = { known_role = known_role, ask = ask_role, answer_type = r[ask_role] }
    if ent then
      local c = ent.list[1]
      out.roles[known_role] = { text = ent.key, resolved_id = c.id, type = c.type, status = "resolved" }
    end
  elseif ent then
    local c = ent.list[1]
    out.subject = { text = ent.key, resolved_id = c.id, type = c.type, status = "resolved" }
    out.concept = out.subject
  end
  for _, tok in ipairs(w) do
    local y = tonumber(tok:match("^(%d%d%d%d)$"))
    if y and y >= 1000 and y <= 2999 then out.constraints.temporal[#out.constraints.temporal + 1] = { kind = "year", op = "in", year = y, text = tostring(y), eff_lo = y * 10000 + 101, eff_hi = y * 10000 + 1231 } end
  end
  out.hypotheses = { { rank = 1, p = 1.0, summary = "keyword route" } }
  out.requires_external_evidence = (intent ~= "instruction_update")
  return out
end

-- Lexical-only ablation: the full lexical stack (UTF-8 lexer, MWE/entity lattice, case-sensitive aliases, typo alternatives)
-- but NO syntax, voice, types, negation scope or competing hypotheses: first relation reading + first entity reading win.
function B.lexical_only(text, lex)
  local Lex = require("asi.nlu.lex")
  local Lattice = require("asi.nlu.lattice")
  local an = Lex.analyze(text, { spell = lex.spell })
  local lat = Lattice.build(an, lex)
  local cover = lat:covers(1)[1]
  local out = { schema = "nlu.sem/1", status = "ok", lexical_only = true, constraints = { positive = {}, negative = {}, preferences = {}, restrictions = {}, temporal = {}, geographic = {}, source = {} },
    hypotheses = { { rank = 1, p = 1.0, summary = "lexical route" } }, ambiguity = { state = "resolved", points = {} }, roles = {}, unexplained = {}, dependencies = {} }
  local rel, ent, concept
  if cover then
    for _, sp in ipairs(cover.spans) do
      for _, r in ipairs(sp.readings) do
        if r.kind == "relnoun" and not rel then rel = { rel = lex:get_rel(r.entry.rel), role = r.entry.role } end
        if r.kind == "relverb" and not rel then rel = { rel = lex:get_rel(r.entry.rel), role = r.entry.subj == "to" and "to" or "from", verb = true } end
        if r.kind == "entity" and not ent then ent = { span = sp, e = r.entry } end
        if r.kind == "sense" and sp.kind == "mwe" and not concept then concept = { span = sp, sense = r.sense } end
      end
    end
  end
  local w = {}
  for x in text:lower():gmatch("[%w']+") do w[#w + 1] = x end
  local first = w[1] or ""
  local qwords = { what = true, who = true, which = true, when = true, where = true, how = true, why = true }
  out.speech_act = (qwords[first] or text:find("%?%s*$")) and "question" or "statement"
  if rel then
    out.intent = "factual_lookup"
    out.relation = { id = rel.rel.id, from_type = rel.rel.from, to_type = rel.rel.to }
    local known_role = (rel.role == "to") and "from" or "to"
    local ask_role = rel.role
    if rel.verb then known_role, ask_role = "from", "to" end
    out.query = { known_role = known_role, ask = ask_role, answer_type = rel.rel[ask_role] }
    if ent then out.roles[known_role] = { text = ent.span.text, resolved_id = ent.e.id, type = ent.e.etype, status = "resolved" } end
  elseif concept then
    out.intent = "definition"
    out.concept = { text = concept.span.text, type = concept.sense.type, senses = { { id = concept.sense.id, type = concept.sense.type } } }
  elseif ent then
    out.intent = (first == "what" or first == "who") and "description" or "factual_lookup"
    out.subject = { text = ent.span.text, resolved_id = ent.e.id, type = ent.e.etype, status = "resolved" }
  else out.intent = "unknown" end
  out.requires_external_evidence = true
  return out
end

return B
