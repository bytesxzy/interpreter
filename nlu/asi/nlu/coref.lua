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
  plural_mismatch = -0.6, none_personal = 0.15, none_demonstrative = 2.0, temperature = 0.35, resolve_p = 0.60, resolve_margin = 0.30,
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

-- recency rank per entity: mentions within one sentence share a rank (their order is not a recency signal)
local function recency_ranks(mem)
  local keyed, seen = {}, {}
  for key, e in pairs(mem.entities) do
    local lm = e.mentions[#e.mentions]
    local rk = (lm and lm.turn or 0) * 1000 + ((lm and lm.sent) or 0)
    keyed[key] = rk
    seen[rk] = true
  end
  local list = {}
  for rk in pairs(seen) do list[#list + 1] = rk end
  table.sort(list, function(a, b) return a > b end)
  local rank_of = {}
  for i, rk in ipairs(list) do rank_of[rk] = i end
  local out = {}
  for key, rk in pairs(keyed) do out[key] = rank_of[rk] end
  return out
end

---------------------------------------------------------------- agreement
-- returns ok, penalty, reason
-- the type used for agreement: an attested type, or an inferred one that cannot be a supertype of person (an inferred 'agent' says nothing about animacy)
local function effective_type(lex, e)
  if e.type then return e.type end
  local it = e.itype
  if it and (lex:isa(it, "person") or not lex:isa("person", it)) then return it end
  return nil
end
C.effective_type = effective_type

local function agreement(lex, feats, e, form)
  local W = C.W
  local t = effective_type(lex, e)
  local an = tostring(feats.animate or "any")
  local person_like = t and lex:isa(t, "person") or false
  if an == "1" then
    if t and not person_like then return false, 0, "animate pronoun '" .. form .. "' cannot refer to a " .. t end
    if not t and e.pname then return true, W.unknown_animacy * 0.2, "multiword capitalised name without organisation or place cues: probably a person" end
    if not t then return true, W.unknown_animacy, "animacy of the candidate is unknown" end
  elseif an == "0" then
    if person_like then return false, 0, "'" .. form .. "' does not refer to a person (" .. t .. ")" end
    if not t and e.pname then return true, W.unknown_animacy * 1.5, "looks like a person's name; '" .. form .. "' is inanimate" end
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

-- pleonastic "it": weather/ambient verbs ("It rained on the ferry"), ambient adjectives ("It was cold") and extraposition ("It is clear that ...",
-- "It seems to ...") have no antecedent.  Closed word lists live in the lexicon (cue extrapose_* / ambient_adj, verb act=ambient).
local function expletive_it(S, np, h)
  local lex = S.lex
  local P = require("asi.nlu.parse")
  local c1 = np.c1
  local nx = S.chunks[c1 + 1]
  if not nx then return false end
  for _, vp in ipairs(P.parse_vp(S, c1 + 1)) do
    local v = lex.verbs[vp.lemma]
    if v and v.act == "ambient" then return true end
  end
  local function is_cue(name, c) return c and c.single and lex:is_cue(name, c.unit.form) end
  local k = c1 + 1
  local is_be = nx.single and nx.cats and nx.cats.aux_be
  if is_be then k = k + 1 end
  while S.chunks[k] and S.chunks[k].cats and S.chunks[k].cats.adv do k = k + 1 end
  local c = S.chunks[k]
  if is_be and is_cue("ambient_adj", c) then return true end
  if (is_be and is_cue("extrapose_adj", c)) or (not is_be and is_cue("extrapose_verb", nx)) then
    for j = k, math.min(k + 4, #S.chunks) do
      local cj = S.chunks[j]
      if cj and cj.single and lex:is_cue("extrapose_comp", cj.unit.form) then return true end
    end
  end
  return false
end

function View:pronoun_binding(S, ctx, np, expected, h, role, b)
  local mem, lex, W = self.mem, self.lex, C.W
  local feats = np.pron.feats or {}
  local form = np.pron.form:lower()
  b.discourse, b.pronoun = true, form
  -- indefinites ("someone", "everything") are not anaphors; pleonastic "it" has no antecedent
  local pcats = np.pron.cats or {}
  if pcats.pron_indef and form ~= "one" and form ~= "ones" then b.status, b.fit, b.indefinite = "indefinite", 0.25, true return b end
  if form == "it" and expletive_it(S, np, h) then b.status, b.fit, b.expletive = "expletive", 0.25, true return b end
  -- a fronted topic ("Going back to X, who acquired it?") is the antecedent of the third-person pronouns of the sentence; the topic phrase is resolved in resolve_references
  if S.topic and (form == "it" or form == "its" or form == "they" or form == "their" or form == "them" or form == "he" or form == "she" or form == "his" or form == "her" or form == "him") then
    b.status, b.fit, b.topic_bound, b.cands = "topic_pending", 0.25, true, {}
    return b
  end
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
  local ranks = recency_ranks(mem)
  local order = {}
  for _, e in pairs(mem.entities) do order[#order + 1] = e end
  table.sort(order, function(a, c) if ranks[a.key] ~= ranks[c.key] then return ranks[a.key] < ranks[c.key] end return a.key < c.key end)
  local live, rejected = {}, {}
  for _, e in ipairs(order) do
    local key = e.key
    local rank = ranks[key]
    if exclude[key] then
      rejected[#rejected + 1] = { id = key, type = e.type, reasons = { "co-argument of the same predicate: a non-reflexive pronoun cannot corefer with it" } }
    else
      local ok, pen, why = agreement(lex, feats, e, form)
      if not ok then rejected[#rejected + 1] = { id = key, type = e.type, reasons = { why } }
      else
        local et = effective_type(lex, e)
        local fit = (expected and et) and lex:compat(et, expected) or 0.25
        if fit == -1.0 then
          rejected[#rejected + 1] = { id = key, type = et, reasons = { "type " .. tostring(et) .. " cannot fill " .. tostring(expected) } }
        else
          local reasons = {}
          local sal = math.min(1, mem:salience(e)) * (e.weak and 0.4 or 1)
          local s = W.salience * sal
          reasons[#reasons + 1] = string.format("salience %.2f%s", sal, e.weak and " (weak: capitalisation is the only name evidence)" or "")
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
  for _, k in ipairs({ "topic", "subject", "concept", "target", "focus", "object", "basis" }) do visit(interp[k], k, nil, 0) end
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
  local kind_evidence = false -- some candidate is known (by type or by the conversation's own description) to be the kind the head noun names
  local ranks = recency_ranks(mem)
  local order = {}
  for _, e in pairs(mem.entities) do order[#order + 1] = e end
  table.sort(order, function(a, b) if ranks[a.key] ~= ranks[b.key] then return ranks[a.key] < ranks[b.key] end return a.key < b.key end)
  for _, e in ipairs(order) do
    local rank = ranks[e.key]
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
        local who = r.backref_who
        if who and e.by_speaker and e.by_speaker[who] then s = s + 0.4; reasons[#reasons + 1] = "introduced by the " .. who .. " (the clause says so)"
        elseif who and e.by_speaker and not e.by_speaker[who] then s = s - 0.5; reasons[#reasons + 1] = "never mentioned by the " .. who end
        if r.head then
          local best = 0
          for _, d in pairs(e.descriptors or {}) do best = math.max(best, C.descriptor_match(self, r.head, d)) end
          if best > 0 then s = s + 1.2 * best; reasons[#reasons + 1] = string.format("described in the conversation as a matching kind of '%s' (%.1f)", r.head, best) end
          -- modifiers of the reference ("the SMALL company") that the description of the entity repeats
          if best > 0 and r.modifiers then
            for _, d in pairs(e.descriptors or {}) do
              if C.descriptor_match(self, r.head, d) > 0 then
                local dt = " " .. (d.text or ""):lower() .. " "
                for _, m in ipairs(r.modifiers) do
                  local w = (m.text or ""):lower()
                  if w ~= "" and dt:find(" " .. w .. " ", 1, true) then s = s + 0.5; reasons[#reasons + 1] = "its description repeats '" .. w .. "'"; break end
                end
                break
              end
            end
          end
          -- the head noun names a KIND ("the company ..."): a candidate with no evidence at all of being that kind (no matching type, no matching description)
          -- is a poor referent, however recently it was named
          local head_type
          for _, sn in ipairs(lex.sense_by_head[(r.head or ""):lower()] or {}) do if sn.type and sn.kind == "typenoun" then head_type = head_type or sn.type end end
          if head_type then
            local type_ok = e.type and lex:compat(e.type, head_type) >= 0.5
            if type_ok or best > 0 then kind_evidence = true end
            if not type_ok and best == 0 then s = s - 1.0; reasons[#reasons + 1] = "no evidence that it is a " .. r.head end
          end
        end
        if e.weak then s = s - 0.8; reasons[#reasons + 1] = "weak name evidence (sentence-initial capital only)" end
        cands[#cands + 1] = { id = e.key, type = e.type, name = e.names and next(e.names) and select(2, next(e.names)) or e.key, score = s, reasons = reasons, turn = e.last_turn }
      end
    end
  end
  -- an entity whose only evidence is a sentence-initial capital is a candidate of last resort, never a competitor of an established one
  local strong = {}
  for _, c in ipairs(cands) do if not (mem.entities[c.id] and mem.entities[c.id].weak) then strong[#strong + 1] = c end end
  if #strong > 0 and #strong < #cands then
    for _, c in ipairs(cands) do
      if mem.entities[c.id] and mem.entities[c.id].weak then rejected[#rejected + 1] = { id = c.id, reason = "weak name evidence (sentence-initial capital only) while established entities exist" } end
    end
    cands = strong
  end
  table.sort(cands, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.id < b.id end)
  if #cands > 0 then
    local ps = softmax(U.map(cands, function(c) return c.score end), W.temperature)
    for i, c in ipairs(cands) do c.p = ps[i] end
  end
  -- the head noun names a KIND ("the company ...") but nothing in the conversation says that ANY candidate is one: ranking by recency alone is a guess
  local head_named = false
  if r.head then for _, sn in ipairs(lex.sense_by_head[(r.head or ""):lower()] or {}) do if sn.type and sn.kind == "typenoun" then head_named = true end end end
  cands.kind_unverified = head_named and not kind_evidence and #cands > 1 or nil
  return cands, rejected
end

-- classifying descriptors attached to entity mentions by apposition ("X, a small robotics business") or copula ("X is a robotics company")
-- items = { {key=, c1=, c2=}, ... } chunk ranges of entity mentions in state S
-- the entity/name spans of a sentence state, as {key, type, name, weak, c1, c2} (one key per span; ambiguous spans are skipped)
function C.mentions_from_state(S, text_of)
  local out = {}
  for k, c in ipairs(S.chunks) do
    local ids, name_r, n = {}, nil, 0
    for _, r in ipairs(c.entities) do if not r.fuzzy and r.entry then ids[r.entry.id] = r.entry.etype end end
    for _ in pairs(ids) do n = n + 1 end
    for _, r in ipairs(c.names) do name_r = name_r or r end
    local text = S.an.original:sub(S.units[c.u1].s, S.units[c.u2].e)
    if n == 1 then
      local id, ty = next(ids)
      out[#out + 1] = { key = id, type = ty, name = text, c1 = k, c2 = k }
    elseif n == 0 and name_r and not (c.single and #c.relnouns > 0) then
      out[#out + 1] = { key = "mention:" .. text:lower(), type = name_r.type_guess, name = text, weak = name_r.weak, c1 = k, c2 = k,
        pname = name_r.multiword and not name_r.head_cue and not name_r.type_guess or nil }
    end
  end
  return out
end

local NAMING_BEFORE = { { "called" }, { "named" }, { "dubbed" }, { "known", "as" }, { "by", "the", "name" }, { "by", "the", "name", "of" }, { "goes", "by" }, { "go", "by" }, { "labelled" }, { "labeled" } }

-- determiners that open a classifying noun phrase after a name ("X, a small business", "X, this little company", "X, my new supplier")
local DESCRIPTOR_DET = U.set({ "a", "an", "the", "this", "that", "another", "my", "our", "their", "his", "her", "your", "one" })
-- words that name a NAME, not a kind ("the name he gave me was X"): the kind is then given by the closest earlier noun phrase
local NAME_WORD = U.set({ "name", "names", "brand", "label" })
-- conjunctions that open a new clause: the subject of the introducer of a name starts after them
local SEG_CONJ = U.set({ "and", "but", "so", "because", "since", "while", "although", "though", "whereas", "yet", "or", "if", "when", "then" })

local function chunk_form(S, i)
  local ck = S.chunks[i]
  return ck and ck.single and ck.unit and ck.unit.form or nil
end

-- where does the introducer of the name at chunk k1 begin?  "is X", "was called X", "goes by the name X", "the name he gave me was X" -> index of its first chunk
local function name_introducer(S, k1)
  local q = k1 - 1
  if chunk_form(S, q) == "of" and chunk_form(S, q - 1) == "name" then q = q - 1 end
  if chunk_form(S, q) == "name" and (chunk_form(S, q - 1) == "the" or chunk_form(S, q - 1) == "a") then q = q - 2 end
  local f, ck = chunk_form(S, q), S.chunks[q]
  if not f then return nil end
  local function be(i) local c = S.chunks[i]; return c and c.single and c.cats and c.cats.aux_be == true end
  if be(q) then return q end
  if f == "called" or f == "named" or f == "dubbed" or f == "labelled" or f == "labeled" then return be(q - 1) and q - 1 or q end
  if f == "as" and chunk_form(S, q - 1) == "known" then return be(q - 2) and q - 2 or q - 1 end
  if f == "by" and (chunk_form(S, q - 1) == "go" or chunk_form(S, q - 1) == "goes" or chunk_form(S, q - 1) == "went") then return q - 1 end
  return nil
end

-- the classifying noun phrase that is the subject of the clause ending right before chunk e: first chunk index it may start at -> np
local function classifying_np_in(P, S, b, e, strict)
  local fallback
  for k0 = b, e do
    local c0 = S.chunks[k0]
    if c0 and c0.single and c0.cats and (c0.cats.det or c0.cats.poss_det) then
      for _, np in ipairs(P.parse_np(S, k0)) do
        if np.head and np.nxt <= e + 1 and (np.head_kind == "typenoun" or np.head_kind == "unknown" or np.head_kind == "concept") then
          -- punctuation or a clause-linking conjunction between the noun phrase and the introducer means the noun phrase belongs to a different clause
          -- (a relative clause such as "I'm vetting" or "we might partner with" has neither)
          local crosses = false
          for z = np.nxt, e do
            local cz = S.chunks[z]
            if cz and (cz.pre or (cz.single and SEG_CONJ[cz.unit.form])) then crosses = true end
          end
          if not crosses then
            if np.head_kind == "typenoun" then return np end
            if k0 == b and not fallback then fallback = np end
          end
          break
        end
      end
    end
  end
  return not strict and fallback or nil
end

-- "the small company I'm auditing for work this month IS Brindle Analytics", "the tiny business I'm vetting GOES BY THE NAME X", "a small company we might
-- partner with, and THE NAME he gave me WAS X": a noun phrase that opens the clause classifies the name that completes it
local function describe_by_introducer(P, S, mem, it, speaker)
  local ks = name_introducer(S, it.c1)
  if not ks or ks < 2 then return end
  local e = ks - 1
  local sent = S.chunks[e].sent
  local b, steps = e, 0
  while b >= 1 and steps < 20 do
    local ck = S.chunks[b]
    if ck.sent ~= sent then b = b + 1; break end
    if ck.single and SEG_CONJ[ck.unit.form] and b < e then b = b + 1; break end
    if ck.pre then
      if ck.single and SEG_CONJ[ck.unit.form] and b < e then b = b + 1 end
      break
    end
    b = b - 1; steps = steps + 1
  end
  if b < 1 then b = 1 end
  local np = classifying_np_in(P, S, b, e, false)
  if np and NAME_WORD[np.head.unit and np.head.unit.form or ""] then np = nil; b = b - 1
    -- the subject only names a name: the kind is given by the closest earlier classifying noun phrase of the sentence
    local lo = math.max(1, b - 20)
    for k0 = b, lo, -1 do
      local c0 = S.chunks[k0]
      if c0 and c0.sent ~= sent then break end
      if c0 and c0.single and c0.cats and (c0.cats.det or c0.cats.poss_det) then
        for _, cand in ipairs(P.parse_np(S, k0)) do
          if cand.head_kind == "typenoun" and cand.head and not NAME_WORD[cand.head.unit and cand.head.unit.form or ""] then np = cand; break end
        end
        if np then break end
      end
    end
  end
  if np and np.head and np.head.form then mem:describe(it.key, np.head.form, P.span_text(S, np), speaker) end
end

function C.describe_entities(view, S, items, speaker)
  local P = require("asi.nlu.parse")
  local mem = view.mem
  for _, it in ipairs(items) do
    -- "a small business CALLED X" / "a small firm that goes by the name X" / "this small company, X,": the noun phrase BEFORE the name describes it
    do
      local k1 = it.c1
      local found
      for _, pat in ipairs(NAMING_BEFORE) do
        local ok = true
        for i, w in ipairs(pat) do
          local ck = S.chunks[k1 - #pat + i - 1]
          if not (ck and ck.single and ck.unit.form == w) then ok = false break end
        end
        if ok then found = #pat break end
      end
      local np_end = found and (k1 - found - 1) or nil
      if not np_end then
        -- reversed apposition "this small company, X,": the name opens after a comma and a determined noun phrase ends right before it
        local ce = S.chunks[k1]
        if ce and ce.pre and ce.pre:find("comma") then np_end = k1 - 1 end
      end
      if np_end and np_end >= 1 then
        for k0 = math.max(1, np_end - 6), np_end do
          local c0 = S.chunks[k0]
          local det = c0 and c0.single and c0.cats and (c0.cats.det == true or c0.cats.poss_det == true)
          if det then
            for _, np in ipairs(P.parse_np(S, k0)) do
              if np.nxt == np_end + 1 + (found and found or 0) - (found and found or 0) and (np.head_kind == "typenoun" or np.head_kind == "unknown" or np.head_kind == "concept") and np.head then
                mem:describe(it.key, np.head.form, P.span_text(S, np), speaker)
                goto next_pattern
              end
            end
          end
        end
      end
      ::next_pattern::
    end
    describe_by_introducer(P, S, mem, it, speaker)
    local k = it.c2 + 1
    local c = S.chunks[k]
    -- "X, which is a small business" / "X, who is a founder": skip a relativiser + copula after the comma
    if c and c.pre and c.pre:find("comma") and c.single and (c.unit.form == "which" or c.unit.form == "who" or c.unit.form == "that") then
      local c2 = S.chunks[k + 1]
      if c2 and c2.single and c2.cats and c2.cats.aux_be then k = k + 1; c = S.chunks[k]; c.relcl = true end
    end
    if c then
      local copula = c.single and c.cats and (c.cats.aux_be == true) and (not c.pre or c.relcl)
      local appos = c.pre and c.pre:find("comma") and c.single and c.cats and (c.cats.det == true or c.cats.poss_det == true)
      if copula then k = k + 1; c = S.chunks[k] end
      if c and (copula or appos) then
        local det = c.single and c.cats and (c.cats.det == true or c.cats.poss_det == true) and DESCRIPTOR_DET[c.unit.form]
        if det then
          for _, np in ipairs(P.parse_np(S, k)) do
            if (np.head_kind == "typenoun" or np.head_kind == "unknown" or np.head_kind == "concept") and np.head then
              mem:describe(it.key, np.head.form, P.span_text(S, np), speaker)
              break
            end
          end
        end
      end
    end
  end
end

-- do two head nouns denote the same kind of thing? equal stems, or senses of compatible lexicon types
function C.descriptor_match(view, head, d)
  local Mem = require("asi.nlu.memory")
  if Mem.stem(head) == Mem.stem(d.head) then return 1.0 end
  local lex = view.lex
  local ta, tb
  for _, sn in ipairs(lex.sense_by_head[head] or {}) do ta = ta or sn.type end
  for _, sn in ipairs(lex.sense_by_head[d.head] or {}) do tb = tb or sn.type end
  if ta and tb then
    local ab, ba = lex:compat(ta, tb), lex:compat(tb, ta)
    if ab >= 0.9 and ba >= 0.9 then return 0.7 end
    -- "the organisation I mentioned" may denote what was described as "a company" (the description names a subtype of the reference's kind); the converse is weaker
    if ba >= 0.9 then return 0.6 end
    if ab >= 0.9 then return 0.4 end
  end
  return 0
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
  local handler
  handler = function(r, role, expected)
    if r.asked then return end
    if r.pronoun and r.topic_bound and interp.topic then
      -- the pronoun denotes the fronted topic
      local t = interp.topic
      local ant = t.antecedent or (t.resolved_id and { key = t.resolved_id, text = t.text, type = t.type })
      local trec
      if ant and ant.key and (t.status == "resolved" or t.status == "unseen" or t.resolved_id) then
        r.antecedent = { key = ant.key, text = ant.text, type = ant.type, turn = ant.turn, via = "topic", p = 1.0 }
        r.status, r.resolved_id = "resolved", ant.key
        trec = { kind = "pronoun", mention = r.text, role = role, status = "resolved", antecedent = r.antecedent, pronoun = r.pronoun, distance_turns = 0 }
      else
        trec = { kind = "pronoun", mention = r.text, role = role, status = (t.status == "ambiguous") and "ambiguous" or "unresolved", pronoun = r.pronoun,
          requirement = "the pronoun '" .. tostring(r.pronoun) .. "' refers to the fronted topic '" .. tostring(t.text) .. "', which is itself not resolved" }
      end
      add(trec)
      return
    end
    local classes = r.head and lex:refclasses(r.head) or {}
    local artifact_classes, corr = {}, false
    for c in pairs(classes) do
      if c == "correction" then corr = true else artifact_classes[c] = true end
    end
    local rec
    if r.ordinal_ref then
      rec = { kind = "ordinal_entity", mention = r.text, role = role, ordinal = r.ordinal, status = (r.status == "resolved") and "resolved" or "unresolved", antecedent = r.antecedent }
      if rec.status == "resolved" then rec.distance_turns = mem.turn - (r.antecedent.turn or mem.turn)
      else rec.requirement = "the conversation holds no list with a member number " .. tostring(r.ordinal) end
    elseif r.pronoun then
      if r.deictic or r.non_anaphoric then return end
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
        if #cands == 1 or (top.p >= C.W.resolve_p and margin >= C.W.resolve_margin and not cands.kind_unverified) then
          rec.status = "resolved"
          rec.antecedent = { key = top.id, text = top.name, type = top.type, turn = top.turn, distance_turns = mem.turn - (top.turn or mem.turn), via = "backreference", p = top.p }
          rec.distance_turns = rec.antecedent.distance_turns
          r.status, r.antecedent, r.resolved_id = "resolved", rec.antecedent, top.id
          if top.type and not r.type then r.type = top.type end
        else
          rec.status = "ambiguous"
          rec.requirement = cands.kind_unverified and ("nothing in the conversation says which earlier entity is a " .. tostring(r.head) .. "; the intended one is not determined")
            or ("several earlier entities fit '" .. r.text .. "'; the intended one is not determined")
        end
      end
    end
    if rec then add(rec) end
  end
  local topic_done
  if interp.topic then handler(interp.topic, "topic", nil); topic_done = interp.topic end
  C.walk(interp, function(r, role, expected) if r ~= topic_done then handler(r, role, expected) end end)
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
