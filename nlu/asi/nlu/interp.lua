-- asi.nlu.interp: the interpreter facade.  text -> lexical analysis -> lattice -> semantic hypotheses -> interpretation.
-- LM-independent, deterministic (no clock/randomness), metered (explicit `limited` status instead of silent guessing).
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Lattice = require("asi.nlu.lattice")
local Sem = require("asi.nlu.sem")
local Resources = require("asi.nlu.resources")

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

function I:interpret(text, call)
  call = call or {}
  local meter = U.meter(call.budget or self.budget)
  local an = Lex.analyze(text, { spell = self.lex.spell, now = call.now, meter = meter, max_bytes = call.max_bytes })
  local result = { original = an.original, analysis = an, status = an.status, sentences = {} }
  if an.status == "rejected" then return result end
  local lat = Lattice.build(an, self.lex, { meter = meter })
  result.lattice = lat
  local ctx = { flags = self.flags, temperature = self.temperature, max_covers = self.max_covers, meter = meter, domains = call.domains,
    mentioned = call.mentioned, support = call.support }
  for _, sent in ipairs(an.sentences) do
    local res = Sem.analyze_sentence(an, lat, self.lex, sent, ctx)
    if res then
      result.sentences[#result.sentences + 1] = { res = res, interp = Sem.render(res, ctx) }
    end
    if meter.over then
      result.status = "limited"
      break
    end
  end
  local rendered = {}
  for i, s in ipairs(result.sentences) do rendered[i] = s.interp end
  result.main_index = pick_main(rendered)
  result.main = rendered[result.main_index]
  result.work = meter:snapshot()
  return result
end

return I
