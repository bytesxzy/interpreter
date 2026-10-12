-- asi.nlu.verify: constraint-aware retrieval + SEMANTIC VERIFICATION + evidence sufficiency.
--   stage 1  candidate generation   typed assertion channel (relation, entity)  +  entity mentions  +  phrase-aware BM25F
--   stage 2  semantic verification  every candidate must satisfy: requested entity (identity), relation (id AND direction), answer type, time,
--                                   source constraint, exclusions, modality.  A record that merely mentions the entity, or shares words with
--                                   the question ("capital punishment" for "capital of France"), is NEVER sufficient evidence.
--   stage 3  aggregation            independent support, conflicts (temporal / reliability resolution is explicit), ambiguity across readings,
--                                   and one of: answerable | contradictory | ambiguous | potentially_answerable | insufficient | unsupported
local U = require("asi.nlu.util")
local TU = require("asi.nlu.textutil")

local V = {}
V.STATUS = { "answerable", "potentially_answerable", "ambiguous", "contradictory", "insufficient", "unsupported", "not_applicable" }

V.W = { conflict_gap = 0.30, hedge_weight = 0.5, undated_weight = 0.7, structured_bonus = 0.1, min_strength = 0.4 }

---------------------------------------------------------------- small helpers
local function year_of_key(k) if not k then return nil end return k // 10000 end

local function key_match(desc, variants)
  if not desc then return false end
  for _, v in ipairs(variants) do
    if desc.key == v then return "exact" end
    for _, c in ipairs(desc.cands or {}) do if c.id == v then return "candidate" end end
  end
  return false
end

local function desc_text(d)
  if not d then return "" end
  if d.literal then return d.literal.text end
  return d.text or d.key or ""
end

local function answer_key(kb, d)
  if not d then return nil end
  if d.literal then return "lit:" .. (d.literal.value and tostring(d.literal.value) or d.literal.text:lower()) end
  if d.key then return kb and kb:canonical(d.key) or d.key end
  return "text:" .. (d.text or ""):lower()
end

-- is the relation a "state" (holds over a period) rather than an "event" (happened once)?
local function is_event(kb, rel_id)
  local rel = kb.lex:get_rel(rel_id)
  return rel ~= nil and (rel.when ~= nil or rel.event == true or rel.open == true)
end

local function quote_of(a)
  local t = a.text or ""
  if #t > 320 then t = t:sub(1, 317) .. "..." end
  return t
end

---------------------------------------------------------------- checks
-- time: returns "ok" | "undated" | "past_only" | "mismatch", reason
local function time_check(kb, plan, a, ref_year)
  local req = plan.time or { mode = "current" }
  local ev = is_event(kb, a.rel)
  local lo = a.valid_from or (a.valid_at and a.valid_at.lo) or (a.as_of and a.as_of.lo)
  local hi = a.valid_to or (a.valid_at and a.valid_at.hi) or (a.as_of and a.as_of.hi)
  local dated = lo ~= nil or hi ~= nil
  if req.mode == "current" then
    if ev then return "ok" end                                  -- events do not "end"
    if a.former or a.ended then return "past_only", "the record says this is no longer the case" end
    if a.valid_to and ref_year and year_of_key(a.valid_to) < ref_year then return "past_only", "valid only until " .. tostring(year_of_key(a.valid_to)) end
    if a.tense == "past" and not a.valid_from and not (a.as_of) then return "past_only", "stated in the past tense with no indication that it still holds" end
    return "ok"   -- a present-tense statement is asserted to hold now (as of the record), dated or not
  elseif req.mode == "past_leaning" then
    if ev or a.former or a.ended or a.valid_to or a.tense == "past" then return "ok" end
    return "undated", "a present-tense fact answers a past-tense question only loosely"
  elseif req.mode == "former" then
    if a.former or a.ended or a.valid_to or a.tense == "past" then return "ok" end
    return "mismatch", "the record states a present fact, but a former/historical one was requested"
  elseif req.mode == "at" then
    if not dated then return (ev and "ok") or "undated" end
    local rlo, rhi = req.lo or -math.huge, req.hi or math.huge
    local alo, ahi = lo or -math.huge, hi or math.huge
    if ahi < rlo or alo > rhi then return "mismatch", "the record's validity period does not include the requested time" end
    return "ok"
  elseif req.mode == "after" then
    if not dated then return "undated" end
    if hi and req.lo and hi < req.lo then return "mismatch", "ends before the requested period" end
    return "ok"
  elseif req.mode == "before" then
    if not dated then return "undated" end
    if lo and req.hi and lo > req.hi then return "mismatch", "begins after the requested period" end
    return "ok"
  end
  return "ok"
end

-- source constraint ("the supplied 2020 dataset"): returns "ok" | "unverified" | "mismatch", reason
local function source_check(kb, plan, rec)
  if not plan.sources or #plan.sources == 0 then return "ok" end
  local label = kb:dataset_label_of(rec)
  local verdict, reason = "ok", nil
  for _, s in ipairs(plan.sources) do
    if s.year then
      local have = rec.dataset_year or (label and label.year)
      if have == nil then verdict, reason = "unverified", "the dataset does not declare which year it belongs to"
      elseif have ~= s.year then return "mismatch", string.format("record belongs to the %s dataset, not the requested %s", tostring(have), tostring(s.year)) end
    elseif s.label then
      local have = label and (label.name or label.id)
      if have and not tostring(have):lower():find(tostring(s.label):lower(), 1, true) then
        -- a label we cannot match textually is not proof of mismatch, but it is not verification either
        verdict, reason = "unverified", "the requested source '" .. tostring(s.label) .. "' could not be matched to this dataset's declared label"
      elseif not have then verdict, reason = "unverified", "the dataset declares no label to compare with '" .. tostring(s.label) .. "'" end
    end
  end
  return verdict, reason
