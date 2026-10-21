-- Evaluation of the dataset reading: what the engine makes of a dataset (kind, persona, tone, which parts are facts and which are not) and how it follows the user's
-- instructions about it.  usage: lua5.4 tools/run_dataset_eval.lua CASES.json [--failures N] [--verbose]
-- Case file: { "schema": "nlu.dataset_cases/1", "cases": [ { "id", "category", "files": [ { "name", "text" } ], "expect": {...}, "turns": [ { "say", "expect": {...} } ] } ] }
--   expect.kind          dataset kind: persona_sheet | style_guide | dialogue_corpus | qa_pairs | knowledge_base | mixed
--   expect.persona       null (no persona) | { "name": "Aria" | null, "placeholder": "AI model name" | null }
--   expect.descriptors   ids that must be among the persona's descriptors        expect.not_descriptors   ids that must NOT be
--   expect.not_facts     substrings whose sentences must not become facts (no assertion built from them, no vocabulary entry)
--   expect.facts         [ { "rel", "from", "to" } ]  each must be among the extracted assertions (from / to: substring of the entity key or text, case-insensitive)
--   expect.answers       [ { "q", "status", "answer" } ]  the engine's evidence status and verified answer for a question
--   expect.flagged       substrings that must be reported as instructions aimed at the reader
--   turns[i].expect      the same, checked after the user's instruction; plus persona_active (bool), reply_contains (substrings of the engine's reply)
-- Every check counts once; a case passes when all of its checks pass.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local U = require("asi.nlu.util")
local R = require("asi.nlu.resources")
local K = require("asi.nlu.knowledge")
local Engine = require("asi.nlu.engine")
local Voice = require("asi.nlu.voice")
local Profile = require("asi.nlu.profile")

local path = arg[1]
if not path then io.stderr:write("usage: run_dataset_eval.lua CASES.json [--failures N] [--verbose]\n"); os.exit(2) end
local max_fail, verbose = 20, false
for i = 2, #arg do
  if arg[i] == "--failures" then max_fail = tonumber(arg[i + 1]) or 20 end
  if arg[i] == "--verbose" then verbose = true end
end
local f = assert(io.open(path, "rb")); local text = f:read("a"); f:close()
local doc, derr = U.json_decode(text)
if not doc then io.stderr:write("bad case file: " .. tostring(derr) .. "\n"); os.exit(2) end

local function lower(s) return tostring(s or ""):lower() end
local function contains(hay, needle) return lower(hay):find(lower(needle), 1, true) ~= nil end

local lex = R.core()
local stats = {}     -- check type -> { n, ok }
local function tally(kind, ok) local s = stats[kind]; if not s then s = { n = 0, ok = 0 }; stats[kind] = s end; s.n = s.n + 1; if ok then s.ok = s.ok + 1 end end
local failures = {}

local function desc_set(section)
  local set = {}
  for _, d in ipairs(section and section.descriptors or {}) do set[d.id] = true end
  return set
end

local function has_descriptor(set, want)
  if set[want] then return true end
  if want == "voice:*" then for id in pairs(set) do if id:sub(1, 6) == "voice:" then return true end end end
  if want:sub(1, 6) == "voice:" then
    for id in pairs(set) do if id:sub(1, 6) == "voice:" and contains(id, want:sub(7)) then return true end end
  end
  return false
end

local function entity_matches(d, want)
  if not d then return false end
  if want == nil or want == "" then return true end
  return contains(d.key, want) or contains(d.text, want) or (d.literal and (contains(d.literal.text, want) or tostring(d.literal.value) == want)) or false
end

