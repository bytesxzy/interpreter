-- asi.nlu.qa: a question and the answer given to it become one assertion.
--   QA.convert(kb, interp, question, answer)  ->  assertion | nil, reason
-- The question is interpreted by the engine's OWN question interpreter (relation, known role, asked role, subject entity); the answer supplies the asked
-- value: the whole answer when it is one value ("Berlin", "1999", "8849 metres"), otherwise the single mention of the asked type found inside it.
-- A yes/no question takes its polarity from the answer ("Yes!", "Nope").  Nothing is guessed: an unresolved subject, several candidate values or a question
-- with a time / source / exclusion constraint produce no assertion and a reason, never a best guess.
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Plan = require("asi.nlu.plan")
local Assertions = require("asi.nlu.assertions")
local L = require("asi.nlu.data.style_lex")

local QA = {}

local YES = U.set({ "yes", "yeah", "yep", "yup", "correct", "right", "indeed", "certainly", "absolutely", "sure", "affirmative", "true", "aye", "yea" })
local NO = U.set({ "no", "nope", "nah", "incorrect", "wrong", "negative", "false", "nay" })
local INTERJ = U.set(L.interjections)

-- words that introduce the value without being part of it
local LEAD_PHRASES = { { "the", "answer", "is" }, { "it", "is" }, { "it's" }, { "it", "was" }, { "that", "is" }, { "that's" }, { "that", "was" }, { "this", "is" }, { "answer" }, { "a" }, { "ans" } }

