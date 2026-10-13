-- asi.nlu.hook: the ONE integration point for a host program (for example the user's exec_eval bundle).
--   local Hook = require("asi.nlu.hook")
--   local out  = Hook.prepare("Which company acquired the business I mentioned earlier?", { memory = Hook.memory("session-1", "alice") })
--   -- out.prompt  : the LM Input Package text (authority boundaries, verified evidence, ambiguity and unresolved requirements)
--   -- out.record  : the versioned Interpretation Record (inspectable without any language model)
-- The hook never calls a language model, a network service or a clock; it never routes text into any other interface of the host.  Natural-language
-- text goes in, a structured interpretation and a bounded, authority-labelled input package come out.
local Hook = {}

local engine

-- datasets: optional list of { text = <file contents>, name = "world_2020.jsonl", dataset = "w2020", label = { year = 2020 }, version = "2020" }
function Hook.configure(opts)
  opts = opts or {}
  local Resources = require("asi.nlu.resources")
  local K = require("asi.nlu.knowledge")
  local Engine = require("asi.nlu.engine")
  local Cal = require("asi.nlu.calibration")
  local kb
  if opts.datasets and #opts.datasets > 0 then
    kb = K.new(Resources.core())
    for _, d in ipairs(opts.datasets) do kb:ingest(d.text, { name = d.name, dataset = d.dataset or d.name, label = d.label, version = d.version }) end
  end
  local model = opts.calibration or Cal.default_model()
  engine = Engine.new({ knowledge = kb, flags = opts.flags, budget = opts.budget, package_chars = opts.package_chars,
    calibration = (model and not opts.no_calibration) and Cal.record_adapter(model) or nil })
  return engine
end

function Hook.engine()
  return engine or Hook.configure({})
end

-- a conversation memory owned by `principal` (another principal is refused access to the namespace)
function Hook.memory(namespace, principal)
  return Hook.engine():memory(namespace, principal)
end

-- text -> { record, package, prompt, result, evidence }.  call = { memory = , speaker = , include_prompt = , package_chars = , budget = }
function Hook.prepare(text, call)
  call = call or {}
  if call.include_prompt == nil then call.include_prompt = true end
  local out = Hook.engine():process(text, call)
  return { record = out.record, package = out.package, prompt = out.package and out.package.prompt, result = out.result, evidence = out.evidence,
    valid = out.valid, light = out.light }
end

function Hook.version()
  local Engine = require("asi.nlu.engine")
  local Record = require("asi.nlu.record")
  return { engine = Engine.VERSION, record_schema = Record.SCHEMA }
end

return Hook
