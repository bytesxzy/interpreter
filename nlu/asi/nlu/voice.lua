-- asi.nlu.voice: the voice the assistant will use.
-- The persona a dataset declares or implies (asi.nlu.profile) is adjusted by what the USER said about it (asi.nlu.override: "a calmer tone", "no caps", "ignore the personality",
-- "play Bob"), and the result is announced in words with the evidence it rests on.  The voice is PRESENTATIONAL: it changes wording, never facts, evidence or rules, and a user
-- instruction always outranks the dataset (user > dataset > default).
--   Voice.collect(memory)            standing voice / reading instructions of a conversation, oldest first
--   Voice.state(items)               their combined effect
--   Voice.policy(state)              the effect on how the dataset is read (roles included / excluded, reading, record overrides)
--   Voice.effective(personas, state) persona + descriptors after the user's adjustments, with what was dropped and why
--   Voice.build(kb, items, opts)     the `voice` section of an Interpretation Record, with announcement and preview
local U = require("asi.nlu.util")
local Style = require("asi.nlu.style")
local Profile = require("asi.nlu.profile")
local L = require("asi.nlu.data.style_lex")

local V = {}
V.SCHEMA = "nlu.voice/1"

local VOICE_SLOTS = { tone = true, persona = true, dataset_role = true }

