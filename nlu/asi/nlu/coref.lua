-- asi.nlu.coref: discourse reference resolution against layered memory.
--   View:pronoun_binding  candidate antecedents for a personal/demonstrative pronoun, scored from real evidence (salience, recency, focus,
--                         agreement, role type, co-argument exclusion) against an explicit "no antecedent" competitor.
--   C.resolve_references  definite back-references ("the business I mentioned earlier"), ordinal/labelled artifacts ("the second
--                         solution", "the revised version"), correction references and comparison sets -- or an explicit,
--                         inspectable "unresolved" requirement.  Nothing is ever fabricated to fill a missing antecedent.
local U = require("asi.nlu.util")

local C = {}
C.W = {
  salience = 1.0, recency = 0.45, focus = 0.8, topical = 0.2, user_intro = 0.1, type_fit = 0.6, unknown_animacy = -0.3,
  plural_mismatch = -0.6, none_personal = 0.30, none_demonstrative = 0.45, temperature = 0.35, resolve_p = 0.60, resolve_margin = 0.30,
}

local TOPICAL = U.set({ "focus", "subject", "stmt_subject", "clause_subject", "arg:from", "item", "chain_arg" })

---------------------------------------------------------------- view over one memory
local View = {}
View.__index = View

function C.view(mem, lex, opts)
  return setmetatable({ mem = mem, lex = lex, opts = opts or {} }, View)
end

-- previously mentioned entities -> weight in [0,1] (feeds entity-candidate scoring as discourse evidence)
function View:mention_weights()
  local out = {}
  for key, e in pairs(self.mem.entities) do
    local s = self.mem:salience(e)
    if s > 0.05 then out[key] = math.min(1, s) end
  end
  return out
end

-- domain cue words in recent turns -> hits per domain (decayed by turn distance; at most 2, like in-message cues)
function View:domain_profile()
  local mem, lex = self.mem, self.lex
  local acc = {}
  for _, id in ipairs(mem.order) do
    local it = mem.items[id]
    if it and it.kind == "utterance" and it.status == "active" and it.turn < mem.turn and mem.turn - it.turn <= 8 and it.speaker == "user" then
      local w = mem.decay ^ (mem.turn - it.turn)
      for word in (it.text or ""):lower():gmatch("[%a][%a'%-]*") do
        for d in pairs(lex:domains_of(word)) do
          acc[d] = acc[d] or {}
          acc[d][word] = math.max(acc[d][word] or 0, w)
        end
      end
    end
  end
  local prof = {}
  for d, words in pairs(acc) do
    local total = 0
    for _, w in pairs(words) do total = total + w end
    if total >= 1.5 then prof[d] = 2 elseif total >= 0.5 then prof[d] = 1 end
  end
  return prof
end

---------------------------------------------------------------- agreement
-- returns ok, penalty, reason
local function agreement(lex, feats, e, form)
  local W = C.W
  local t = e.type
  local an = tostring(feats.animate or "any")
  local person_like = t and lex:isa(t, "person") or false
  if an == "1" then
    if t and not person_like then return false, 0, "animate pronoun '" .. form .. "' cannot refer to a " .. t end
    if not t then return true, W.unknown_animacy, "animacy of the candidate is unknown" end
  elseif an == "0" then
    if person_like then return false, 0, "'" .. form .. "' does not refer to a person (" .. t .. ")" end
    if not t then return true, W.unknown_animacy, "animacy of the candidate is unknown" end
  end
  local num = tostring(feats.number or "any")
  if num == "sg" and e.plural then return true, W.plural_mismatch, "singular pronoun vs plural antecedent" end
  if num == "pl" and not e.plural and e.type then return true, W.plural_mismatch * 0.5, "plural pronoun vs singular antecedent" end
  return true, 0, nil
end

-- other entity arguments of the same hypothesis may not be the antecedent of a non-reflexive pronoun
local function coarguments(H, S, ctx, h, np)
  local ex = {}
  local function consider(x)
    if x and x ~= np and x.head_kind == "entity" then
      local b = H.bind_np(S, ctx, x, nil, h, "coarg")
      if b and b.top and (b.status == "resolved" or b.status == "unseen") then ex[b.top.id] = true end
    end
  end
  for _, x in pairs(h.roles or {}) do consider(x) end
  consider(h.subject); consider(h.concept); consider(h.target); consider(h.focus); consider(h.object)
  for _, x in ipairs(h.items or {}) do consider(x) end
  if h.statement then consider(h.statement.subj); consider(h.statement.obj) end
  if h.clause then consider(h.clause.subj); consider(h.clause.obj) end
  return ex
end

---------------------------------------------------------------- pronoun binding (called from hyp.bind_np)
local function softmax(scores, T)
  local m = -math.huge
  for _, s in ipairs(scores) do if s > m then m = s end end
  local sum, ex = 0, {}
  for i, s in ipairs(scores) do ex[i] = math.exp((s - m) / T); sum = sum + ex[i] end
  for i = 1, #ex do ex[i] = ex[i] / sum end
  return ex
end

function View:pronoun_binding(S, ctx, np, expected, h, role, b)
  local mem, lex, W = self.mem, self.lex, C.W
  local feats = np.pron.feats or {}
  local form = np.pron.form:lower()
  b.discourse, b.pronoun = true, form
  local person = tostring(feats.person or "3")
  if person == "1" or person == "2" then
    local who = person == "1" and "speaker" or "addressee"
    local ty = person == "1" and "person" or "agent"
    local top = { id = who .. ":" .. (person == "1" and (mem.speaker or "user") or "assistant"), type = ty, name = form, p = 1.0, score = 1.0,
      reasons = { "first/second-person pronoun: deictic reference to the " .. who } }
    b.cands, b.top, b.status, b.deictic, b.type = { top }, top, "resolved", who, ty
    b.fit = lex:compat(ty, expected)
    return b
  end
  local H = require("asi.nlu.hyp")
  local exclude = h and coarguments(H, S, ctx, h, np) or {}
  local reflexive = (np.pron.cats and np.pron.cats.pron_refl) == true
  if reflexive then exclude = {} end
  -- recency ranks by sequence of last mention
  local order = {}
  for _, e in pairs(mem.entities) do order[#order + 1] = e end
  table.sort(order, function(a, c) if (a.last_seq or 0) ~= (c.last_seq or 0) then return (a.last_seq or 0) > (c.last_seq or 0) end return a.key < c.key end)
  local live, rejected = {}, {}
  for rank, e in ipairs(order) do
    local key = e.key
    if exclude[key] then
      rejected[#rejected + 1] = { id = key, type = e.type, reasons = { "co-argument of the same predicate: a non-reflexive pronoun cannot corefer with it" } }
    else
      local ok, pen, why = agreement(lex, feats, e, form)
      if not ok then rejected[#rejected + 1] = { id = key, type = e.type, reasons = { why } }
      else
        local fit = (expected and e.type) and lex:compat(e.type, expected) or 0.25
        if fit == -1.0 then
          rejected[#rejected + 1] = { id = key, type = e.type, reasons = { "type " .. tostring(e.type) .. " cannot fill " .. tostring(expected) } }
        else
          local reasons = {}
          local sal = math.min(1, mem:salience(e))
          local s = W.salience * sal
          reasons[#reasons + 1] = string.format("salience %.2f", sal)
          local rec = W.recency / rank
          s = s + rec; reasons[#reasons + 1] = string.format("mention recency rank %d (+%.2f)", rank, rec)
          if mem.focus and mem.focus.key == key then
            local fb = W.focus * (mem.decay ^ math.max(0, mem.turn - mem.focus.turn))
            s = s + fb; reasons[#reasons + 1] = string.format("current discourse focus (+%.2f)", fb)
          end
          local lm = e.mentions[#e.mentions]
          if lm and TOPICAL[lm.role or ""] then s = s + W.topical; reasons[#reasons + 1] = "last mentioned in a topical role (" .. lm.role .. ")" end
          if e.by_user then s = s + W.user_intro; reasons[#reasons + 1] = "introduced by the user" end
          if expected and e.type then s = s + W.type_fit * fit; reasons[#reasons + 1] = string.format("type fit %.2f for %s", fit, tostring(expected)) end
          if pen ~= 0 then s = s + pen; reasons[#reasons + 1] = why end
          local display = e.display or key
          if lm and lm.text then display = lm.text end
          live[#live + 1] = { id = key, type = e.type, name = display, score = s, fit = fit, reasons = reasons, turn = e.last_turn, first_turn = e.first_turn }
        end
      end
    end
  end
  -- plural / collective pronouns may denote the most recent comparison set
  local pl = tostring(feats.number or "any") ~= "sg"
  if pl and mem.comparison and #mem.comparison.keys >= 2 and (form == "they" or form == "them" or form == "these" or form == "those") then
    local sal = mem.decay ^ math.max(0, mem.turn - mem.comparison.turn)
    live[#live + 1] = { id = "group:" .. table.concat(mem.comparison.keys, "+"), type = nil, name = "the compared items", score = W.salience * sal + 0.4, fit = 0.25,
      reasons = { "most recent comparison set", string.format("decay %.2f", sal) }, turn = mem.comparison.turn, group = mem.comparison.keys }
  end
  local demo = (np.pron.cats and (np.pron.cats.pron_dem == true)) or form == "this" or form == "that"
  local none = demo and W.none_demonstrative or W.none_personal
  table.sort(live, function(a, c) if a.score ~= c.score then return a.score > c.score end return a.id < c.id end)
  b.rejected = rejected
  b.expected = expected
  if #live == 0 then
    b.status, b.fit = "unresolved", 0.25
    b.none_reason = #rejected > 0 and "candidate entities exist but none agrees with the pronoun and its role" or "no entity has been mentioned in the available context"
    return b
  end
  local scores = { none }
  for i, c in ipairs(live) do scores[i + 1] = c.score end
  local ps = softmax(scores, W.temperature)
  b.p_none = ps[1]
  for i, c in ipairs(live) do c.p = ps[i + 1] end
  b.cands, b.top = live, live[1]
  local second = math.max(live[2] and live[2].p or 0, b.p_none)
  local margin = live[1].p - second
  b.margin = margin
  if live[1].p >= W.resolve_p and margin >= W.resolve_margin then
    b.status = "resolved"
    b.fit = live[1].fit
    local mem_turn = mem.turn
    b.antecedent = { key = live[1].id, text = live[1].name, type = live[1].type, turn = live[1].turn, distance_turns = math.max(0, mem_turn - (live[1].turn or mem_turn)),
      via = "pronoun", p = live[1].p, group = live[1].group }
  elseif b.p_none >= live[1].p then
    b.status, b.fit = "unresolved", 0.25
    b.none_reason = "no candidate is salient enough to be the antecedent (no-antecedent hypothesis p=" .. string.format("%.2f", b.p_none) .. ")"
  else
    b.status, b.fit = "ambiguous", live[1].fit
    b.none_reason = "several antecedents remain plausible"
  end
  return b
end

---------------------------------------------------------------- non-pronoun references
-- walk every ref table of a rendered interpretation, giving each a role name and the role's expected type
function C.walk(interp, fn)
  local seen = {}
  local function visit(r, role, expected, depth)
    if not r or seen[r] then return end
    seen[r] = true
    fn(r, role, expected)
    if depth < 3 then
      if r.of then visit(r.of, role .. ".of", nil, depth + 1) end
      if r.possessor then visit(r.possessor, role .. ".poss", nil, depth + 1) end
    end
  end
  local rel = interp.relation
  for role, r in pairs(interp.roles or {}) do
    local exp = rel and ((role == "from" and rel.from_type) or (role == "to" and rel.to_type)) or nil
    visit(r, "arg:" .. role, exp, 0)
  end
  for _, k in ipairs({ "subject", "concept", "target", "focus", "object", "basis" }) do visit(interp[k], k, nil, 0) end
  for _, it in ipairs(interp.items or {}) do visit(it, "item", nil, 0) end
  if interp.statement then visit(interp.statement.subject, "stmt_subject", nil, 0); visit(interp.statement.object, "stmt_object", nil, 0) end
  if interp.clause then visit(interp.clause.subject, "clause_subject", nil, 0); visit(interp.clause.object, "clause_object", nil, 0) end
  if interp.instruction then visit(interp.instruction.object, "instruction_object", nil, 0) end
  for _, st in ipairs((interp.query and interp.query.steps) or {}) do visit(st.known, "chain_arg", nil, 0) end
  if interp.query and interp.query.qualifier then visit(interp.query.qualifier.arg, "qualifier", nil, 0) end
end

local function label_kind(lex, r)
  for _, m in ipairs(r.modifiers or {}) do
    local w = (m.text or ""):lower()
    if lex:is_cue("art_latest", w) then return "latest", w end
    if lex:is_cue("art_first", w) then return "first", w end
    if lex:is_cue("art_prev", w) then return "previous", w end
  end
  return nil
end

local function artifact_summary(a)
  return { key = "artifact:" .. a.class .. ":" .. tostring(a.ordinal), text = a.label or (a.class .. " " .. tostring(a.ordinal)), type = "artifact:" .. a.class,
    turn = a.turn, item = a.item, excerpt = (a.text or ""):sub(1, 160), ordinal = a.ordinal, via = "artifact" }
end

-- artifacts of the given classes from the latest enumeration of each class
local function latest_enumeration(mem, class)
  local list = mem.artifacts[class] or {}
  local best_turn = -1
  for _, a in ipairs(list) do if a.turn > best_turn then best_turn = a.turn end end
  local out = {}
  for _, a in ipairs(list) do if a.turn == best_turn then out[#out + 1] = a end end
  table.sort(out, function(a, b) return (a.ordinal or 0) < (b.ordinal or 0) end)
  return out
end

function View:resolve_artifact(r, classes)
  local mem = self.mem
  local lex = self.lex
  local reasons, found, tried = {}, {}, {}
  for class in pairs(classes) do
    if mem.artifacts[class] then
      tried[#tried + 1] = class
      local enum = latest_enumeration(mem, class)
      if r.ordinal then
        for _, a in ipairs(enum) do if a.ordinal == r.ordinal then found[#found + 1] = a; reasons[#reasons + 1] = "ordinal " .. r.ordinal .. " of the latest enumeration of '" .. class .. "' (turn " .. a.turn .. ")" end end
      else
        local kind, word = label_kind(lex, r)
        if kind == "latest" and #enum > 0 then found[#found + 1] = enum[#enum]; reasons[#reasons + 1] = "'" .. word .. "' selects the most recent '" .. class .. "'"
        elseif kind == "first" and #enum > 0 then found[#found + 1] = enum[1]; reasons[#reasons + 1] = "'" .. word .. "' selects the earliest '" .. class .. "'"
        elseif kind == "previous" and #enum > 1 then found[#found + 1] = enum[#enum - 1]; reasons[#reasons + 1] = "'" .. word .. "' selects the one before the latest '" .. class .. "'"
        end
      end
    end
  end
  return found, reasons, tried
end

-- corrections / standing instructions made by the user earlier (superseded ones are kept: they are still "the correction I made")
function View:resolve_correction(r, interp)
  local mem = self.mem
  local cands = {}
  for i = #mem.order, 1, -1 do
    local it = mem.items[mem.order[i]]
    if it and it.speaker == "user" and (it.kind == "correction" or it.kind == "instruction" or it.kind == "prohibition" or it.kind == "preference") and it.turn < mem.turn
      and it.status ~= "revoked" then
      cands[#cands + 1] = it
    end
  end
  local only_corr = {}
  for _, it in ipairs(cands) do if it.kind == "correction" then only_corr[#only_corr + 1] = it end end
  if (r.head == "correction" or r.head == "corrections" or r.head == "amendment") then cands = only_corr end
  return cands
end

function View:describe_item(it)
  return { key = "memory:" .. it.id, text = it.text, type = "memory:" .. it.kind, turn = it.turn, item = it.id, slot = it.slot, value = it.value,
    status = it.status, via = "memory_item" }
end

-- entity referred to by a definite description with a discourse-linked relative clause
function View:resolve_entity_backref(r, expected, exclude)
  local mem, lex, W = self.mem, self.lex, C.W
  local cands, rejected = {}, {}
  local order = {}
  for _, e in pairs(mem.entities) do order[#order + 1] = e end
  table.sort(order, function(a, b) if (a.last_seq or 0) ~= (b.last_seq or 0) then return (a.last_seq or 0) > (b.last_seq or 0) end return a.key < b.key end)
  for rank, e in ipairs(order) do
    if exclude[e.key] then
      rejected[#rejected + 1] = { id = e.key, reason = "argument of the same request" }
    else
      local fit = (expected and e.type) and lex:compat(e.type, expected) or 0.25
      local rtype = r.type
      if rtype and e.type then
        local f2 = lex:compat(e.type, rtype)
        if f2 < fit then fit = f2 end
      end
      if fit == -1.0 then rejected[#rejected + 1] = { id = e.key, reason = "type " .. tostring(e.type) .. " cannot be the described " .. tostring(r.type or expected) }
      elseif e.first_turn >= mem.turn and (e.last_turn or 0) >= mem.turn and #e.mentions <= 1 then
        rejected[#rejected + 1] = { id = e.key, reason = "mentioned only in the current request, not earlier" }
      else
        local reasons = {}
        local s = 0.6 * fit; reasons[#reasons + 1] = string.format("type fit %.2f", fit)
        local rec = W.recency / rank; s = s + rec; reasons[#reasons + 1] = string.format("recency rank %d", rank)
        local sal = math.min(1, mem:salience(e)); s = s + 0.5 * sal; reasons[#reasons + 1] = string.format("salience %.2f", sal)
        if e.by_user then s = s + 0.4; reasons[#reasons + 1] = "mentioned by the user (\"I mentioned\")" end
        cands[#cands + 1] = { id = e.key, type = e.type, name = e.names and next(e.names) and select(2, next(e.names)) or e.key, score = s, reasons = reasons, turn = e.last_turn }
      end
    end
  end
  table.sort(cands, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.id < b.id end)
  if #cands > 0 then
    local ps = softmax(U.map(cands, function(c) return c.score end), W.temperature)
    for i, c in ipairs(cands) do c.p = ps[i] end
  end
  return cands, rejected
end

-- resolve every context-dependent reference of one interpretation.  Returns {references = {...}, by_text = {...}, unresolved = {...}}
function C.resolve_references(view, interp)
  local mem, lex = view.mem, view.lex
  local out = { references = {}, by_text = {}, unresolved = {} }
  local exclude = {}
  C.walk(interp, function(r)
    local k = r.antecedent and r.antecedent.key or r.resolved_id
    if k and not r.backref and not r.pronoun then exclude[k] = true end
  end)
  local n = 0
  local function add(rec)
    n = n + 1
    rec.id = "ref" .. n
    out.references[#out.references + 1] = rec
    out.by_text[rec.mention] = rec
    if rec.status ~= "resolved" then out.unresolved[#out.unresolved + 1] = { reference = rec.id, mention = rec.mention, kind = rec.kind, requirement = rec.requirement } end
  end
  C.walk(interp, function(r, role, expected)
    if r.asked then return end
    local classes = r.head and lex:refclasses(r.head) or {}
    local artifact_classes, corr = {}, false
    for c in pairs(classes) do
      if c == "correction" then corr = true else artifact_classes[c] = true end
    end
    local rec
    if r.pronoun then
      if r.deictic then return end
      local st = r.status
      rec = { kind = "pronoun", mention = r.text, role = role, status = (st == "resolved") and "resolved" or (st == "ambiguous" and "ambiguous" or "unresolved"),
        antecedent = r.antecedent, candidates = r.candidates, pronoun = r.pronoun }
      if rec.status == "resolved" then rec.distance_turns = r.antecedent and r.antecedent.distance_turns or 0
      elseif rec.status == "ambiguous" then rec.requirement = "the pronoun '" .. r.pronoun .. "' has several plausible antecedents; clarification or more context is needed"
      else rec.requirement = "no antecedent for '" .. r.pronoun .. "' is available in the context" end
    elseif r.ordinal and next(artifact_classes) and not r.asked then
      local found, reasons, tried = view:resolve_artifact(r, artifact_classes)
      rec = { kind = "ordinal_artifact", mention = r.text, role = role, ordinal = r.ordinal, reasons = reasons }
      if #found == 1 then
        rec.status, rec.antecedent = "resolved", artifact_summary(found[1])
        rec.distance_turns = mem.turn - found[1].turn
        r.status, r.antecedent = "resolved", rec.antecedent
      elseif #found > 1 then
        rec.status = "ambiguous"; rec.candidates = U.map(found, artifact_summary)
        rec.requirement = "several artifacts match '" .. r.text .. "'"
      else
        rec.status = "unresolved"
        rec.requirement = #tried > 0 and ("the conversation holds no " .. r.ordinal .. (r.ordinal == 1 and "st" or r.ordinal == 2 and "nd" or r.ordinal == 3 and "rd" or "th") .. " " .. tried[1])
          or ("no enumerated " .. (next(artifact_classes)) .. " exists in the conversation")
      end
    elseif corr and (r.backref or r.det == "my" or r.possessor) then
      local items = view:resolve_correction(r, interp)
      rec = { kind = "correction_ref", mention = r.text, role = role }
      if #items == 1 then
        rec.status, rec.antecedent = "resolved", view:describe_item(items[1])
        rec.distance_turns = mem.turn - items[1].turn
        r.status, r.antecedent = "resolved", rec.antecedent
      elseif #items > 1 then
        -- the most recent correction is the default reading of "the correction I made"; the others stay visible as alternatives
        rec.status = "ambiguous"
        rec.candidates = U.map({ table.unpack(items, 1, math.min(#items, 4)) }, function(it) return view:describe_item(it) end)
        rec.requirement = #items .. " earlier user corrections/instructions exist; the one meant by '" .. r.text .. "' is not determined by the text"
      else
        rec.status = "unresolved"
        rec.requirement = "no earlier correction by the user exists in the conversation (none is invented)"
      end
    elseif next(artifact_classes) and (label_kind(lex, r) or r.backref) then
      local found, reasons, tried = view:resolve_artifact(r, artifact_classes)
      rec = { kind = "label_artifact", mention = r.text, role = role, reasons = reasons }
      if #found == 1 then
        rec.status, rec.antecedent = "resolved", artifact_summary(found[1])
        rec.distance_turns = mem.turn - found[1].turn
        r.status, r.antecedent = "resolved", rec.antecedent
      elseif #found > 1 then
        rec.status = "ambiguous"; rec.candidates = U.map(found, artifact_summary)
        rec.requirement = "several artifacts match '" .. r.text .. "'"
      else
        rec.status = "unresolved"
        rec.requirement = "no " .. (next(artifact_classes)) .. " matching '" .. r.text .. "' exists in the conversation"
      end
    elseif r.backref then
      local cands, rejected = view:resolve_entity_backref(r, expected, exclude)
      rec = { kind = "entity_backref", mention = r.text, role = role, rejected = U.map(rejected, function(x) return { id = x.id, reason = x.reason } end) }
      if #cands == 0 then
        rec.status = "unresolved"
        rec.requirement = "'" .. r.text .. "' refers to something mentioned earlier, but no suitable entity exists in the conversation"
      else
        rec.candidates = U.map(cands, function(c) return { id = c.id, type = c.type, name = c.name, p = c.p, score = c.score, reasons = c.reasons, turn = c.turn } end)
        local top = cands[1]
        local margin = top.p - (cands[2] and cands[2].p or 0)
        if #cands == 1 or (top.p >= C.W.resolve_p and margin >= C.W.resolve_margin) then
          rec.status = "resolved"
          rec.antecedent = { key = top.id, text = top.name, type = top.type, turn = top.turn, distance_turns = mem.turn - (top.turn or mem.turn), via = "backreference", p = top.p }
          rec.distance_turns = rec.antecedent.distance_turns
          r.status, r.antecedent, r.resolved_id = "resolved", rec.antecedent, top.id
          if top.type and not r.type then r.type = top.type end
        else
          rec.status = "ambiguous"
          rec.requirement = "several earlier entities fit '" .. r.text .. "'; the intended one is not determined"
        end
      end
    end
    if rec then add(rec) end
  end)
  -- comparison sets: "Which one is older?", "both", "the latter" with no explicit items
  if interp.intent == "comparison" and (not interp.items or #interp.items < 2) then
    local cs = mem.comparison
    local rec = { kind = "comparison_set", mention = interp.sentence and interp.sentence.text or "", role = "items" }
    if cs and #cs.keys >= 2 then
      rec.status = "resolved"
      rec.antecedent = { key = "group:" .. table.concat(cs.keys, "+"), group = cs.keys, turn = cs.turn, via = "comparison", dimension = cs.dimension }
      rec.distance_turns = mem.turn - cs.turn
      rec.items = {}
      for _, k in ipairs(cs.keys) do
        local e = mem.entities[k]
        rec.items[#rec.items + 1] = { key = k, type = e and e.type, text = e and select(2, next(e.names or {})) or k }
      end
    else
      rec.status = "unresolved"
      rec.requirement = "the items to compare are not stated and no earlier comparison set exists"
    end
    add(rec)
  end
  return out
end

return C
