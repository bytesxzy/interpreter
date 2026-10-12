-- asi.nlu.interp: the interpreter facade.  text -> lexical analysis -> lattice -> semantic hypotheses -> interpretation.
-- LM-independent, deterministic (no clock/randomness), metered (explicit `limited` status instead of silent guessing).
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Lattice = require("asi.nlu.lattice")
local Sem = require("asi.nlu.sem")
local Resources = require("asi.nlu.resources")
local Memory = require("asi.nlu.memory")
local Coref = require("asi.nlu.coref")

local I = {}
I.__index = I
I.VERSION = "0.1.0"

function I.new(opts)
  opts = opts or {}
  local self = setmetatable({}, I)
  self.lex = opts.lexicon or Resources.core()
  self.flags = opts.flags or {}           -- ablation switches: no_types, no_domain, no_hypotheses, no_semantics, ...
  self.budget = opts.budget or 2000000    -- integer work units per call
  self.temperature = opts.temperature
  self.max_covers = opts.max_covers or 3
  self.calibration = opts.calibration
  return self
end

-- main sentence: the last question/request, else the last sentence
local function pick_main(rendered)
  local main
  for i, r in ipairs(rendered) do
    if r.speech_act == "question" or r.speech_act == "request" or r.speech_act == "instruction" or r.speech_act == "correction" then main = i end
  end
  return main or #rendered
end

-- scan a sentence's units for discourse cues that change how it is remembered
local function sentence_cues(an, sent, lex)
  local cues = {}
  for i, u in ipairs(an.units) do
    if u.sent == sent.id then
      if lex:cue_at("hedge", an.units, i) then cues.hedged = true end
      if lex:cue_at("revoke", an.units, i) then cues.revoke_cue = true end
      if lex:cue_at("additive", an.units, i) then cues.additive = true end
      if lex:cue_at("scoped", an.units, i) then cues.scoped = true end
    end
  end
  return cues
end

local function trim_selection(sel, max_excluded)
  local out = { selected = {}, excluded = {}, n_selected = #sel.selected, n_excluded = #sel.excluded }
  for _, c in ipairs(sel.selected) do
    local it = c.item
    out.selected[#out.selected + 1] = { id = it.id, kind = it.kind, layer = it.layer, turn = it.turn, speaker = it.speaker, status = it.status, slot = it.slot,
      value = it.value, text = (it.text or ""):sub(1, 200), score = U.round(c.score, 3), factors = c.factors, reliability = it.reliability }
  end
  for i, x in ipairs(sel.excluded) do
    if i > (max_excluded or 8) then break end
    out.excluded[#out.excluded + 1] = { id = x.item.id, kind = x.item.kind, turn = x.item.turn, reason = x.reason, text = (x.item.text or ""):sub(1, 120) }
  end
  return out
end

-- Interpret `text`.  call = { memory = <asi.nlu.memory>, speaker = "user"|"assistant"|"doc", now = <date>, budget = n, domains = {}, support = fn }
-- With a memory, pronouns / back-references / corrections resolve against it and every sentence is observed into it.
-- Without one, a transient memory covers references inside this single message.
function I:interpret(text, call)
  call = call or {}
  local meter = U.meter(call.budget or self.budget)
  local an = Lex.analyze(text, { spell = self.lex.spell, now = call.now, meter = meter, max_bytes = call.max_bytes })
  local result = { original = an.original, analysis = an, status = an.status, sentences = {} }
  if an.status == "rejected" then return result end
  local lat = Lattice.build(an, self.lex, { meter = meter })
  result.lattice = lat
  local flags = self.flags
  local mem = call.memory
  if not mem and not flags.no_memory then mem = Memory.new({ transient = true }) end
  local speaker = call.speaker or "user"
  local view
  if mem then
    mem:begin_turn(speaker)
    view = Coref.view(mem, self.lex)
    result.memory = mem
  end
  if call.light and mem then
    -- light observation (assistant / document turns): attested entity mentions only, no semantic parse and no standing instructions
    for _, sent in ipairs(an.sentences) do
      local ua, ub = Sem.sentence_unit_range(an, sent.id)
      local cover = ua and lat:covers(1, ua, ub)[1]
      for _, sp in ipairs(cover and cover.spans or {}) do
        local ids, name_r = {}, nil
        for _, r in ipairs(sp.readings) do
          if r.kind == "entity" and not r.fuzzy and r.entry then ids[r.entry.id] = r.entry.etype
          elseif r.kind == "name" and not name_r then name_r = r end
        end
        local text = an.original:sub(an.units[sp.i].s, an.units[sp.j].e)
        local n, only = 0, nil
        for id in pairs(ids) do n = n + 1; only = id end
        if n == 1 then mem:mention(only, { type = ids[only], name = text, w = 0.2, role = "mention", speaker = speaker })
        elseif n == 0 and name_r then mem:mention("mention:" .. text:lower(), { type = name_r.type_guess, name = text, w = 0.2, role = "mention", speaker = speaker }) end
      end
    end
    if not call.skip_utterance then mem:note_utterance(text, speaker) end
    result.light, result.work = true, meter:snapshot()
    return result
  end
  local ctx = { flags = flags, temperature = self.temperature, max_covers = self.max_covers, meter = meter, domains = call.domains,
    mentioned = call.mentioned, support = call.support }
  if view and not flags.no_coref then ctx.discourse = view end
  for si, sent in ipairs(an.sentences) do
    if view then
      ctx.mentioned = view:mention_weights()
      if not flags.no_domain then
        local dp = view:domain_profile()
        for d, n in pairs(call.domains or {}) do dp[d] = math.max(dp[d] or 0, n) end
        ctx.domains = dp
      end
    end
    local res = Sem.analyze_sentence(an, lat, self.lex, sent, ctx)
    if res then
      local interp = Sem.render(res, ctx)
      if view and interp.status == "ok" then
        local cues = sentence_cues(an, sent, self.lex)
        -- references that only memory can resolve (back-references, ordinal artifacts, corrections, comparison sets)
        local rr = flags.no_coref and { references = {}, by_text = {}, unresolved = {} } or Coref.resolve_references(view, interp)
        local ctxinfo = { references = rr.references, unresolved = rr.unresolved }
        ctxinfo.dependency = mem:classify_dependency(interp, rr)
        if interp.speech_act ~= "statement" and not flags.no_memory_select then
          local sel = mem:select(interp, { max_items = 12 })
          ctxinfo.memory = trim_selection(sel, 8)
          ctxinfo.memory.namespace, ctxinfo.memory.revision, ctxinfo.memory.turn = mem:ns_key(), mem.revision, mem.turn
          ctxinfo.active_constraints = mem:active_constraints(interp)
        end
        interp.context = ctxinfo
        if speaker == "user" or call.observe_all then
          mem:observe_sentence(interp, { speaker = speaker, sent = si, hedged = cues.hedged, revoke_cue = cues.revoke_cue, additive = cues.additive, scoped = cues.scoped })
        end
      end
      result.sentences[#result.sentences + 1] = { res = res, interp = interp }
    end
    if meter.over then
      result.status = "limited"
      break
    end
  end
  if mem and not call.skip_utterance then mem:note_utterance(text, speaker) end
  local rendered = {}
  for i, s in ipairs(result.sentences) do rendered[i] = s.interp end
  result.main_index = pick_main(rendered)
  result.main = rendered[result.main_index]
  result.work = meter:snapshot()
  return result
end

return I
