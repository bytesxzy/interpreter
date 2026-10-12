-- shared helper: build the controlled acceptance knowledge base
local M = {}
function M.build(root)
  local R = require("asi.nlu.resources")
  local K = require("asi.nlu.knowledge")
  local E = require("asi.nlu.eval")
  local kb = K.new(R.core())
  local reports = {}
  local function load(name, opts)
    local text = assert(E.read_file(root .. "/data/acceptance/" .. name), "cannot read " .. name)
    opts.name = name
    reports[#reports + 1] = kb:ingest(text, opts)
  end
  load("world_2020.jsonl", { dataset = "w2020", label = { year = 2020 }, version = "2020" })
  load("world_2019.jsonl", { dataset = "w2019", label = { year = 2019 }, version = "2019" })
  load("triples.csv", { dataset = "tri", label = { year = 2020 }, version = "2020", mapping = { id_field = nil, text_fields = {}, meta_fields = { "reliability" }, reliability_field = "reliability", triple = { subject = "subject", relation = "relation", object = "object" } } })
  return kb, reports
end
return M
