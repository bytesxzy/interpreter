-- usage: lua5.4 tools/run_perf.lua [--md path]
-- Scaling measurements.  `work` is the deterministic instruction-independent work counter of the interpreter (same on every machine); wall time and memory
-- are measured on the machine that runs the tool and are reported only to show growth, not as absolute claims.
package.path = (arg[0]:match("^(.*)/tools/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local root = arg[0]:match("^(.*)/tools/[^/]*$") or "."
local U = require("asi.nlu.util")
local I = require("asi.nlu.interp")
local Memory = require("asi.nlu.memory")
local K = require("asi.nlu.knowledge")
local R = require("asi.nlu.resources")
local B = require("asi.nlu.rbench")
local Engine = require("asi.nlu.engine")

local opts = { md = root .. "/reports/performance.md" }
do local i = 1; while i <= #arg do local a = arg[i]; if a:sub(1, 2) == "--" then opts[a:sub(3)] = arg[i + 1]; i = i + 2 else i = i + 1 end end end
local out = { "# Performance and scaling", "",
  "Measured by `tools/run_perf.lua`. `work` is the interpreter's deterministic work counter (identical on every machine); wall time and memory are from",
  "the machine that produced this file and show growth only.", "" }
local function mem_kb() collectgarbage("collect"); return collectgarbage("count") end

-- 1. interpretation cost vs input length (one message of N sentences)
do
  local base = { "What is the capital of France?", "Who founded Acme Robotics in 1998?", "Find companies in Germany, not universities.",
    "We decided to use PostgreSQL for the billing service.", "The weather in Lisbon was grey and windy all week.", "Compare Harrow Dynamics and Vireo Labs." }
  local interp = I.new({})
  out[#out + 1] = "## Interpretation cost vs message length (single message, N sentences)"
  out[#out + 1] = ""
  out[#out + 1] = "| sentences | bytes | work | work/sentence | wall (s) |"
  out[#out + 1] = "|---|---|---|---|---|"
  local prev
  for _, n in ipairs({ 1, 6, 24, 96, 384 }) do
    local parts = {}
    for i = 1, n do parts[#parts + 1] = base[(i - 1) % #base + 1] end
    local text = table.concat(parts, " ")
    local t0 = os.clock()
    local r = interp:interpret(text, { budget = 50000000 })
    local wall = os.clock() - t0
    local w = r.work and r.work.total or 0
    out[#out + 1] = string.format("| %d | %d | %d | %.0f | %.3f |", n, #text, w, w / n, wall)
    prev = w
  end
  out[#out + 1] = ""
end

-- 2. memory-layer cost vs conversation length
do
  local LC = require("asi.nlu.longctx")
  out[#out + 1] = "## Conversation memory: cost of the final request vs conversation length"
  out[#out + 1] = ""
  out[#out + 1] = "| turns | memory items | work (final request) | wall total (s) | heap (KB) |"
  out[#out + 1] = "|---|---|---|---|---|"
  local interp = I.new({})
  for _, n in ipairs({ 10, 100, 500, 1000 }) do
    local rng = U.rng(7)
    local sc = LC.BUILD.backref_entity(rng, n, "begin")
    local before = mem_kb()
    local score, mem = LC.run(interp, Memory, sc)
    out[#out + 1] = string.format("| %d | %d | %d | %.2f | %.0f |", n, score.items or 0, score.work_final, score.wall, mem_kb() - before)
  end
  out[#out + 1] = ""
end

-- 3. dataset ingestion and query cost vs dataset size
do
  out[#out + 1] = "## Dataset ingestion and question answering vs dataset size"
  out[#out + 1] = ""
  out[#out + 1] = "| records | ingest wall (s) | heap (KB) | assertions | question work (median) | question wall (ms, median) | correct / answerable |"
  out[#out + 1] = "|---|---|---|---|---|---|---|"
  for _, nf in ipairs({ 40, 200, 1000, 4000 }) do
    local bench = B.generate({ vocab = "dev", seed = 3, n_facts = nf })
    local before = mem_kb()
    local kb = K.new(R.core())
    local t0 = os.clock()
    kb:ingest(B.to_jsonl(bench), { name = "perf.jsonl", dataset = "perf", label = { year = 2020 } })
    local ingest = os.clock() - t0
    local heap = mem_kb() - before
    local eng = Engine.new({ knowledge = kb, validate = false })
    local works, walls, answerable, correct = {}, {}, 0, 0
    local step = math.max(1, #bench.questions // 60)
    for qi = 1, #bench.questions, step do
      local q = bench.questions[qi]
      local t1 = os.clock()
      local o = eng:process(q.question, { cache = false })
      walls[#walls + 1] = (os.clock() - t1) * 1000
      works[#works + 1] = o.record.execution_cost.interpretation_work or 0
      if not q.unsupported and not q.insufficient then
        answerable = answerable + 1
        local es = o.record.evidence_sufficiency
        if es.status == "answerable" and es.answer and es.answer.text:lower() == (q.answer or ""):lower() then correct = correct + 1 end
      end
    end
    table.sort(works); table.sort(walls)
    out[#out + 1] = string.format("| %d | %.2f | %.0f | %d | %d | %.1f | %d / %d |", #bench.records, ingest, heap, kb:stats().assertions or 0, works[(#works + 1) // 2], walls[(#walls + 1) // 2], correct, answerable)
  end
  out[#out + 1] = ""
end

local f = assert(io.open(opts.md, "w"))
f:write(table.concat(out, "\n") .. "\n")
f:close()
print(table.concat(out, "\n"))
