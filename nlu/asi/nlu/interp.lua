-- asi.nlu.interp: the interpreter facade.  text -> lexical analysis -> lattice -> semantic hypotheses -> interpretation.
-- LM-independent, deterministic (no clock/randomness), metered (explicit `limited` status instead of silent guessing).
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Lattice = require("asi.nlu.lattice")
local Sem = require("asi.nlu.sem")
local Resources = require("asi.nlu.resources")
local Memory = require("asi.nlu.memory")
local Coref = require("asi.nlu.coref")
local P = require("asi.nlu.parse")

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
  local ua, ub = Sem.sentence_unit_range(an, sent.id)
  if not ua then return cues end
  for i = ua, ub do
    local u = an.units[i]
    do
      if lex:cue_at("hedge", an.units, i) then cues.hedged = true end
      local rn = lex:cue_at("revoke", an.units, i)
      if rn and not cues.revoke then
        -- a revocation needs a TARGET: a slot noun ("the dataset instruction"), an instruction-class noun ("my last constraint"), or nothing but
        -- anaphora ("never mind." / "scratch that").  "Never mind the noise outside" revokes nothing.
        local rv = { bare = true }
        for k = i + rn, #an.units do
          local u = an.units[k]
          if u.sent ~= sent.id then break end
          local cats = lex:cats(u.form) or {}
          local closed = cats.det or cats.pron or cats.prep or cats.aux_be or cats.aux_do or cats.adv or cats.polite or cats.conj or cats.particle or u.kind ~= "word"
          local slot = lex:resource(u.form)
          if slot and slot ~= "year" then rv.slot = rv.slot or slot; rv.bare = false
          elseif lex:refclasses(u.form).correction then rv.class = true; rv.bare = false
          elseif not closed then rv.bare = false end
        end
        cues.revoke = rv
      end
      if lex:cue_at("additive", an.units, i) then cues.additive = true end
      if lex:cue_at("scoped", an.units, i) then cues.scoped = true end
      if lex:cue_at("decision", an.units, i) then cues.decision = true end
      if lex:cue_at("decision_ref", an.units, i) then cues.decision_ref = true end
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
    if not mem.refclasses then local lx = self.lex; mem.refclasses = function(w) return lx:refclasses(w) end end
    mem:begin_turn(speaker)
    view = Coref.view(mem, self.lex)
    result.memory = mem
  end
  if call.light and mem then
    -- light observation (assistant / document turns): attested entity mentions only, no semantic parse and no standing instructions
    for _, sent in ipairs(an.sentences) do
      local ua, ub = Sem.sentence_unit_range(an, sent.id)
      local cover = ua and lat:covers(1, ua, ub)[1]
      local found = {}
      for si, sp in ipairs(cover and cover.spans or {}) do
        local ids, name_r = {}, nil
        for _, r in ipairs(sp.readings) do
          if r.kind == "entity" and not r.fuzzy and r.entry then ids[r.entry.id] = r.entry.etype
          elseif r.kind == "name" and not name_r then name_r = r end
        end
        local text = an.original:sub(an.units[sp.i].s, an.units[sp.j].e)
        local n, only = 0, nil
        for id in pairs(ids) do n = n + 1; only = id end
        if n == 1 then
          mem:mention(only, { type = ids[only], name = text, w = 0.2, role = "mention", speaker = speaker })
          found[#found + 1] = { key = only, c1 = si, c2 = si }
        elseif n == 0 and name_r then
          local key = "mention:" .. text:lower()
          mem:mention(key, { type = name_r.type_guess, name = text, w = 0.2, role = "mention", speaker = speaker, weak = name_r.weak })
          found[#found + 1] = { key = key, c1 = si, c2 = si }
        end
      end
      if #found > 0 then
        local S = P.new_state(an, self.lex, lat, cover, { flags = flags, meter = meter })
        Coref.describe_entities(view, S, found, speaker)
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
      local cues = view and sentence_cues(an, sent, self.lex) or {}
      -- a stated decision is remembered even when the sentence has no parsable relational structure
      if view and cues.decision and speaker == "user" then mem:note_decision(interp.sentence.text, { sent = si }) end
      if view then
        -- references that only memory can resolve (back-references, ordinal artifacts, corrections, comparison sets)
        local rr = (flags.no_coref or interp.status ~= "ok") and { references = {}, by_text = {}, unresolved = {} } or Coref.resolve_references(view, interp)
        local ctxinfo = { references = rr.references, unresolved = rr.unresolved }
        if interp.speech_act ~= "statement" and not flags.no_memory_select then
          local sel = mem:select(interp, { max_items = 12, decision_ref = cues.decision_ref })
          ctxinfo.memory = trim_selection(sel, 8)
          ctxinfo.memory.namespace, ctxinfo.memory.revision, ctxinfo.memory.turn = mem:ns_key(), mem.revision, mem.turn
          ctxinfo.memory.n_candidates, ctxinfo.memory.n_items = sel.n_candidates, sel.n_items
          ctxinfo.active_constraints = mem:active_constraints(interp)
          if interp.intent == "conversation_recall" then
            rr.recall_found = #sel.selected > 0
            ctxinfo.recall = { found = rr.recall_found }
            if not rr.recall_found then
              rr.unresolved[#rr.unresolved + 1] = { kind = "conversation_recall", mention = interp.sentence.text, requirement = "nothing in the conversation matches what is being recalled (none is invented)" }
            end
          end
        end
        ctxinfo.dependency = mem:classify_dependency(interp, rr)
        if interp.status ~= "ok" then ctxinfo.note = "no semantic interpretation; only lexical memory selection was possible" end
        interp.context = ctxinfo
        if interp.status == "ok" and (speaker == "user" or call.observe_all) then
          mem:observe_sentence(interp, { speaker = speaker, sent = si, hedged = cues.hedged, revoke = cues.revoke, additive = cues.additive, scoped = cues.scoped })
          local items = {}
          Coref.walk(interp, function(r)
            local key = r.antecedent and r.antecedent.key or r.resolved_id
            if key and r.chunk_range and not r.deictic and not r.pronoun and not r.backref then items[#items + 1] = { key = key, c1 = r.chunk_range[1], c2 = r.chunk_range[2] } end
          end)
          if #items > 0 then Coref.describe_entities(view, res.S, items, speaker) end
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
