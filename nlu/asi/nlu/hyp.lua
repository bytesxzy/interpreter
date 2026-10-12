-- asi.nlu.hyp: competing interpretation hypotheses.
-- Scores are sums of NAMED, bounded factors (so provenance is real: it lists the computations that produced the score).
-- Hard constraints (type clash on a required role) VETO a hypothesis; soft evidence only ranks.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local Cons = require("asi.nlu.constraints")

local H = {}

-- weights are fixed constants; they were only ever adjusted against the DEV split (see reports/)
H.W = {
  type_fit = 1.1,       -- multiplier on compat(-1..1) per bound role
  coverage = 1.6,       -- fraction of content chunks explained
  unexplained = -0.30,  -- per unexplained content chunk
  lex_entity = 0.15,    -- attested entity span used
  lex_mwe = 0.20,       -- attested multiword unit used
  domain = 0.35,
  discourse = 0.30,
  support = 0.25,
  fuzzy = -0.45,
  unseen = -0.05,
  exact_case = 0.15,
  temperature = 0.55,
  entity_temperature = 0.30,
  resolve_p = 0.60, resolve_margin = 0.30,
}

local FRAME_PRIOR = {
  ["wh_copular:relnp"] = 0.12, ["wh_verb:active"] = 0.10, ["wh_do:object_gap"] = 0.10, ["wh_passive:stranded_by"] = 0.10,
  ["request:relnp"] = 0.08, ["request:search"] = 0.05, ["request:entity"] = 0.0, ["request:concept"] = 0.0,
}

local function softmax(scores, T)
  local m = -math.huge
  for _, s in ipairs(scores) do if s > m then m = s end end
  local sum, ex = 0, {}
  for i, s in ipairs(scores) do ex[i] = math.exp((s - m) / T); sum = sum + ex[i] end
  for i = 1, #ex do ex[i] = ex[i] / sum end
  return ex
end
H.softmax = softmax

---------------------------------------------------------------- context domains (see parse.lua: P.domain_hits / P.domain_gain)
-- best domain support among an NP's candidate senses (used to rank typenoun/concept readings such as program.academic vs software)
local function sense_domain(S, ctx, np)
  local best_hits, best_sense = 0, nil
  for _, s in ipairs(np.senses or {}) do
    local h = P.domain_hits(S, ctx, s.domain, np.u1, np.u2)
    if h > best_hits then best_hits, best_sense = h, s end
  end
  return best_hits, best_sense
end
H.sense_domain = sense_domain

