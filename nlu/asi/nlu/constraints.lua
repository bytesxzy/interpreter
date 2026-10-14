-- asi.nlu.constraints: negation / exclusion / preference / restriction scopes + temporal, geographic and source constraints.
--   1. find_segments  : cue-led clauses ("not X", "excluding X", "prioritize X", "only using X") with STRUCTURAL extents
--   2. parse_segments : each segment is parsed on its own into a typed constraint (before any masking)
--   3. mask           : segment chunks are hidden from the positive frames, so negative scope cannot leak into the positive reading
--   4. attach         : leftover chunks of the chosen frame become temporal / geographic / source constraints
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local F = require("asi.nlu.frames2")

local cat = P.cat
local Cons = {}
local function C(S, k) return S.chunks[k] end

local function other(role) return role == "to" and "from" or "to" end

---------------------------------------------------------------- segment detection
local function verb_start(S, k)
  local c = C(S, k)
  if not c or not c.single then return false end
  for _, a in ipairs(P.verb_analyses(S, c)) do if a.form == "base" and a.act and not a.guessed then return true end end
  return false
end

-- returns kind, number-of-cue-chunks, cue text
-- negated inclusion / want: "Don't include X", "Never list X", "I'd rather you didn't show X", "I don't want any X" -> an exclusion cue of 2-4 chunks
local NEG_WANT = U.set({ "want", "need", "like" })
local function negated_inclusion(S, k)
  local c = C(S, k)
  if not (c and c.single) then return nil end
  local j
  if c.unit.form == "never" then j = k + 1
  elseif cat(c, "aux_do") or cat(c, "modal") or cat(c, "aux_have") then
    local n = C(S, k + 1)
    if n and n.single and P.is_neg(n) then j = k + 2 end
  end
  if not j then return nil end
  local v = C(S, j)
  if not (v and v.single and not v.masked) then return nil end
  -- "don't BOTHER including X" / "don't bother to include X"
  local bother = 0
  if v.unit.form == "bother" then
    bother = 1
    local t = C(S, j + 1)
    if t and t.single and t.unit.form == "to" then bother = 2 end
    v = C(S, j + bother)
    if not (v and v.single and not v.masked) then return nil end
  end
  for _, a in ipairs(P.verb_analyses(S, v)) do
    if (a.form == "base" or (bother > 0 and a.form == "ing")) and not a.guessed and (a.act == "include" or a.act == "retrieve" or a.act == "constraint" or NEG_WANT[a.lemma]) then return j - k + 1 + bother end
  end
  return nil
end