end

local function type_check(kb, d, want)
  if not want then return "ok" end
  local ty = d and (d.type or (d.literal and (d.literal.kind == "number" and "number" or d.literal.kind == "temporal" and "date" or "text")))
  if not ty then return "unknown" end
  local fit = kb.lex:compat(ty, want)
  if fit == -1.0 then return "mismatch", "answer is a " .. ty .. ", a " .. want .. " was requested" end
  if fit < 0.5 then return "weak" end
  return "ok"
end

local function excluded_by(kb, plan, d)
  for _, ex in ipairs(plan.exclusions or {}) do
    local t = ex.target
    if t and d then
      if t.type and d.type and kb.lex:compat(d.type, t.type) >= 0.9 then return ex, "answer is a " .. d.type .. ", which the request excludes" end
      if t.text and d.text and (t.scope == "reference" or t.scope == "entity") and t.text:lower() == (d.text or ""):lower() then return ex, "answer is excluded by the request" end
    end
  end
end

---------------------------------------------------------------- evidence items
local function evidence_item(kb, a, role, checks, extra)
  local rec = kb:record(a.record)
  local ds = rec and kb.datasets[rec.dataset]
  local item = { role = role, record = a.record, dataset = rec and rec.dataset, dataset_version = rec and rec.version, source = rec and rec.source,
    field = a.field, quote = quote_of(a), span = { a.s, a.e }, relation = a.rel, polarity = a.polarity, modality = a.modality, tense = a.tense, pattern = a.pattern,
    from = a.from and { key = a.from.key, text = desc_text(a.from), type = a.from.type }, to = a.to and { key = a.to.key, text = desc_text(a.to), type = a.to.type },
    reliability = rec and rec.reliability, reliability_source = rec and rec.reliability_source, structured = a.structured or nil,
    date = rec and rec.date_text, dataset_label = ds and ds.label, checks = checks }
  if a.valid_from then item.valid_from = a.valid_from end
  if a.valid_to then item.valid_to = a.valid_to end
  if a.event_time then item.event_time = a.event_time.year or a.event_time.text end
  if a.former then item.former = true end
  for k, v in pairs(extra or {}) do item[k] = v end
  return item
end

