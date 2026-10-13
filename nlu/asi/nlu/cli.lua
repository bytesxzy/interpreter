-- asi.nlu.cli: command-line front end of the interpretation engine.  LM-independent, deterministic, no network.
--   interpret         interpret text (optionally against datasets and a conversation memory); human summary, JSON record, or the LM Input Package
--   interpret-eval    run a gold-case file (dev / val / test / any .cases file) with optional ablations
--   interpret-report  one-page status: the latest measured numbers (re-run on demand) in the Implemented/Verified/Measured/Unproven vocabulary
--   interpret-trace   full provenance of one request: tokens, segmentation, competing hypotheses with every named factor, repairs, constraints, evidence checks
--   interpret-memory  feed a conversation (U:/A: lines) into a memory namespace and show / save / load the memory state
--   interpret-replay  re-run a saved record's request and verify it reproduces bit-for-bit (determinism and integrity)
-- usage: lua asi.lua <command> [options]      (see `help`)
local U = require("asi.nlu.util")

local CLI = {}

local HELP = [=[
asi-nlu: LM-independent natural-language interpretation engine

  interpret [TEXT] [--file F] [--data F[:year=2020][:name=n]]... [--json] [--prompt] [--save-record F] [--calibration F] [--ns NS --user U]
  interpret-eval   [--split dev|val|test] [--file F] [--mode full|baseline|lexical_only|no_types|no_domain|no_hypotheses|no_coref|no_memory|no_repair] [--failures N]
  interpret-report [--run]
  interpret-trace  TEXT [--top N] [--data F]...
  interpret-memory [--turns FILE] [--ns NS --user U] [--save F] [--load F] [--ask TEXT]
  interpret-replay RECORD.json [--data F]...
  help
]=]

