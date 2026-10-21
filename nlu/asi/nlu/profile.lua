-- asi.nlu.profile: what a dataset IS, from the clues in the data itself.
--   Profile.new()                              an empty profile (one per dataset id)
--   Profile.add_records(profile, records, opts) classify the segments of newly ingested records (field names, speaker labels, persona / style statements,
--                                              example utterances, behaviour directives, dataset descriptions) with the sequential context between records
--   Profile.skip_ranges(profile, rec_id, field) byte ranges of a record field that are NOT knowledge (style specifications, example utterances, ...)
--   Profile.personas(profile)                  the personas the dataset declares or implies: name / placeholder, declared and measured tone, examples, conflicts
--   Profile.kind(profile)                      persona_sheet | dialogue_corpus | qa_pairs | knowledge_base | glossary | table | style_guide | mixed, with the shares it rests on
--   Profile.summary(profile)                   the compact, serialisable view used in records, reports and the command line
-- Everything is derived from structure and lexicon data (asi.nlu.data.style_lex); no sentence of any example is known to this module.
local U = require("asi.nlu.util")
local Persona = require("asi.nlu.persona")
local Style = require("asi.nlu.style")
local L = require("asi.nlu.data.style_lex")

local Pr = {}
Pr.SCHEMA = "nlu.profile/1"

---------------------------------------------------------------- field roles from names
local function set_of(list) local s = {}; for _, w in ipairs(list) do s[w] = true end return s end
local PERSONA_KIND = {}
for _, k in ipairs(L.persona_kinds) do PERSONA_KIND[k:lower()] = true end
local FIELD_WORDS = {
  system = set_of({ "system", "sys", "system_prompt", "system_message", "systemprompt", "instructions", "instruction_prompt", "preamble", "context_prompt" }),
  persona = set_of({ "persona", "character", "personality", "bio", "backstory", "character_description", "persona_description", "characterization", "profile_text", "traits" }),
  style = set_of({ "tone", "style", "voice", "mood", "vibe", "register", "speaking_style", "writing_style", "manner", "attitude", "demeanor" }),
  name = set_of({ "persona_name", "character_name", "bot_name", "assistant_name", "agent_name", "ai_name", "char_name", "npc_name", "speaker_name" }),
  assistant = set_of({ "response", "output", "completion", "answer", "assistant", "gpt", "bot", "reply", "model", "ai", "a", "text_output", "chosen", "target", "responses", "answers", "model_output",
    "assistant_message", "assistant_response", "bot_response", "bot_reply", "agent", "character_response" }),
  user = set_of({ "prompt", "input", "instruction", "question", "query", "user", "human", "request", "q", "text_input", "questions", "queries", "user_message", "user_input",
    "human_input", "message", "utterance" }),
  speaker = set_of({ "speaker", "role", "from", "author", "sender", "who", "actor" }),
  dialogue = set_of({ "dialogue", "dialog", "conversation", "conversations", "messages", "chat", "chats", "transcript", "turns", "history", "script", "dialogues" }),
}
local ROLE_ORDER = { "name", "system", "persona", "style", "dialogue", "assistant", "user", "speaker" }