---------------------------------------------------------------- lookup
-- verifies the assertions that bear on (relation, entity reading); returns per-reading outcome
local function verify_assertions(kb, plan, reading, rel_id, known_role, ask_role, answer_type, ref_year, collect)
  local idx = kb.index
  local variants = kb:variants(reading.key)
  local seen, assertions = {}, {}
  for _, vkey in ipairs(variants) do
    local list = (known_role == "from") and idx:assertions_from(rel_id, vkey) or idx:assertions_to(rel_id, vkey)
    for _, a in ipairs(list) do if not seen[a.id] then seen[a.id] = true; assertions[#assertions + 1] = a end end
  end
  local rel = kb.lex:get_rel(rel_id)
  if rel and rel.symmetric then
    for _, vkey in ipairs(variants) do
      local list = (known_role == "from") and idx:assertions_to(rel_id, vkey) or idx:assertions_from(rel_id, vkey)
      for _, a in ipairs(list) do if not seen[a.id] then seen[a.id] = true; assertions[#assertions + 1] = a end end
    end
  end
  local out = { supports = {}, refutes = {}, partial = {}, rejected = {}, n_assertions = #assertions }
  local skip = plan.skip or {}   -- ablation switches: which verification checks are disabled (all enabled in production)
  for _, a in ipairs(assertions) do
    local rec = kb:record(a.record)
    local checks = { relation = true }
    local known_desc = known_role == "from" and a.from or a.to
    local ans_desc = ask_role == "to" and a.to or a.from
    local m = key_match(known_desc, variants)
    checks.entity = m or false
    local fails, flags = {}, {}
    if rec and rec.duplicate_of and not skip.duplicates then fails[#fails + 1] = "duplicate of " .. rec.duplicate_of .. " (does not corroborate)" end
    if a.modality == "hypothetical" and not skip.modality then fails[#fails + 1] = "hypothetical statement, not an assertion of fact" end
    if a.is_class then fails[#fails + 1] = "classification, not the requested relation" end
    if m == "candidate" then flags[#flags + 1] = "subject is ambiguous in the record" end
    if a.open_relation then flags[#flags + 1] = "relation word is not in the lexicon (open relation '" .. tostring(a.rel) .. "')" end
    local ty, tywhy = type_check(kb, ans_desc, answer_type)
    if skip.type then ty = "ok" end
    checks.answer_type = ty
    if ty == "mismatch" then fails[#fails + 1] = tywhy elseif ty == "unknown" then flags[#flags + 1] = "answer type not established" end
    local tm, twhy = time_check(kb, plan, a, ref_year)
    if skip.time then tm = "ok" end
    checks.time = tm
    if tm == "mismatch" then fails[#fails + 1] = twhy end
    local sm, swhy = source_check(kb, plan, rec)
    if skip.source then sm = "ok" end
    checks.source = sm
    if sm == "mismatch" then fails[#fails + 1] = swhy end
    local ex, exwhy = excluded_by(kb, plan, ans_desc)
    if skip.exclusion then ex = nil end
    checks.exclusion = ex == nil
    if ex then fails[#fails + 1] = exwhy end
    if #fails > 0 then
      out.rejected[#out.rejected + 1] = evidence_item(kb, a, "rejected", checks, { reasons = fails })
    elseif a.polarity == "negative" and not skip.polarity then
      out.refutes[#out.refutes + 1] = { assertion = a, item = evidence_item(kb, a, "refutes", checks, { flags = flags }), key = answer_key(kb, ans_desc) }
    else
      local weak = {}
      if tm == "past_only" then weak[#weak + 1] = twhy end
      if tm == "undated" then flags[#flags + 1] = "undated" end
      if sm == "unverified" then flags[#flags + 1] = swhy end
      if a.modality == "hedged" then flags[#flags + 1] = "hedged ('reportedly', 'maybe', ...)" end
      if reading.fuzzy then flags[#flags + 1] = "the question's entity name matched this record only through a spelling variant" end
      local entry = { assertion = a, key = answer_key(kb, ans_desc), desc = ans_desc, checks = checks, flags = flags, time = tm, source = sm,
        item = evidence_item(kb, a, "supports", checks, { flags = flags }), rec = rec }
      if reading.fuzzy then
        entry.item.role = "partial"
        entry.item.reasons = { "identity of the entity rests on a spelling correction ('" .. tostring(reading.text) .. "' -> '" .. tostring(reading.key) .. "')" }
        out.partial[#out.partial + 1] = entry
      elseif tm == "past_only" then
        entry.item.role = "historical"
        entry.item.reasons = { twhy }
        out.partial[#out.partial + 1] = entry
      elseif sm == "unverified" or (m == "candidate") then
        out.partial[#out.partial + 1] = entry
      else
        out.supports[#out.supports + 1] = entry
      end
    end
  end
  return out
end

-- group supporting entries by answer; independence = distinct non-duplicate records
local function group_answers(kb, entries, skip_rel)
  local groups, order = {}, {}
  for _, e in ipairs(entries) do
    local g = groups[e.key]
    if not g then
      g = { key = e.key, desc = e.desc, text = desc_text(e.desc), type = e.desc and e.desc.type, entries = {}, records = {}, strength = 0, n_records = 0, latest_from = nil }
      groups[e.key] = g
      order[#order + 1] = e.key
    end
    g.entries[#g.entries + 1] = e
    if not g.records[e.assertion.record] then
      g.records[e.assertion.record] = true
      g.n_records = g.n_records + 1
      local w = skip_rel and 0.5 or (e.rec and e.rec.reliability or 0.5)
      if e.assertion.modality == "hedged" then w = w * V.W.hedge_weight end
      if e.time == "undated" then w = w * V.W.undated_weight end
      if e.assertion.structured then w = math.min(1, w + V.W.structured_bonus) end
      g.strength = 1 - (1 - g.strength) * (1 - w)    -- independent sources combine like noisy-OR
    end
    local vf = e.assertion.valid_from or (e.assertion.valid_at and e.assertion.valid_at.lo)
    if vf and (not g.latest_from or vf > g.latest_from) then g.latest_from = vf end
    if e.time == "ok" and (e.assertion.valid_from or e.assertion.valid_at) then g.dated = true end
  end
  local out = {}
  for _, k in ipairs(order) do out[#out + 1] = groups[k] end
  table.sort(out, function(a, b) if a.strength ~= b.strength then return a.strength > b.strength end return a.key < b.key end)
  return out
end

-- choose among competing answers; returns winner|nil, conflict description|nil
local function resolve_groups(groups, refuted)
  if #groups == 0 then return nil end
  -- drop answers a reliable record explicitly denies
  local live, denied = {}, {}
  for _, g in ipairs(groups) do
    local d = refuted[g.key]
    if d and d.strength >= g.strength - 1e-9 and d.n_records >= g.n_records then denied[#denied + 1] = g else live[#live + 1] = g end
  end
  if #live == 0 then return nil, { kind = "all_answers_denied", denied = U.map(denied, function(g) return g.key end) } end
  if #live == 1 then
    return live[1], (#groups > 1) and { kind = "denied_alternatives", resolution = "alternatives are explicitly denied by other records", others = U.map(denied, function(g) return g.key end) } or nil
  end
  -- temporal resolution: a later-starting answer supersedes an earlier one when both are dated
  local dated = {}
  for _, g in ipairs(live) do if g.latest_from then dated[#dated + 1] = g end end
  if #dated == #live then
    table.sort(dated, function(a, b) return a.latest_from > b.latest_from end)
    if dated[1].latest_from ~= dated[2].latest_from then
      return dated[1], { kind = "superseded", resolution = string.format("'%s' (valid from %s) supersedes '%s' (valid from %s)", dated[1].text, tostring(dated[1].latest_from), dated[2].text, tostring(dated[2].latest_from)),
        others = U.map({ table.unpack(dated, 2) }, function(g) return g.key end) }
    end
  end
  -- reliability / corroboration resolution, explicit and only when the gap is clear
  local a, b = live[1], live[2]
  if a.strength - b.strength >= V.W.conflict_gap and a.n_records >= b.n_records then
    return a, { kind = "resolved_by_reliability", resolution = string.format("'%s' (strength %.2f, %d record(s)) outweighs '%s' (strength %.2f, %d record(s))", a.text, a.strength, a.n_records, b.text, b.strength, b.n_records),
      others = U.map({ table.unpack(live, 2) }, function(g) return g.key end) }
  end
  return nil, { kind = "contradiction", answers = U.map(live, function(g) return g.key end) }
end

local function answers_view(groups)
  return U.map(groups, function(g)
    return { key = g.key, text = g.text, type = g.type, strength = U.round(g.strength, 3), independent_records = g.n_records,
      records = U.sorted_keys(g.records) }
  end)
end

---------------------------------------------------------------- topical candidates (kept apart from evidence)
local function topical(kb, plan, readings, handled_records, limit)
  local idx = kb.index
  local out = {}
  local seen = {}
  local rel = plan.relation and kb.lex:get_rel(plan.relation)
  local rel_terms = {}
  if rel then
    for _, n in ipairs(rel.nouns_to or {}) do for _, t in ipairs(TU.terms(n)) do rel_terms[#rel_terms + 1] = t end end
    for _, n in ipairs(rel.nouns_from or {}) do for _, t in ipairs(TU.terms(n)) do rel_terms[#rel_terms + 1] = t end end
    for _, v in ipairs(rel.verbs or {}) do for _, t in ipairs(TU.terms(v.lemma)) do rel_terms[#rel_terms + 1] = t end end
  end
  local rel_set = U.set(rel_terms)
  for _, r in ipairs(readings) do
    for _, vkey in ipairs(kb:variants(r.key)) do
      for _, d in ipairs(idx:docs_mentioning(vkey)) do
        local doc = idx.docs[d]
        if not seen[doc.id] and not handled_records[doc.id] then
          seen[doc.id] = true
          local rec = doc.rec
          -- does the record at least contain the relation's own words?  (then a reader might extract the fact; we could not)
          local words = TU.terms(rec.text or "")
          local shared = 0
          for _, w in ipairs(words) do if rel_set[w] then shared = shared + 1 end end
          local others = {}
          for _, aid in ipairs(doc.assertions) do
            local a = idx.assertions[aid]
            if a and not a.removed and not a.is_class and a.rel ~= plan.relation then others[#others + 1] = a.rel end
          end
          -- instruction-like sentences are withheld from the quote (they stay in the record as untrusted content, never as text a reader could obey)
          local rd = kb.reader_directed[rec.id]
          local text = rec.text or ""
          if rd then
            local parts = {}
            for _, f in ipairs(rec.text_fields or {}) do
              local ft = rec.field_text[f] or ""
              local cuts = {}
              for _, x in ipairs(rd) do if x.field == f then cuts[#cuts + 1] = x end end
              table.sort(cuts, function(a, b) return a.s > b.s end)
              for _, x in ipairs(cuts) do ft = ft:sub(1, x.s - 1) .. "[sentence withheld: instruction-like content]" .. ft:sub(x.e + 1) end
              parts[#parts + 1] = ft
            end
            text = table.concat(parts, "\n")
          end
          out[#out + 1] = { record = doc.id, entity = r.key, shares_relation_words = shared > 0 or nil, other_relations = #others > 0 and others or nil,
            quote = text:sub(1, 200), reliability = rec.reliability, instruction_like = rd and #rd or nil }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.record < b.record end)
  if limit and #out > limit then for i = #out, limit + 1, -1 do out[i] = nil end end
  return out
end

---------------------------------------------------------------- the entry points
local function reference_year(kb)
  local y
  for _, did in ipairs(kb.dataset_order) do
    local ds = kb.datasets[did]
    if ds.label and ds.label.year and (not y or ds.label.year > y) then y = ds.label.year end
    for _, id in ipairs(ds.order) do
      local r = ds.records[id]
      if r.year and (not y or r.year > y) and not (ds.label and ds.label.year) then y = r.year end
    end
  end
  return y
end

-- ABLATION ONLY ("retrieval without semantic verification"): entity identity + lexical ranking, no relation / type / time / polarity checks.
-- The top records that mention the entity and share words with the relation are returned as "evidence" without being checked.
local function run_untyped(kb, plan, res)
  local readings = plan.subjects or {}
  local rel = plan.relation and kb.lex:get_rel(plan.relation)
  local terms = {}
  if rel then
    for _, n in ipairs(rel.nouns_to or {}) do for _, t in ipairs(TU.terms(n)) do terms[#terms + 1] = t end end
    for _, v in ipairs(rel.verbs or {}) do for _, t in ipairs(TU.terms(v.lemma)) do terms[#terms + 1] = t end end
  end
  local cand = {}
  for _, r in ipairs(readings) do for _, vkey in ipairs(kb:variants(r.key)) do for _, d in ipairs(kb.index:docs_mentioning(vkey)) do cand[d] = true end end end
  local ranked = {}
  for _, hit in ipairs(kb.index:search({ terms = terms, phrases = {} }, 200)) do if cand[hit.doc] then ranked[#ranked + 1] = hit end end
  for d in pairs(cand) do
    local found = false
    for _, h in ipairs(ranked) do if h.doc == d then found = true end end
    if not found then ranked[#ranked + 1] = { doc = d, score = 0 } end
  end
  for i = 1, math.min(3, #ranked) do
    local doc = kb.index.docs[ranked[i].doc]
    res.selected[#res.selected + 1] = { role = "supports", record = doc.id, quote = (doc.rec.text or ""):sub(1, 200), reliability = doc.rec.reliability, unverified = true }
  end
  res.status = (#res.selected > 0) and "answerable" or "unsupported"
  res.untyped = true
end

-- lookup (single relation), including multi-hop chains
local function run_lookup(kb, plan, res)
  if plan.skip and plan.skip.typed then return run_untyped(kb, plan, res) end
  local ref_year = reference_year(kb)
  local readings = plan.subjects or {}
  res.checks_summary = { readings = #readings }
  if #readings == 0 then
    res.status = "insufficient"
    res.reasons[#res.reasons + 1] = "the entity the question is about could not be identified (" .. tostring(plan.subject_status) .. "); no retrieval is possible"
    res.interpretation_incomplete = true
    return
  end
  local per_reading = {}
  local all_rejected, all_refutes = {}, {}
  local handled = {}
  for _, r in ipairs(readings) do
    local out = verify_assertions(kb, plan, r, plan.relation, plan.known_role, plan.ask, plan.answer_type, ref_year)
    for _, e in ipairs(out.supports) do handled[e.assertion.record] = true end
    for _, e in ipairs(out.partial) do handled[e.assertion.record] = true end
    for _, e in ipairs(out.refutes) do handled[e.assertion.record] = true end
    for _, x in ipairs(out.rejected) do handled[x.record] = true; all_rejected[#all_rejected + 1] = x end
    -- refutations indexed by denied answer
    local refuted = {}
    for _, rf in ipairs(out.refutes) do
      local g = refuted[rf.key]
      if not g then g = { strength = 0, n_records = 0, records = {} }; refuted[rf.key] = g end
      if not g.records[rf.assertion.record] then g.records[rf.assertion.record] = true; g.n_records = g.n_records + 1; g.strength = 1 - (1 - g.strength) * (1 - (rf.assertion.reliability or 0.5)) end
      all_refutes[#all_refutes + 1] = rf.item
    end
    local groups = group_answers(kb, out.supports, plan.skip and plan.skip.reliability)
    local winner, conflict = resolve_groups(groups, refuted)
    per_reading[#per_reading + 1] = { reading = r, out = out, groups = groups, winner = winner, conflict = conflict, partial = out.partial }
  end
  res.rejected = all_rejected
  res.refuting = all_refutes
  -- which readings have verified support?  A winner resting only on low-reliability sources is NOT sufficient: it becomes partial evidence.
  local supported = {}
  for _, pr in ipairs(per_reading) do
    if pr.winner and pr.winner.strength < V.W.min_strength and not (plan.skip and plan.skip.reliability) then
      for _, e in ipairs(pr.winner.entries) do
        e.item.role = "partial"
        e.item.reasons = { string.format("the only support is a low-reliability source (strength %.2f < %.2f)", pr.winner.strength, V.W.min_strength) }
        pr.partial[#pr.partial + 1] = e
      end
      pr.winner = nil
    end
    if pr.winner then supported[#supported + 1] = pr end
  end
  local any_conflict, any_partial, any_assertion, any_doc = false, false, false, false
  for _, pr in ipairs(per_reading) do
    if pr.conflict and pr.conflict.kind == "contradiction" then any_conflict = true end
    if #pr.partial > 0 then any_partial = true end
    if pr.out.n_assertions > 0 then any_assertion = true end
    if #kb.index:docs_mentioning(pr.reading.key) > 0 then any_doc = true end
  end
  if #supported >= 2 and #readings >= 2 then
    res.status = "ambiguous"
    res.reasons[#res.reasons + 1] = "the entity mention has several readings and the dataset supports an answer for more than one"
    res.answers_by_reading = U.map(supported, function(pr) return { reading = pr.reading.key, text = pr.reading.text, p = pr.reading.p, answer = pr.winner.text, answer_key = pr.winner.key } end)
    for _, pr in ipairs(supported) do for _, e in ipairs(pr.winner.entries) do res.selected[#res.selected + 1] = e.item end end
  elseif #supported >= 1 then
    local pr = supported[1]
    if #supported == 1 and #readings >= 2 then res.notes[#res.notes + 1] = "the dataset evidence selects the reading '" .. pr.reading.key .. "' among " .. #readings .. " candidates" end
    res.status = "answerable"
    res.reading = pr.reading
    res.answers = answers_view({ pr.winner })
    local alts = {}
    for _, g in ipairs(pr.groups) do if g.key ~= pr.winner.key then alts[#alts + 1] = g end end
    if #alts > 0 then res.alternative_answers = answers_view(alts) end
    res.answer = { key = pr.winner.key, text = pr.winner.text, type = pr.winner.type }
    for _, e in ipairs(pr.winner.entries) do res.selected[#res.selected + 1] = e.item end
    if pr.conflict then
      res.conflicts[#res.conflicts + 1] = pr.conflict
      -- the losing side stays visible, separately, as legitimate conflicting evidence
      for _, g in ipairs(pr.groups) do
        if g.key ~= pr.winner.key then for _, e in ipairs(g.entries) do e.item.role = "conflicting"; res.conflicting_evidence[#res.conflicting_evidence + 1] = e.item end end
      end
    end
    if any_conflict and pr.conflict == nil then res.notes[#res.notes + 1] = "another reading of the entity has contradicting evidence" end
  else
    -- nothing verified
    local contradiction
    for _, pr in ipairs(per_reading) do if pr.conflict and pr.conflict.kind == "contradiction" then contradiction = pr end end
    if contradiction then
      res.status = "contradictory"
      res.conflicts[#res.conflicts + 1] = contradiction.conflict
      res.answers = answers_view(contradiction.groups)
      for _, g in ipairs(contradiction.groups) do for _, e in ipairs(g.entries) do e.item.role = "conflicting"; res.conflicting_evidence[#res.conflicting_evidence + 1] = e.item end end
      res.reasons[#res.reasons + 1] = "records give different answers and neither time, reliability nor corroboration separates them"
    elseif any_partial then
      res.status = "potentially_answerable"
      local why = {}
      for _, pr in ipairs(per_reading) do
        for _, e in ipairs(pr.partial) do
          res.partial_evidence[#res.partial_evidence + 1] = e.item
          why[#why + 1] = (e.item.reasons and e.item.reasons[1]) or (e.flags and e.flags[1]) or "partially verified"
        end
      end
      res.reasons[#res.reasons + 1] = "evidence exists but is not fully verified: " .. table.concat(U.sorted_keys(U.set(why)), "; ")
    elseif #all_rejected > 0 and any_assertion then
      res.status = "insufficient"
      res.reasons[#res.reasons + 1] = "the relation is asserted only in records that fail the question's constraints (type, time, source or exclusions)"
    elseif any_doc then
      res.status = "insufficient"
      res.reasons[#res.reasons + 1] = "records mention the entity but none establishes the requested relation"
    else
      res.status = "unsupported"
      res.reasons[#res.reasons + 1] = "no record in the dataset mentions the requested entity"
    end
  end
  res.topical = topical(kb, plan, readings, handled, 8)
  res.assertion_count = 0
  for _, pr in ipairs(per_reading) do res.assertion_count = res.assertion_count + pr.out.n_assertions end
end

local function run_chain(kb, plan, res)
  -- each step feeds the next: step i's answers become step i+1's known entities
  local ref_year = reference_year(kb)
  local current = nil
  local steps_out = {}
  for _, st in ipairs(plan.chain) do
    local known = st.known
    if st.var or #known == 0 then known = current or {} end
    local sub = { kind = "lookup", relation = st.relation, known_role = st.known_role, ask = st.ask_role, subjects = known, time = plan.time, sources = plan.sources, exclusions = {},
      subject_status = st.known_status }
    local r = U.copy({ selected = {}, rejected = {}, reasons = {}, notes = {}, conflicts = {}, conflicting_evidence = {}, partial_evidence = {}, refuting = {} })
    run_lookup(kb, sub, r)
    steps_out[#steps_out + 1] = { relation = st.relation, status = r.status, answer = r.answer, known = U.map(known, function(k) return k.key end) }
    for _, e in ipairs(r.selected) do e.step = st.index; res.selected[#res.selected + 1] = e end
    for _, e in ipairs(r.rejected) do e.step = st.index; res.rejected[#res.rejected + 1] = e end
    if r.status ~= "answerable" then
      res.status = r.status
      res.reasons[#res.reasons + 1] = string.format("step %d (%s) is %s: %s", st.index, st.relation, r.status, table.concat(r.reasons, "; "))
      res.steps = steps_out
      return false
    end
    current = { { key = r.answer.key, text = r.answer.text, type = r.answer.type, p = 1.0 } }
  end
  res.steps = steps_out
  return true, current
end

function V.run(kb, plan, opts)
  opts = opts or {}
  if opts.skip then plan = U.shallow(plan); plan.skip = opts.skip end
  local res = { status = "not_applicable", reasons = {}, notes = {}, selected = {}, rejected = {}, conflicts = {}, conflicting_evidence = {}, partial_evidence = {},
    refuting = {}, topical = {}, plan_kind = plan.kind, knowledge_digest = kb:digest() }
  if plan.kind == "lookup" then
    if plan.chain and #plan.chain > 0 then
      local ok, current = run_chain(kb, plan, res)
      if ok then
        local final = { kind = "lookup", relation = plan.relation, known_role = plan.known_role, ask = plan.ask, subjects = current, time = plan.time, sources = plan.sources,
          exclusions = plan.exclusions, answer_type = plan.answer_type }
        local r2 = { selected = {}, rejected = {}, reasons = {}, notes = {}, conflicts = {}, conflicting_evidence = {}, partial_evidence = {}, refuting = {}, topical = {} }
        run_lookup(kb, final, r2)
        for k, v in pairs(r2) do
          if type(v) == "table" and #v > 0 and res[k] then for _, x in ipairs(v) do res[k][#res[k] + 1] = x end elseif res[k] == nil or type(v) ~= "table" then res[k] = v end
        end
        res.status, res.answer, res.answers, res.reading = r2.status, r2.answer, r2.answers, r2.reading
      end
    else
      run_lookup(kb, plan, res)
    end
  elseif plan.kind == "verify" then
    -- "Is Paris the capital of France?" -> look up the relation for the known side and compare with the stated other side
    local from_r, to_r = plan.from_readings or {}, plan.to_readings or {}
    if #from_r == 0 or #to_r == 0 or not plan.relation then
      res.status = "insufficient"
      res.reasons[#res.reasons + 1] = "the claim to verify is not fully identified"
      res.interpretation_incomplete = true
    else
      local sub = { kind = "lookup", relation = plan.relation, known_role = "from", ask = "to", subjects = from_r, time = plan.time, sources = plan.sources, exclusions = {} }
      run_lookup(kb, sub, res)
      res.claim = { from = from_r[1].key, to = to_r[1].key }
      if res.status == "answerable" then
        local match = false
        for _, rd in ipairs(to_r) do if kb:canonical(rd.key) == res.answer.key then match = true end end
        res.verdict = match and "supported" or "contradicted"
        if not match then res.reasons[#res.reasons + 1] = "the dataset states a different value: " .. tostring(res.answer.text) end
      elseif res.status == "contradictory" then res.verdict = "contested" end
    end
  elseif plan.kind == "define" then
    V.define(kb, plan, res)
  elseif plan.kind == "search" then
    V.search(kb, plan, res)
  elseif plan.kind == "compare" then
    V.compare(kb, plan, res)
  else
    res.status = "not_applicable"
    res.reasons[#res.reasons + 1] = plan.reason or "no retrieval is required for this request"
  end
  res.summary = V.summarise(res)
  return res
end

---------------------------------------------------------------- definitions / descriptions
function V.define(kb, plan, res)
  local idx = kb.index
  local readings = plan.subjects or {}
  if #readings == 0 then res.status = "insufficient"; res.reasons[#res.reasons + 1] = "the term could not be identified"; return end
  local found = {}
  local handled = {}
  for _, r in ipairs(readings) do
    for _, vkey in ipairs(kb:variants(r.key)) do
      for _, a in ipairs(idx:classifications(vkey)) do
        local rec = kb:record(a.record)
        if rec and not rec.duplicate_of and a.polarity ~= "negative" then
          handled[a.record] = true
          found[#found + 1] = { reading = r, item = (function() local it = evidence_item(kb, a, "supports", { relation = "definition", entity = "exact" }); it.class = a.class_text; return it end)(), class_type = a.class_type }
        end
      end
    end
  end
  if #found > 0 then
    -- different class types from different readings = ambiguity retained
    local by_reading = {}
    for _, f in ipairs(found) do by_reading[f.reading.key] = by_reading[f.reading.key] or f end
    local n = 0
    for _ in pairs(by_reading) do n = n + 1 end
    res.status = (n >= 2) and "ambiguous" or "answerable"
    for _, f in ipairs(found) do res.selected[#res.selected + 1] = f.item end
    if n >= 2 then
      res.answers_by_reading = {}
      for k, f in pairs(by_reading) do res.answers_by_reading[#res.answers_by_reading + 1] = { reading = k, text = f.reading.text, answer = f.item.class } end
      table.sort(res.answers_by_reading, function(a, b) return a.reading < b.reading end)
      res.reasons[#res.reasons + 1] = "the term has several readings and the dataset describes more than one"
    else
      res.answer = { text = found[1].item.class, key = "class:" .. tostring(found[1].item.class) }
    end
  else
    local any = false
    for _, r in ipairs(readings) do if #idx:docs_mentioning(r.key) > 0 then any = true end end
    res.status = any and "insufficient" or "unsupported"
    res.reasons[#res.reasons + 1] = any and "records mention the term but none defines it" or "no record mentions the term"
  end
  res.topical = topical(kb, { relation = nil }, readings, handled, 6)
end

---------------------------------------------------------------- set search with positive / negative filters
local function value_matches(kb, a, f)
  -- does assertion `a` (relation of the filter) carry the filter's value?  keys first, then the value's head word (weak, flagged)
  local val = f.value
  if not val then return true, "exact" end
  local to = a.to
  if not to then return false end
  if val.resolved_id and to.key and kb:canonical(to.key) == kb:canonical(val.resolved_id) then return true, "exact" end
  local vt = (val.core or val.text or ""):lower()
  local tt = (to.term or to.text or ""):lower()
  if vt ~= "" and (tt == vt or tt:find(vt, 1, true) or vt:find(tt, 1, true)) then return true, "text" end
  local vs = {}
  for _, t in ipairs(TU.terms(vt)) do vs[t] = true end
  for _, t in ipairs(TU.terms(tt)) do if vs[t] then return true, "term" end end
  return false
end

function V.search(kb, plan, res)
  local idx = kb.index
  local target_type = plan.target and plan.target.type
  local positive, temporal = {}, {}
  for _, f in ipairs(plan.filters or {}) do
    if f.kind == "relation" and (f.polarity or "positive") == "positive" then positive[#positive + 1] = f
    elseif f.kind == "temporal" then temporal[#temporal + 1] = f end
  end
  local negatives = {}
  for _, n in ipairs(plan.exclusions or {}) do negatives[#negatives + 1] = n end
  if #positive + #temporal == 0 then
    res.status = "insufficient"
    res.reasons[#res.reasons + 1] = "the request has no relation or time filter the dataset could be searched on"
    return
  end
  -- candidate entities: everything that is the subject of an assertion bearing on a filter
  local cand = {}
  local function consider(a, role)
    local d = a[role]
    if d and d.key and not d.literal then cand[d.key] = d end
  end
  for _, f in ipairs(positive) do
    local rel = kb.lex:get_rel(f.relation)
    local role = f.target_role == "to" and "from" or "to"
    for _, a in ipairs(idx.assertions) do if not a.removed and a.rel == f.relation and not a.is_class then consider(a, f.target_role == "from" and "to" or "from") end end
  end
  for _, f in ipairs(temporal) do
    for _, a in ipairs(idx.assertions) do
      if not a.removed then
        local rel = kb.lex:get_rel(a.rel)
        if a.rel == f.relation or (rel and rel.when == f.relation) then consider(a, "from") end
      end
    end
  end
  local passed, failed = {}, {}
  local keys = U.sorted_keys(cand)
  for _, key in ipairs(keys) do
    local d = cand[key]
    local ok_all, evidence, why = true, {}, {}
    -- target type
    local ty = d.type
    if target_type and ty and kb.lex:compat(ty, target_type) == -1.0 then ok_all = false; why[#why + 1] = "is a " .. ty .. ", not a " .. target_type end
    if ok_all then
      for _, f in ipairs(positive) do
        local found
        for _, vkey in ipairs(kb:variants(key)) do
          local list = (f.target_role == "from") and idx:assertions_to(f.relation, vkey) or idx:assertions_from(f.relation, vkey)
          for _, a in ipairs(list) do
            local rec = kb:record(a.record)
            if rec and not rec.duplicate_of and a.polarity ~= "negative" and a.modality ~= "hypothetical" then
              local ok = value_matches(kb, a, f)
              if ok then found = found or a end
            end
          end
        end
        if found then evidence[#evidence + 1] = evidence_item(kb, found, "supports", { relation = true, entity = "exact" }) else ok_all = false; why[#why + 1] = "no record states " .. f.relation end
      end
      for _, f in ipairs(temporal) do
        local good
        for _, vkey in ipairs(kb:variants(key)) do
          for _, a in ipairs(idx:assertions_about(vkey)) do
            local rel = kb.lex:get_rel(a.rel)
            local lo, hi
            if a.rel == f.relation and a.to and a.to.literal then lo, hi = a.to.literal.lo, a.to.literal.hi
            elseif rel and rel.when == f.relation and a.event_time then lo, hi = a.event_time.lo, a.event_time.hi end
            if lo then
              local pass
              if f.op == "after" or f.op == "since" then pass = lo >= (f.eff_lo or 0)
              elseif f.op == "before" or f.op == "until" or f.op == "by" then pass = hi and f.eff_hi and hi <= f.eff_hi
              else pass = lo >= (f.eff_lo or -math.huge) and (hi or lo) <= (f.eff_hi or math.huge) end
              if pass then good = good or a end
            end
          end
        end
        if good then evidence[#evidence + 1] = evidence_item(kb, good, "supports", { relation = true, time = "ok" }) else ok_all = false; why[#why + 1] = "no dated record satisfies the time filter" end
      end
    end
    -- exclusions
    if ok_all then
      for _, n in ipairs(negatives) do
        local t = n.target or {}
        if t.type and ty and kb.lex:compat(ty, t.type) >= 0.9 then ok_all = false; why[#why + 1] = "is a " .. ty .. " (excluded)" end
        for _, nf in ipairs(n.filters or {}) do
          if nf.kind == "relation" then
            for _, vkey in ipairs(kb:variants(key)) do
              for _, a in ipairs(idx:assertions_from(nf.relation, vkey)) do
                local rec = kb:record(a.record)
                if rec and not rec.duplicate_of and a.polarity ~= "negative" and value_matches(kb, a, nf) then
                  ok_all = false; why[#why + 1] = "matches the excluded condition (" .. nf.relation .. ")"
                  evidence[#evidence + 1] = evidence_item(kb, a, "excluded_by", { relation = true }, { reasons = { "satisfies the excluded filter" } })
                end
              end
            end
          end
        end
      end
    end
    if ok_all then passed[#passed + 1] = { key = key, text = d.text, type = ty, evidence = evidence }
    else failed[#failed + 1] = { key = key, text = d.text, reasons = why, evidence = evidence } end
  end
  res.matches = passed
  res.excluded_entities = failed
  if #passed > 0 then
    res.status = "answerable"
    for _, m in ipairs(passed) do for _, e in ipairs(m.evidence) do res.selected[#res.selected + 1] = e end end
    res.answers = U.map(passed, function(m) return { key = m.key, text = m.text, type = m.type, independent_records = #m.evidence } end)
  elseif #keys > 0 then
    res.status = "insufficient"
    res.reasons[#res.reasons + 1] = "candidates exist but none satisfies every filter and exclusion"
  else
    res.status = "unsupported"
    res.reasons[#res.reasons + 1] = "the dataset holds no assertions the requested filters could apply to"
  end
end

---------------------------------------------------------------- comparison
function V.compare(kb, plan, res)
  local lex = kb.lex
  local dim = plan.dimension and lex.dims[plan.dimension] or (lex.parent and lex.parent.dims[plan.dimension])
  if not dim or not plan.items or #plan.items < 2 then
    res.status = "insufficient"
    res.reasons[#res.reasons + 1] = "the comparison needs two identified items and a measurable dimension"
    return
  end
  local values, missing = {}, {}
  for _, it in ipairs(plan.items) do
    local got
    for _, r in ipairs(it.readings or {}) do
      for _, rel_id in ipairs(dim.rels or {}) do
        for _, vkey in ipairs(kb:variants(r.key)) do
          for _, a in ipairs(kb.index:assertions_from(rel_id, vkey)) do
            if a.polarity ~= "negative" and a.to and not got then got = { assertion = a, rel = rel_id } end
          end
        end
      end
    end
    if got then
      local v = got.assertion.to.literal and (got.assertion.to.literal.value or got.assertion.to.literal.lo) or nil
      if got.assertion.event_time and not v then v = got.assertion.event_time.lo end
      values[#values + 1] = { item = it.text, value = v, text = desc_text(got.assertion.to), evidence = evidence_item(kb, got.assertion, "supports", { relation = true, entity = "exact" }) }
    else missing[#missing + 1] = it.text end
  end
  for _, v in ipairs(values) do res.selected[#res.selected + 1] = v.evidence end
  res.values = U.map(values, function(v) return { item = v.item, value = v.value, text = v.text } end)
  if #missing == 0 then
    local numeric = true
    for _, v in ipairs(values) do if type(v.value) ~= "number" then numeric = false end end
    res.status = numeric and "answerable" or "potentially_answerable"
    if not numeric then res.reasons[#res.reasons + 1] = "values were found but are not comparable numbers or dates" end
  else
    res.status = (#values > 0) and "potentially_answerable" or "insufficient"
    res.reasons[#res.reasons + 1] = "no value for the dimension was found for: " .. table.concat(missing, ", ")
  end
end

---------------------------------------------------------------- summary line (human + LM readable, derived, never invented)
function V.summarise(res)
  local parts = { "status=" .. res.status }
  if res.answer then parts[#parts + 1] = "answer=" .. tostring(res.answer.text) end
  parts[#parts + 1] = string.format("verified=%d rejected=%d conflicting=%d topical=%d", #res.selected, #res.rejected, #res.conflicting_evidence, #res.topical)
  return table.concat(parts, " ")
end

return V