local function all_assertions(kb)
  local out = {}
  for _, doc_ in pairs(kb.index.docs) do
    for _, aid in ipairs(doc_.assertions or {}) do
      local a = kb.index.assertions[aid]
      if a and not a.removed then out[#out + 1] = a end
    end
  end
  return out
end

local function run_expect(case, kb, eng, mem, ex, section, reply, label, fails)
  local function check(kind, ok, msg)
    tally(kind, ok)
    if not ok then fails[#fails + 1] = label .. " " .. kind .. ": " .. msg end
  end
  if ex.kind then
    local kind = Profile.kind(kb.profiles[next(kb.profiles)] or Profile.new())
    local got
    for _, did in ipairs(kb.dataset_order) do got = got or select(1, Profile.kind(kb.profiles[did])) end
    check("kind", got == ex.kind, "expected " .. ex.kind .. ", got " .. tostring(got))
  end
  if ex.persona ~= nil then
    local p = section and section.persona
    if ex.persona == U.NULL or ex.persona == false then
      check("persona", not (p and (p.name or p.name_placeholder or section.active)), "expected no persona, got " .. tostring(p and (p.name or p.name_placeholder) or (section and section.active and "(unnamed active voice)")))
    else
      local ok = p ~= nil
      local why = ok and "" or "no persona"
      if ok and ex.persona.name and ex.persona.name ~= U.NULL then ok = lower(p.name) == lower(ex.persona.name); why = "name " .. tostring(p.name) .. " vs " .. tostring(ex.persona.name) end
      if ok and ex.persona.placeholder and ex.persona.placeholder ~= U.NULL then
        ok = p.name_placeholder ~= nil and lower(p.name_placeholder):gsub("[%[%]<>{}%s]", "") == lower(ex.persona.placeholder):gsub("[%[%]<>{}%s]", "")
        why = "placeholder " .. tostring(p.name_placeholder) .. " vs " .. tostring(ex.persona.placeholder)
      end
      check("persona", ok, why)
    end
  end
  local set = desc_set(section)
  for _, d in ipairs(ex.descriptors or {}) do check("descriptor_recall", has_descriptor(set, d), "missing " .. d .. " (got " .. table.concat(U.sorted_keys(set), ",") .. ")") end
  for _, d in ipairs(ex.not_descriptors or {}) do check("descriptor_exclusion", not has_descriptor(set, d), "unexpected " .. d) end
  if ex.persona_active ~= nil then check("persona_active", (section and section.active or false) == ex.persona_active, "active=" .. tostring(section and section.active)) end
  for _, sub in ipairs(ex.reply_contains or {}) do check("reply", reply ~= nil and contains(reply.text, sub), "reply lacks '" .. sub .. "': " .. tostring(reply and reply.text):sub(1, 160)) end
  if ex.not_facts or ex.facts then
    local as = all_assertions(kb)
    for _, sub in ipairs(ex.not_facts or {}) do
      local bad
      for _, a in ipairs(as) do if contains(a.text, sub) or (a.qa and contains(a.qa.answer, sub)) then bad = a.rel .. ":" .. tostring(a.text):sub(1, 60); break end end
      if not bad then for key, v in pairs(kb.vocab) do if contains(v.text or key, sub) then bad = "vocab " .. key; break end end end
      check("not_facts", bad == nil, "'" .. sub .. "' became knowledge (" .. tostring(bad) .. ")")
    end
    for _, fx in ipairs(ex.facts or {}) do
      local found
      for _, a in ipairs(as) do
        if (not fx.rel or a.rel == fx.rel) and entity_matches(a.from, fx.from) and entity_matches(a.to, fx.to) then found = true; break end
      end
      check("facts", found == true, "missing fact " .. U.json_encode(fx))
    end
  end
  for _, fl in ipairs(ex.flagged or {}) do
    local found
    for _, list in pairs(kb.reader_directed) do for _, rd in ipairs(list) do if contains(rd.text, fl) then found = true end end end
    check("flagged", found == true, "'" .. fl .. "' not reported as aimed at the reader")
  end
  for _, aq in ipairs(ex.answers or {}) do
    local out = eng:process(aq.q, { memory = mem, cache = false })
    local es = out.record.evidence_sufficiency
    local ok = true
    local why = ""
    if aq.status then ok = es.status == aq.status; why = "status " .. tostring(es.status) .. " vs " .. aq.status end
    if ok and aq.answer then ok = es.answer ~= nil and contains(es.answer.text, aq.answer); why = "answer " .. tostring(es.answer and es.answer.text) .. " vs " .. aq.answer end
    check("answers", ok, aq.q .. " -> " .. why)
  end
end

local n_cases, n_pass = 0, 0
local by_cat = {}
for _, case in ipairs(doc.cases or {}) do
  n_cases = n_cases + 1
  local kb = K.new(lex)
  local ok_ingest, ierr = pcall(function()
    for _, file in ipairs(case.files or {}) do
      kb:ingest(file.text, { name = file.name, dataset = (file.name:gsub("%..*$", "")) })
    end
  end)
  local fails = {}
  if not ok_ingest then fails[#fails + 1] = "ingest raised: " .. tostring(ierr) end
  local eng = Engine.new({ knowledge = kb })
  local mem = eng:memory("eval-" .. tostring(case.id), "eval")
  if ok_ingest then
    local ok_run, rerr = pcall(function()
      local section = Voice.build(kb, {}, {})
      if case.expect then run_expect(case, kb, eng, mem, case.expect, section, nil, case.id .. " [reading]", fails) end
      for ti, turn in ipairs(case.turns or {}) do
        local out = eng:process(turn.say, { memory = mem, cache = false })
        local rec = out.record
        if turn.expect then run_expect(case, kb, eng, mem, turn.expect, rec.voice, rec.engine_reply, case.id .. " [turn " .. ti .. ": " .. turn.say .. "]", fails) end
      end
    end)
    if not ok_run then fails[#fails + 1] = "run raised: " .. tostring(rerr) end
  end
  local cat = case.category or "uncategorised"
  by_cat[cat] = by_cat[cat] or { n = 0, ok = 0 }
  by_cat[cat].n = by_cat[cat].n + 1
  if #fails == 0 then n_pass = n_pass + 1; by_cat[cat].ok = by_cat[cat].ok + 1
  else
    failures[#failures + 1] = { id = case.id, fails = fails }
  end
  if verbose then print(case.id, #fails == 0 and "ok" or "FAIL") end
end

local function wilson(k, n)
  if n == 0 then return 0, 0 end
  local z = 1.96
  local p = k / n
  local den = 1 + z * z / n
  local c = (p + z * z / (2 * n)) / den
  local h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
  return math.max(0, c - h), math.min(1, c + h)
end

local lo, hi = wilson(n_pass, n_cases)
print(string.format("dataset cases: n=%d  all-checks accuracy=%.3f [%.3f,%.3f]", n_cases, n_cases > 0 and n_pass / n_cases or 0, lo, hi))
local kinds = U.sorted_keys(stats)
for _, k in ipairs(kinds) do
  local s = stats[k]
  local l, h = wilson(s.ok, s.n)
  print(string.format("  %-22s %3d/%-3d = %.3f [%.3f,%.3f]", k, s.ok, s.n, s.ok / s.n, l, h))
end
local cats = U.sorted_keys(by_cat)
for _, c in ipairs(cats) do print(string.format("  category %-22s %3d/%-3d", c, by_cat[c].ok, by_cat[c].n)) end
if #failures > 0 and max_fail > 0 then
  print("\nFAILURES:")
  for i, fl in ipairs(failures) do
    if i > max_fail then print("  ... " .. (#failures - max_fail) .. " more"); break end
    for _, m in ipairs(fl.fails) do print("  " .. m) end
  end
end
os.exit(n_pass == n_cases and 0 or 1)
