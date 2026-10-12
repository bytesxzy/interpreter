-- asi.nlu.eval: gold-case evaluation harness (LM-independent).
--   case line:   ID | category | text | gold            gold = key=value; key=value; ...
--   keys: act intent rel rel! from to subject concept target focus object ask atype temporal tc neg pos pref src amb alts ctx items inst evid pol status
-- Matching is field-by-field; a case passes only if every gold field it specifies matches. Serious fields are tracked separately.
local U = require("asi.nlu.util")

local E = {}

E.SERIOUS = U.set({ "intent", "rel", "rel!", "from", "to", "subject", "concept", "target", "focus", "object", "ask", "neg", "amb", "alts", "items",
  "inst", "tc", "pos", "pol", "src", "ctx", "pref", "dep", "ref", "active", "inactive", "sel", "unres" })

---------------------------------------------------------------- parsing
function E.parse_cases(text, source)
  local cases, errs = {}, {}
  local ln = 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    ln = ln + 1
    local l = U.trim(line)
    if l ~= "" and l:sub(1, 1) ~= "#" then
      local parts = {}
      for part in (l .. " | "):gmatch("(.-)%s%|%s") do parts[#parts + 1] = part end
      if #parts < 4 then errs[#errs + 1] = string.format("%s:%d: expected 'ID | category | text | gold'", source or "?", ln)
      else
        local gold = {}
        for kv in (parts[4] .. ";"):gmatch("(.-);") do
          kv = U.trim(kv)
          if kv ~= "" then
            local k, v = kv:match("^([%w_!]+)%s*=%s*(.*)$")
            if k then gold[k] = v else errs[#errs + 1] = string.format("%s:%d: bad gold item '%s'", source or "?", ln, kv) end
          end
        end
        local cs = { id = parts[1], category = parts[2], text = parts[3], gold = gold, line = ln, source = source }
        -- multi-turn case:  U: first turn // A: assistant turn // U: the request being evaluated   (gold applies to the last turn)
        if cs.text:match("^[UAD]:%s") then
          cs.turns = {}
          for seg in (cs.text .. " // "):gmatch("(.-) //%s") do
            local who, body = seg:match("^([UAD]):%s*(.*)$")
            if who then cs.turns[#cs.turns + 1] = { speaker = (who == "U" and "user") or (who == "A" and "assistant") or "doc", text = body }
            elseif #cs.turns > 0 then cs.turns[#cs.turns].text = cs.turns[#cs.turns].text .. " // " .. seg end
          end
          cs.final_text = cs.turns[#cs.turns].text
        end
        cases[#cases + 1] = cs
      end
    end
  end
  return cases, errs
end

---------------------------------------------------------------- matching helpers
local DETS = U.set({ "the", "a", "an", "this", "that", "these", "those", "his", "her", "its", "their", "our", "my", "your" })
local function norm_text(s)
  s = (s or ""):lower():gsub("[%?%!%.,;:\"]+$", ""):gsub("^[\"']", ""):gsub("%s+", " ")
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  while #words > 1 and DETS[words[1]] do table.remove(words, 1) end
  return table.concat(words, " ")
end

local function type_of(r)
  if not r then return nil end
  return r.type or (r.senses and r.senses[1] and r.senses[1].type)
end

local function ref_ok(lex, pred, gold)
  if not pred then return false, "missing" end
  local text, ty, id = gold:match("^([^:]*):?([^:]*):?(.*)$")
  -- a resolved pronoun / back-reference is judged by what it was resolved TO
  local ptext = (pred.antecedent and pred.antecedent.text) or pred.text
  if text ~= "*" and text ~= "" and norm_text(ptext) ~= norm_text(text) then return false, "text '" .. tostring(ptext) .. "' ~= '" .. text .. "'" end
  if ty ~= "" and ty ~= "*" then
    local pt = type_of(pred)
    if not pt then
      -- an ambiguous/unresolved mention has no single type; accept when any candidate satisfies the gold type
      local any = false
      for _, c in ipairs(pred.candidates or {}) do if c.type and (c.type == ty or lex:isa(c.type, ty)) then any = true end end
      if not any then return false, "type nil ~= " .. ty end
    elseif pt ~= ty and not lex:isa(pt, ty) then return false, "type " .. pt .. " ~= " .. ty end
  end
  if id ~= "" and id ~= "*" and pred.resolved_id ~= id then return false, "id " .. tostring(pred.resolved_id) .. " ~= " .. id end
  return true
end

local function list_of(v) local t = {}; for x in ((v or "") .. ","):gmatch("(.-),") do x = U.trim(x); if x ~= "" then t[#t + 1] = x end end; return t end

local function neg_matches(lex, n, spec)
  local scope, key = spec:match("^([%w_]+):(.*)$")
  local tgt = n.target or {}
  if scope and tgt.scope ~= scope and not (scope == "type" and tgt.scope == "filtered") then return false end
  local k = (key or ""):lower()
  local plus = nil
  local base, filt = k:match("^(.-)%+(.*)$")
  if base then k = base; plus = filt end
  local ok = false
  if k == "" or k == "*" then ok = true
  elseif tgt.type and (tgt.type == k or lex:isa(tgt.type, k)) then ok = true
  elseif (tgt.text or ""):lower():find(k, 1, true) then ok = true
  elseif tgt.candidates then for _, c in ipairs(tgt.candidates) do if c.id:find(k, 1, true) then ok = true end end end
  if ok and plus then
    local rel_name, val = plus:match("^([%w_]+):?(.*)$")
    local found = false
    for _, f in ipairs(n.filters or {}) do
      if f.relation == rel_name and (val == "" or (f.value and (f.value.text or ""):lower():find(val, 1, true))) then found = true end
    end
    ok = found
  end
  return ok
end

local function tc_matches(c, spec)
  -- spec: op:year   or   label:2020   or   derived:2020   or   between:2010-2015
  local op, val = spec:match("^([%w_]+):(.*)$")
  if not op then return false end
  local function inrange(lo, hi, y)
    if y == nil then return false end
    if lo and lo > y * 10000 + 1231 then return false end
    if hi and hi < y * 10000 + 101 then return false end
    return true
  end
  if op == "label" or op == "derived" then
    return tostring(c.year or c.text or ""):find(val, 1, true) ~= nil and ((op == "label" and c.role == "label") or (op == "derived" and c.role == "derived"))
  end
  local a, b = val:match("^(%d+)%-(%d+)$")
  if op == "between" and a then
    return c.eff_lo ~= nil and c.eff_hi ~= nil and math.floor(c.eff_lo / 10000) == tonumber(a) and math.floor(c.eff_hi / 10000) == tonumber(b)
  end
  local y = tonumber(val)
  if not y then return false end
  if op == "in" then return c.eff_lo ~= nil and c.eff_hi ~= nil and math.floor(c.eff_lo / 10000) == y and math.floor(c.eff_hi / 10000) == y end
  if op == "before" then return c.eff_hi ~= nil and c.eff_lo == nil and math.floor(c.eff_hi / 10000) <= y end
  if op == "after" then return c.eff_lo ~= nil and c.eff_hi == nil and math.floor(c.eff_lo / 10000) >= y end
  if op == "since" then return c.eff_lo ~= nil and c.eff_hi == nil and math.floor(c.eff_lo / 10000) == y end
  if op == "until" then return c.eff_hi ~= nil and c.eff_lo == nil and math.floor(c.eff_hi / 10000) == y end
  return false
end

-- all temporal constraints of an interpretation: standalone ones and temporal filters attached to the target set
local function all_temporal(m)
  local out = {}
  for _, t in ipairs(m.constraints.temporal or {}) do out[#out + 1] = t end
  for _, p in ipairs(m.constraints.positive or {}) do if p.kind == "temporal" then out[#out + 1] = p end end
  return out
end

function E.compare(lex, m, gold)
  local res, ok_all = {}, true
  local function chk(key, ok, got)
    res[key] = { ok = ok, got = got, expected = gold[key] }
    if not ok then ok_all = false end
  end
  if not m then
    for k in pairs(gold) do chk(k, false, "no interpretation") end
    return { ok = false, fields = res }
  end
  local c = m.constraints or { positive = {}, negative = {}, temporal = {}, geographic = {}, source = {}, preferences = {}, restrictions = {} }
  if gold.status then chk("status", (m.status or "ok") == gold.status, m.status) end
  if gold.act then chk("act", m.speech_act == gold.act, m.speech_act) end
  if gold.intent then chk("intent", m.intent == gold.intent, m.intent) end
  if gold.rel then
    local got = m.relation and m.relation.id or "-"
    chk("rel", got == gold.rel, got)
  end
  if gold["rel!"] then
    local got = m.relation and m.relation.id or "-"
    chk("rel!", got ~= gold["rel!"], got)
  end
  for _, role in ipairs({ "from", "to" }) do
    if gold[role] then
      local ok, why = ref_ok(lex, m.roles and m.roles[role], gold[role])
      chk(role, ok, why or (m.roles and m.roles[role] and m.roles[role].text))
    end
  end
  for _, k in ipairs({ "subject", "concept", "target", "focus", "object" }) do
    if gold[k] then
      local ok, why = ref_ok(lex, m[k], gold[k])
      chk(k, ok, why or (m[k] and m[k].text))
    end
  end
  if gold.ask then chk("ask", m.query and m.query.ask == gold.ask, m.query and m.query.ask) end
  if gold.atype then
    local got = m.query and (m.query.answer_type or m.query.relation_answer_type)
    chk("atype", got ~= nil and (got == gold.atype or lex:isa(got, gold.atype)), got)
  end
  if gold.temporal then chk("temporal", m.temporal_scope == gold.temporal, m.temporal_scope) end
  if gold.tc then
    local ok, got = true, {}
    local temps = all_temporal(m)
    for _, spec in ipairs(list_of(gold.tc)) do
      local found = false
      for _, t in ipairs(temps) do if tc_matches(t, spec) then found = true end end
      if not found then ok = false end
    end
    for _, t in ipairs(temps) do got[#got + 1] = tostring(t.op) .. ":" .. tostring(t.year or t.text) end
    chk("tc", ok, table.concat(got, ","))
  end
  if gold.neg then
    local specs = list_of(gold.neg)
    local ok, got = true, {}
    if specs[1] == "none" then ok = (#c.negative == 0)
    else
      for _, spec in ipairs(specs) do
        local found = false
        for _, n in ipairs(c.negative) do if neg_matches(lex, n, spec) then found = true end end
        if not found then ok = false end
      end
    end
    for _, n in ipairs(c.negative) do got[#got + 1] = tostring(n.target and n.target.scope) .. ":" .. tostring(n.target and (n.target.type or n.target.text)) end
    chk("neg", ok, table.concat(got, ","))
  end
  if gold.pos then
    local ok, got = true, {}
    for _, spec in ipairs(list_of(gold.pos)) do
      local kind, key = spec:match("^([%w_]+):(.*)$")
      local found = false
      if kind == "relation" then
        for _, p in ipairs(c.positive) do if p.kind == "relation" and p.relation == key then found = true end end
      elseif kind == "temporal" then
        for _, p in ipairs(c.positive) do if p.kind == "temporal" and p.relation == key then found = true end end
      elseif kind == "geo" then
        for _, g in ipairs(c.geographic or {}) do if (g.text or ""):lower():find(key:lower(), 1, true) then found = true end end
        for _, p in ipairs(c.positive) do if p.kind == "geographic" and p.value and (p.value.text or ""):lower():find(key:lower(), 1, true) then found = true end end
      elseif kind == "has" then
        for _, p in ipairs(c.positive) do if p.kind == "has" and p.value and (p.value.text or ""):lower():find(key:lower(), 1, true) then found = true end end
      end
      if not found then ok = false end
    end
    for _, p in ipairs(c.positive) do got[#got + 1] = tostring(p.kind) .. ":" .. tostring(p.relation) end
    chk("pos", ok, table.concat(got, ","))
  end
  if gold.pref then
    local ok = true
    for _, s in ipairs(list_of(gold.pref)) do
      local found = false
      for _, p in ipairs(c.preferences or {}) do if (p.text or ""):lower():find(s:lower(), 1, true) then found = true end end
      if not found then ok = false end
    end
    chk("pref", ok, tostring(#(c.preferences or {})) .. " preference(s)")
  end
  if gold.src then
    local res_, label = gold.src:match("^([%w_]+):?(.*)$")
    local ok = false
    for _, s in ipairs(c.source or {}) do
      if s.resource == res_ and (label == "" or tostring(s.label or ""):find(label, 1, true)) then ok = true end
    end
    for _, s in ipairs(c.restrictions or {}) do
      if s.resource == res_ and (label == "" or tostring(s.text or ""):lower():find(label:lower(), 1, true)) then ok = true end
    end
    chk("src", ok, tostring(#(c.source or {})) .. " source constraint(s)")
  end
  if gold.amb then chk("amb", m.ambiguity and m.ambiguity.state == gold.amb, m.ambiguity and m.ambiguity.state) end
  if gold.alts then
    local want = {}
    for id in gold.alts:gmatch("[^|]+") do want[id] = true end
    local have = {}
    local function scan(r) if r and r.candidates then for _, cd in ipairs(r.candidates) do have[cd.id] = true end end end
    for _, r in pairs(m.roles or {}) do scan(r) end
    for _, k in ipairs({ "subject", "concept", "target", "focus", "object" }) do scan(m[k]) end
    for _, p in ipairs(m.ambiguity and m.ambiguity.points or {}) do for _, cd in ipairs(p.candidates or {}) do if cd.id then have[cd.id] = true end end end
    local ok = true
    for id in pairs(want) do if not have[id] then ok = false end end
    chk("alts", ok, table.concat(U.sorted_keys(have), "|"))
  end
  if gold.ctx then
    local want = list_of(gold.ctx)
    local have = {}
    for _, d in ipairs(m.dependencies or {}) do have[d.kind] = true end
    local ok = true
    if want[1] == "none" then ok = next(have) == nil else for _, w in ipairs(want) do if not have[w] then ok = false end end end
    chk("ctx", ok, table.concat(U.sorted_keys(have), ","))
  end
  if gold.items then
    local want = {}
    for x in gold.items:gmatch("[^|]+") do want[#want + 1] = norm_text(x) end
    local ok = m.items ~= nil and #m.items == #want
    if ok then for i, w in ipairs(want) do if norm_text(m.items[i].text) ~= w then ok = false end end end
    chk("items", ok, m.items and table.concat(U.map(m.items, function(r) return r.text end), "|") or "none")
  end
  if gold.inst then
    local ins = m.instruction
    local ok = ins ~= nil
    local got = {}
    if ins then
      for kv in (gold.inst .. ","):gmatch("(.-),") do
        local k, v = kv:match("^(%w+)=(.*)$")
        if k == "slot" then if ins.slot ~= v then ok = false end
        elseif k == "value" then
          local val = ins.value and (tostring(ins.value.year or ins.value.word or ins.value.label or "")) or ""
          if not val:lower():find(v:lower(), 1, true) then ok = false end
        elseif k == "corr" then if (ins.correction and "1" or "0") ~= v then ok = false end
        elseif k == "persist" then if (ins.persist and "1" or "0") ~= v then ok = false end
        elseif k == "verb" then if ins.verb ~= v then ok = false end end
      end
      got = { tostring(ins.slot), ins.value and tostring(ins.value.year or ins.value.word) or "-", tostring(ins.correction), tostring(ins.persist) }
    end
    chk("inst", ok, table.concat(got, "/"))
  end
  local cx = m.context or {}
  if gold.dep then
    local got = cx.dependency and cx.dependency.primary or "-"
    chk("dep", got == gold.dep, got)
  end
  if gold.ref then
    -- ref=<mention>><antecedent text | resolved | ambiguous | unresolved>, ...
    local ok, got = true, {}
    for _, spec in ipairs(list_of(gold.ref)) do
      local mention, want = spec:match("^(.-)>(.*)$")
      local found
      for _, r in ipairs(cx.references or {}) do if norm_text(r.mention) == norm_text(mention) then found = r end end
      if not found then ok = false; got[#got + 1] = mention .. ">(none)"
      else
        local w = norm_text(want)
        local have = found.status
        if w == "resolved" or w == "ambiguous" or w == "unresolved" then
          if have ~= w then ok = false end
        else
          if have ~= "resolved" or norm_text((found.antecedent and found.antecedent.text) or "") ~= w then ok = false end
        end
        got[#got + 1] = mention .. ">" .. have .. ((found.antecedent and found.antecedent.text) and (":" .. found.antecedent.text:sub(1, 30)) or "")
      end
    end
    chk("ref", ok, table.concat(got, ","))
  end
  if gold.active or gold.inactive then
    local act = {}
    for _, c in ipairs(cx.active_constraints or {}) do if c.slot then act[c.slot .. ":" .. tostring(c.value)] = true end end
    local ok = true
    for _, spec in ipairs(list_of(gold.active)) do if not act[spec] then ok = false end end
    for _, spec in ipairs(list_of(gold.inactive)) do if act[spec] then ok = false end end
    chk(gold.active and "active" or "inactive", ok, table.concat(U.sorted_keys(act), ","))
  end
  if gold.sel then
    -- sel=+fragment,-fragment : memory items whose text contains the fragment must (not) have been selected
    local ok, sel = true, (cx.memory and cx.memory.selected) or {}
    for _, spec in ipairs(list_of(gold.sel)) do
      local sign, frag = spec:sub(1, 1), spec:sub(2):lower()
      local hit = false
      for _, it in ipairs(sel) do if (it.text or ""):lower():find(frag, 1, true) then hit = true end end
      if (sign == "+" and not hit) or (sign == "-" and hit) then ok = false end
    end
    chk("sel", ok, tostring(#sel) .. " selected")
  end
  if gold.unres then chk("unres", #(cx.unresolved or {}) == tonumber(gold.unres), tostring(#(cx.unresolved or {}))) end
  if gold.chain then
    local got = m.query and m.query.chain and table.concat(m.query.chain, ">") or ""
    chk("chain", got == gold.chain, got)
  end
  if gold.pol then chk("pol", (m.polarity or "positive") == gold.pol, m.polarity) end
  if gold.evid then chk("evid", (m.requires_external_evidence and "1" or "0") == gold.evid, tostring(m.requires_external_evidence)) end
  return { ok = ok_all, fields = res }
end

---------------------------------------------------------------- semantic signature (metamorphic tests)
function E.signature(m)
  if not m then return "none" end
  -- the asked role's wh-noun ("Which city ...") is a type constraint on the answer, not an argument: it is not part of the signature
  local function r(x) if not x or x.asked then return "-" end return x.resolved_id or norm_text(x.text) end
  local negs = {}
  for _, n in ipairs(m.constraints and m.constraints.negative or {}) do negs[#negs + 1] = tostring(n.target and (n.target.type or n.target.text) or "?") end
  table.sort(negs)
  local tcs = {}
  for _, t in ipairs(all_temporal(m)) do
    if t.role ~= "derived" then tcs[#tcs + 1] = tostring(t.op) .. ":" .. tostring(t.year or t.text) end
  end
  table.sort(tcs)
  return table.concat({ m.intent or "?", m.relation and m.relation.id or "-", r(m.roles and m.roles.from), r(m.roles and m.roles.to), r(m.subject), r(m.concept),
    m.query and m.query.ask or "-", table.concat(negs, "+"), table.concat(tcs, "+"), m.ambiguity and m.ambiguity.state or "?", m.temporal_scope or "-" }, "|")
end

---------------------------------------------------------------- runner factory (shared by tools, tests and the CLI)
-- mode: "full" | "baseline" | "lexical_only" | comma-separated ablation flags (no_types,no_domain,no_hypotheses,no_coref,no_memory,...)
local MAIN_FALLBACK = { status = "no_interpretation", speech_act = "unknown", intent = "unknown",
  constraints = { positive = {}, negative = {}, temporal = {}, geographic = {}, source = {}, preferences = {}, restrictions = {} },
  ambiguity = { state = "unresolvable", points = {} }, roles = {}, dependencies = {} }

function E.make_runner(mode, lex, extra)
  mode = mode or "full"
  extra = extra or {}
  if mode == "baseline" then
    local B = require("asi.nlu.baseline")
    return function(t) return B.interpret(t, lex), 0 end
  elseif mode == "lexical_only" then
    local B = require("asi.nlu.baseline")
    return function(t) return B.lexical_only(t, lex), 0 end
  end
  local I = require("asi.nlu.interp")
  local Memory = require("asi.nlu.memory")
  local flags = {}
  if mode ~= "full" then for f in mode:gmatch("[^,]+") do flags[f] = true end end
  local interp = I.new({ flags = flags, lexicon = lex, budget = extra.budget })
  return function(t, cs)
    local turns = cs and cs.turns
    if not turns or flags.no_memory then
      local r = interp:interpret((turns and cs.final_text) or t, {})
      return r.main or MAIN_FALLBACK, r.work and r.work.total or 0
    end
    local mem = Memory.new({ ns = { user = "eval", project = "eval", conversation = cs.id } })
    local last, work = nil, 0
    for i, turn in ipairs(turns) do
      local r = interp:interpret(turn.text, { memory = mem, speaker = turn.speaker, light = (turn.speaker ~= "user") })
      work = work + (r.work and r.work.total or 0)
      if i == #turns then last = r end
    end
    return (last and last.main) or MAIN_FALLBACK, work
  end
end

---------------------------------------------------------------- running + aggregation
-- runner(text, case) -> interpretation table (the "main" sentence interpretation)
function E.run(cases, runner, lex, opts)
  opts = opts or {}
  local out = { results = {}, by_cat = {}, field_fail = {}, serious_fail = 0, any_fail = 0, n = #cases, work = 0, wall = 0 }
  local sigs = {}
  for _, cs in ipairs(cases) do
    local t0 = os.clock()
    local ok, m, work = pcall(runner, cs.text, cs)
    out.wall = out.wall + (os.clock() - t0)
    local cmp
    if not ok then
      cmp = { ok = false, fields = { crash = { ok = false, got = tostring(m) } } }
      m = nil
    else
      cmp = E.compare(lex, m, cs.gold)
      out.work = out.work + (work or 0)
    end
    local serious_bad = false
    for k, f in pairs(cmp.fields) do
      if not f.ok then
        out.field_fail[k] = (out.field_fail[k] or 0) + 1
        if E.SERIOUS[k] or k == "crash" then serious_bad = true end
      end
    end
    local cat = out.by_cat[cs.category]
    if not cat then cat = { n = 0, pass = 0, serious = 0 }; out.by_cat[cs.category] = cat end
    cat.n = cat.n + 1
    if cmp.ok then cat.pass = cat.pass + 1 else out.any_fail = out.any_fail + 1 end
    if serious_bad then cat.serious = cat.serious + 1; out.serious_fail = out.serious_fail + 1 end
    local r = { case = cs, ok = cmp.ok, serious = serious_bad, fields = cmp.fields, interp = m }
    out.results[#out.results + 1] = r
    if cs.gold.mm then
      local gid, rel_, other = cs.gold.mm:match("^([%w_]+):(%a+):?([%w_]*)$")
      if gid then sigs[#sigs + 1] = { id = cs.id, group = gid, kind = rel_, other = other, sig = E.signature(m), case = cs } end
    end
  end
  -- metamorphic checks: members of one class must share a signature; `ne` classes must differ from the class they name
  local classes = {}
  for _, s in ipairs(sigs) do classes[s.group] = classes[s.group] or {}; table.insert(classes[s.group], s) end
  out.metamorphic = { eq_total = 0, eq_ok = 0, ne_total = 0, ne_ok = 0, failures = {} }
  for gid, members in pairs(classes) do
    local base = members[1].sig
    for i = 2, #members do
      out.metamorphic.eq_total = out.metamorphic.eq_total + 1
      if members[i].sig == base then out.metamorphic.eq_ok = out.metamorphic.eq_ok + 1
      else table.insert(out.metamorphic.failures, { kind = "equivalence", group = gid, a = members[1].id, b = members[i].id, sig_a = base, sig_b = members[i].sig }) end
    end
    for _, m in ipairs(members) do
      if m.kind == "ne" and m.other ~= "" and classes[m.other] then
        out.metamorphic.ne_total = out.metamorphic.ne_total + 1
        if classes[m.other][1].sig ~= m.sig then out.metamorphic.ne_ok = out.metamorphic.ne_ok + 1
        else table.insert(out.metamorphic.failures, { kind = "distinction", group = gid, other = m.other, a = m.id, sig = m.sig }) end
      end
    end
  end
  return out
end

function E.summary(rep, label)
  local lines = {}
  local n = rep.n
  local lo, hi = U.wilson(n - rep.any_fail, n)
  local slo, shi = U.wilson(n - rep.serious_fail, n)
  lines[#lines + 1] = string.format("%s: n=%d  all-fields accuracy=%.3f [%.3f,%.3f]  serious-error rate=%.3f [%.3f,%.3f]  (any-error %.3f)",
    label or "eval", n, (n - rep.any_fail) / n, lo, hi, rep.serious_fail / n, 1 - shi, 1 - slo, rep.any_fail / n)
  for _, cat in ipairs(U.sorted_keys(rep.by_cat)) do
    local c = rep.by_cat[cat]
    local l, h = U.wilson(c.pass, c.n)
    lines[#lines + 1] = string.format("  %-28s n=%-3d pass=%-3d acc=%.2f [%.2f,%.2f] serious=%d", cat, c.n, c.pass, c.pass / c.n, l, h, c.serious)
  end
  local ff = {}
  for k, v in pairs(rep.field_fail) do ff[#ff + 1] = { k, v } end
  table.sort(ff, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  local parts = {}
  for _, x in ipairs(ff) do parts[#parts + 1] = x[1] .. "=" .. x[2] end
  lines[#lines + 1] = "  failing fields: " .. (#parts > 0 and table.concat(parts, " ") or "none")
  if rep.metamorphic and (rep.metamorphic.eq_total + rep.metamorphic.ne_total) > 0 then
    local m = rep.metamorphic
    lines[#lines + 1] = string.format("  metamorphic: equivalence %d/%d  distinction %d/%d", m.eq_ok, m.eq_total, m.ne_ok, m.ne_total)
  end
  return table.concat(lines, "\n")
end

function E.failures(rep, limit)
  local out = {}
  for _, r in ipairs(rep.results) do
    if not r.ok then
      local bad = {}
      for k, f in pairs(r.fields) do if not f.ok then bad[#bad + 1] = string.format("%s: got [%s] want [%s]", k, tostring(f.got), tostring(f.expected)) end end
      table.sort(bad)
      out[#out + 1] = string.format("%s [%s] %q%s\n    %s", r.case.id, r.case.category, r.case.text, r.serious and " (SERIOUS)" or "", table.concat(bad, "\n    "))
      if limit and #out >= limit then break end
    end
  end
  return table.concat(out, "\n")
end

---------------------------------------------------------------- manifests (dev / val / test integrity)
function E.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function E.checksum(path)
  local s = E.read_file(path)
  return s and U.sha256(s) or nil
end

return E