---------------------------------------------------------------- binding an NP argument to candidates + types
-- expected: type name (or union) or nil.  Returns bound table and the best type-fit in [-1, 1]
function H.bind_np(S, ctx, np, expected, h, role)
  if np.bound and np.bound_for == expected and (np.head_kind ~= "pronoun" or np.bound_h == h) then return np.bound, np.bound.fit end
  local lex = S.lex
  local W = H.W
  local b = { cands = {}, status = "unresolved", expected = expected }
  if np.head_kind == "entity" then
    local scored = {}
    for _, cd in ipairs(np.cands or {}) do
      local s, reasons = 0, {}
      local ty = cd.type
      local fit
      if cd.unseen then
        s = s + W.unseen
        if ty then fit = lex:compat(ty, expected) else fit = 0.25; reasons[#reasons + 1] = "type inferred from relation signature" end
        reasons[#reasons + 1] = "not in any loaded entity table (open-set mention)"
      else
        fit = lex:compat(ty, expected)
      end
      if ctx.flags and ctx.flags.no_types then fit = 0.25 end
      s = s + 0.6 * fit
      if fit == -1.0 and expected then reasons[#reasons + 1] = "type " .. tostring(ty) .. " incompatible with expected " .. tostring(expected) end
      if cd.exact_case then s = s + W.exact_case; reasons[#reasons + 1] = "exact-case name match" end
      if cd.fuzzy then s = s + W.fuzzy * (1 - cd.fuzzy) - 0.15; reasons[#reasons + 1] = "fuzzy match from '" .. tostring(cd.fuzzy_from) .. "'" end
      if not (ctx.flags and ctx.flags.no_domain) then
        local dh = P.domain_hits(S, ctx, cd.domain, np.u1, np.u2)
        local gain = P.domain_gain(dh)
        if gain > 0 then s = s + gain; reasons[#reasons + 1] = dh .. " domain cue(s) in context" end
      end
      if ctx.mentioned and ctx.mentioned[cd.id] then s = s + W.discourse * ctx.mentioned[cd.id]; reasons[#reasons + 1] = "previously mentioned in the conversation" end
      if ctx.support then
        local n = ctx.support(cd.id) or 0
        if n > 0 then
          s = s + (n >= 3 and 0.6 or 0.3)
          reasons[#reasons + 1] = n .. (cd.unseen and " dataset mention(s)" or " supporting dataset record(s)")
        end
      end
      s = s + 0.1 * ((cd.prior or 0.5) - 0.5)
      scored[#scored + 1] = { id = cd.id, type = ty, name = cd.name, score = s, fit = fit, vetoed = (fit == -1.0 and expected ~= nil),
        reasons = reasons, unseen = cd.unseen, weak = cd.weak, fuzzy = cd.fuzzy, source = cd.source, domain = cd.domain }
    end
    local live = {}
    for _, c in ipairs(scored) do if not c.vetoed then live[#live + 1] = c end end
    table.sort(live, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.id < b.id end)
    local rejected = {}
    for _, c in ipairs(scored) do if c.vetoed then rejected[#rejected + 1] = c end end
    if #live > 0 then
      local ps = softmax(U.map(live, function(c) return c.score end), W.entity_temperature)
      for i, c in ipairs(live) do c.p = ps[i] end
      b.cands = live
      b.top = live[1]
      b.rejected = rejected
      local margin = live[1].p - (live[2] and live[2].p or 0)
      if #live == 1 or (live[1].p >= W.resolve_p and margin >= W.resolve_margin) then
        b.status = live[1].unseen and "unseen" or "resolved"
      else b.status = "ambiguous" end
      b.margin = margin
      b.fit = live[1].fit
    else
      b.rejected = rejected
      b.status = "unresolved"
      b.fit = (#rejected > 0) and -1.0 or 0.25
    end
  elseif np.head_kind == "typenoun" or np.head_kind == "concept" then
    -- rank the NP's senses by domain support; the best one defines the type
    local senses = U.copy(np.senses or {})
    local hits, best = sense_domain(S, ctx, np)
    if best then
      for i, s in ipairs(senses) do if s.id == best.id then table.remove(senses, i); table.insert(senses, 1, s) break end end
      if not (ctx.flags and ctx.flags.no_domain) then b.domain_gain = P.domain_gain(hits) end
    end
    local ty = senses[1] and senses[1].type
    b.type, b.fit = ty, lex:compat(ty, expected)
    if ctx.flags and ctx.flags.no_types then b.fit = 0.25 end
    b.status = "resolved"
    b.senses = senses
    np.senses = senses
  elseif np.head_kind == "relnoun" then
    local e = np.relnouns and np.relnouns[1]
    local rel = e and lex:get_rel(e.rel)
    b.type = rel and rel[e.role] or nil
    b.fit = lex:compat(b.type, expected)
    b.status = "resolved"
  elseif np.head_kind == "var" then
    -- intermediate result of an earlier step of a multi-hop chain: its type comes from that step
    b.type, b.fit, b.status, b.chain_var = np.type, lex:compat(np.type, expected), "resolved", np.var
  elseif np.head_kind == "pronoun" then
    if ctx.discourse and not (ctx.flags and ctx.flags.no_coref) then
      ctx.discourse:pronoun_binding(S, ctx, np, expected, h, role, b)
    else
      b.status, b.fit, b.pending = "pending", 0.25, true
    end
  elseif np.head_kind == "temporal" then b.type, b.fit, b.status = "date", lex:compat("date", expected), "resolved"
  elseif np.head_kind == "number" then b.type, b.fit, b.status = "number", lex:compat("number", expected), "resolved"
  elseif np.head_kind == "quote" or np.head_kind == "literal" then b.type, b.fit, b.status = "text", 0.25, "resolved"
  else
    b.fit, b.status = 0.25, "unknown_term"
  end
  np.bound, np.bound_for, np.bound_h = b, expected, h
  return b, b.fit
end

---------------------------------------------------------------- per-hypothesis finalisation
local function content_chunks(S)
  if S.content_count then return S.content_count end
  local n = 0
  for k = S.first, S.last do
    local c = S.chunks[k]
    if not c.masked and not P.is_function_chunk(S, c) then n = n + 1 end
  end
  S.content_count = n
  return n
end

local function bind_all(S, ctx, h)
  local W = H.W
  local function fit_factor(name, fit, note)
    if fit == nil then return end
    h.factors[#h.factors + 1] = { name = name, v = W.type_fit * fit * 0.5, note = note }
    if fit == -1.0 then h.veto = h.veto or note end
  end
  if h.rel_obj and h.rel_obj.open then
    -- the relation word is not in the lexicon: it is kept under its own name, at a cost, so any lexicon reading of the same words wins
    h.factors[#h.factors + 1] = { name = "open_relation", v = -0.35, note = "relation inferred from a word the lexicon does not know ('" .. tostring(h.rel_obj.id) .. "'); not mapped onto any known relation" }
  end
  if h.rel_obj then
    for _, role in ipairs({ "from", "to" }) do
      local np = h.roles[role]
      if np then
        -- an open relation has no type signature: its arguments are neither rewarded nor vetoed
        local b, fit = H.bind_np(S, ctx, np, (not h.rel_obj.open) and h.rel_obj[role] or nil, h, role)
        local what = (b.top and b.top.name) or P.span_text(S, np)
        if b.status == "unresolved" and fit == -1.0 then
          fit_factor("type_fit:" .. role, -1.0, "'" .. P.span_text(S, np) .. "' cannot be a " .. tostring(h.rel_obj[role]) .. " (role '" .. role .. "' of " .. h.rel_obj.id .. ")")
        else
          fit_factor("type_fit:" .. role, fit, string.format("'%s' as %s of %s (fit %.2f)", what, role, h.rel_obj.id, fit))
        end
        if b.top and b.top.fuzzy then h.factors[#h.factors + 1] = { name = "fuzzy", v = W.fuzzy, note = "entity matched through a spelling variant" } end
      end
    end
    if h.wh_type and h.ask then
      local fit = S.lex:compat(h.wh_type, h.rel_obj[h.ask])
      if ctx.flags and ctx.flags.no_types then fit = 0.25 end
      fit_factor("answer_type_fit", fit, string.format("wh-type '%s' vs %s of %s (fit %.2f)", h.wh_type, h.ask, h.rel_obj.id, fit))
    end
  end
  -- every step of a multi-hop chain is typed against its own relation signature
  for si, st in ipairs(h.chain or {}) do
    local b, fit = H.bind_np(S, ctx, st.known, st.rel_obj[st.known_role], h, "chain" .. si)
    local what = (b.top and b.top.name) or P.span_text(S, st.known)
    fit_factor("chain_fit:" .. si, fit, string.format("step %d: '%s' as %s of %s (fit %.2f)", si, what, st.known_role, st.rel, fit))
  end
  if h.subject then H.bind_np(S, ctx, h.subject, h.expect_type, h, "subject") end
  if h.concept then H.bind_np(S, ctx, h.concept, nil, h, "concept") end
  if h.target then H.bind_np(S, ctx, h.target, nil, h, "target") end
  for _, it in ipairs(h.items or {}) do H.bind_np(S, ctx, it, nil, h, "item") end
  if h.focus then H.bind_np(S, ctx, h.focus, nil, h, "focus") end
  if h.object then H.bind_np(S, ctx, h.object, nil, h, "object") end
  if h.basis then H.bind_np(S, ctx, h.basis.np, nil, h, "basis") end
  if h.statement then
    if h.statement.subj then H.bind_np(S, ctx, h.statement.subj, nil, h, "subject") end
    if h.statement.obj then H.bind_np(S, ctx, h.statement.obj, nil, h, "object") end
  end
  -- sense-level domain evidence for typenoun/concept readings (competing readings of a word such as "program")
  for _, np in ipairs({ h.concept, h.target, h.object, h.focus }) do
    if np and np.bound and np.bound.domain_gain and np.bound.domain_gain > 0 then
      h.factors[#h.factors + 1] = { name = "sense_domain", v = np.bound.domain_gain, note = "context domain supports the chosen sense of '" .. P.span_text(S, np) .. "'" }
    end
  end
  -- unaided fuzzy lexemes (typos of relation words / senses) cost confidence once per chunk
  for k in pairs(h.used) do
    local c = S.chunks[k]
    if c and c.fuzzy and #c.entities == 0 then
      h.factors[#h.factors + 1] = { name = "fuzzy_lexeme", v = W.fuzzy * (1 - c.fuzzy) - 0.15, note = "'" .. tostring(c.fuzzy_from) .. "' matched through a spelling variant" }
    end
  end

end

function H.finalize(S, ctx, h)
  local W = H.W
  local F2 = require("asi.nlu.frames2")
  F2.expand_chain(S, h)   -- turn nested relational NPs / relative clauses into ordered lookup steps
  F2.attach_basis(S, h)   -- "considering X" / "given X" arguments
  Cons.attach(S, h)
  bind_all(S, ctx, h)

  -- lexical attestation of the spans actually used
  local lex_bonus = 0
  for k in pairs(h.used) do
    local c = S.chunks[k]
    if c then
      if c.kind == "entity" and #c.entities > 0 then lex_bonus = lex_bonus + W.lex_entity
      elseif c.kind == "mwe" then lex_bonus = lex_bonus + W.lex_mwe end
    end
  end
  if lex_bonus > 0 then h.factors[#h.factors + 1] = { name = "lexical_attestation", v = lex_bonus, note = "attested multiword/entity spans used" } end

  -- coverage
  local total = math.max(1, content_chunks(S))
  local unexplained = Cons.unexplained(S, h)
  local explained = total - #unexplained
  local cov = explained / total
  h.coverage = cov
  h.unexplained = unexplained
  h.factors[#h.factors + 1] = { name = "coverage", v = W.coverage * cov, note = string.format("%d of %d content chunks explained", explained, total) }
  if #unexplained > 0 then
    h.factors[#h.factors + 1] = { name = "unexplained", v = W.unexplained * #unexplained, note = #unexplained .. " content chunk(s) not accounted for" }
  end
  local prior = FRAME_PRIOR[h.frame]
  if prior then h.factors[#h.factors + 1] = { name = "frame_prior", v = prior, note = "construction prior for " .. h.frame } end
  local s = 0
  for _, f in ipairs(h.factors) do s = s + f.v end
  h.score = s
  return h
end

-- NP objects are shared between competing hypotheses, so np.bound can belong to the last hypothesis finalised.  Rebinding the
-- winner restores its own bindings before anything is rendered or audited; factors added again are discarded (scores unchanged).
function H.rebind(S, ctx, h)
  local n = #h.factors
  local veto = h.veto
  bind_all(S, ctx, h)
  for i = #h.factors, n + 1, -1 do h.factors[i] = nil end
  h.veto = veto
end

---------------------------------------------------------------- selection
local function hyp_signature(S, h)
  local parts = { h.intent or "?", h.op or "?", h.rel or "-", h.ask or "-", h.polarity or "+" }
  for _, role in ipairs({ "from", "to", "subject" }) do
    local np = h.roles[role]
    if np then
      -- resolved entities compare by id; open-set mentions by their normalised text (the same name under two segmentations is one reading)
      local id = np.bound and np.bound.top and np.bound.top.id
      if not id or id:sub(1, 8) == "mention:" then id = P.core_text(S, np) end
      parts[#parts + 1] = role .. "=" .. id
    end
  end
  local obj = h.concept or h.target or h.focus or h.object
  if obj then
    -- same words + same semantic type == same reading, regardless of how the lattice segmented them
    local ty = obj.bound and (obj.bound.type or (obj.bound.senses and obj.bound.senses[1] and obj.bound.senses[1].type))
    parts[#parts + 1] = "obj=" .. P.core_text(S, obj) .. ":" .. tostring(ty)
  end
  for _, it in ipairs(h.items or {}) do parts[#parts + 1] = "item=" .. (it.head and it.head.form or "?") end
  if h.instruction then parts[#parts + 1] = "inst=" .. tostring(h.instruction.verb) .. ":" .. tostring(h.instruction.slot) end
  if h.clause then parts[#parts + 1] = "clause=" .. tostring(h.clause.lemma) end
  if h.statement then parts[#parts + 1] = "stmt=" .. tostring(h.statement.lemma) end
  return table.concat(parts, "|")
end

local function summarize(S, h)
  local function np_text(np) return np and P.span_text(S, np) or nil end
  local t = {}
  if h.rel then t[#t + 1] = h.rel end
  if h.known_role and h.roles[h.known_role] then t[#t + 1] = h.known_role .. "=" .. np_text(h.roles[h.known_role]) end
  if h.ask then t[#t + 1] = "ask=" .. h.ask end
  local obj = h.concept or h.target or h.focus or h.object or h.subject
  if obj then t[#t + 1] = "obj=" .. np_text(obj) end
  return (h.intent or "?") .. ": " .. table.concat(t, " ")
end
H.summarize = summarize

-- ranks finalised hypotheses; returns {ranked, rejected, top, posterior...}
function H.select(S, ctx, hyps)
  local W = H.W
  local live, rejected = {}, {}
  for _, h in ipairs(hyps) do
    if h.veto then rejected[#rejected + 1] = h else live[#live + 1] = h end
  end
  -- merge duplicates by signature, keep the best score and remember the other frames that agreed
  table.sort(live, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (a.frame or "") < (b.frame or "")
  end)
  local merged, seen = {}, {}
  for _, h in ipairs(live) do
    h.sig = hyp_signature(S, h)
    local m = seen[h.sig]
    if m then m.agreeing_frames[#m.agreeing_frames + 1] = h.frame
    else h.agreeing_frames = {}; seen[h.sig] = h; merged[#merged + 1] = h end
  end
  local ps = softmax(U.map(merged, function(h) return h.score end), (ctx.temperature or W.temperature))
  for i, h in ipairs(merged) do h.p = ps[i]; h.summary = summarize(S, h) end
  return { ranked = merged, rejected = rejected }
end

-- ambiguity points between the top hypothesis and its serious competitors + unresolved entity bindings inside the top hypothesis
function H.ambiguity(S, ctx, sel)
  local W = H.W
  local points = {}
  local top = sel.ranked[1]
  if not top then return { state = "unresolvable", points = points } end
  local function np_roles(h)
    local out = {}
    for _, role in ipairs({ "from", "to", "subject" }) do if h.roles[role] then out[role] = h.roles[role] end end
    if h.concept then out.concept = h.concept end
    if h.focus then out.focus = h.focus end
    if h.target then out.target = h.target end
    return out
  end
  -- (1) unresolved entity candidates inside the winning hypothesis
  for role, np in pairs(np_roles(top)) do
    local b = np.bound
    if b and b.status == "ambiguous" then
      local cands = {}
      for _, c in ipairs(b.cands) do if c.p >= 0.08 then cands[#cands + 1] = { id = c.id, type = c.type, p = c.p, reasons = c.reasons } end end
      points[#points + 1] = { id = "entity:" .. P.span_text(S, np), kind = "entity", role = role, mention = P.span_text(S, np), material = true, resolved = false,
        candidates = cands, rejected = U.map(b.rejected or {}, function(r) return { id = r.id, reason = r.reasons[#r.reasons] } end) }
    elseif b and b.status == "resolved" and b.top and #b.cands > 1 then
      points[#points + 1] = { id = "entity:" .. P.span_text(S, np), kind = "entity", role = role, mention = P.span_text(S, np), material = true, resolved = true,
        chosen = b.top.id, candidates = U.map(b.cands, function(c) return { id = c.id, type = c.type, p = c.p } end),
        rejected = U.map(b.rejected or {}, function(r) return { id = r.id, reason = r.reasons[#r.reasons] } end) }
    end
  end
  -- (2) competing hypotheses that differ in relation / intent / sense
  for i = 2, #sel.ranked do
    local alt = sel.ranked[i]
    if alt.p >= 0.12 then
      local kind
      if alt.rel ~= top.rel then kind = "relation"
      elseif alt.intent ~= top.intent then kind = "intent"
      elseif alt.ask ~= top.ask then kind = "role_direction"
      else kind = "sense" end
      points[#points + 1] = { id = "hyp:" .. i, kind = kind, material = true, resolved = (top.p >= W.resolve_p and (top.p - alt.p) >= W.resolve_margin),
        chosen = top.summary, candidates = { { summary = top.summary, p = top.p }, { summary = alt.summary, p = alt.p } } }
    end
  end
  local state = "resolved"
  for _, pt in ipairs(points) do if pt.material and not pt.resolved then state = "ambiguous" end end
  if (top.p < W.resolve_p or (sel.ranked[2] and top.p - sel.ranked[2].p < W.resolve_margin)) and sel.ranked[2] and sel.ranked[2].p >= 0.2 then
    local hasHyp = false
    for _, pt in ipairs(points) do if pt.kind ~= "entity" and not pt.resolved then hasHyp = true end end
    if hasHyp then state = "ambiguous" end
  end
  return { state = state, points = points }
end

return H