local function words_of(text)
  local ws = {}
  for w in text:lower():gsub("[’]", "'"):gmatch("[%a][%a']*") do ws[#ws + 1] = w end
  return ws
end

-- the answer without leading interjections / lead-in phrases and without closing punctuation
local function clean_answer(text)
  local t = text:gsub("^%s+", ""):gsub("%s+$", "")
  for _ = 1, 4 do
    local before = t
    -- a leading run of interjection words ("Oh!", "Ahoy,", "WOW!!!")
    local w, rest = t:match("^([%a']+)[%s%p]*()")
    if w and INTERJ[w:lower()] and rest then t = t:sub(rest) end
    local lw = words_of(t)
    for _, ph in ipairs(LEAD_PHRASES) do
      local ok = #lw > #ph
      for i, x in ipairs(ph) do if lw[i] ~= x then ok = false break end end
      if ok then
        -- drop the phrase's words from the start of the text
        local pos = 1
        for _ = 1, #ph do
          local _, e = t:find("^[%s%p]*[%a][%a'’]*", pos)
          pos = (e or pos) + 1
        end
        t = t:sub(pos):gsub("^[%s%p]+", "")
        break
      end
    end
    if t == before then break end
  end
  t = t:gsub("[%s%p]+$", "")
  return t
end

-- a lexicon entity must fit the asked type; a name the data introduces ("mention:" keys, typed only by a guess) may fit it as a supertype or without any type
local function compatible(lex, ty, expected, key)
  if not expected or expected == "" then return true end
  local guess = key and key:sub(1, 8) == "mention:"
  if not ty then return guess == true end
  return lex:compat(ty, expected) >= (guess and 0.5 or 0.9)
end

-- the descriptor of the asked value inside an answer
local function answer_descriptor(kb, answer, expected, subject_key)
  local clean = clean_answer(answer)
  if clean ~= "" then
    local d = kb:link_text(clean, expected)
    if d and not d.unverified_link and (d.literal or d.key) and d.key ~= subject_key then
      if d.literal then
        if not expected or kb.lex:compat(d.type or "number", expected) >= 0.5 then return d, "whole answer" end
      elseif compatible(kb.lex, d.type, expected, d.key) then
        d.status = d.status or "resolved"
        return d, "whole answer"
      end
    end
  end
  -- the single mention of the expected type inside the answer
  local ex = Assertions.new(kb.lex, {})
  local r = ex:extract(answer, {})
  local cands, seen = {}, {}
  for _, m in ipairs(r.mentions or {}) do
    if m.key and m.key ~= subject_key and not seen[m.key] and not m.weak and not m.ambiguous then
      local ty = m.type
      if not ty and m.key:sub(1, 8) == "mention:" then ty = nil end
      if compatible(kb.lex, ty, expected, m.key) then seen[m.key] = true; cands[#cands + 1] = m end
    end
  end
  if #cands == 1 then
    local m = cands[1]
    return { key = m.key, text = m.text, type = m.type, status = "resolved" }, "mention in answer"
  elseif #cands > 1 then
    return nil, "several candidate values in the answer"
  end
  -- a quantity: the single number in the answer
  if expected and (expected:find("number") or expected:find("quantity") or expected:find("money")) then
    local an = Lex.analyze(answer, {})
    local found
    for _, u in ipairs(an.units or {}) do
      if u.kind == "number" and u.numval and not u.ordinal then
        if found then return nil, "several numbers in the answer" end
        found = u
      end
    end
    if found then
      local nt = answer:sub(found.s, found.e)
      return { literal = { kind = "number", value = found.numval, text = nt }, text = nt, type = "number" }, "number in answer"
    end
  end
  return nil, "no value of the asked type in the answer"
end

-- interp: an Interp (built on kb.lex); returns an assertion in the index's format (pattern = "qa_pair") or nil, reason
function QA.convert(kb, interp, question, answer)
  local ok, res = pcall(function() return interp:interpret(question, {}) end)
  if not ok or not res or not res.main then return nil, "question not interpreted" end
  local plan = Plan.build(res.main, kb)
  if plan.kind ~= "lookup" and plan.kind ~= "verify" then return nil, "question is not a lookup or a yes/no question" end
  if plan.chain then return nil, "multi-step question" end
  local t = plan.time or {}
  if (t.basis and not t.basis:find("^default")) or (plan.sources and #plan.sources > 0) or (plan.exclusions and #plan.exclusions > 0) then
    return nil, "question has time / source / exclusion constraints"
  end
  local rel = plan.relation and kb.lex:get_rel(plan.relation)
  if not rel then return nil, "relation unknown" end
  if plan.kind == "verify" then
    local fs, ts = plan.from_readings or {}, plan.to_readings or {}
    if #fs ~= 1 or #ts ~= 1 or plan.from_status == "ambiguous" or plan.to_status == "ambiguous" then return nil, "yes/no question about an unresolved pair" end
    local first = words_of(answer)[1]
    local polarity = first and ((YES[first] and "positive") or (NO[first] and "negative")) or nil
    if not polarity then return nil, "answer is neither yes nor no" end
    local f, o = fs[1], ts[1]
    return { rel = rel.id, pattern = "qa_pair", polarity = polarity, modality = "asserted", tense = "present",
      from = { key = f.key, text = f.text, type = f.type, status = "resolved" }, to = { key = o.key, text = o.text, type = o.type, status = "resolved" },
      sent = 0, s = 1, e = #answer, text = question .. " -> " .. answer, qa = { question = question, answer = answer, kind = "yes_no" } }
  end
  local subjects = plan.subjects or {}
  if #subjects ~= 1 or (plan.subject_status ~= "resolved" and plan.subject_status ~= "unseen") then return nil, "question subject is not a single entity" end
  local known, ask = plan.known_role, plan.ask
  if not known or not ask or known == ask then return nil, "question roles unclear" end
  local subj = subjects[1]
  if not subj.key or subj.key:sub(1, 6) == "sense:" or subj.key:sub(1, 5) == "term:" then return nil, "question subject is a concept, not an entity" end
  local expected = rel[ask]
  local d, how = answer_descriptor(kb, answer, expected, subj.key)
  if not d then return nil, how end
  local subject_d = { key = subj.key, text = subj.text, type = subj.type, status = "resolved" }
  local a = { rel = rel.id, pattern = "qa_pair", polarity = "positive", modality = "asserted", tense = "present", sent = 0, s = 1, e = #answer,
    text = question .. " -> " .. answer, qa = { question = question, answer = answer, kind = "lookup", value_from = how } }
  a[known], a[ask] = subject_d, d
  return a
end

return QA