local STYLE_PREV = U.set({ "answer", "answers", "respond", "responds", "reply", "replies", "speak", "speaks", "write", "writes", "talk", "talks", "format", "express", "phrase", "explain", "summarize", "summarise" })
local function seg_start(S, k)
  local c = C(S, k)
  if not c or c.masked then return nil end
  local lex, units = S.lex, S.units
  do
    local nv = negated_inclusion(S, k)
    if nv then return "exclusion", nv, S.an.original:sub(units[c.u1].s, units[C(S, k + nv - 1).u2].e) end
  end
  local n = lex:cue_at("exclusion", units, c.u1)
  if n then
    -- count chunks covered by n units
    local cnt, consumed = 0, 0
    while C(S, k + cnt) and consumed < n do consumed = consumed + (C(S, k + cnt).u2 - C(S, k + cnt).u1 + 1); cnt = cnt + 1 end
    -- "without"/"except" inside an NP are still exclusions of the following NP; but "excluding" etc. need a body
    return "exclusion", cnt, S.an.original:sub(units[c.u1].s, units[C(S, k + cnt - 1).u2].e)
  end
  n = lex:cue_at("preference", units, c.u1)
  if n then
    local cnt, consumed = 0, 0
    while C(S, k + cnt) and consumed < n do consumed = consumed + (C(S, k + cnt).u2 - C(S, k + cnt).u1 + 1); cnt = cnt + 1 end
    -- "especially"/"just" style adverbs are weak; require something nominal to follow
    return "preference", cnt, S.an.original:sub(units[c.u1].s, units[C(S, k + cnt - 1).u2].e)
  end
  -- restriction: "only using", "only from", "based only on", "limited to", "restricted to"
  local rn = lex:cue_at("restriction", units, c.u1)
  -- "Answer ONLY IN French": after a verb of communication the restriction is a manner (a style instruction), not a restriction on the evidence
  local pv = C(S, k - 1)
  if rn and pv and pv.single and not pv.masked and not pv.pre and STYLE_PREV[pv.unit.form] then rn = nil end
  if rn then
    local nxt = C(S, k + 1)
    if nxt and nxt.single and (nxt.unit.form == "using" or nxt.unit.form == "from" or nxt.unit.form == "in" or nxt.unit.form == "on" or nxt.unit.form == "with") then
      return "restriction", 2, S.an.original:sub(units[c.u1].s, units[nxt.u2].e)
    end
    if c.single and (c.unit.form == "limited" or c.unit.form == "restricted") and nxt and nxt.single and nxt.unit.form == "to" then
      return "restriction", 2, S.an.original:sub(units[c.u1].s, units[nxt.u2].e)
    end
  end
  -- constituent negation:  ", not X"  "but not X"  sentence-initial "not X"  "no X"
  if c.single and c.unit.form == "not" and not c.unit.neg_clitic then
    local nxt = C(S, k + 1)
    local prev = C(S, k - 1)
    if nxt and nxt.single and nxt.unit.form == "only" then return nil end
    local boundary = (k == S.first) or c.pre or (prev and prev.single and cat(prev, "conj") and (prev.unit.form == "but" or prev.unit.form == "and" or prev.unit.form == "or"))
    local verbal = prev and prev.single and (cat(prev, "aux_be") or cat(prev, "aux_do") or cat(prev, "aux_have") or cat(prev, "modal"))
    if boundary and not verbal and nxt then return "exclusion", 1, "not" end
  end
  if c.single and c.unit.form == "no" then
    local nxt = C(S, k + 1)
    local prev = C(S, k - 1)
    if nxt and not nxt.pre and not (k == S.first and nxt.pre) then
      local interjection = (k == S.first) and nxt.pre ~= nil
      local prep_before = prev and prev.single and (cat(prev, "prep") or cat(prev, "conj"))
      local verb_before = prev and verb_start(S, k - 1)
      if not interjection and (k == S.first or c.pre or prep_before or verb_before) and nxt.single == false or (nxt and nxt.single and not cat(nxt, "punct")) then
        if not interjection then return "exclusion", 1, "no" end
      end
    end
  end
  return nil
end

local function starts_new_clause(S, k)
  local c = C(S, k)
  if not c then return true end
  if c.single and cat(c, "conj") and (c.unit.form == "and" or c.unit.form == "or" or c.unit.form == "but") then
    local n = C(S, k + 1)
    if not n then return true end
    return seg_start(S, k + 1) ~= nil or verb_start(S, k + 1)
  end
  if seg_start(S, k) then return true end
  if verb_start(S, k) then return true end
  if c.single and c.unit.form == "but" then return true end
  return false
end

local function seg_end(S, body_first)
  local e = body_first - 1
  local k = body_first
  while k <= S.last do
    local c = C(S, k)
    if c.masked then break end
    if k > body_first then
      local pre = c.pre
      if pre and (pre:find("sent") or pre:find("semi") or pre:find("colon") or pre:find("paren")) then break end
      if pre and pre:find("comma") and starts_new_clause(S, k) then break end
      if c.single and c.unit.form == "but" then break end
      if c.single and cat(c, "conj") and (c.unit.form == "and" or c.unit.form == "or") and starts_new_clause(S, k) then break end
      if not (pre and pre:find("comma")) and seg_start(S, k) then break end
    end
    e = k
    k = k + 1
  end
  return e
end

