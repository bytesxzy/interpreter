-- usage: lua5.4 tools/template_coverage.lua --templates path.json [--vocab heldout3] [--show fail|all|none] [--json out.json]
-- Template-level coverage, separated from retrieval: for every FACT template, does the assertion extractor produce the intended (relation, holder, value)?
-- For every QUESTION template, does the interpreter produce the intended (relation, known role = holder, asked role = value)?
-- Names are drawn from the syllable tables of asi.nlu.rbench, so no entity is in the lexicon.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local U = require("asi.nlu.util")
local B = require("asi.nlu.rbench")
local R = require("asi.nlu.resources")
local Interp = require("asi.nlu.interp")
local Assertions = require("asi.nlu.assertions")

local opts = { vocab = "heldout3", show = "fail", samples = "3" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end
assert(opts.templates, "--templates path.json is required")
B.load_templates(opts.vocab, opts.templates)
local gen = B.generate({ vocab = opts.vocab, seed = 1, n_facts = 5 })   -- forces the vocabulary tables to be valid; names below use the same generator functions
local lex = R.core()
local interp = Interp.new({ lexicon = lex })
local extractor = Assertions.new(lex, {})

local V = B.VOCAB[opts.vocab]
local rng = U.rng(99)
local function name(coda) local s = rng:pick(V.onset) .. rng:pick(V.mid) .. rng:pick(coda); return s:sub(1, 1):upper() .. s:sub(2) end
local function fresh()
  return { K = name(V.coda_country), C = name(V.coda_city), O = name(V.coda_city) .. " " .. rng:pick(V.org),
    P = rng:pick(V.first) .. " " .. rng:pick(V.last), X = rng:pick(V.money) }
end
local function fill(t, v) return (t:gsub("%%(%u)", function(k) return v[k] or ("%" .. k) end)) end
local HOLDER = { capital = "K", currency = "K", founder = "O", ceo = "O", headquarters = "O" }
local VALUE = { capital = "C", currency = "X", founder = "P", ceo = "P", headquarters = "C" }
local REL = { capital = "capital", currency = "currency", founder = "founder", ceo = "ceo", headquarters = "headquarters" }

local function norm(s) return (s or ""):lower():gsub("[^%w ]", ""):gsub("%s+", " ") end

local results = { facts = {}, questions = {} }
for rel, lists in pairs(B.TEMPLATES[opts.vocab]) do
  for ti, tm in ipairs(lists) do
    local text = tm[1]
    local pass, tried, why = 0, 0, nil
    for _ = 1, tonumber(opts.samples) do
      local v = fresh()
      local sentence = fill(text, v)
      local res = extractor:extract(sentence, {})
      tried = tried + 1
      local ok = false
      for _, a in ipairs(res.assertions) do
        local function t(d) return d and norm(d.text or (d.key and d.key:gsub("^mention:", "")) or "") or "" end
        if a.rel == REL[rel] and not a.is_class and a.polarity ~= "negative" then
          local holder, value = norm(v[HOLDER[rel]]), norm(v[VALUE[rel]])
          local from_ok = a.from and (norm(a.from.text or "") == holder or norm((a.from.key or ""):gsub("^mention:", "")) == holder)
          local to_ok = a.to and (norm(a.to.text or "") == value or norm((a.to.key or ""):gsub("^mention:", "")) == value or norm((a.to.key or ""):gsub("^term:", "")) == value
            or norm((a.to.key or ""):gsub("^sense:", "")) == value or (a.to.literal and norm(a.to.literal.text) == value))
          if from_ok and to_ok then ok = true end
          why = why or string.format("got %s(%s -> %s)", a.rel, tostring(a.from and (a.from.key or a.from.text)), tostring(a.to and (a.to.key or a.to.text)))
        else why = why or string.format("got %s", tostring(a.rel)) end
      end
      if #res.assertions == 0 then why = "no assertion" end
      if ok then pass = pass + 1 end
    end
    results.facts[#results.facts + 1] = { rel = rel, text = text, pass = pass, tried = tried, why = why }
  end
end
for rel, qs in pairs(B.QUESTIONS[opts.vocab]) do
  for _, text in ipairs(qs) do
    local pass, tried, why = 0, 0, nil
    for _ = 1, tonumber(opts.samples) do
      local v = fresh()
      local q = fill(text, v)
      local r = interp:interpret(q, {})
      local m = r.main
      tried = tried + 1
      local ok = false
      if m and m.status == "ok" and m.relation and m.query then
        local ref = m.roles and m.roles[m.query.known_role]
        local holder = norm(v[HOLDER[rel]])
        local rel_ok = (m.relation.id == REL[rel]) or (m.relation.id == "creator" and rel == "founder") or (m.relation.id == "leader" and rel == "ceo")
        local dir_ok = m.query.known_role == "from" and m.query.ask == "to"
        local ent_ok = ref and (norm(ref.text):find(holder, 1, true) ~= nil)
        ok = rel_ok and dir_ok and ent_ok and true or false
        if not ok then why = string.format("got rel=%s known=%s ask=%s holder=%s", m.relation.id, tostring(m.query.known_role), tostring(m.query.ask), ref and ref.text or "-") end
      else why = string.format("intent=%s status=%s", m and tostring(m.intent) or "-", m and tostring(m.status) or "-") end
      if ok then pass = pass + 1 end
    end
    results.questions[#results.questions + 1] = { rel = rel, text = text, pass = pass, tried = tried, why = why }
  end
end

local function summarize(list, label)
  local n, ok = 0, 0
  for _, r in ipairs(list) do n = n + r.tried; ok = ok + r.pass end
  local lo, hi = U.wilson(ok, n)
  print(string.format("%-10s %d/%d = %.3f [%.3f,%.3f]", label, ok, n, n > 0 and ok / n or 0, lo, hi))
  table.sort(list, function(a, b) if a.rel ~= b.rel then return a.rel < b.rel end return a.text < b.text end)
  for _, r in ipairs(list) do
    if opts.show == "all" or (opts.show == "fail" and r.pass < r.tried) then
      print(string.format("   [%s] %d/%d  %-68s %s", r.rel, r.pass, r.tried, r.text, r.pass < r.tried and (r.why or "") or ""))
    end
  end
  return ok, n
end
local fo, fn = summarize(results.facts, "FACTS")
local qo, qn = summarize(results.questions, "QUESTIONS")
if opts.json then local f = io.open(opts.json, "w"); f:write(U.json_encode({ facts = results.facts, questions = results.questions, fact_pass = fo, fact_n = fn, q_pass = qo, q_n = qn }, { pretty = true, nan_null = true })); f:close() end