function Pr.field_role(name)
  local n = (name or ""):lower():gsub("[%s%-%.]+", "_")
  for _, role in ipairs(ROLE_ORDER) do if FIELD_WORDS[role][n] then return role end end
  -- compound names: any token ("assistant_text", "user_turn", "system_text")
  for tok in n:gmatch("[^_]+") do
    for _, role in ipairs({ "system", "persona", "style", "assistant", "user", "dialogue" }) do
      if FIELD_WORDS[role][tok] and (role ~= "assistant" or #tok > 1) then return role end
    end
  end
  return nil
end

-- prose columns of a persona table ("description", "bio") are persona text when the table also has persona / style columns
local PERSONA_PROSE = set_of({ "description", "summary", "about", "details", "notes", "profile", "bio", "backstory", "traits" })

-- the roles of a set of field names, with the context rules: user / assistant sides only mean something as a PAIR (a lone "model" column is a car model),
-- and in a persona table a bare "name" column is the persona's name and the prose columns are the persona text
function Pr.resolve_field_roles(names)
  local roles = {}
  for _, f in ipairs(names) do
    local r = Pr.field_role(f)
    if r then roles[f] = r end
  end
  local has_user, has_ass = false, false
  for _, r in pairs(roles) do if r == "user" then has_user = true elseif r == "assistant" then has_ass = true end end
  local pair = has_user and has_ass
  if not pair then for f, r in pairs(roles) do if r == "user" or r == "assistant" then roles[f] = nil end end end
  local persona_cols = false
  for _, r in pairs(roles) do if r == "persona" or r == "style" then persona_cols = true end end
  if persona_cols then
    for _, f in ipairs(names) do
      local lf = f:lower()
      if not roles[f] then
        if lf == "name" or lf == "nickname" or lf == "alias" then roles[f] = "name"
        elseif PERSONA_PROSE[lf] then roles[f] = "persona" end
      end
    end
  end
  return roles, pair
end

---------------------------------------------------------------- cheap gate: does a text mention anything a persona scan could use?
local TRIGGER = {}
local function add_words(list)
  for _, p in ipairs(list) do for w in p:lower():gsub("[%-_]", " "):gmatch("[%a']+") do TRIGGER[w] = true end end
end
add_words(L.voice_verbs); add_words(L.persona_kinds); add_words(L.example_intros); add_words(L.style_labels); add_words(L.name_labels); add_words(L.example_labels)
add_words(L.behavior_cues); add_words({ "persona", "character", "pretend", "roleplay", "act", "name", "tone", "voice" })
for _, d in pairs(L.descriptors) do add_words(d.declared or {}) end
local function needs_scan(text)
  if text:find("[%[%]<>{}\"“”]") then return true end
  for w in text:lower():gmatch("[%a']+") do if TRIGGER[w] then return true end end
  return text:find(":", 1, true) ~= nil
end

---------------------------------------------------------------- profile object
function Pr.new()
  return { schema = Pr.SCHEMA, recs = {}, order = {}, field_roles = {}, pending = nil, revision = 0, notes = {}, persona_seen = false }
end

---------------------------------------------------------------- meta statements ("This dataset contains ...")
local META_IDX = Style.phrase_index(L.meta_phrases)
local function meta_like(text)
  local head = text:lower():gsub("^%s+", ""):sub(1, 90)
  local ws = {}
  for w in head:gmatch("[%a']+") do ws[#ws + 1] = w; if #ws >= 8 then break end end
  for i = 1, math.min(#ws, 6) do
    local len = Style.match_at(META_IDX, ws, i)
    if len then return true end
  end
  return false
end

---------------------------------------------------------------- utterance-likeness (for the paragraphs under "talks like this:")
local function utterance_like(text)
  local f = Style.measure(text)
  if (f.n_words or 0) == 0 or f.n_words > 90 then return false end
  if text:find('^%s*["“«]') then return true end
  return f.caps_ratio >= 0.3 or f.excl_per_sentence >= 0.5 or f.emoji >= 1 or f.interjection_rate >= 5 or f.first_person_rate >= 6 or f.second_person_rate >= 6
    or f.question_ratio >= 0.5 or f.ellipsis_ratio >= 0.3
end
Pr.utterance_like = utterance_like

---------------------------------------------------------------- speaker-labelled transcripts: "User: ...", "Aria: ..."
local USER_SP, ASSIST_SP, SYSTEM_SP = set_of(L.user_speakers), set_of(L.assistant_speakers), set_of(L.system_speakers)
local LABELLED = {}
for _, k in ipairs(L.style_labels) do LABELLED[k] = true end
for _, k in ipairs(L.name_labels) do LABELLED[k] = true end
for _, k in ipairs(L.example_labels) do LABELLED[k] = true end
for _, k in ipairs({ "persona", "character", "role", "bot", "assistant", "ai", "agent" }) do LABELLED[k] = nil end   -- these double as speaker labels

local function parse_turns(text)
  local turns, counts = {}, {}
  local pos = 1
  while pos <= #text do
    local le = (text:find("\n", pos, true) or (#text + 1)) - 1
    local line = text:sub(pos, le)
    local lab, vs = line:match("^%s*[%-%*•]?%s*([%a][%w _%.%-']-)%s*:%s*()")
    if lab and #lab <= 28 and #line >= vs then
      local nl = lab:lower():gsub("[%s%-_]+", " ")
      if not LABELLED[nl] and not nl:find("^http") then
        turns[#turns + 1] = { label = lab, norm = nl, s = pos + vs - 1, e = le, line_s = pos }
        counts[nl] = (counts[nl] or 0) + 1
      end
    elseif #turns > 0 and line:match("%S") then
      -- continuation line of the previous turn
      local last = turns[#turns]
      if line:find("^%s") or not line:find(":") then last.e = le end
    end
    pos = le + 2
  end
  return turns, counts
end

---------------------------------------------------------------- hints: section titles and type columns say what the paragraphs under them are
local HINT = {}
for kind, list in pairs(L.hint_words) do HINT[kind] = set_of(list) end
local STYLE_TITLE_VERB = set_of({ "talk", "talks", "talking", "speak", "speaks", "speaking", "sound", "sounds", "sounding", "respond", "responds", "responding" })
local HINT_FIELDS = set_of({ "section", "type", "kind", "category", "label", "tag", "tags", "segment", "part", "heading", "header", "title", "record_type", "entry_type", "class" })

local function hint_of_text(t)
  local h
  for w in t:lower():gmatch("[%a']+") do
    for kind, set in pairs(HINT) do if set[w] then h = h or {}; h[kind] = true end end
    if STYLE_TITLE_VERB[w] then h = h or {}; h.style = true end
  end
  return h
end

local function record_hint(rec)
  local h
  for f, v in pairs(rec.fields or {}) do
    if HINT_FIELDS[f:lower()] and type(v) == "string" and #v <= 60 then
      local x = hint_of_text(v)
      if x then h = h or {}; for k in pairs(x) do h[k] = true end end
    end
  end
  return h
end

-- how much less evidence a statement needs: a system field, a section titled "Persona" / "Style" / "Rules", or a persona that is already established earlier in the dataset
local function context_bonus(profile, hint, frole)
  local b = 0
  if frole == "system" then b = 1.0 end
  if hint and (hint.persona or hint.style or hint.rules) then return math.max(b, 1.0) end
  if hint and hint.knowledge then return b end
  if profile.persona_seen then b = math.max(b, 0.8) end
  return b
end

local function shift_item(it, off)
  it.s, it.e = it.s + off, it.e + off
  if it.subject and it.subject.s then
    local sj = {}
    for k, v in pairs(it.subject) do sj[k] = v end
    sj.s, sj.e = sj.s + off, sj.e + off
    it.subject = sj
  end
  return it
end

---------------------------------------------------------------- one record field
-- returns segs ({ field, s, e, role, via, text, ... }) and items (the Persona.scan items with their field)
-- ctx: { lex, hint }
local function analyze_field(profile, rec, f, text, frole, ctx)
  local segs, items = {}, {}
  local function seg(role, s, e, via, extra)
    local sg = { field = f, s = s, e = e, role = role, via = via, text = text:sub(s, math.min(e, s + 400)) }
    if extra then for k, v in pairs(extra) do sg[k] = v end end
    segs[#segs + 1] = sg
    return sg
  end
  if frole == "assistant" then seg("turn_assistant", 1, #text, "field:" .. f); return segs, items end
  if frole == "user" then seg("turn_user", 1, #text, "field:" .. f); return segs, items end
  if frole == "other" then seg("turn_other", 1, #text, "speaker field", { speaker_norm = ctx.speaker_norm, speaker = ctx.speaker }); return segs, items end
  if frole == "name" then
    local nm = U.trim(text)
    local ph = Persona.placeholders(nm)[1]
    local it = { kind = "persona_declaration", s = 1, e = #text, via = "field:" .. f, score = 3, subject = ph and { kind = "placeholder", text = ph.inner, form = ph.inner:lower() }
      or { kind = "name", text = nm, form = nm:lower() }, evidence = { "field:" .. f } }
    items[#items + 1] = it
    seg("persona_declaration", 1, #text, "field:" .. f, { item = it })
    return segs, items
  end
  if frole == "persona" or frole == "style" then
    local descs = Style.declared(text)
    local cues = Persona.behavior_cues_in(text)
    local kind = frole == "persona" and "persona_declaration" or "style_spec"
    local nm = frole == "persona" and text:match("^%s*([%u][%w'’%-]*)") or nil
    local it = { kind = kind, s = 1, e = #text, via = "field:" .. f, score = 3, descriptors = descs, evidence = { "field:" .. f }, behavior_cues = cues, presentational = #cues == 0,
      subject = nm and { kind = "name", text = nm, form = nm:lower() } or { kind = "generic", text = "", form = "" }, persona_kind = Persona.kind_in(text) }
    -- a name is a name only when the text says "Aria, ..." / "Aria is ...", not a sentence that merely starts with a capital
    if nm and (PERSONA_KIND[nm:lower()] or nm:lower() == "a" or nm:lower() == "an" or nm:lower() == "the") then it.subject = { kind = "generic", text = "", form = "" } end
    items[#items + 1] = it
    seg(kind, 1, #text, "field:" .. f, { item = it })
    return segs, items
  end
  -- general text, system prompts and dialogue fields: transcripts first, then statements (system turns get more benefit of the doubt)
  local hint = ctx.hint
  local bonus = context_bonus(profile, hint, frole)
  local turns, tcount = parse_turns(text)
  local repeated, known = false, false
  for norm, n in pairs(tcount) do
    if n >= 2 then repeated = true end
    if USER_SP[norm] or ASSIST_SP[norm] or SYSTEM_SP[norm] then known = true end
  end
  local labelled = #turns >= 2 and (repeated or known)
  local res = needs_scan(text) and Persona.scan(text, { lex = ctx.lex, bonus = bonus }) or { items = {} }
  local scanned = res.items
  if labelled then
    for _, t in ipairs(turns) do
      if SYSTEM_SP[t.norm] then
        local r2 = Persona.scan(text:sub(t.s, t.e), { lex = ctx.lex, bonus = 1.0 })
        if #r2.items > 0 then
          local keep = {}
          for _, it in ipairs(scanned) do if not (it.s <= t.e and it.e >= t.s) then keep[#keep + 1] = it end end
          for _, it in ipairs(r2.items) do keep[#keep + 1] = shift_item(it, t.s - 1) end
          scanned = keep
        end
      end
    end
  end
  for _, it in ipairs(scanned) do
    local drop = false
    if labelled then
      for _, t in ipairs(turns) do
        if USER_SP[t.norm] and it.s >= t.s and it.e <= t.e and it.kind ~= "example" then it.in_user_turn = true end
        -- "assistant: THE CAPITAL OF FRANCE IS PARIS" is a turn, not a persona declared by a label
        if it.via == "label" and it.label and it.label == t.norm and it.e >= t.s - 1 and it.s <= t.e then drop = true end
      end
    end
    if not drop then
    items[#items + 1] = it
    if it.kind == "style_spec" then
      if it.presentational == false then seg("behavior_directive", it.s, it.e, "style statement with behaviour cues: " .. table.concat(it.behavior_cues or {}, ","), { item = it })
      else seg("style_spec", it.s, it.e, it.via or "voice statement", { item = it }) end
    elseif it.kind == "persona_declaration" then
      if it.presentational == false then seg("behavior_directive", it.s, it.e, "persona statement with behaviour cues: " .. table.concat(it.behavior_cues or {}, ","), { item = it })
      else seg("persona_declaration", it.s, it.e, it.via or "declaration", { item = it }) end
    elseif it.kind == "example" then seg(it.anti and "anti_example" or "style_example", it.s, it.e, it.via or "example", { item = it })
    elseif it.kind == "behavior_directive" then seg("behavior_directive", it.s, it.e, "directive: " .. table.concat(it.cues or {}, ","), { item = it }) end
    end
  end
  -- speaker-labelled turns
  if labelled then
    for _, t in ipairs(turns) do
      local role = USER_SP[t.norm] and "turn_user" or (ASSIST_SP[t.norm] and "turn_assistant") or (SYSTEM_SP[t.norm] and "turn_system") or "turn_other"
      local overlaps = false
      for _, sg in ipairs(segs) do
        if sg.s <= t.e and sg.e >= t.s and (sg.role == "style_example" or sg.role == "anti_example" or sg.role == "style_spec" or sg.role == "persona_declaration"
          or sg.role == "behavior_directive") and not (role == "turn_user") then overlaps = true end
      end
      -- the statements and examples inside a turn stay segments of their own; the rest of the turn is the turn
      if not overlaps then seg(role, t.s, t.e, "speaker label '" .. t.label .. "'", { speaker = t.label, speaker_norm = t.norm })
      elseif role ~= "turn_system" then
        -- a turn that contains a quoted example or statement still has its own voice (the remainder is a turn of that speaker)
        seg(role, t.s, t.e, "speaker label '" .. t.label .. "' (with statements)", { speaker = t.label, speaker_norm = t.norm, contains_statements = true })
      end
    end
  end
  -- an examples section: a paragraph that reads like an utterance is an example of how the persona talks
  if #segs == 0 and hint and hint.example and (profile.persona_seen or hint.style or hint.persona) and Pr.utterance_like(text) then
    local q = text:match('^%s*["“«](.*)["”»]%s*$')
    seg("style_example", 1, #text, "section hint (examples)", { item = { kind = "example", s = 1, e = #text, text = q or text, via = "section_hint" } })
    items[#items + 1] = segs[#segs].item
  end
  -- dataset descriptions
  if #segs == 0 and meta_like(text) then seg("meta", 1, #text, "dataset description") end
  return segs, items
end

---------------------------------------------------------------- speakers: who is the assistant when the labels are names
local function speaker_roles(profile)
  local c = profile.sp_cache
  if c and c.rev == profile.revision then return c.map, c.stats end
  local stats = {}
  for _, rid in ipairs(profile.order) do
    for _, sg in ipairs(profile.recs[rid].segs) do
      if sg.speaker_norm then
        local st = stats[sg.speaker_norm]
        if not st then st = { turns = 0, questions = 0, label = sg.speaker }; stats[sg.speaker_norm] = st end
        st.turns = st.turns + 1
        if sg.text and sg.text:match("%?[%s\"”'»]*$") then st.questions = st.questions + 1 end
      end
    end
  end
  local has_user, has_ass = false, false
  local unknown = {}
  for norm in pairs(stats) do
    if USER_SP[norm] then has_user = true elseif ASSIST_SP[norm] then has_ass = true elseif not SYSTEM_SP[norm] then unknown[#unknown + 1] = norm end
  end
  table.sort(unknown)
  local map = {}
  if #unknown == 1 then
    if has_user and not has_ass then map[unknown[1]] = "turn_assistant"
    elseif has_ass and not has_user then map[unknown[1]] = "turn_user" end
  elseif #unknown == 2 and not has_user and not has_ass then
    local a1, a2 = stats[unknown[1]], stats[unknown[2]]
    local qa, qb = a1.questions / math.max(a1.turns, 1), a2.questions / math.max(a2.turns, 1)
    if math.abs(qa - qb) >= 0.3 then
      if qa > qb then map[unknown[1]], map[unknown[2]] = "turn_user", "turn_assistant" else map[unknown[1]], map[unknown[2]] = "turn_assistant", "turn_user" end
    end
  end
  profile.sp_cache = { rev = profile.revision, map = map, stats = stats }
  return map, stats
end

-- the role of a segment once the speakers of the whole dataset are known
local function role_of(profile, sg)
  if sg.speaker_norm and sg.role == "turn_other" then return speaker_roles(profile)[sg.speaker_norm] or "turn_other" end
  return sg.role
end
Pr.role_of = role_of

local function tally(profile)
  local c = profile.tally_cache
  if c and c.rev == profile.revision then return c.counts end
  local counts = { records = #profile.order }
  for _, rid in ipairs(profile.order) do
    for _, sg in ipairs(profile.recs[rid].segs) do
      local r = role_of(profile, sg)
      counts[r] = (counts[r] or 0) + 1
    end
  end
  profile.tally_cache = { rev = profile.revision, counts = counts }
  return counts
end
Pr.counts = tally

---------------------------------------------------------------- adding records
-- records: the records of a dataset in order (each with fields, text_fields, field_text); opts: { lex = lexicon }
function Pr.add_records(profile, records, opts)
  opts = opts or {}
  -- field roles are decided per field name over the whole batch (with the context rules in resolve_field_roles)
  local seen_fields, names = {}, {}
  for _, rec in ipairs(records) do
    for f in pairs(rec.fields or {}) do if not seen_fields[f] then seen_fields[f] = true; names[#names + 1] = f end end
    for _, f in ipairs(rec.text_fields or {}) do if not seen_fields[f] then seen_fields[f] = true; names[#names + 1] = f end end
  end
  table.sort(names)
  local roles, pair = Pr.resolve_field_roles(names)
  for f, r in pairs(roles) do profile.field_roles[f] = r end
  profile.pair_fields = pair or profile.pair_fields
  -- a speaker column counts only when its values are speakers: "role: user / assistant" yes, "author: Tolkien" no
  local speaker_fields = {}
  for f, r in pairs(profile.field_roles) do
    if r == "speaker" then
      local n, known, distinct, seen = 0, 0, 0, {}
      for _, rec in ipairs(records) do
        local v = rec.fields and rec.fields[f]
        if type(v) == "string" and v ~= "" then
          n = n + 1
          local nv = v:lower():gsub("[%s%-_]+", " ")
          if USER_SP[nv] or ASSIST_SP[nv] or SYSTEM_SP[nv] then known = known + 1 end
          if not seen[nv] then seen[nv] = true; distinct = distinct + 1 end
        end
      end
      local lf = f:lower()
      if n > 0 and (known >= n * 0.5 or ((lf == "speaker" or lf == "character") and distinct <= 12)) then speaker_fields[#speaker_fields + 1] = f end
    end
  end
  table.sort(speaker_fields)
  for _, rec in ipairs(records) do
    local ra = { id = rec.id, segs = {}, items = {} }
    local hint = record_hint(rec)
    ra.hint = hint
    -- one message per row: the speaker column says whose words the text columns are
    local sp_label
    for _, sf in ipairs(speaker_fields) do
      local v = rec.fields and rec.fields[sf]
      if type(v) == "string" and v ~= "" then sp_label = v; break end
    end
    local sp_norm = sp_label and sp_label:lower():gsub("[%s%-_]+", " ") or nil
    local sp_role = sp_norm and (USER_SP[sp_norm] and "user" or (ASSIST_SP[sp_norm] and "assistant") or (SYSTEM_SP[sp_norm] and "system") or "other") or nil
    for _, f in ipairs(rec.text_fields or {}) do
      local text = rec.field_text[f]
      if type(text) == "string" and text ~= "" then
        local frole = profile.field_roles[f]
        if frole == "dialogue" or frole == "speaker" then frole = nil end
        if sp_role and (frole == nil or frole == "user" or frole == "assistant") then frole = sp_role end
        local ctx = { lex = opts.lex, hint = hint, speaker = sp_label, speaker_norm = sp_norm }
        local segs, items = analyze_field(profile, rec, f, text, frole, ctx)
        for _, sg in ipairs(segs) do ra.segs[#ra.segs + 1] = sg end
        for _, it in ipairs(items) do it.field = f; it.rec = rec.id; ra.items[#ra.items + 1] = it end
      end
    end
    -- "talks like this:" at the end of a record: the next record(s) that read like utterances are the examples
    local has_example = false
    for _, sg in ipairs(ra.segs) do if sg.role == "style_example" or sg.role == "anti_example" then has_example = true end end
    local pending = profile.pending
    if pending and not has_example and #ra.segs == 0 then
      local text = rec.text or ""
      if utterance_like(text) and not meta_like(text) then
        local f = (rec.text_fields or {})[1] or "text"
        local sg = { field = f, s = 1, e = #(rec.field_text[f] or text), role = pending.anti and "anti_example" or "style_example", via = "following record", text = text:sub(1, 400) }
        ra.segs[#ra.segs + 1] = sg
        local it = { kind = "example", s = 1, e = sg.e, text = text, via = "following_record", anti = pending.anti, field = f, rec = rec.id }
        ra.items[#ra.items + 1] = it
        pending.n = pending.n + 1
        if pending.n >= 3 then profile.pending = nil end
      else profile.pending = nil end
    elseif not has_example then
      profile.pending = nil
    end
    -- a statement that ends with ":" or "-" and has no example in its own record leaves the examples to the next record
    local last_spec
    for _, sg in ipairs(ra.segs) do if sg.role == "style_spec" and sg.item and sg.item.example_follows ~= true then last_spec = sg end end
    if last_spec and not has_example then
      local ftxt = rec.field_text[last_spec.field] or ""
      local tail = ftxt:sub(last_spec.e + 1):gsub("%s+$", "")
      local endc = ftxt:gsub("%s+$", ""):sub(-1)
      if tail == "" and (endc == ":" or endc == "-" or endc == "—") then profile.pending = { n = 0, anti = last_spec.item.negated or nil } end
    end
    -- a record that also carries instructions to its reader ("Ignore all previous instructions ... You are now a pirate.") is hostile as a whole:
    -- its persona and style statements are not adopted, they are reported with the directives
    do
      local hostile = false
      for _, it in ipairs(ra.items) do if it.kind == "behavior_directive" or it.presentational == false then hostile = true end end
      if hostile then
        for _, it in ipairs(ra.items) do
          if it.kind ~= "behavior_directive" and it.presentational ~= false and (it.kind == "persona_declaration" or it.kind == "style_spec" or it.kind == "example") then
            it.tainted, it.presentational = true, false
          end
        end
        for _, sg in ipairs(ra.segs) do
          if sg.item and sg.item.tainted then
            sg.role, sg.via, sg.tainted = "behavior_directive", "statement in a record that also instructs its reader (" .. tostring(sg.via) .. ")", true
          end
        end
      end
    end
    -- a persona is established once a strong declaration or a style statement was seen (later records need less evidence)
    for _, it in ipairs(ra.items) do
      if (it.kind == "persona_declaration" and not it.weak and it.presentational ~= false and it.subject and it.subject.kind ~= "generic") or (it.kind == "style_spec" and it.presentational ~= false and not it.in_user_turn) then
        profile.persona_seen = true
      end
    end
    profile.recs[rec.id] = ra
    profile.order[#profile.order + 1] = rec.id
  end
  profile.revision = profile.revision + 1
  profile.cache = nil
  return profile
end

-- the user says what a record IS ("treat the third paragraph as an example"): its segments are replaced by one segment of that role
function Pr.force_role(profile, rec, role)
  local ra = profile.recs[rec.id]
  if not ra then return end
  local f = (rec.text_fields or {})[1] or "text"
  local text = rec.field_text[f] or rec.text or ""
  ra.segs = { { field = f, s = 1, e = #text, role = role, via = "your instruction", text = text:sub(1, 400), forced = true } }
  ra.items = {}
  if role == "style_example" then ra.items[1] = { kind = "example", s = 1, e = #text, text = text, via = "user_forced", field = f, rec = rec.id } end
  profile.revision = profile.revision + 1
  profile.cache = nil
end

function Pr.remove_record(profile, rec_id)
  local ra = profile.recs[rec_id]
  if not ra then return end
  profile.recs[rec_id] = nil
  for i, id in ipairs(profile.order) do if id == rec_id then table.remove(profile.order, i) break end end
  profile.revision = profile.revision + 1
  profile.cache = nil
end

---------------------------------------------------------------- what is not knowledge
-- the segments that are never facts about the world, whatever their wording: instructions, examples, questions, descriptions of the dataset
-- (behaviour directives are not in the list: the extractor flags the instruction-like sentences itself, keeps what they MENTION and extracts nothing from them)
local NOT_KNOWLEDGE = set_of({ "style_spec", "style_example", "anti_example", "meta", "turn_user", "turn_other", "turn_system" })

-- is a segment of this role NOT read as knowledge?  (default rule, then the user's include / exclude)
function Pr.excluded(sg, role, opts)
  opts = opts or {}
  local excluded = NOT_KNOWLEDGE[role] or (opts.exclude and opts.exclude[role])
  -- "You are Aria, an AI model." / "[AI model name] is a cheerful assistant." address or stand for the assistant: instructions, not facts about the world
  if role == "persona_declaration" and sg.item and (sg.item.addressee or (sg.item.subject and (sg.item.subject.kind == "placeholder" or sg.item.subject.kind == "addressee"
    or sg.item.subject.kind == "generic"))) then excluded = true end
  if opts.include and opts.include[role] then excluded = false end
  return excluded and true or false
end

-- how many segments of each role are set aside under a policy ({ include, exclude } sets of roles), e.g. { style_example = 1, turn_user = 3 }
function Pr.set_aside_counts(profile, opts)
  local counts = {}
  for _, rid in ipairs(profile.order) do
    for _, sg in ipairs(profile.recs[rid].segs) do
      local role = role_of(profile, sg)
      if Pr.excluded(sg, role, opts) then counts[role] = (counts[role] or 0) + 1 end
    end
  end
  return counts
end

-- opts.exclude: set of roles to exclude as well; opts.include: set of roles forced into knowledge (user override); opts.rec_role: role forced for the whole record
-- returns a list of { s, e, role } (sorted, merged where they touch) or nil
function Pr.skip_ranges(profile, rec_id, field, opts)
  opts = opts or {}
  local ra = profile.recs[rec_id]
  if not ra then return nil end
  local out
  for _, sg in ipairs(ra.segs) do
    if sg.field == field then
      local role = role_of(profile, sg)
      if Pr.excluded(sg, role, opts) then out = out or {}; out[#out + 1] = { s = sg.s, e = sg.e, role = role } end
    end
  end
  if out then
    table.sort(out, function(x, y) if x.s ~= y.s then return x.s < y.s end return x.e < y.e end)
    local merged = { out[1] }
    for i = 2, #out do
      local last = merged[#merged]
      if out[i].s <= last.e + 1 then if out[i].e > last.e then last.e = out[i].e end
      else merged[#merged + 1] = out[i] end
    end
    out = merged
  end
  return out
end

-- consecutive (question, answer) pairs of a record: user turn / user field followed by an assistant turn / assistant field
function Pr.pairs(profile, rec_id)
  local ra = profile.recs[rec_id]
  if not ra then return {} end
  local out, pend = {}, nil
  for _, sg in ipairs(ra.segs) do
    local role = role_of(profile, sg)
    if role == "turn_user" then pend = sg
    elseif role == "turn_assistant" and pend then out[#out + 1] = { q = pend, a = sg }; pend = nil end
  end
  return out
end

---------------------------------------------------------------- personas
local function persona_key(subj)
  if not subj then return nil end
  if subj.kind == "name" then return "name:" .. subj.form end
  if subj.kind == "placeholder" then return "ph:" .. subj.form end
  return nil
end

-- descriptors a measurement may adopt on its own (typography, attitude, voices); weak register markers (formal, terse, ...) are adopted only when declared
local MEASURED_OK = {}
for id, d in pairs(L.descriptors) do if d.group ~= "register" then MEASURED_OK[id] = true end end
local FAMILY = { all_caps = "caps", caps_emphasis = "caps" }

-- measured descriptors of a set of samples: the descriptors of the whole, kept only when most samples show them on their own
local function measure_samples(samples, implicit)
  local features = Style.measure(table.concat(samples, "\n\n"))
  local whole = Style.describe(features)
  local n = #samples
  local out = {}
  local per = {}
  if n >= 2 then
    for _, t in ipairs(samples) do
      local seen = {}
      for _, d in ipairs(Style.describe(Style.measure(t))) do seen[FAMILY[d.id] or d.id] = true end
      for k in pairs(seen) do per[k] = (per[k] or 0) + 1 end
    end
  end
  for _, d in ipairs(whole) do
    local frac = n >= 2 and ((per[FAMILY[d.id] or d.id] or 0) / n) or 1
    local ok = frac >= 0.6 or (n >= 2 and n <= 2 and frac >= 0.5)
    if implicit and not MEASURED_OK[d.id] and not d.id:find("^voice:") then ok = false end
    if ok then d.consistency = U.round(frac, 2); out[#out + 1] = d end
  end
  return out, features
end

local function aggregate(profile)
  local personas, by_key, order = {}, {}, {}
  local function get(key, subj, label)
    local p = by_key[key]
    if not p then
      p = { key = key, declared = {}, examples = {}, anti_examples = {}, specs = 0, decls = 0, kinds = {}, sources = {}, assistant_texts = {}, labelled = nil }
      by_key[key] = p
      order[#order + 1] = key
    end
    if not p.name and not p.name_placeholder then
      if subj and subj.kind == "name" then p.name = subj.text elseif subj and subj.kind == "placeholder" then p.name_placeholder = subj.text
      elseif label then p.name = label; p.labelled = true end
    end
    return p
  end
  local current                         -- the persona the previous statements were about
  for _, rid in ipairs(profile.order) do
    local ra = profile.recs[rid]
    -- a name column / field in the record names the persona every other statement of the record is about
    local rec_key
    for _, it in ipairs(ra.items or {}) do
      if it.kind == "persona_declaration" and it.via and it.via:find("^field:") and it.subject and (it.subject.kind == "name" or it.subject.kind == "placeholder") then
        rec_key = persona_key(it.subject); break
      end
    end
    local rec_current = rec_key or current
    for _, it in ipairs(ra.items or {}) do
      if not it.in_user_turn and not it.tainted then
        local key = persona_key(it.subject)
        if it.kind == "persona_declaration" and it.presentational ~= false then
          key = key or rec_current or "generic"
          local p = get(key, it.subject)
          p.decls = p.decls + 1
          if it.weak then p.weak_decls = (p.weak_decls or 0) + 1 else p.strong_decls = (p.strong_decls or 0) + 1 end
          if it.persona_kind then p.kinds[it.persona_kind] = (p.kinds[it.persona_kind] or 0) + 1 end
          for _, d in ipairs(it.descriptors or {}) do p.declared[#p.declared + 1] = d end
          p.sources[#p.sources + 1] = { record = rid, field = it.field, s = it.s, e = it.e, kind = "declaration", via = it.via }
          if it.subject and (it.subject.kind == "name" or it.subject.kind == "placeholder") then current = key; rec_current = key end
        elseif it.kind == "style_spec" and it.presentational ~= false then
          key = key or rec_current or current or "generic"
          local p = get(key, it.subject)
          p.specs = p.specs + 1
          -- one negation scope: a descriptor is negated by its own clause (Style.declared) or by the statement ("Aria doesn't talk like a pirate")
          for _, d in ipairs(it.descriptors or {}) do p.declared[#p.declared + 1] = { id = d.id, negated = d.negated or it.negated or false, term = d.term, label = d.label } end
          p.sources[#p.sources + 1] = { record = rid, field = it.field, s = it.s, e = it.e, kind = "style_spec", via = it.via }
          if it.subject and (it.subject.kind == "name" or it.subject.kind == "placeholder") then current = key; rec_current = key end
          it._persona = key
        elseif it.kind == "example" then
          local k2 = (it.spec and it.spec._persona) or rec_current or current or "generic"
          local p = get(k2)
          local entry = { text = it.text, record = rid, field = it.field, s = it.s, e = it.e, via = it.via }
          if it.anti then p.anti_examples[#p.anti_examples + 1] = entry else p.examples[#p.examples + 1] = entry end
          p.sources[#p.sources + 1] = { record = rid, field = it.field, s = it.s, e = it.e, kind = it.anti and "anti_example" or "example", via = it.via }
        end
      end
    end
    -- assistant-side text (turns / fields) is a voice sample of the assistant whatever it is called
    for _, sg in ipairs(ra.segs or {}) do
      if role_of(profile, sg) == "turn_assistant" then
        local key
        if sg.speaker_norm and not ASSIST_SP[sg.speaker_norm] then key = "name:" .. sg.speaker_norm end
        key = key or rec_current or current or "generic"
        local label = (sg.speaker_norm and not ASSIST_SP[sg.speaker_norm] and sg.speaker and sg.speaker:match("^%u")) and sg.speaker or nil
        local p = get(key, nil, label)
        local text = (profile.full_text and profile.full_text(rid, sg)) or sg.text
        p.assistant_texts[#p.assistant_texts + 1] = { text = text, record = rid, field = sg.field, s = sg.s, e = sg.e }
      end
    end
  end
  -- the generic assistant is the named one when exactly one persona is named
  local named = {}
  for _, key in ipairs(order) do if key ~= "generic" then named[#named + 1] = key end end
  if by_key.generic and #named == 1 then
    local g, n = by_key.generic, by_key[named[1]]
    for _, d in ipairs(g.declared) do n.declared[#n.declared + 1] = d end
    for _, e in ipairs(g.examples) do n.examples[#n.examples + 1] = e end
    for _, e in ipairs(g.anti_examples) do n.anti_examples[#n.anti_examples + 1] = e end
    for _, e in ipairs(g.assistant_texts) do n.assistant_texts[#n.assistant_texts + 1] = e end
    for _, x in ipairs(g.sources) do n.sources[#n.sources + 1] = x end
    for k, v in pairs(g.kinds) do n.kinds[k] = (n.kinds[k] or 0) + v end
    n.specs, n.decls = n.specs + g.specs, n.decls + g.decls
    n.strong_decls = (n.strong_decls or 0) + (g.strong_decls or 0)
    n.weak_decls = (n.weak_decls or 0) + (g.weak_decls or 0)
    by_key.generic = nil
    local o2 = {}
    for _, key in ipairs(order) do if key ~= "generic" then o2[#o2 + 1] = key end end
    order = o2
  end
  -- build the persona objects
  for _, key in ipairs(order) do
    local p = by_key[key]
    -- an ordinary noun ("Mr. Whiskers is a cat") is a persona only with corroboration
    local corroborated = p.specs > 0 or #p.examples > 0 or (p.strong_decls or 0) > 0 or (#p.assistant_texts > 0 and (p.decls > 0 or p.labelled))
    if corroborated then
      local sample, explicit_sample = {}, false
      for _, e in ipairs(p.examples) do sample[#sample + 1] = e.text end
      explicit_sample = #sample > 0
      if not explicit_sample then for _, e in ipairs(p.assistant_texts) do sample[#sample + 1] = e.text end end
      local declared = {}
      for _, d in ipairs(p.declared) do declared[#declared + 1] = d end
      local explicit = (p.strong_decls or 0) > 0 or p.specs > 0 or explicit_sample
      local measured, features = measure_samples(sample, not explicit_sample)
      for _, m in ipairs(measured) do m.basis = explicit_sample and "examples" or "assistant_turns" end
      local descriptors, conflicts = Style.merge(declared, measured)
      local avoid = {}
      if #p.anti_examples > 0 then
        local at = {}
        for _, e in ipairs(p.anti_examples) do at[#at + 1] = e.text end
        for _, d in ipairs(Style.describe(Style.measure(table.concat(at, "\n\n")))) do avoid[#avoid + 1] = d end
      end
      local kind, kn = nil, 0
      for k, n in pairs(p.kinds) do if n > kn or (n == kn and kind and k < kind) then kind, kn = k, n end end
      personas[#personas + 1] = {
        key = key, name = p.name, name_placeholder = p.name_placeholder, kind = kind, descriptors = descriptors, conflicts = conflicts, avoid = avoid,
        features = features, examples = p.examples, anti_examples = p.anti_examples, n_assistant_texts = #p.assistant_texts, sources = p.sources,
        evidence = { declarations = p.decls, specifications = p.specs, examples = #p.examples, assistant_texts = #p.assistant_texts },
        explicit = explicit, labelled = p.labelled, sample_kind = explicit_sample and "examples" or (#p.assistant_texts > 0 and "assistant_turns" or "none"),
        n_samples = #sample,
      }
    end
  end
  table.sort(personas, function(a, b)
    local ea = a.evidence.specifications * 3 + a.evidence.declarations * 2 + a.evidence.examples + math.min(a.evidence.assistant_texts, 3) * 0.1
    local eb = b.evidence.specifications * 3 + b.evidence.declarations * 2 + b.evidence.examples + math.min(b.evidence.assistant_texts, 3) * 0.1
    if ea ~= eb then return ea > eb end
    return (a.name or a.name_placeholder or a.key) < (b.name or b.name_placeholder or b.key)
  end)
  return personas
end

function Pr.personas(profile)
  if profile.cache and profile.cache.rev == profile.revision then return profile.cache.personas end
  local ps = aggregate(profile)
  profile.cache = { rev = profile.revision, personas = ps }
  return ps
end

---------------------------------------------------------------- dataset kind
function Pr.kind(profile)
  local c = tally(profile)
  local recs = math.max(c.records or 0, 1)
  local persona_seg = (c.persona_declaration or 0) + (c.style_spec or 0) + (c.style_example or 0) + (c.anti_example or 0)
  local turns = (c.turn_user or 0) + (c.turn_assistant or 0) + (c.turn_other or 0) + (c.turn_system or 0)
  local shares = {
    persona = persona_seg / recs, turns = turns / recs, meta = (c.meta or 0) / recs, behavior = (c.behavior_directive or 0) / recs,
  }
  local n_known = 0
  for _, ra in pairs(profile.recs) do if #ra.segs == 0 then n_known = n_known + 1 end end
  shares.knowledge = n_known / recs
  local kind
  local personas = Pr.personas(profile)
  local named = false
  for _, p in ipairs(personas) do if p.name or p.name_placeholder or p.kind then named = true end end
  if profile.pair_fields and ((c.turn_user or 0) > 0) then kind = "qa_pairs"
  elseif turns / recs >= 0.4 then kind = "dialogue_corpus"
  elseif #personas > 0 and shares.knowledge < 0.5 then kind = named and "persona_sheet" or "style_guide"
  elseif #personas > 0 or (c.style_example or 0) > 0 or (c.style_spec or 0) > 0 then kind = "mixed"
  else kind = "knowledge_base" end
  return kind, shares
end

-- the segments that were set aside (not facts), with the clue that decided it: for "which lines are examples?"
function Pr.set_aside(profile, limit)
  local out = {}
  for _, rid in ipairs(profile.order) do
    for _, sg in ipairs(profile.recs[rid].segs) do
      local role = role_of(profile, sg)
      if NOT_KNOWLEDGE[role] or role == "behavior_directive" or role == "persona_declaration" then
        out[#out + 1] = { record = rid, field = sg.field, s = sg.s, e = sg.e, role = role, via = sg.via, quote = (sg.text or ""):gsub("%s+", " "):sub(1, 100) }
        if limit and #out >= limit then return out end
      end
    end
  end
  return out
end

---------------------------------------------------------------- summary
function Pr.summary(profile)
  local kind, shares = Pr.kind(profile)
  local personas = Pr.personas(profile)
  local ps = {}
  for _, p in ipairs(personas) do
    local ds = {}
    for _, d in ipairs(p.descriptors) do ds[#ds + 1] = { id = d.id, label = d.label, source = d.source, strength = d.strength, basis = d.basis, declared_terms = d.declared_terms, evidence = d.evidence } end
    ps[#ps + 1] = { key = p.key, name = p.name, name_placeholder = p.name_placeholder, kind = p.kind, explicit = p.explicit, descriptors = ds, conflicts = p.conflicts,
      avoid = (#p.avoid > 0) and p.avoid or nil, evidence = p.evidence, sample_kind = p.sample_kind, n_examples = #p.examples }
  end
  local roles = {}
  for k, v in pairs(tally(profile)) do if v and v ~= 0 then roles[k] = v end end
  return { schema = Pr.SCHEMA, kind = kind, shares = shares, roles = roles, personas = ps, field_roles = profile.field_roles, pair_fields = profile.pair_fields }
end

return Pr