---------------------------------------------------------------- argument parsing
local function parse_args(argv)
  local opts, pos, multi = {}, {}, {}
  local i = 1
  local FLAGS = { json = true, prompt = true, run = true, help = true, verbose = true }
  while i <= #argv do
    local a = argv[i]
    if a:sub(1, 2) == "--" then
      local k = a:sub(3)
      if FLAGS[k] then opts[k] = true; i = i + 1
      else
        local v = argv[i + 1]
        if k == "data" then multi.data = multi.data or {}; table.insert(multi.data, v) else opts[k] = v end
        i = i + 2
      end
    else pos[#pos + 1] = a; i = i + 1 end
  end
  return opts, pos, multi
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot read " .. tostring(path) end
  local s = f:read("a")
  f:close()
  return s
end

local function root_dir()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  return (src:match("^(.*)/nlu/asi/nlu/cli%.lua$") or src:match("^(.*)/asi/nlu/cli%.lua$") or ".")
end

---------------------------------------------------------------- shared setup
local function build_engine(multi, opts)
  local R = require("asi.nlu.resources")
  local K = require("asi.nlu.knowledge")
  local Engine = require("asi.nlu.engine")
  local Cal = require("asi.nlu.calibration")
  local kb
  if multi.data and #multi.data > 0 then
    kb = K.new(R.core())
    for _, spec in ipairs(multi.data) do
      local path, rest = spec:match("^([^:]+)(.*)$")
      local text, err = read_file(path)
      if not text then return nil, err end
      local label, name = {}, path:match("[^/]+$")
      local dataset
      for kv in rest:gmatch(":([^:]+)") do
        local k, v = kv:match("^(%w+)=(.+)$")
        if k == "year" then label.year = tonumber(v) elseif k == "name" then dataset = v end
      end
      local rep = kb:ingest(text, { name = name, dataset = dataset or name:gsub("%..*$", ""), label = label, version = tostring(label.year or "1") })
      io.stderr:write(string.format("loaded %s: %d added, %d rejected\n", path, rep.added or 0, #(rep.rejected or {})))
    end
  end
  local cal
  local model = opts.calibration and Cal.load_file(opts.calibration) or Cal.default_model(root_dir())
  if model then cal = Cal.record_adapter(model) end
  return Engine.new({ knowledge = kb, calibration = cal }), kb
end

local function out(s) io.stdout:write(s .. "\n") end

---------------------------------------------------------------- human summary
local function fmt_ref(r)
  if not r then return "-" end
  local s = r.text or "?"
  if r.resolved_id then s = s .. " [" .. r.resolved_id .. "]" elseif r.status then s = s .. " (" .. r.status .. ")" end
  return s
end

local function summarize(o)
  local rec = o.record
  local lines = {}
  if not rec then lines[#lines + 1] = "(light observation only)"; return table.concat(lines, "\n") end
  lines[#lines + 1] = string.format("input      : %s", rec.original_input)
  local si = rec.semantic_intent or {}
  lines[#lines + 1] = string.format("status     : %s   speech act: %s   intent: %s   frame: %s", si.status or "?", si.speech_act or "?", si.intent or "?", si.frame or "?")
  local rr = rec.requested_relations or {}
  if rr.relation then
    lines[#lines + 1] = string.format("relation   : %s (from=%s, to=%s)   known role=%s  asks=%s   answer type: %s", rr.relation.id, tostring(rr.relation.from_type), tostring(rr.relation.to_type),
      rr.query and rr.query.known_role or "-", rr.query and rr.query.ask or "-", tostring(rec.requested_answer_type))
  end
  for _, e in ipairs(rec.resolved_entities or {}) do
    lines[#lines + 1] = string.format("entity     : %-28s -> %s (%s)", e.mention or "?", e.key or "?", e.type or "?")
  end
  local amb = rec.ambiguity_state
  if amb and amb.state ~= "resolved" then lines[#lines + 1] = "ambiguity  : " .. tostring(amb.state) end
  for _, kind in ipairs({ { "negative_constraints", "exclude" }, { "positive_constraints", "require" }, { "temporal_constraints", "time" }, { "source_constraints", "source" }, { "preferences", "prefer" } }) do
    for _, c in ipairs(rec[kind[1]] or {}) do lines[#lines + 1] = string.format("constraint : %-8s %s", kind[2], c.text or c.label or U.json_encode(c):sub(1, 90)) end
  end
  local c = rec.confidence or {}
  if c.interpretation_correct then
    lines[#lines + 1] = string.format("confidence : P(primary reading correct) = %.2f (calibrated; valid for %s)", c.interpretation_correct.calibrated, tostring(c.interpretation_correct.valid_for))
  elseif c.semantic_interpretation then
    lines[#lines + 1] = string.format("confidence : raw semantic score %.2f (uncalibrated, not a probability)", c.semantic_interpretation.raw or 0)
  end
  local es = rec.evidence_sufficiency
  if es and es.status ~= "not_applicable" then
    lines[#lines + 1] = string.format("evidence   : %s%s", es.status, es.answer and (" -> " .. tostring(es.answer.text)) or "")
    for _, ev in ipairs(rec.selected_evidence or {}) do lines[#lines + 1] = string.format("             [%s] %s (reliability %.2f, %s)", ev.role or "evidence", ev.record, ev.reliability or 0, ev.source and ev.source.name or "?") end
  end
  for _, u in ipairs(rec.unresolved_requirements or {}) do lines[#lines + 1] = string.format("unresolved : %s - %s", u.kind or "?", tostring(u.requirement or u.mention or "")) end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------- commands
local function cmd_interpret(opts, pos, multi)
  local eng, err = build_engine(multi, opts)
  if not eng then io.stderr:write(err .. "\n"); return 2 end
  local text = pos[1]
  if opts.file then text = read_file(opts.file) elseif not text then text = io.read("a") end
  if not text or text == "" then io.stderr:write("no input text\n"); return 2 end
  local call = { cache = false, include_prompt = opts.prompt }
  if opts.ns then
    local mem, merr = eng:memory(opts.ns, opts.user or "user")
    if not mem then io.stderr:write(tostring(merr) .. "\n"); return 2 end
    call.memory = mem
  end
  local o = eng:process(text, call)
  if opts["save-record"] and o.record then
    local f = assert(io.open(opts["save-record"], "wb"))
    f:write(U.json_encode(o.record, { pretty = true, nan_null = true }))
    f:close()
  end
  if opts.json then out(U.json_encode(o.record or { light = true }, { pretty = true, nan_null = true }))
  elseif opts.prompt then out(o.package and o.package.prompt or "(no package)")
  else out(summarize(o)) end
  return 0
end

local function cmd_eval(opts, pos, multi)
  local E = require("asi.nlu.eval")
  local R = require("asi.nlu.resources")
  local path = opts.file or (root_dir() .. "/data/eval/" .. (opts.split or "dev") .. ".cases")
  local text, err = read_file(path)
  if not text then io.stderr:write(err .. "\n"); return 2 end
  if (opts.split == "test") and not opts.file then
    io.stderr:write("NOTE: the test split is frozen; every run is a use of the held-out set and must be logged in reports/heldout_log.md\n")
  end
  local cases, errs = E.parse_cases(text, path)
  if #errs > 0 then for _, e in ipairs(errs) do io.stderr:write(e .. "\n") end; return 2 end
  local lex = R.core()
  local rep = E.run(cases, E.make_runner(opts.mode or "full", lex), lex)
  out(E.summary(rep, (opts.mode or "full") .. "/" .. (opts.split or path)))
  local f = E.failures(rep, tonumber(opts.failures) or 15)
  if f ~= "" then out("\nFAILURES:\n" .. f) end
  return (rep.any_fail == 0) and 0 or 1
end

local function cmd_trace(opts, pos, multi)
  local R = require("asi.nlu.resources")
  local Interp = require("asi.nlu.interp")
  local text = pos[1]
  if not text then io.stderr:write("usage: interpret-trace TEXT\n"); return 2 end
  local interp = Interp.new({ lexicon = R.core() })
  local r = interp:interpret(text, {})
  local an = r.analysis
  out("TEXT: " .. an.original)
  local forms = {}
  for _, u in ipairs(an.units) do forms[#forms + 1] = string.format("%s[%d-%d]%s", u.form, u.s, u.e, u.surface_form and ("<" .. u.surface_form .. ">") or "") end
  out("UNITS: " .. table.concat(forms, " "))
  local top = tonumber(opts.top) or 5
  for si, s in ipairs(r.sentences) do
    local res, interp_s = s.res, s.interp
    out(string.format("\n--- sentence %d: %s", si, interp_s.sentence and interp_s.sentence.text or "?"))
    for ci, cv in ipairs(res.covers or {}) do
      local t = {}
      for _, sp in ipairs(cv.spans) do t[#t + 1] = sp.kind .. ":" .. (sp.text or "?") end
      out(string.format("cover #%d (score %.2f): %s", ci, cv.score, table.concat(t, " | ")))
    end
    if interp_s.repairs then
      for _, rp in ipairs(interp_s.repairs) do out(string.format("repair: %s", rp.kind == "ignored" and ("ignored '" .. tostring(rp.word) .. "'") or ("'" .. tostring(rp.from) .. "' read as '" .. tostring(rp.to) .. "' (edit distance " .. tostring(rp.dist) .. ")"))) end
    end
    out(string.format("hypotheses (%d ranked, %d vetoed):", #res.ranked, #(res.rejected or {})))
    for i, h in ipairs(res.ranked) do
      if i > top then break end
      out(string.format("  #%d  p=%.3f  score=%.2f  frame=%s  %s", i, h.p or 0, h.score or 0, tostring(h.frame), tostring(h.summary or "")))
      for _, f in ipairs(h.factors or {}) do out(string.format("        %+.2f  %-28s %s", f.v or 0, f.name or "?", f.note or "")) end
    end
    for _, rj in ipairs(res.rejected or {}) do out(string.format("  VETO %s: %s", tostring(rj.frame), tostring(rj.veto))) end
    out(string.format("ambiguity: %s", res.ambiguity and res.ambiguity.state or "?"))
    for _, pt in ipairs((res.ambiguity and res.ambiguity.points) or {}) do out(string.format("   - %s %s resolved=%s", tostring(pt.kind), tostring(pt.mention or pt.id), tostring(pt.resolved))) end
    local cons = interp_s.constraints or {}
    for _, kind in ipairs({ "negative", "positive", "temporal", "geographic", "source", "preferences", "restrictions" }) do
      for _, c in ipairs(cons[kind] or {}) do out(string.format("constraint[%s]: %s", kind, U.json_encode(c))) end
    end
  end
  return 0
end

local function cmd_memory(opts, pos, multi)
  local eng, err = build_engine(multi, opts)
  if not eng then io.stderr:write(err .. "\n"); return 2 end
  local Memory = require("asi.nlu.memory")
  local mem
  if opts.load then
    local text, rerr = read_file(opts.load)
    if not text then io.stderr:write(rerr .. "\n"); return 2 end
    local m, derr = Memory.deserialize(text)
    if not m then io.stderr:write(tostring(derr) .. "\n"); return 2 end
    mem = m
    out("loaded memory (checksum verified), " .. tostring(mem.index and mem.index.n or "?") .. " items")
  else
    mem = eng:memory(opts.ns or "cli", opts.user or "user")
  end
  if opts.turns then
    local text, rerr = read_file(opts.turns)
    if not text then io.stderr:write(rerr .. "\n"); return 2 end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
      local who, body = line:match("^([UAD]):%s*(.*)$")
      if who and body ~= "" then
        local speaker = (who == "U" and "user") or (who == "A" and "assistant") or "doc"
        eng.interp:interpret(body, { memory = mem, speaker = speaker, light = (speaker ~= "user") })
      end
    end
  end
  if opts.ask then
    local o = eng:process(opts.ask, { memory = mem, speaker = "user", cache = false })
    out(summarize(o))
    local m = o.result and o.result.main
    for _, r in ipairs((m and m.context and m.context.references) or {}) do
      out(string.format("reference  : '%s' -> %s %s", r.mention, r.status, r.antecedent and (r.antecedent.text or r.antecedent.key) or ""))
    end
    for _, c in ipairs((m and m.context and m.context.active_constraints) or {}) do out(string.format("active     : %s %s=%s (%s)", c.kind or "?", tostring(c.slot or c.text), tostring(c.value), tostring(c.status))) end
    for _, it in ipairs((m and m.context and m.context.memory and m.context.memory.selected) or {}) do out(string.format("selected   : [turn %s %s] %s", tostring(it.turn), tostring(it.kind), tostring(it.text))) end
  end
  local d = mem.describe and mem:describe() or nil
  if d then out("memory     : " .. U.json_encode(d)) end
  if opts.save then
    local blob = mem:serialize()
    local f = assert(io.open(opts.save, "wb"))
    f:write(blob)
    f:close()
    out("saved memory to " .. opts.save)
  end
  return 0
end

local function cmd_replay(opts, pos, multi)
  local Record = require("asi.nlu.record")
  local path = pos[1]
  if not path then io.stderr:write("usage: interpret-replay RECORD.json\n"); return 2 end
  local text, err = read_file(path)
  if not text then io.stderr:write(err .. "\n"); return 2 end
  local saved, derr = U.json_decode(text)
  if not saved then io.stderr:write("bad record: " .. tostring(derr) .. "\n"); return 2 end
  local ok_integrity = Record.verify_integrity(saved)
  local eng, eerr = build_engine(multi, opts)
  if not eng then io.stderr:write(eerr .. "\n"); return 2 end
  local o = eng:process(saved.original_input, { cache = false })
  local again = o.record
  out(string.format("saved record integrity hash verifies : %s", tostring(ok_integrity)))
  out(string.format("re-run request id equals saved id      : %s", tostring(again.request_id == saved.request_id)))
  out(string.format("re-run integrity hash equals saved     : %s", tostring(again.integrity.sha256 == saved.integrity.sha256)))
  local same = ok_integrity and again.request_id == saved.request_id and again.integrity.sha256 == saved.integrity.sha256
  out(same and "REPLAY OK: identical record (deterministic)" or "REPLAY DIFFERS (different data, lexicon or engine version, or nondeterminism)")
  return same and 0 or 1
end

local function cmd_report(opts, pos, multi)
  local root = root_dir()
  local lines = { "asi-nlu status report", string.rep("=", 60) }
  local function sh(cmd) local p = io.popen(cmd .. " 2>&1"); local s = p:read("a"); p:close(); return s end
  if opts.run then
    local lua = arg and arg[-1] or "lua5.4"
    lines[#lines + 1] = "-- unit/acceptance tests"
    lines[#lines + 1] = sh(lua .. " " .. root .. "/tests/run_all.lua | tail -1")
    for _, sp in ipairs({ "dev", "val" }) do
      lines[#lines + 1] = "-- interpretation gold: " .. sp
      lines[#lines + 1] = sh(lua .. " " .. root .. "/tools/run_eval.lua --split " .. sp .. " --failures 0 | head -1")
    end
  end
  for _, rp in ipairs({ "reports/00_audit.md", "reports/performance.md", "reports/calibration.md", "reports/heldout_log.md", "reports/FINAL_REPORT.md" }) do
    local t = read_file(root .. "/" .. rp)
    lines[#lines + 1] = string.format("%-28s %s", rp, t and (#t .. " bytes") or "(not generated)")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Vocabulary: Implemented = code exists and runs; Verified = covered by a passing test; Measured = a benchmark number with an interval exists;"
  lines[#lines + 1] = "            Unproven = no evidence in this environment (e.g. behaviour inside the user's own bundle, which was not available here)."
  lines[#lines + 1] = "See reports/FINAL_REPORT.md for the per-item classification."
  out(table.concat(lines, "\n"))
  return 0
end

local COMMANDS = {
  interpret = cmd_interpret, ["interpret-eval"] = cmd_eval, ["interpret-report"] = cmd_report,
  ["interpret-trace"] = cmd_trace, ["interpret-memory"] = cmd_memory, ["interpret-replay"] = cmd_replay,
}

function CLI.run(argv)
  local cmd = argv[1]
  if not cmd or cmd == "help" or cmd == "--help" or cmd == "-h" then out(HELP); return 0 end
  local fn = COMMANDS[cmd]
  if not fn then io.stderr:write("unknown command '" .. tostring(cmd) .. "'\n" .. HELP); return 2 end
  local rest = {}
  for i = 2, #argv do rest[#rest + 1] = argv[i] end
  local opts, pos, multi = parse_args(rest)
  local ok, res = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, opts, pos, multi)
  if not ok then io.stderr:write(res .. "\n"); return 3 end
  return res or 0
end

CLI.COMMANDS = COMMANDS
return CLI
