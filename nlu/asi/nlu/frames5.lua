-- asi.nlu.frames5: instructions about HOW a dataset is read and HOW the assistant sounds, and questions about the engine's own reading
-- (extends asi.nlu.frames / frames2 / frames3 / frames4 on the same table; every function adds competing hypotheses).
--   voice_instruction   "Use a calmer tone."  "No caps."  "Ignore the personality."  "Treat the examples as facts."  "Play Bob instead."   a standing instruction (slot tone / persona / dataset_role)
--   voice_query         "What tone will you use?"  "How did you read the dataset?"                                                          a question about the engine itself (intent interpretation_query)
-- The wording is recognised by asi.nlu.override (word classes and clause structure); this module only turns what it found into hypotheses with named factors.
local P = require("asi.nlu.parse")
local F = require("asi.nlu.frames4")
local Override = require("asi.nlu.override")

local newh, addf = F.newh, F.addf

local SLOT = { tone = "tone", persona = "persona", dataset_role = "dataset_role" }

local function sentence_text(S)
  local s = S.sentence
  if not (s and s.s and s.e) then return nil end
  return S.an.original:sub(s.s, s.e)
end

local function parse_sentence(S)
  if S.override_parse ~= nil then return S.override_parse or nil end
  local text = sentence_text(S)
  S.override_parse = false
  if text and text ~= "" then
    local res = Override.parse(text, { names = S.ctx and S.ctx.persona_names })
    if #res.items > 0 then S.override_parse = res end
  end
  return S.override_parse or nil
end

local function use_all(S, h)
  for k = S.first, S.last do
    local c = S.chunks[k]
    if c and not c.masked then h.used[k] = true end
  end
end

function F.voice_instruction(S, out)
  local res = parse_sentence(S)
  if not res then return end
  for _, item in ipairs(res.items) do
    if SLOT[item.kind] and #item.ops > 0 then
      local c1 = S.chunks[S.first]
      if c1 then
        local h = newh(S, "instruction:" .. item.kind, "instruction", "instruction_update", "instruct")
        use_all(S, h)
        local np = { head = c1, head_kind = "concept", mods = {}, u1 = c1.u1, u2 = c1.u2, c1 = c1.idx, c2 = c1.idx, nxt = c1.idx + 1, notes = {}, score = 0 }
        h.instruction = { verb = "adjust", act = "constraint", np = np, slot = SLOT[item.kind], value = { word = table.concat(item.ops, ";"), label = item.label }, persist = true,
          ops = item.ops }
        h.persist = true
        h.voice_ops = item.ops
        addf(h, "voice_override", 1.8, "wording about the " .. item.kind:gsub("_", " ") .. ": " .. table.concat(item.evidence or {}, "; "))
        addf(h, "persist_cue", 0.3, "a standing instruction about the voice / the reading of the dataset")
        out[#out + 1] = h
      end
    end
  end
end

function F.voice_query(S, out)
  local res = parse_sentence(S)
  if not res then return end
  for _, item in ipairs(res.items) do
    if item.kind == "query_tone" or item.kind == "query_reading" then
      local h = newh(S, "voice_query", "question", "interpretation_query", "report")
      use_all(S, h)
      h.voice_query = item.kind
      h.requires_evidence = false
      addf(h, "voice_query", 1.8, "the question is about the engine's own reading of the dataset / the voice it will use ('" .. tostring(item.label) .. "')")
      out[#out + 1] = h
    end
  end
end

return F