---------------------------------------------------------------- the user's standing instructions
function V.collect(mem)
  local items = {}
  if not mem or not mem.order then return items end
  for _, id in ipairs(mem.order) do
    local it = mem.items[id]
    if it and it.status == "active" and (it.kind == "instruction" or it.kind == "correction") and VOICE_SLOTS[it.slot or ""] and type(it.value) == "string" then
      local ops = {}
      for op in it.value:gmatch("[^;]+") do ops[#ops + 1] = op end
      items[#items + 1] = { slot = it.slot, ops = ops, text = it.text, turn = it.turn, id = it.id }
    end
  end
  return items
end

local function fresh_state()
  return { persona = { off = false }, tone = {}, dataset = { include = {}, exclude = {}, records = {} }, applied = {}, refused = {} }
end

-- items: { { ops = {...}, text, turn } ... } oldest first
function V.state(items)
  local st = fresh_state()
  for _, item in ipairs(items or {}) do
    local applied = { text = item.text, turn = item.turn, ops = item.ops }
    st.applied[#st.applied + 1] = applied
    for _, op in ipairs(item.ops or {}) do
      local head, rest = op:match("^(%a+):(.*)$")
      if head == "persona" then
        local sub, arg = rest:match("^(%a+):?(.*)$")
        if sub == "off" then st.persona.off = true
        elseif sub == "on" then st.persona.off = false; st.persona.pick = nil; st.persona.chain = nil
        elseif sub == "pick" then
          st.persona.pick, st.persona.off = arg, false
          -- "the other one" is relative to the persona in force at that point: the picks are kept in order
          st.persona.chain = st.persona.chain or {}
          st.persona.chain[#st.persona.chain + 1] = arg
        elseif sub == "name" then st.persona.name = arg end
      elseif head == "dataset" then
        local sub, arg = rest:match("^(%a+):?(.*)$")
        if sub == "reading" then
          if arg == "default" then st.dataset.reading = nil; st.dataset.include, st.dataset.exclude, st.dataset.records = {}, {}, {}
          else st.dataset.reading = arg; if arg == "facts" then st.persona.off = true end end
        elseif sub == "include" then
          if arg == "behavior_directive" then st.refused[#st.refused + 1] = "instructions aimed at the reader are never treated as facts or obeyed"
          else st.dataset.include[arg] = true; st.dataset.exclude[arg] = nil end
        elseif sub == "exclude" then st.dataset.exclude[arg] = true; st.dataset.include[arg] = nil
        elseif sub == "record" then
          local ref, action = arg:match("^(.*):(%a+)$")
          if ref then st.dataset.records[#st.dataset.records + 1] = { ref = ref, action = action } end
        end
      elseif head == "tone" then
        local sub, arg = rest:match("^([%a_]+):?(.*)$")
        if sub == "reset" then st.tone = {}; st.persona.off = false; st.persona.pick = nil
        elseif sub == "neutral" then st.tone = { { verb = "neutral", turn = item.turn } }
        elseif sub == "set" then st.tone[#st.tone + 1] = { verb = "set", id = arg, turn = item.turn }
        elseif sub == "set_voice" then st.tone[#st.tone + 1] = { verb = "set_voice", label = arg, turn = item.turn }
        elseif sub == "data_style" then st.tone[#st.tone + 1] = { verb = "data_style", turn = item.turn } end
      elseif head == "add" or head == "drop" or head == "more" or head == "less" or head == "down" then
        st.tone[#st.tone + 1] = { verb = head, id = rest, turn = item.turn }
      end
    end
  end
  return st
end

-- how the dataset is to be read, as the knowledge base understands it
function V.policy(st)
  local d = st.dataset
  local pol = { reading = d.reading, include = {}, exclude = {}, records = {} }
  for r in pairs(d.include) do pol.include[r] = true end
  for r in pairs(d.exclude) do pol.exclude[r] = true end
  for _, rr in ipairs(d.records) do pol.records[#pol.records + 1] = { ref = rr.ref, action = rr.action } end
  if not pol.reading and next(pol.include) == nil and next(pol.exclude) == nil and #pol.records == 0 then return nil end
  return pol
end

---------------------------------------------------------------- personas of the datasets
function V.personas(kb)
  local out = {}
  if not kb or not kb.profiles then return out end
  for _, did in ipairs(kb.dataset_order or {}) do
    local pr = kb.profiles[did]
    if pr then
      for _, p in ipairs(Profile.personas(pr)) do p.dataset = did; out[#out + 1] = p end
    end
  end
  -- the order: most evidence first; equal evidence keeps the order of the datasets and, inside one, the order in which the dataset introduces its personas
  for i, p in ipairs(out) do p.order = i end
  table.sort(out, function(a, b)
    local ea = a.evidence.specifications * 3 + a.evidence.declarations * 2 + a.evidence.examples
    local eb = b.evidence.specifications * 3 + b.evidence.declarations * 2 + b.evidence.examples
    if ea ~= eb then return ea > eb end
    return a.order < b.order
  end)
  return out
end

-- lower-case name -> name, for the recogniser of "play Bob instead"
function V.persona_names(kb)
  local names
  for _, p in ipairs(V.personas(kb)) do
    if p.name then names = names or {}; names[p.name:lower()] = p.name end
  end
  return names
end

---------------------------------------------------------------- the effective persona and tone
local function copy_desc(d)
  local c = {}
  for k, v in pairs(d) do c[k] = v end
  return c
end
local function label_of(id) return (L.descriptors[id] and L.descriptors[id].label) or id end
local THRESHOLD = 0.3

function V.effective(personas, st, opts)
  opts = opts or {}
  local eff = { active = false, descriptors = {}, dropped = {}, notes = {}, op_notes = {}, alternatives = {}, conflicts = {} }
  -- 1. which persona
  local chosen
  if not st.persona.off then
    if st.persona.pick then
      chosen = personas[1]
      for _, want0 in ipairs(st.persona.chain or { st.persona.pick }) do
        local want = want0:lower()
        if want == "other" then
          local nxt
          for _, p in ipairs(personas) do if p ~= chosen then nxt = p break end end
          if nxt then chosen = nxt else eff.notes[#eff.notes + 1] = "you asked for the other character, but the dataset names only one persona" end
        else
          local found
          for _, p in ipairs(personas) do if p.name and p.name:lower() == want then found = p break end end
          if found then chosen = found else eff.notes[#eff.notes + 1] = "no persona called '" .. want0 .. "' in the dataset; the previous persona is kept" end
        end
      end
    else
      chosen = personas[1]
    end
    for _, p in ipairs(personas) do if p ~= chosen then eff.alternatives[#eff.alternatives + 1] = { name = p.name, name_placeholder = p.name_placeholder, key = p.key, kind = p.kind } end end
  elseif #personas > 0 then
    eff.notes[#eff.notes + 1] = "the persona of the dataset is switched off at your request"
  end
  -- 2. its descriptors (a copy) and the user's adjustments in order
  local map, order = {}, {}
  local function put(d) if not map[d.id] then order[#order + 1] = d.id end; map[d.id] = d end
  local function remove(id, why)
    if map[id] then
      eff.dropped[#eff.dropped + 1] = { id = id, label = map[id].label, reason = why }
      map[id] = nil
    end
  end
  if chosen then
    for _, d in ipairs(chosen.descriptors or {}) do if d.id:sub(1, 4) ~= "not_" then put(copy_desc(d)) end end
    for _, c in ipairs(chosen.conflicts or {}) do eff.conflicts[#eff.conflicts + 1] = c end
    -- a declared negation ("never shouts") removes what the examples would suggest
    for _, d in ipairs(chosen.descriptors or {}) do
      if d.negates and map[d.negates] then remove(d.negates, "the dataset says the persona does not do this") end
    end
  end
  -- the facts of the dataset are written in the voice it declares: its typography belongs to the persona ("everything is shouted!!!" and every fact in capitals with exclamation marks)
  if chosen and opts.data_style and not st.persona.off then
    local TYPO = { all_caps = true, caps_emphasis = true, exclamatory = true, emoji = true, elongation = true, ellipsis = true }
    local LOUD = { all_caps = true, caps_emphasis = true, exclamatory = true, dramatic = true, enthusiastic = true, elongation = true, emoji = true }
    local loud = false
    for id in pairs(map) do if LOUD[id] then loud = true end end
    if loud then
      for _, d in ipairs(opts.data_style) do
        if TYPO[d.id] and not map[d.id] and (d.strength or 0) >= 0.3 then
          local clash = false
          for id in pairs(map) do for _, x in ipairs(L.excludes[id] or {}) do if x == d.id then clash = true end end end
          for _, cd in ipairs(chosen.descriptors or {}) do if cd.id == "not_" .. d.id then clash = true end end
          if not clash then
            local c = copy_desc(d)
            c.source, c.basis = "measured", "dataset_text"
            c.strength = math.min(d.strength or 0.5, 0.7)
            c.label = c.label or label_of(d.id)
            c.evidence = (d.evidence or "") .. " -- measured from the facts of the dataset, which are written in this voice"
            put(c)
          end
        end
      end
    end
  end
  local function exclude_of(id, why)
    for _, x in ipairs(L.excludes[id] or {}) do remove(x, why) end
  end
  for _, t in ipairs(st.tone or {}) do
    local v, id = t.verb, t.id
    if v == "neutral" then
      for k in pairs(map) do remove(k, "you asked for a neutral tone") end
      eff.neutral = true
    elseif v == "data_style" then
      if chosen and #(chosen.descriptors or {}) > 0 and not st.persona.off then
        -- the dataset HAS a voice (its persona): "like the dataset" is that voice
        for k in pairs(map) do remove(k, "replaced by the dataset's voice, as you asked") end
        for _, d in ipairs(chosen.descriptors) do if d.id:sub(1, 4) ~= "not_" then put(copy_desc(d)) end end
        eff.neutral = nil
      else
      for k in pairs(map) do remove(k, "replaced by the dataset's own writing style, as you asked") end
      if opts.data_style and #opts.data_style > 0 then
        for _, d in ipairs(opts.data_style) do
          local c = copy_desc(d)
          c.source = "measured"
          c.label = c.label or label_of(c.id)
          put(c)
        end
        eff.neutral = nil
      else eff.op_notes[#eff.op_notes + 1] = { text = "the dataset's own text has no distinctive writing style to take over", turn = t.turn } end
      end
    elseif v == "set" then
      for k in pairs(map) do remove(k, "replaced by the voice you asked for") end
      put({ id = id, label = label_of(id), strength = 0.9, source = "user", evidence = "you asked for it" })
      eff.neutral = nil
    elseif v == "set_voice" then
      for k in pairs(map) do remove(k, "replaced by the voice you asked for") end
      put({ id = "voice:" .. t.label:lower(), label = "like " .. t.label, strength = 0.9, source = "user", free = true, evidence = "you asked for it" })
      eff.neutral = nil
    elseif v == "add" then
      local d = map[id]
      if d then d.strength = math.max(d.strength or 0, 0.8); d.source = (d.source == "declared" or d.source == "both") and "both" or "user" else put({ id = id, label = label_of(id), strength = 0.8, source = "user", evidence = "you asked for it" }) end
      exclude_of(id, "contradicts '" .. label_of(id) .. "' that you asked for")
      eff.neutral = nil
    elseif v == "more" then
      local d = map[id]
      if d then d.strength = math.min(1, (d.strength or 0.5) + 0.3); d.adjusted = "more" else put({ id = id, label = label_of(id), strength = 0.7, source = "user", evidence = "you asked for more of it" }) end
      exclude_of(id, "contradicts the '" .. label_of(id) .. "' that you asked for")
      eff.neutral = nil
    elseif v == "less" then
      local d = map[id]
      if d then
        d.strength = (d.strength or 0.5) - 0.4
        d.adjusted = "less"
        if d.strength < THRESHOLD then remove(id, "you asked for less of it") end
      else eff.op_notes[#eff.op_notes + 1] = { text = "'" .. label_of(id) .. "' was not part of the voice, so there is less of it already", turn = t.turn } end
    elseif v == "down" then
      local d = map[id]
      if d then
        -- "tone it down": typography goes, the attitude is reduced
        local grp = L.descriptors[id] and L.descriptors[id].group
        if grp == "typography" then remove(id, "you asked to tone it down")
        else
          d.strength = (d.strength or 0.5) - 0.5
          d.adjusted = "less"
          if d.strength < THRESHOLD then remove(id, "you asked to tone it down") end
        end
      end
    elseif v == "drop" then
      if map[id] then remove(id, "you asked to drop it") else eff.op_notes[#eff.op_notes + 1] = { text = "'" .. label_of(id) .. "' was not part of the voice", turn = t.turn } end
    end
  end
  -- a descriptor that a later instruction put back ("go back to the dataset's tone") was not dropped in the end
  do
    local keep = {}
    for _, d in ipairs(eff.dropped) do if not map[d.id] then keep[#keep + 1] = d end end
    eff.dropped = keep
  end
  local listed = {}
  for _, id in ipairs(order) do
    local d = map[id]
    if d and not listed[id] and (d.strength or 0) >= THRESHOLD then listed[id] = true; eff.descriptors[#eff.descriptors + 1] = d end
  end
  table.sort(eff.descriptors, function(a, b) if a.strength ~= b.strength then return a.strength > b.strength end return a.id < b.id end)
  -- 3. persona identity
  if chosen or st.persona.name then
    eff.persona = { key = chosen and chosen.key, name = st.persona.name or (chosen and chosen.name), name_placeholder = (not st.persona.name) and chosen and chosen.name_placeholder or nil,
      kind = chosen and chosen.kind, explicit = chosen and chosen.explicit or false, sample_kind = chosen and chosen.sample_kind, dataset = chosen and chosen.dataset,
      authority = (st.persona.name or st.persona.pick) and "user" or "dataset", name_source = st.persona.name and "user" or (chosen and chosen.name and "dataset") or nil,
      evidence = chosen and chosen.evidence, examples = chosen and chosen.examples, avoid = chosen and chosen.avoid, features = chosen and chosen.features }
    if eff.persona.name_placeholder and not eff.persona.name then
      eff.notes[#eff.notes + 1] = "the dataset gives the persona only a placeholder ('" .. eff.persona.name_placeholder .. "'), not a name: tell me its name if it should have one"
    end
  end
  eff.active = (#eff.descriptors > 0) or (eff.persona ~= nil and not eff.neutral)
  if #eff.descriptors > 0 and not eff.persona then eff.persona = { authority = "user" } end
  return eff
end

---------------------------------------------------------------- instructions for the host
function V.instructions(eff)
  local out = {}
  for _, d in ipairs(eff.descriptors or {}) do
    if d.free then out[#out + 1] = "Speak in the manner of " .. d.label:gsub("^like ", "") .. "."
    else
      local t = L.instructions[d.id]
      if t then out[#out + 1] = t end
    end
  end
  return out
end

---------------------------------------------------------------- opener and preview
-- the persona's own way of starting: the run of short exclamations at the start of its first example ("Oh. My. Goodness!!!"), exactly as written
function V.opener(examples)
  local ex = examples and examples[1]
  if not ex or not ex.text then return nil end
  local text = ex.text:gsub("^%s+", "")
  local out, pos, n = {}, 1, 0
  while pos <= #text and n < 4 do
    local s, e, body, term = text:find("^([^%.!%?]+)([%.!%?]+)%s*", pos)
    if not s then break end
    local nw = 0
    for _ in body:gmatch("[%a']+") do nw = nw + 1 end
    if nw == 0 or nw > 2 then break end
    out[#out + 1] = body .. term
    pos = e + 1
    n = n + 1
    if term:find("!") and n >= 1 and nw <= 2 then
      -- the run ends at the first emphatic terminal
      break
    end
  end
  if #out == 0 or n == 0 then return nil end
  local opener = table.concat(out, " ")
  if #opener > 60 then return nil end
  -- a single plain word with a full stop is just a short first sentence, not an opener
  if n == 1 and not opener:find("[!%?]") then return nil end
  return opener
end

function V.preview(eff, sentence)
  sentence = sentence or "This is how I will sound when I answer."
  local set = {}
  for _, d in ipairs(eff.descriptors or {}) do set[d.id] = true end
  local opener
  if eff.persona and eff.persona.examples and (set.dramatic or set.exclamatory) then opener = V.opener(eff.persona.examples) end
  local emoji
  if set.emoji and eff.persona and eff.persona.examples then
    for _, ex in ipairs(eff.persona.examples) do
      local e = ex.text and ex.text:match("[\240-\244][\128-\191][\128-\191][\128-\191]")
      if e then emoji = e break end
    end
  end
  return Style.render(sentence, { descriptors = set, interjection = opener, emoji = emoji })
end

---------------------------------------------------------------- reading of the datasets
local KIND_TEXT = {
  persona_sheet = "a persona sheet (it describes a character and how it talks, next to other content)",
  style_guide = "a style guide (it says how to sound)",
  dialogue_corpus = "a conversation (turns of a user and an assistant)",
  qa_pairs = "question-and-answer pairs",
  knowledge_base = "a plain knowledge base",
  mixed = "a knowledge base with a persona / style description mixed in",
}

local ROLE_TEXT = {
  style_spec = "style statement(s)", persona_declaration = "persona statement(s)", style_example = "example utterance(s)", anti_example = "counter-example(s)",
  turn_user = "user turn(s)", turn_other = "turn(s) of other speakers", turn_system = "system turn(s)", meta = "description(s) of the dataset", behavior_directive = "instruction(s) aimed at the reader",
}

function V.reading(kb)
  local out = {}
  if not kb or not kb.profiles then return out end
  for _, did in ipairs(kb.dataset_order or {}) do
    local pr = kb.profiles[did]
    if pr then
      local kind, shares = Profile.kind(pr)
      local counts = Profile.counts(pr)
      local roles = {}
      for r, n in pairs(counts) do if r ~= "records" and n > 0 then roles[r] = n end end
      local eff_pol0 = kb.effective_policy and kb:effective_policy(did) or { include = {}, exclude = {}, records = {} }
      local aside_default = Profile.set_aside_counts(pr, {})
      local aside_policy = Profile.set_aside_counts(pr, { include = eff_pol0.include, exclude = eff_pol0.exclude })
      local pol = kb.policy and kb.policy[did]
      local eff_pol = kb.effective_policy and kb:effective_policy(did) or { include = {}, exclude = {}, records = {} }
      local included, excluded = {}, {}
      for role in pairs(eff_pol.include) do if roles[role] then included[#included + 1] = role end end
      for role in pairs(eff_pol.exclude) do if roles[role] then excluded[#excluded + 1] = role end end
      table.sort(included); table.sort(excluded)
      local counted = {}
      for role, n in pairs(aside_default) do if (aside_policy[role] or 0) < n then counted[role] = n - (aside_policy[role] or 0) end end
      out[#out + 1] = { dataset = did, kind = kind, records = counts.records or 0, roles = roles, aside = aside_policy, counted = counted, shares = shares, pair_fields = pr.pair_fields, included = included, excluded = excluded,
        reading = eff_pol.reading,
        qa_pairs_converted = (function() local n = 0; for rid, r in pairs(kb.qa_report or {}) do if rid:sub(1, #did + 1) == did .. ":" then n = n + r.converted end end return n end)(),
        policy = pol }
    end
  end
  return out
end

local function plural(n, word) return n .. " " .. word end

local function quote_of(kb, src)
  local rec = kb and kb:record(src.record)
  local text = rec and rec.field_text and rec.field_text[src.field]
  if not text then return nil end
  local q = text:sub(src.s, math.min(src.e, src.s + 90)):gsub("%s+", " ")
  return q
end

local function list_text(items)
  if #items == 0 then return "" end
  if #items == 1 then return items[1] end
  if #items == 2 then return items[1] .. " and " .. items[2] end
  return table.concat(items, ", ", 1, #items - 1) .. " and " .. items[#items]
end

-- opts.mode: "full" (default) | "voice" (the persona and tone only); opts.turn: the turn whose transient notes are shown
function V.announce(eff, reading, st, kb, opts)
  opts = opts or {}
  local voice_only = opts.mode == "voice"
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  -- what the dataset is
  if not voice_only then
    for _, r in ipairs(reading or {}) do
      local set_aside, counted, dropped_roles = {}, {}, {}
      for _, role in ipairs({ "persona_declaration", "style_spec", "style_example", "anti_example", "turn_user", "turn_system", "turn_other", "meta" }) do
        local n = r.aside and r.aside[role]
        if n and n > 0 then set_aside[#set_aside + 1] = plural(n, ROLE_TEXT[role]) end
        local c = r.counted and r.counted[role]
        if c and c > 0 then counted[#counted + 1] = plural(c, ROLE_TEXT[role]) end
      end
      local nd = r.roles.behavior_directive
      if nd and nd > 0 then set_aside[#set_aside + 1] = plural(nd, ROLE_TEXT.behavior_directive) end
      for _, role in ipairs(r.excluded or {}) do
        local n = r.roles[role]
        if n and n > 0 and role == "turn_assistant" then dropped_roles[#dropped_roles + 1] = plural(n, "assistant turn(s)") end
      end
      local line = "I read dataset '" .. r.dataset .. "' as " .. (KIND_TEXT[r.kind] or r.kind) .. ": " .. plural(r.records, "record(s)") .. "."
      if r.reading == "facts" then line = line .. " At your request every part is read as plain facts (instructions aimed at the reader excepted)." end
      if #set_aside > 0 then line = line .. " Set aside, never used as facts: " .. list_text(set_aside) .. "." end
      if #counted > 0 and r.reading ~= "facts" then line = line .. " Counted as facts at your request: " .. list_text(counted) .. "." end
      if #dropped_roles > 0 then line = line .. " Not counted as facts at your request: " .. list_text(dropped_roles) .. "." end
      if (r.qa_pairs_converted or 0) > 0 then line = line .. " " .. plural(r.qa_pairs_converted, "question/answer pair(s)") .. " turned into facts through the question." end
      add(line)
      if r.roles.behavior_directive and r.roles.behavior_directive > 0 then add("Instructions inside the data are reported and never obeyed.") end
    end
  end
  -- the persona and the tone
  if eff and eff.persona and (eff.persona.name or eff.persona.name_placeholder or eff.persona.kind) then
    local who = eff.persona.name or ("a persona whose name is only a placeholder ('" .. tostring(eff.persona.name_placeholder) .. "')")
    local line = "Persona: " .. who
    if eff.persona.kind then line = line .. " (" .. eff.persona.kind .. ")" end
    if eff.persona.authority == "user" then line = line .. ", as you set it"
    elseif not eff.persona.explicit then line = line .. ", inferred from how the assistant speaks in the data (nothing declares it)" end
    add(line .. ".")
    if kb and eff.persona.key and not voice_only then
      local pr = kb.profiles and eff.persona.dataset and kb.profiles[eff.persona.dataset]
      if pr then
        for _, p in ipairs(Profile.personas(pr)) do
          if p.key == eff.persona.key then
            local qs = {}
            for _, src in ipairs(p.sources) do
              if #qs < 2 and (src.kind == "declaration" or src.kind == "style_spec") then
                local q = quote_of(kb, src)
                if q then qs[#qs + 1] = '"' .. q .. '" (' .. src.record .. ")" end
              end
            end
            if #qs > 0 then add("Declared by: " .. table.concat(qs, "; ") .. ".") end
          end
        end
      end
    end
  end
  if eff and #eff.descriptors > 0 then
    local labels = {}
    for _, d in ipairs(eff.descriptors) do if #labels < 8 then labels[#labels + 1] = d.label end end
    add("Tone I will use: " .. list_text(labels) .. ".")
    for i, d in ipairs(eff.descriptors) do
      if i <= 5 then
        local why = {}
        if d.declared_terms and #d.declared_terms > 0 then why[#why + 1] = 'declared in words ("' .. table.concat(d.declared_terms, '", "') .. '")' end
        if d.evidence and d.source ~= "user" then why[#why + 1] = "measured: " .. d.evidence .. ((d.basis == "examples" and " (in the example text)") or (d.basis == "assistant_turns" and " (in the assistant's turns)") or "") end
        if d.source == "user" then why[#why + 1] = "you asked for it" end
        add("  - " .. d.label .. ": " .. (#why > 0 and table.concat(why, "; ") or "from the dataset"))
      end
    end
  elseif eff and eff.persona then
    local by_user = false
    for _, d in ipairs(eff.dropped or {}) do if d.reason and d.reason:find("you ") then by_user = true end end
    add(by_user and "Tone: neutral, after your changes." or "No distinctive tone was found, so I will answer in a neutral tone.")
  elseif eff and eff.neutral then
    add("Tone: neutral, as you asked.")
  elseif eff and not eff.active then
    add("I take no persona and no tone from the data, so I answer in a neutral tone.")
  end
  for _, c in ipairs(eff and eff.conflicts or {}) do
    if c.kind == "declared_negation" then add("Note: the dataset says the persona is not " .. tostring(c.id) .. " although the examples sound that way (" .. tostring(c.measured) .. "); I follow the statement.")
    elseif c.kind == "contradiction" then add("Note: the dataset both describes the persona as " .. tostring(c.a) .. " and as " .. tostring(c.b) .. " (" .. tostring(c.a_source) .. " vs " .. tostring(c.b_source) .. "); both are kept, tell me which to follow.")
    elseif c.kind == "self_contradiction" then add("Note: the dataset contradicts itself about " .. tostring(c.id) .. ": " .. tostring(c.declared) .. ".") end
  end
  -- what was dropped, grouped by the reason
  do
    local by, order = {}, {}
    for _, d in ipairs(eff and eff.dropped or {}) do
      if d.reason and (d.reason:find("you ") or d.reason:find("contradicts")) then
        if not by[d.reason] then by[d.reason] = {}; order[#order + 1] = d.reason end
        table.insert(by[d.reason], d.label)
      end
    end
    for _, reason in ipairs(order) do add("Dropped: " .. list_text(by[reason]) .. " (" .. reason .. ").") end
  end
  if eff and #eff.alternatives > 0 and not voice_only then
    local names = {}
    for _, a in ipairs(eff.alternatives) do names[#names + 1] = a.name or a.name_placeholder or a.key end
    add("The dataset also describes: " .. list_text(names) .. ". Say 'play <name>' to switch.")
  end
  for _, n in ipairs(eff and eff.notes or {}) do add("Note: " .. n .. ".") end
  for _, n in ipairs(eff and eff.op_notes or {}) do if opts.turn == nil or n.turn == opts.turn then add("Note: " .. n.text .. ".") end end
  for _, r in ipairs(st and st.refused or {}) do add("Refused: " .. r .. ".") end
  if st and #st.applied > 0 and not voice_only then
    local ap = {}
    for _, a in ipairs(st.applied) do ap[#ap + 1] = '"' .. tostring(a.text):gsub("%s+", " ") .. '"' end
    add("Your instructions applied: " .. table.concat(ap, "; ") .. ".")
  end
  if eff and (eff.active or (eff.persona ~= nil)) then
    add("The voice changes how I phrase answers, not what is true: facts come from the dataset's records, never from the persona statements or the examples.")
    if not voice_only then add("To change it: 'use a calmer tone', 'no caps', 'play <other>', 'ignore the personality', 'treat the examples as facts'.") end
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------- the engine's own answer to an instruction or a question about its reading
local function describe_op(op)
  local head, rest = op:match("^(%a+):(.*)$")
  if head == "add" then return "added " .. label_of(rest)
  elseif head == "drop" then return "dropped " .. label_of(rest)
  elseif head == "more" then return "more " .. label_of(rest)
  elseif head == "less" then return "less " .. label_of(rest)
  elseif head == "down" then return "toned down " .. label_of(rest)
  elseif head == "tone" then
    local sub, arg = rest:match("^([%a_]+):?(.*)$")
    if sub == "data_style" then return "talking like the dataset's own text"
    elseif sub == "neutral" then return "neutral tone" elseif sub == "reset" then return "back to the dataset's tone"
    elseif sub == "set" then return "voice set to " .. label_of(arg) elseif sub == "set_voice" then return "voice set to like " .. arg end
  elseif head == "persona" then
    local sub, arg = rest:match("^(%a+):?(.*)$")
    if sub == "off" then return "persona off" elseif sub == "on" then return "persona on" elseif sub == "pick" then return "playing " .. arg elseif sub == "name" then return "persona named " .. arg end
  elseif head == "dataset" then
    local sub, arg = rest:match("^(%a+):?(.*)$")
    if sub == "reading" then return arg == "facts" and "reading the dataset as plain facts" or "reading the dataset as its own structure shows"
    elseif sub == "include" then return "counting the " .. (ROLE_TEXT[arg] or arg):gsub("%(s%)", "s") .. " as facts"
    elseif sub == "exclude" then return "not counting the " .. (ROLE_TEXT[arg] or arg):gsub("%(s%)", "s") .. " as facts"
    elseif sub == "record" then local ref, action = arg:match("^(.*):(%a+)$"); return "record " .. tostring(ref):gsub("^n=", "#"):gsub("^about=", "about ") .. " is " .. tostring(action):gsub("_", " ") end
  end
  return op
end

-- kind: "instruction" | "query_tone" | "query_reading"; own_ops: the ops of the instruction in this very request
function V.reply(kb, kind, section, own_ops, policy_changed)
  if not section then return nil end
  local text = {}
  if kind == "instruction" then
    local dataset_op, voice_op = false, false
    local parts = {}
    for _, op in ipairs(own_ops or {}) do
      if op:find("^dataset:") then dataset_op = true else voice_op = true end
      parts[#parts + 1] = describe_op(op)
    end
    local ch = section.change
    if dataset_op then
      local head = "Understood: " .. table.concat(parts, "; ") .. "."
      if policy_changed then head = head .. " I read the dataset again with that." end
      text[#text + 1] = head
      text[#text + 1] = section.announcement
    else
      if ch and ch.changed then
        local line = "Understood."
        if #ch.after > 0 then line = line .. " Tone: " .. list_text(ch.after) .. "."
        else line = line .. " Tone: neutral." end
        if #ch.removed > 0 then line = line .. " Dropped: " .. list_text(ch.removed) .. "." end
        if ch.persona_before ~= ch.persona_after then line = line .. " Persona: " .. tostring(ch.persona_after or "none") .. (ch.persona_before and (" (was " .. ch.persona_before .. ")") or "") .. "." end
        text[#text + 1] = line
      else
        local why = {}
        for _, n in ipairs(section.notes or {}) do why[#why + 1] = n end
        text[#text + 1] = "Understood, but nothing changes" .. (voice_op and ": the voice was already like that." or ".")
      end
      for _, line in ipairs((function() local t = {}; for l in ((section.announcement_voice or "") .. "\n"):gmatch("(.-)\n") do if l:find("^Note:") then t[#t + 1] = l end end return t end)()) do text[#text + 1] = line end
    end
  elseif kind == "query_tone" then
    local keep = {}
    for line in (section.announcement .. "\n"):gmatch("(.-)\n") do
      if line:find("^Persona:") or line:find("^Declared by:") or line:find("^Tone") or line:find("^I take no") or line:find("^No distinctive") or line:find("^  %- ") or line:find("^Note:") or line:find("^Dropped:") or line:find("^Your instructions") or line:find("^The voice") or line:find("^To change") or line:find("^The dataset also") then
        keep[#keep + 1] = line
      end
    end
    if #keep == 0 then keep[1] = "The dataset gives me no persona or tone, so I answer in a neutral tone." end
    text[#text + 1] = table.concat(keep, "\n")
    if section.preview then text[#text + 1] = "Preview: " .. section.preview end
  elseif kind == "query_reading" then
    for line in (section.announcement .. "\n"):gmatch("(.-)\n") do
      if line:find("^I read dataset") or line:find("^Instructions inside") then text[#text + 1] = line end
    end
    if kb and kb.profiles then
      for _, did in ipairs(kb.dataset_order or {}) do
        local pr = kb.profiles[did]
        if pr then
          local aside = Profile.set_aside(pr, 8)
          for _, a in ipairs(aside) do
            text[#text + 1] = string.format('  - %s in %s: "%s" (clue: %s)', (ROLE_TEXT[a.role] or a.role):gsub("%(s%)", ""), a.record, a.quote, tostring(a.via))
          end
        end
      end
    end
    if #text == 0 then text[1] = "No dataset is loaded." end
  end
  return { kind = kind, text = table.concat(text, "\n"), authority = "engine" }
end

-- what an instruction changed: the labels of the tone before and after, the persona before and after
local function labels_of(eff)
  local out = {}
  for _, d in ipairs(eff.descriptors or {}) do out[#out + 1] = d.label end
  return out
end
local function persona_label(eff)
  return eff.persona and (eff.persona.name or (eff.persona.name_placeholder and ("a placeholder '" .. eff.persona.name_placeholder .. "'"))) or nil
end
function V.diff(before, after)
  local b, a = labels_of(before), labels_of(after)
  local bs, as = {}, {}
  for _, l in ipairs(b) do bs[l] = true end
  for _, l in ipairs(a) do as[l] = true end
  local added, removed = {}, {}
  for _, l in ipairs(a) do if not bs[l] then added[#added + 1] = l end end
  for _, l in ipairs(b) do if not as[l] then removed[#removed + 1] = l end end
  return { before = b, after = a, added = added, removed = removed, persona_before = persona_label(before), persona_after = persona_label(after),
    changed = (#added + #removed > 0) or persona_label(before) ~= persona_label(after) }
end

---------------------------------------------------------------- the section of an Interpretation Record
-- kb: knowledge base (or nil), items: V.collect(memory) (+ the instruction of this very call when stateless), opts: { preview = sentence }
function V.build(kb, items, opts)
  opts = opts or {}
  local personas = V.personas(kb)
  local st = V.state(items)
  local wants_data_style = false
  for _, t in ipairs(st.tone) do if t.verb == "data_style" then wants_data_style = true end end
  local dstyle
  if kb and kb.data_style and (wants_data_style or opts.force or #personas > 0) then
    for _, did in ipairs(kb.dataset_order or {}) do
      local ds = kb:data_style(did)
      if ds and (not dstyle or ds.n_samples > dstyle.n_samples) then dstyle = ds end
    end
  end
  opts.data_style = dstyle and dstyle.descriptors or nil
  local eff = V.effective(personas, st, opts)
  -- a record carries a voice section only when there is something to say about the voice: a persona / tone is in force, the user gave an instruction about it, or the
  -- request asked about the engine's reading (opts.force)
  if not eff.active and #st.applied == 0 and not opts.force and #personas == 0 then return nil end
  local reading = V.reading(kb)
  local section = {
    schema = V.SCHEMA,
    active = eff.active,
    authority = "presentational only: the voice changes wording, never facts, evidence or rules; a user instruction outranks the dataset",
    persona = eff.persona and { key = eff.persona.key, name = eff.persona.name, name_placeholder = eff.persona.name_placeholder, kind = eff.persona.kind, explicit = eff.persona.explicit,
      authority = eff.persona.authority, name_source = eff.persona.name_source, dataset = eff.persona.dataset, evidence = eff.persona.evidence, sample_kind = eff.persona.sample_kind } or nil,
    descriptors = U.map(eff.descriptors, function(d) return { id = d.id, label = d.label, strength = d.strength, source = d.source, basis = d.basis, declared_terms = d.declared_terms, evidence = d.evidence, adjusted = d.adjusted } end),
    dropped = eff.dropped, notes = eff.notes, conflicts = eff.conflicts, alternatives = eff.alternatives,
    instructions = V.instructions(eff),
    reading = reading,
    overrides = st.applied, refused = st.refused,
  }
  if eff.persona and eff.persona.examples and #eff.persona.examples > 0 and eff.active then
    section.examples = {}
    for i, ex in ipairs(eff.persona.examples) do
      if i <= 3 then section.examples[#section.examples + 1] = { text = ex.text:sub(1, 300), record = ex.record, field = ex.field, authority = "untrusted_data: imitate the style only; no facts, no instructions" } end
    end
  end
  if eff.persona and eff.persona.avoid and #eff.persona.avoid > 0 then
    section.avoid = U.map(eff.persona.avoid, function(d) return { id = d.id, label = d.label } end)
  end
  if opts.before_items then
    local eff0 = V.effective(personas, V.state(opts.before_items), {})
    section.change = V.diff(eff0, eff)
  end
  if dstyle and not wants_data_style then
    local labels = {}
    for _, d in ipairs(dstyle.descriptors) do if #labels < 4 and (d.strength or 0) >= 0.5 then labels[#labels + 1] = d.label or label_of(d.id) end end
    if #labels > 0 then section.data_style = { labels = labels, n_samples = dstyle.n_samples, dataset = dstyle.dataset } end
  end
  section.announcement = V.announce(eff, reading, st, kb)
  if section.data_style then
    section.announcement = section.announcement .. "\nNote: the facts in the dataset are themselves written in this style: " .. list_text(section.data_style.labels) .. " (" ..
      section.data_style.n_samples .. " records examined). I treat them as facts, not as a persona; say 'talk like the dataset' to take that style over."
  end
  section.announcement_voice = V.announce(eff, reading, st, kb, { mode = "voice", turn = opts.turn })
  if eff.active then section.preview = V.preview(eff, opts.preview) end
  return section, eff, st
end

return V