-- cues whose body is a noun phrase (or a coordinated list of them) and nothing more: "countries OTHER THAN Switzerland use the franc" ends the body at "Switzerland"
local NP_SCOPED = U.set({ "other than", "besides", "apart from", "aside from", "except", "excepting", "except for", "save for", "excluding", "barring", "not including", "outside", "outside of", "bar" })
local RELATIVIZERS = U.set({ "that", "who", "which", "whose", "whom" })
local function np_chain_end(S, k)
  local nps = P.parse_np(S, k)
  if #nps == 0 then return nil end
  -- a verb inside the noun phrase ("Pellucid Freight SERVE Hamburg") means the phrase has run into the clause that follows it
  local function verbish(np)
    local function bad(c)
      return c and (c.copula_like or (c.cats and (c.cats.copula_like or c.cats.aux_be or c.cats.aux_do or c.cats.aux_have or c.cats.modal))
        or (c.verbs and #c.verbs > 0 and #c.senses == 0 and #c.entities == 0 and #c.relnouns == 0)) or false
    end
    for _, m in ipairs(np.mods or {}) do if bad(m.chunk) then return true end end
    return np.head and np.head.single and bad(np.head) or false
  end
  local best
  for _, np in ipairs(nps) do
    if not verbish(np) and (not best or np.score > best.score) then best = np end
  end
  if not best then return nil end
  local e = best.c2
  for _ = 1, 8 do
    local nx = C(S, e + 1)
    if not nx or nx.masked then break end
    if nx.single and cat(nx, "conj") and (nx.unit.form == "and" or nx.unit.form == "or" or nx.unit.form == "nor") then
      local n2 = P.parse_np(S, e + 2)
      if #n2 > 0 then e = n2[1].c2 else break end
    elseif nx.pre and nx.pre:find("comma") then
      local n2 = P.parse_np(S, e + 1)
      if #n2 > 0 and not (n2[1].head_kind == "pronoun") then
        local after = C(S, n2[1].c2 + 1)
        if after and ((after.single and cat(after, "conj") and (after.unit.form == "and" or after.unit.form == "or")) or (after.pre and after.pre:find("comma"))) then e = n2[1].c2 else break end
      else break end
    else break end
  end
  local after = C(S, e + 1)
  if after and after.single and RELATIVIZERS[after.unit.form] then return nil end    -- "excluding those that hire interns": the relative clause belongs to the body
  return e
end

-- "Which countries OTHER THAN SWITZERLAND use the franc?": a noun-phrase-internal exclusion sits between the wh-phrase and its verb.  Its chunks move to the end of
-- the sentence (unit offsets untouched), so the clause around it reads as if the exclusion were absent.
local function relocate_inner_segments(S, segs)
  for si = #segs, 1, -1 do
    local sg = segs[si]
    local nx = C(S, sg.b + 1)
    if sg.kind == "exclusion" and sg.cue and NP_SCOPED[sg.cue:lower()] and nx and not nx.pre and not (nx.single and cat(nx, "conj")) and sg.b < S.last and sg.a > S.first then
      local len = sg.b - sg.a + 1
      local new = {}
      for i = 1, sg.a - 1 do new[#new + 1] = S.chunks[i] end
      for i = sg.b + 1, #S.chunks do new[#new + 1] = S.chunks[i] end
      for i = sg.a, sg.b do new[#new + 1] = S.chunks[i] end
      for i, ch in ipairs(new) do ch.idx = i end
      S.chunks = new
      for sj, o in ipairs(segs) do
        if sj ~= si and o.a > sg.b then o.a, o.b, o.body_first, o.body_last = o.a - len, o.b - len, o.body_first - len, o.body_last - len end
      end
      local total = #new
      sg.a, sg.b, sg.body_first, sg.body_last = total - len + 1, total, sg.body_first + (total - len + 1 - sg.a), sg.body_last + (total - len + 1 - sg.a)
      S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
    end
  end
end

function Cons.find_segments(S)
  local segs = {}
  local k = S.first
  while k <= S.last do
    local kind, ncue, cue = seg_start(S, k)
    if kind then
      local body_first = k + ncue
      local e = seg_end(S, body_first)
      if kind == "exclusion" and cue and NP_SCOPED[cue:lower()] and e >= body_first then
        local ne = np_chain_end(S, body_first)
        if ne and ne < e then e = ne end
      end
      if e >= body_first then
        segs[#segs + 1] = { kind = kind, cue = cue, a = k, b = e, body_first = body_first, body_last = e }
        k = e + 1
      else k = k + 1 end
    else k = k + 1 end
  end
  relocate_inner_segments(S, segs)
  return segs
end

function Cons.apply_masks(S, segs)
  for _, sg in ipairs(segs) do
    for i = sg.a, sg.b do S.chunks[i].masked = true; S.chunks[i].mask_kind = sg.kind end
  end
  S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
end

function Cons.clear_masks(S)
  for _, c in ipairs(S.chunks) do c.masked = nil; c.mask_kind = nil end
  S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
end

---------------------------------------------------------------- segment bodies -> typed constraints
local JOINERS = U.set({ "and", "or", "nor" })

local function describe_target(S, np)
  local t = { text = P.span_text(S, np), head_kind = np.head_kind }
  if np.head_kind == "typenoun" then
    t.scope, t.type = "type", np.senses and np.senses[1] and np.senses[1].type
    t.plural = np.plural
  elseif np.head_kind == "entity" then
    t.scope = "entity"; t.cands = np.cands
  elseif np.head_kind == "pronoun" then
    t.scope = "reference"; t.pron = np.pron and np.pron.form
  elseif np.head_kind == "relnoun" then
    t.scope = "role"; t.rel = np.relnouns and np.relnouns[1] and np.relnouns[1].rel
  else
    t.scope = "topic"
  end
  if np.superlative then t.superlative = np.superlative; t.scope = "description" end -- "the largest city": a description, not a type
  if np.count then t.count = np.count end
  if np.temporal_scope then t.temporal_scope = np.temporal_scope end
  if np.of_arg then t.of = describe_target(S, np.of_arg) end
  if np.possessor then t.possessor = describe_target(S, np.possessor) end
  t.np = np
  return t
end

local function parse_items(S, first, last)
  local items, unparsed = {}, {}
  local k = first
  while k <= last do
    local c = C(S, k)
    if c.single and (JOINERS[c.unit.form] or false) and k > first then k = k + 1
    elseif c.pre and (c.pre:find("comma")) and k > first and not C(S, k).single and false then k = k + 1
    else
      local best
      for _, np in ipairs(P.parse_np(S, k)) do
        if np.nxt - 1 <= last and (not best or np.nxt > best.nxt or (np.nxt == best.nxt and np.score > best.score)) then best = np end
      end
      if best then
        local filters, nk = F.parse_filters(S, best.nxt, best, last)
        items[#items + 1] = { np = best, filters = filters, first = k, last = nk - 1 }
        k = nk
      else
        unparsed[#unparsed + 1] = k
        k = k + 1
      end
    end
  end
  return items, unparsed
end

Cons.describe_target = describe_target

function Cons.parse_segments(S, segs)
  local out = { negative = {}, preferences = {}, restrictions = {}, ordering = {}, unparsed = {} }
  for _, sg in ipairs(segs) do
    local items, unparsed = parse_items(S, sg.body_first, sg.body_last)
    for _, u in ipairs(unparsed) do out.unparsed[#out.unparsed + 1] = { chunk = u, seg = sg.kind } end
    for _, it in ipairs(items) do
      local tgt = describe_target(S, it.np)
      tgt.filters = it.filters
      local ent = { cue = sg.cue, kind = sg.kind, target = tgt, scope_chunks = { sg.a, sg.b },
        scope_text = S.an.original:sub(S.units[S.chunks[sg.a].u1].s, S.units[S.chunks[sg.b].u2].e), source_units = { S.chunks[sg.a].u1, S.chunks[sg.b].u2 } }
      if sg.kind == "exclusion" then out.negative[#out.negative + 1] = ent
      elseif sg.kind == "preference" then out.preferences[#out.preferences + 1] = ent
      elseif sg.kind == "restriction" then
        ent.resource = (it.np.head and S.lex:resource(it.np.head.form)) or nil
        if it.np.temporal_mod then ent.label = it.np.temporal_mod.text end
        ent.qualifiers = {}
        for _, m in ipairs(it.np.mods) do ent.qualifiers[#ent.qualifiers + 1] = m.form end
        out.restrictions[#out.restrictions + 1] = ent
      end
    end
    if #items == 0 and (sg.kind == "exclusion") then
      out.unparsed[#out.unparsed + 1] = { chunk = sg.body_first, seg = sg.kind, note = "exclusion cue without a parsable target" }
    end
  end
  return out
end

---------------------------------------------------------------- leftover chunks of the winning frame
local function temporal_constraint(expr, role_override)
  return { kind = expr.kind, text = expr.text, op = expr.op, eff_lo = expr.eff_lo, eff_hi = expr.eff_hi, lo = expr.lo, hi = expr.hi,
    role = role_override or expr.role, scope = expr.scope, precision = expr.precision, relative = expr.relative, resolved = expr.resolved,
    persist = expr.persist, unresolved = expr.unresolved, year = expr.year }
end

local function place_compatible(S, np)
  if np.head_kind ~= "entity" then return false end
  for _, cd in ipairs(np.cands or {}) do
    if cd.unseen or S.lex:compat(cd.type, "place") > 0 or S.lex:compat(cd.type, "organization") > 0 then return true end
  end
  return false
end

function Cons.attach(S, h)
  local cons = h.constraints
  cons.temporal = cons.temporal or {}
  cons.geographic = cons.geographic or {}
  cons.source = cons.source or {}
  cons.ordering = cons.ordering or {}
  cons.quantity = cons.quantity or {}
  local lex = S.lex
  local k = S.first
  local used = h.used
  while k <= S.last do
    local c = C(S, k)
    if not used[k] and not c.masked then
      local handled = false
      -- source phrases: "according to the supplied 2020 dataset", "based on the report", "from the 2020 census"
      local n = lex:cue_at("source_intro", S.units, c.u1)
      if n then
        local cnt, consumed = 0, 0
        while C(S, k + cnt) and consumed < n do consumed = consumed + (C(S, k + cnt).u2 - C(S, k + cnt).u1 + 1); cnt = cnt + 1 end
        for _, np in ipairs(P.parse_np(S, k + cnt)) do
          local canon = np.head and lex:resource(np.head.form)
          if canon then
            local src = { kind = "source", resource = canon, text = P.span_text(S, np), quals = {}, cue = c.text }
            if np.temporal_mod then src.label = np.temporal_mod.text; src.label_year = np.temporal_mod.year end
            for _, m in ipairs(np.mods) do if m.kind == "mod" or m.kind == "ordinal" or m.kind == "superlative" or m.kind == "temporal_adj" then src.quals[#src.quals + 1] = m.form end end
            cons.source[#cons.source + 1] = src
            for i = k, np.c2 do used[i] = true end
            k = np.c2; handled = true
            break
          end
        end
      end
      -- temporal expressions
      if not handled and c.temporal then
        local ex = c.temporal
        if ex.kind == "persist" or ex.persist then
          h.persist = true; used[k] = true; handled = true
        elseif ex.kind == "marker" then
          h.temporal_scope = h.temporal_scope or ex.scope; used[k] = true; handled = true
        elseif ex.kind == "weekday" then used[k] = true; handled = true
        elseif ex.role == "label" then
          -- a year-like label that modifies a resource noun is a source label, not a time scope
          local nx = C(S, k + 1)
          local canon = nx and nx.single and lex:resource(nx.unit.form)
          if canon then
            cons.source[#cons.source + 1] = { kind = "source", resource = canon, label = ex.text, label_year = ex.year, quals = {}, implicit = true }
            used[k] = true; used[k + 1] = true; k = k + 1; handled = true
          else
            cons.temporal[#cons.temporal + 1] = temporal_constraint(ex, "scope"); used[k] = true; handled = true
          end
        else
          cons.temporal[#cons.temporal + 1] = temporal_constraint(ex); used[k] = true; handled = true
          if ex.scope and not h.temporal_scope then h.temporal_scope = ex.scope end
        end
      end
      -- geographic phrases: "in Germany", "near Boston"
      if not handled and c.single and cat(c, "prep") and (c.unit.form == "in" or c.unit.form == "near" or c.unit.form == "around" or c.unit.form == "within" or c.unit.form == "across") then
        for _, np in ipairs(P.parse_np(S, k + 1, { no_of = true })) do
          if place_compatible(S, np) then
            cons.geographic[#cons.geographic + 1] = { prep = c.unit.form, value = np, text = P.span_text(S, np) }
            for i = k, np.c2 do used[i] = true end
            k = np.c2; handled = true
            break
          end
        end
      end
      -- temporal-scope adverbs and marker words  ("currently", "formerly")
      if not handled and c.single and c.unit.temporal_scope then
        h.temporal_scope = h.temporal_scope or c.unit.temporal_scope; used[k] = true
      end
    end
    k = k + 1
  end
end

-- unexplained content chunks (closed-class function words are not "content")
function Cons.unexplained(S, h)
  local out = {}
  -- a clause-suffix reading leaves everything before its first chunk unexplained
  for _, pc in ipairs(S.prefix_chunks or {}) do out[#out + 1] = pc.idx end
  for k = S.first, S.last do
    local c = C(S, k)
    if not c.masked and not h.used[k] and not P.is_function_chunk(S, c) then out[#out + 1] = k end
  end
  return out
end

return Cons
