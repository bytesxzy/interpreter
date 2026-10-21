-- asi.nlu.engine: the complete LM-independent pipeline.
--   text -> lexical analysis -> semantic interpretation (competing hypotheses) -> context / memory -> retrieval plan -> candidate generation
--        -> semantic verification -> Interpretation Record -> LM Input Package
-- No stage calls a language model, a network service or a clock.  Every stage is metered; a resource limit yields an explicit `limited` status
-- and an unresolved requirement, never a confident guess.
local U = require("asi.nlu.util")
local Interp = require("asi.nlu.interp")
local Memory = require("asi.nlu.memory")
local Resources = require("asi.nlu.resources")
local Plan = require("asi.nlu.plan")
local Verify = require("asi.nlu.verify")
local Record = require("asi.nlu.record")
local Package = require("asi.nlu.package")
local Voice = require("asi.nlu.voice")

local E = {}
E.__index = E
E.VERSION = Record.ENGINE_VERSION

-- opts: { lexicon, knowledge, flags, budget, calibration, package_chars, cache_size, validate }
function E.new(opts)
  opts = opts or {}
  local self = setmetatable({}, E)
  self.base_lexicon = opts.lexicon or Resources.core()
  self.kb = opts.knowledge
  self.flags = opts.flags or {}
  self.budget = opts.budget or 2000000
  self.calibration = opts.calibration
  self.package_chars = opts.package_chars or 6000
  self.validate = opts.validate ~= false
  self.cache, self.cache_order, self.cache_size = {}, {}, opts.cache_size or 256
  self.store = Memory.store()
  self.stats = { requests = 0, cache_hits = 0 }
  self:rebuild_interpreter()
  return self
end

function E:rebuild_interpreter()
  local lex = self.kb and self.kb.lex or self.base_lexicon
  self.interp = Interp.new({ lexicon = lex, flags = self.flags, budget = self.budget })
end

function E:set_knowledge(kb)
  self.kb = kb
  self:rebuild_interpreter()
  self.cache, self.cache_order = {}, {}
end

-- open (or create) a conversation memory; a principal that does not own the namespace is refused
function E:memory(ns, principal)
  return self.store:open(ns, principal)
end

local function recent_turns(mem, n)
  local out = {}
  if not mem then return out end
  for i = #mem.order, 1, -1 do
    local it = mem.items[mem.order[i]]
    if it and it.kind == "utterance" and it.turn < mem.turn and it.status == "active" then
      table.insert(out, 1, { speaker = it.speaker, text = it.text, turn = it.turn })
      if #out >= n then break end
    end
  end
  return out
end

local function flags_signature(flags)
  local ks = U.sorted_keys(flags)
  local parts = {}
  for _, k in ipairs(ks) do parts[#parts + 1] = k .. "=" .. tostring(flags[k]) end
  return table.concat(parts, ",")
end

function E:cache_key(text, call)
  return U.sha256(table.concat({ text, self.kb and self.kb:digest() or "nokb", tostring((self.kb and self.kb.lex or self.base_lexicon).revision), flags_signature(self.flags),
    Record.SCHEMA, E.VERSION, tostring(call.now), tostring(self.package_chars) }, "\0"))
end

-- call: { memory, speaker, now, budget, include_prompt, cache }
function E:process(text, call)
  call = call or {}
  self.stats.requests = self.stats.requests + 1
  local key
  -- results are cached only for stateless calls: a call with a memory has side effects and depends on the memory revision
  if not call.memory and call.cache ~= false then
    key = self:cache_key(text, call)
    local hit = self.cache[key]
    if hit then self.stats.cache_hits = self.stats.cache_hits + 1; return hit, true end
  end
  local result = self.interp:interpret(text, { memory = call.memory, speaker = call.speaker, now = call.now, budget = call.budget, domains = call.domains, light = call.light,
    persona_names = self.kb and Voice.persona_names(self.kb) or nil })
  local out = { result = result }
  if result.light then out.light = true; return out end
  local m = result.main
  -- what the user said about the voice and about how the dataset is read (an instruction of THIS request is already in the memory; a stateless call carries it itself)
  local voice_items = Voice.collect(call.memory)
  local own_ops, own_slot
  if m and m.instruction and m.instruction.ops and (m.instruction.slot == "tone" or m.instruction.slot == "persona" or m.instruction.slot == "dataset_role") then
    own_ops, own_slot = m.instruction.ops, m.instruction.slot
    if not call.memory then voice_items[#voice_items + 1] = { slot = own_slot, ops = own_ops, text = text, turn = 1 } end
  end
  local policy_changed = false
  if self.kb and self.kb.profiles then
    policy_changed = self.kb:set_policy_all(Voice.policy(Voice.state(voice_items)))
    if policy_changed then self:rebuild_interpreter(); self.cache, self.cache_order = {}, {}; key = nil end
  end
  if own_ops then key = nil end
  local plan = Plan.build(m, self.kb)
  local evidence
  if self.kb and plan.kind ~= "none" and not (self.flags.no_retrieval) then
    -- verification ablations (each flag disables exactly one check; production runs with none)
    local skip
    for flag, name in pairs({ v_no_time = "time", v_no_type = "type", v_no_source = "source", v_no_polarity = "polarity", v_no_duplicates = "duplicates",
      v_no_reliability = "reliability", v_no_exclusion = "exclusion", v_no_modality = "modality", v_no_typed = "typed", v_no_specialization = "specialization" }) do
      if self.flags[flag] then skip = skip or {}; skip[name] = true end
    end
    evidence = Verify.run(self.kb, plan, { skip = skip })
  end
  local voice = Voice.build(self.kb, voice_items, { turn = call.memory and call.memory.turn or 1 })
  local reply
  if voice then
    if own_ops then reply = Voice.reply(self.kb, "instruction", voice, own_ops, policy_changed)
    elseif m and m.voice_query then reply = Voice.reply(self.kb, m.voice_query, voice) end
  elseif m and m.voice_query then
    reply = { kind = m.voice_query, text = "No dataset with a persona, a tone or a structure to report is loaded.", authority = "engine" }
  end
  local rec = Record.build({ result = result, plan = plan, evidence = evidence, flags = self.flags, calibration = self.calibration,
    lexicon_revision = (self.kb and self.kb.lex or self.base_lexicon).revision, interpreter_version = Interp.VERSION, recent = recent_turns(call.memory, 3), voice = voice, reply = reply })
  out.plan, out.evidence, out.record = plan, evidence, rec
  if self.validate then
    local ok, errs = Record.validate(rec)
    out.valid, out.validation_errors = ok, errs
    if not ok then rec.unresolved_requirements[#rec.unresolved_requirements + 1] = { kind = "schema_violation", requirement = table.concat(errs, "; "):sub(1, 400) } end
  end
  out.package = Package.build(rec, { max_chars = call.package_chars or self.package_chars, include_prompt = call.include_prompt })
  if key then
    self.cache[key] = out
    self.cache_order[#self.cache_order + 1] = key
    if #self.cache_order > self.cache_size then
      local old = table.remove(self.cache_order, 1)
      self.cache[old] = nil
    end
  end
  return out, false
end

-- convenience: a conversation bound to one namespace and owner
function E:conversation(ns, principal, defaults)
  local mem, err = self:memory(ns, principal)
  if not mem then return nil, err end
  local conv = { engine = self, memory = mem }
  function conv:say(text, speaker, opts)
    local call = U.shallow(opts or {})
    call.memory, call.speaker = mem, speaker or "user"
    if call.speaker ~= "user" and call.light == nil then call.light = true end
    return self.engine:process(text, call)
  end
  return conv
end

return E
