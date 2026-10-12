-- asi.nlu.frames2: request-side constructions (imperatives, search with filters, comparison, definition/description,
-- statements, focus, instructions/corrections).  Extends asi.nlu.frames.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local F = require("asi.nlu.frames")

local cat = P.cat
local newh, addf, use_np = F.newh, F.addf, F.use_np
local function C(S, k) return S.chunks[k] end
local function barrier(c) return c ~= nil and c.pre ~= nil end
local function other(role) return role == "to" and "from" or "to" end
local function use(h, a, b) for i = a, b or a do h.used[i] = true end end

local WRAPPER_NOUNS = U.set({ "concept", "term", "notion", "idea", "meaning", "definition", "word", "phrase", "topic" })

-- "the concept of X" / "the meaning of X" -> X
local function unwrap(np)
  if np and np.of_arg and (np.head_kind == "typenoun" or np.head_kind == "concept" or np.head_kind == "unknown")
    and np.head and WRAPPER_NOUNS[np.head.form] then
    return np.of_arg, true
  end
  return np, false
end

local function skip_fillers(S, k)
  -- "me", "for", "about", "up", "out", "the following" style fillers after a request verb
  local used = {}
  while true do
    local c = C(S, k)
    if c and c.single and not c.masked and (c.unit.form == "me" or c.unit.form == "for" or c.unit.form == "about" or c.unit.form == "up"
      or c.unit.form == "out" or c.unit.form == "regarding" or c.unit.form == "on" and false) then
      used[#used + 1] = k; k = k + 1
    else break end
  end
  return k, used
end

---------------------------------------------------------------- filters on a target set  (shared with constraints.lua)
-- parse modifiers that follow a target NP:  [that|which|who] [adv] V NP  |  V-ing NP  |  V-ed <temporal|by NP>  |  in/based in PLACE  |  with N X
-- returns list of filters and the next chunk index.  Every filter records exactly the chunks it consumed.
function F.parse_filters(S, k, target_np, limit_idx)
  local filters = {}
  local lex = S.lex
  limit_idx = limit_idx or S.last
  local function last_unmasked(i) return i <= limit_idx and C(S, i) and not C(S, i).masked end
  local guard = 0
  while last_unmasked(k) and guard < 8 do
    guard = guard + 1
    local c = C(S, k)
    local start = k
    local progressed = false
    -- optional list joiner
    if c.single and (cat(c, "conj") and (c.unit.form == "and" or c.unit.form == "or") ) and not (c.pre and c.pre:find("sent")) then
      k = k + 1; c = C(S, k)
      if not c or c.masked then break end
    end
    -- relativiser
    local rel_marker
    if c.single and (c.unit.form == "that" or c.unit.form == "which" or c.unit.form == "who") then rel_marker = true; k = k + 1 end
    -- verb phrase (participial or relative)
    -- with a relativiser ("that currently offer ...") any finite form is fine; without one only participles can modify a noun
    local tmp = rel_marker and P.parse_vp(S, k, {}) or P.parse_vp(S, k, { participle_ok = true })
    for _, vp in ipairs(tmp) do
      for _, e in ipairs(vp.analysis.entries) do
        local rel = lex:get_rel(e.rel)
        if rel then
          local f
          local nxt = vp.nxt
          local tc = C(S, nxt)
          -- (a) passive participle + temporal expression:  "established after 2020"  -> rel.when
          if (vp.vform == "pp" or vp.vform == "past") and tc and tc.temporal and tc.temporal.kind ~= "marker" and rel.when and lex:get_rel(rel.when) and not tc.masked then
            local trel = lex:get_rel(rel.when)
            f = { kind = "temporal_relation", rel = trel.id, via = rel.id, role = "from", expr = tc.temporal, chunks = { start, vp.c2, nxt }, adv = vp.tscope }
            nxt = nxt + 1
          elseif e.prep then
            if C(S, nxt) and C(S, nxt).single and cat(C(S, nxt), "prep") and C(S, nxt).unit.form == e.prep then
              for _, np in ipairs(P.parse_np(S, nxt + 1, { no_of = false })) do
                local t_role = e.subj
                f = { kind = "relation", rel = rel.id, target_role = t_role, value = np, chunks = { start, vp.c2, nxt }, adv = vp.tscope, polarity = vp.neg and "negative" or "positive" }
                nxt = np.nxt
                break
              end
            end
          else
            for _, np in ipairs(P.parse_np(S, nxt)) do
              local pass = vp.voice == "passive" or vp.vform == "pp"
              local t_role = pass and other(e.subj) or e.subj
              if pass and not (C(S, np.c1) and false) then
                -- passive with by-agent:  "founded by X"
              end
              f = { kind = "relation", rel = rel.id, target_role = t_role, value = np, chunks = { start, vp.c2 }, adv = vp.tscope, polarity = vp.neg and "negative" or "positive" }
              nxt = np.nxt
              break
            end
            if not f and (vp.vform == "pp" or vp.voice == "passive") and C(S, nxt) and C(S, nxt).single and C(S, nxt).unit.form == "by" then
              for _, np in ipairs(P.parse_np(S, nxt + 1)) do
                f = { kind = "relation", rel = rel.id, target_role = other(e.subj), value = np, chunks = { start, vp.c2, nxt }, adv = vp.tscope }
                nxt = np.nxt
                break
              end
            end
          end
          if f then
            f.span = { first = start, last = nxt - 1 }
            filters[#filters + 1] = f
            k = nxt
            progressed = true
            break
          end
        end
      end
      if progressed then break end
    end
    if not progressed then
      -- PP filters: geography ("in Germany"), attribute quantities ("with more than 100 employees")
      local pc = C(S, start)
      if rel_marker then pc = nil end
      if pc and pc.single and cat(pc, "prep") and not pc.masked then
        local f = pc.unit.form
        if f == "in" or f == "near" or f == "around" or f == "within" or f == "across" then
          for _, np in ipairs(P.parse_np(S, start + 1, { no_of = false })) do
            if np.head_kind == "entity" then
              filters[#filters + 1] = { kind = "geo", prep = f, value = np, chunks = { start }, span = { first = start, last = np.nxt - 1 } }
              k = np.nxt; progressed = true
              break
            end
          end
        elseif f == "with" then
          local nk = start + 1
          -- quantity comparator:  "with more than 100 employees"
          local cmp_n = lex:cue_at("quantifier_cmp", S.units, C(S, nk) and C(S, nk).u1 or 0)
          for _, np in ipairs(P.parse_np(S, nk, { no_of = false })) do
            f = { kind = "has", value = np, chunks = { start }, span = { first = start, last = np.nxt - 1 } }
            filters[#filters + 1] = f
            k = np.nxt; progressed = true
            break
          end
        end
      end
    end
    if not progressed then k = start; break end
  end
  return filters, k
end

---------------------------------------------------------------- request frames
local ACT_INFORM_DEFINE = U.set({ "define" })

local function finish_target_h(S, h, np, k_after, filters)
  h.target = np
  h.filters = filters
  for _, f in ipairs(filters) do
    for i = f.span.first, f.span.last do h.used[i] = true end
  end
end

-- build hypotheses from a request object NP (shared by imperatives, polite wrappers and "I want ...")
local function from_object_np(S, out, np, verb_info, speech_act, prefix_used, fprefix)
  local act = verb_info and verb_info.act
  local lemma = verb_info and verb_info.lemma
  local function base(frame)
    if fprefix then frame = frame:gsub("^request", fprefix) end
    local h = newh(S, frame, speech_act or "request")
    use_np(h, np)
    for _, u in ipairs(prefix_used or {}) do h.used[u] = true end
    if verb_info and verb_info.chunk_idx then h.used[verb_info.chunk_idx] = true end
    h.request_verb = lemma
    F.mark_pron(h, np)
    return h
  end
  local subj, unwrapped = unwrap(np)
  if unwrapped then np = subj end
  if np.head_kind == "relnoun" then
    for _, o in ipairs(F.relnp_options(S, np)) do
      local h = base("request:relnp")
      if o.arg then
        h.rel, h.rel_obj = o.rel.id, o.rel
        h.roles[o.known_role] = o.arg
        h.known_role, h.ask = o.known_role, o.ask_role
        h.ask_type = o.rel[o.ask_role]
        h.op, h.intent, h.requires_evidence = "lookup", "factual_lookup", true
        addf(h, "relnp_arg", 0.7, "relational noun with explicit argument")
        if o.compound then addf(h, "compound_arg", -0.25, "entity+noun compound") end
        if np.temporal_scope then h.temporal_scope = np.temporal_scope end
        if np.superlative then h.ordering = { superlative = np.superlative } end
        if o.kind_mod then h.kind_mod = o.kind_mod.form; use(h, o.kind_mod.chunk.idx) end
        F.mark_pron(h, o.arg)
      else
        h.op, h.intent, h.rel, h.rel_obj, h.concept = "define", "definition", o.rel.id, o.rel, np
        addf(h, "relnoun_no_arg", -1.0, "relational noun without its argument")
      end
      out[#out + 1] = h
    end
  elseif np.head_kind == "entity" then
    local h = base("request:entity")
    h.op, h.intent, h.requires_evidence = "describe", "entity_description", true
    h.subject = np; h.roles.subject = np
    if act == "inform" and lemma == "define" then h.op, h.intent = "define", "definition"; h.concept = np end
    out[#out + 1] = h
  elseif np.head_kind == "typenoun" or np.head_kind == "concept" or np.head_kind == "unknown" then
    -- plural typenoun => search for a set;  singular typenoun after find/list => search too;  concept/unknown => define/describe
    local plural = np.plural
    if (np.head_kind == "typenoun") and (plural or act == "retrieve") then
      local h = base("request:search")
      h.op, h.intent, h.requires_evidence = "search", "search", true
      local filters, kf = F.parse_filters(S, np.nxt, np)
      finish_target_h(S, h, np, kf, filters)
      addf(h, "search_target", 0.5, "typed target set")
      if #filters > 0 then addf(h, "filters_parsed", 0.15 * #filters, #filters .. " filter(s) from relative/participial clauses") end
      out[#out + 1] = h
    end
    local h = base("request:concept")
    if act == "inform" and lemma == "explain" then h.op, h.intent = "explain", "explanation"
    elseif act == "inform" and lemma == "describe" then h.op, h.intent = "describe", "entity_description"
    else h.op, h.intent = "define", "definition" end
    h.concept = np
    h.requires_evidence = true
    if np.head_kind == "unknown" then addf(h, "unknown_term", -0.15, "term not in the lexicon") end
    out[#out + 1] = h
  elseif np.head_kind == "pronoun" then
    local h = base("request:pronoun")
    h.op, h.intent = "describe", "entity_description"
    h.subject = np
    out[#out + 1] = h
  elseif np.head_kind == "quote" or np.head_kind == "literal" then
    local h = base("request:literal")
    h.op, h.intent, h.requires_evidence = "describe", "entity_description", true
    h.subject = np
    out[#out + 1] = h
  end
end

function F.request(S, out)
  local k = S.first
  local c = C(S, k)
  if not c or c.masked then return end
  local w = S.wrapper or { kinds = {} }
  local wrapped = #w.kinds > 0
  -- 1. imperative verb at the start of the core
  local vana = (c.single or c.kind == "mwe") and P.verb_analyses(S, c) or {}
  for _, a in ipairs(vana) do
    if a.form == "base" and (a.act or #a.entries > 0) and not cat(c, "wh") then
      local act = a.act or "task"
      local nk, fill_used = skip_fillers(S, k + 1)
      local vinfo = { act = act, lemma = a.lemma, chunk_idx = k }
      if act == "inform" or act == "retrieve" or act == "task" or act == "focus" then
        -- explain why/how ...
        local wh = P.parse_wh(S, nk)
        local sub_h
        for _, wq in ipairs(wh) do
          if wq.adverbial and (wq.wh == "why" or wq.wh == "how") and a.lemma == "explain" then
            local h = newh(S, "request:explain_clause", "request", wq.wh == "why" and "causal_explanation" or "explanation", "explain")
            h.wh = wq; h.request_verb = a.lemma; h.requires_evidence = true
            use(h, k); for _, u in ipairs(fill_used) do h.used[u] = true end
            for i = wq.c1, wq.c2 do h.used[i] = true end
            local cl = F.parse_clause(S, wq.nxt)
            if cl then h.clause = cl; for i = wq.nxt, cl.last do h.used[i] = true end; addf(h, "clause_parsed", 0.4, "explanatory clause identified")
            else addf(h, "clause_missing", -0.6, "no clause to explain") end
            out[#out + 1] = h
          end
        end
        for _, np in ipairs(P.parse_np(S, nk)) do
          if act == "task" or act == "focus" then
            local h = newh(S, "request:task", "request", "task", "task")
            use(h, k); use_np(h, np); for _, u in ipairs(fill_used) do h.used[u] = true end
            h.task_verb = a.lemma; h.object = np; h.requires_context = true
            F.mark_pron(h, np)
            out[#out + 1] = h
          else
            from_object_np(S, out, np, vinfo, "request", fill_used)
          end
        end
      elseif act == "compare" then
        for _, np1 in ipairs(P.parse_np(S, nk)) do
          local items, endk = { np1 }, np1.nxt
          while true do
            local jc = C(S, endk)
            if jc and jc.single and (jc.unit.form == "and" or jc.unit.form == "with" or jc.unit.form == "to" or jc.unit.form == "versus" or jc.unit.form == "vs"
              or (jc.pre and jc.pre:find("comma") and false)) then
              local nps = P.parse_np(S, endk + 1)
              if nps[1] then items[#items + 1] = nps[1]; endk = nps[1].nxt else break end
            else break end
          end
          if #items >= 2 then
            local h = newh(S, "request:compare", "request", "comparison", "compare")
            use(h, k); for _, u in ipairs(fill_used) do h.used[u] = true end
            h.items = items
            for _, it in ipairs(items) do use_np(h, it) end
            for i = np1.nxt, endk - 1 do h.used[i] = true end
            h.requires_evidence = true
            addf(h, "comparison_items", 0.5, #items .. " items to compare")
            out[#out + 1] = h
          end
        end
      end
    end
  end
  -- 2. wrapper-led requests ("I want the capital of France", "Could you tell me about Mercury")
  if wrapped then
    local nk, fill_used = skip_fillers(S, k)
    local c0 = C(S, nk)
    local prefix = fill_used
    if c0 and c0.single and not c0.masked and (c0.unit.form == "about" or c0.unit.form == "regarding") then prefix = { nk }; nk = nk + 1 end
    for _, np in ipairs(P.parse_np(S, nk)) do
      from_object_np(S, out, np, { act = "inform", lemma = w.verb }, "request", prefix)
    end
  end
end

---------------------------------------------------------------- bare NP (fragment)  "capital of France"  "france capital?"  "Mercury"
function F.np_only(S, out)
  if S.wrapper and #S.wrapper.kinds > 0 then return end -- wrapper-led requests are handled by F.request
  for _, np in ipairs(P.parse_np(S, S.first)) do
    from_object_np(S, out, np, nil, "fragment", {}, "fragment")
  end
end

---------------------------------------------------------------- comparison questions
-- "What changed between the first version and the revised version?"
function F.wh_change(S, out)
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if not wh.adverbial then
      for _, vp in ipairs(P.parse_vp(S, wh.nxt)) do
        if vp.lemma == "change" or vp.lemma == "differ" or vp.lemma == "vary" then
          local pk = vp.nxt
          local pc = C(S, pk)
          if pc and pc.single and (pc.unit.form == "between" or pc.unit.form == "from") then
            for _, np1 in ipairs(P.parse_np(S, pk + 1)) do
              local jc = C(S, np1.nxt)
              if jc and jc.single and (jc.unit.form == "and" or jc.unit.form == "to") then
                for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do
                  local h = newh(S, "wh_change:diff", "question", "comparison", "diff")
                  use(h, wh.c1, wh.c2); F.use_np(h, np1); F.use_np(h, np2)
                  for i = vp.c1, np2.c1 - 1 do h.used[i] = true end
                  h.items = { np1, np2 }
                  h.requires_evidence = true
                  F.mark_pron(h, np1); F.mark_pron(h, np2)
                  addf(h, "diff_between_two", 0.6, "what-changed between two items")
                  out[#out + 1] = h
                end
              end
            end
          end
        end
      end
    end
  end
end

-- "Which one is older?"  "Which is larger, A or B?"  "Is A older than B?"
function F.compare_q(S, out)
  local lex = S.lex
  local function comp_adj(c)
    if not (c and c.single) then return nil end
    local f = c.unit.form
    for _, r in ipairs(lex:readings(f)) do
      if r.pos == "adj" and (r.feat == "comp" or r.feat == "sup") then return r end
    end
    return nil
  end
  local k0 = S.first
  for _, wh in ipairs(P.parse_wh(S, k0)) do
    if not wh.adverbial then
      local bk = wh.nxt
      local be = C(S, bk)
      if be and be.single and (cat(be, "aux_be") or cat(be, "clitic_s")) then
        local ac = C(S, bk + 1)
        local r = comp_adj(ac)
        if r then
          local h = newh(S, "compare_q:wh_adj", "question", "comparison", "rank_attribute")
          use(h, wh.c1, wh.c2); use(h, bk, bk + 1)
          h.wh = wh; h.dimension = r.dim; h.degree = r.feat; h.adj = r.lemma
          h.requires_evidence = true
          addf(h, "comparative_adjective", 0.5, r.lemma .. " (" .. r.feat .. ") on dimension " .. tostring(r.dim))
          -- candidates "A or B"
          local nk = bk + 2
          local items = {}
          local c3 = C(S, nk)
          if c3 and c3.pre and c3.pre:find("comma") then nk = nk end
          for _, np in ipairs(P.parse_np(S, nk)) do
            items[#items + 1] = np; use_np(h, np)
            local oc = C(S, np.nxt)
            if oc and oc.single and oc.unit.form == "or" then
              local nps = P.parse_np(S, np.nxt + 1)
              if nps[1] then items[#items + 1] = nps[1]; use(h, np.nxt); use_np(h, nps[1]) end
            end
            break
          end
          if #items > 0 then h.items = items end
          out[#out + 1] = h
        end
      end
    end
  end
  -- "Is A older than B?"
  local c0 = C(S, k0)
  if c0 and c0.single and cat(c0, "aux_be") then
    for _, np1 in ipairs(P.parse_np(S, k0 + 1)) do
      local ac = C(S, np1.nxt)
      local r = comp_adj(ac)
      local tc = C(S, np1.nxt + 1)
      if r and tc and tc.single and tc.unit.form == "than" then
        for _, np2 in ipairs(P.parse_np(S, np1.nxt + 2)) do
          local h = newh(S, "compare_q:yes_no", "question", "verification", "verify_comparison")
          use(h, k0); use_np(h, np1); use(h, np1.nxt, np1.nxt + 1); use_np(h, np2)
          h.items = { np1, np2 }; h.dimension = r.dim; h.degree = r.feat; h.adj = r.lemma
          h.requires_evidence = true
          addf(h, "comparative_adjective", 0.5, r.lemma .. " on " .. tostring(r.dim))
          out[#out + 1] = h
        end
      end
    end
  end
end

---------------------------------------------------------------- statements, focus, instructions, corrections
local function resource_slot(S, np)
  if not np or not np.head then return nil end
  local canon = S.lex:resource(np.head.form)
  if not canon and np.head.single then canon = S.lex:resource(np.head.unit.form) end
  return canon
end

function F.instruction(S, out)
  local lex = S.lex
  local k = S.first
  local c = C(S, k)
  if not c or c.masked then return end
  -- correction / persistence cues at the start: "Actually, ...", "No, wait, ...", "From now on ..."
  local corr_n = lex:cue_at("correction", S.units, c.u1)
  local persist_n = lex:cue_at("persist", S.units, c.u1)
  local skipped = {}
  local correction, persist = false, false
  local function skip_units(n)
    local consumed = 0
    while C(S, k) and consumed < n do
      consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1)
      skipped[#skipped + 1] = k; k = k + 1
    end
  end
  if corr_n then correction = true; skip_units(corr_n) end
  c = C(S, k)
  if c and lex:cue_at("persist", S.units, c.u1) then persist = true; skip_units(lex:cue_at("persist", S.units, c.u1)) end
  c = C(S, k)
  -- temporal persist marker already lexed as a temporal chunk ("From now on", "Going forward")
  while c and c.temporal and (c.temporal.kind == "persist" or c.temporal.persist) do persist = true; skipped[#skipped + 1] = k; k = k + 1; c = C(S, k) end
  if c and c.pre and (c.pre:find("comma")) then end
  c = C(S, k)
  if not c or c.masked then return end
  for _, a in ipairs(c.single and P.verb_analyses(S, c) or {}) do
    if a.form == "base" and (a.act == "constraint" or a.act == "exclude" or a.act == "include") then
      local nk = k + 1
      local fill = {}
      local nc = C(S, nk)
      -- "switch to X" / "go with X" / "stick with X"
      if nc and nc.single and (nc.unit.form == "to" or nc.unit.form == "with") then fill[#fill + 1] = nk; nk = nk + 1 end
      for _, np in ipairs(P.parse_np(S, nk)) do
        local h = newh(S, "instruction:" .. a.act, "instruction", "instruction_update", "instruct")
        for _, s in ipairs(skipped) do h.used[s] = true end
        use(h, k); for _, f in ipairs(fill) do h.used[f] = true end; use_np(h, np)
        local slot = resource_slot(S, np)
        local value
        if np.temporal_mod then value = { year = np.temporal_mod.year, label = np.temporal_mod.text, expr = np.temporal_mod }
        else
          for _, m in ipairs(np.mods) do if m.kind == "mod" or m.kind == "ordinal" then value = value or { word = m.form, label = m.text } end end
        end
        h.instruction = { verb = a.lemma, act = a.act, np = np, slot = slot, value = value, correction = correction, persist = persist }
        h.correction, h.persist = correction, persist
        if slot then addf(h, "resource_slot", 0.5, "instruction targets the '" .. slot .. "' slot") end
        if correction then addf(h, "correction_cue", 0.4, "explicit correction marker") end
        if persist then addf(h, "persist_cue", 0.3, "applies from now on") end
        F.mark_pron(h, np)
        out[#out + 1] = h
      end
    end
  end
  -- bare correction followed by a plain fragment: "Actually, the 2025 one."  handled as statement with correction flag
  if correction and #out == 0 then
    local nk = k
    for _, np in ipairs(P.parse_np(S, nk)) do
      local h = newh(S, "instruction:correction_fragment", "correction", "correction", "instruct")
      for _, s in ipairs(skipped) do h.used[s] = true end
      use_np(h, np)
      h.instruction = { verb = nil, np = np, slot = resource_slot(S, np), correction = true, persist = persist }
      h.correction = true
      F.mark_pron(h, np)
      out[#out + 1] = h
      break
    end
  end
end

-- "I'm researching Company A." / "Let's talk about X." / "We are looking at Y."
function F.focus(S, out)
  local lex = S.lex
  local c = C(S, S.first)
  if not c then return end
  local n = lex:cue_at("focus_intro", S.units, c.u1)
  if n then
    local k = S.first
    local consumed = 0
    while C(S, k) and consumed < n do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); k = k + 1 end
    for _, np in ipairs(P.parse_np(S, k)) do
      local h = newh(S, "statement:focus", "statement", "statement", "focus")
      for i = S.first, k - 1 do h.used[i] = true end
      use_np(h, np)
      h.focus = np
      F.mark_pron(h, np)
      addf(h, "focus_cue", 0.6, "explicit topic-focus statement")
      out[#out + 1] = h
    end
  end
end

-- declarative statements: NP + VP + NP  /  NP be NP  (used for memory and for extracting assertions)
function F.statement(S, out)
  local k = S.first
  for _, snp in ipairs(P.parse_np(S, k)) do
    for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
      local objs = P.parse_np(S, vp.nxt)
      local h = newh(S, "statement:svo", "statement", "statement", "assert")
      use_np(h, snp); for i = vp.c1, vp.c2 do h.used[i] = true end
      h.statement = { subj = snp, vp = vp, lemma = vp.lemma, neg = vp.neg }
      if objs[1] then use_np(h, objs[1]); h.statement.obj = objs[1] end
      for _, e in ipairs(vp.analysis.entries) do
        local rel = S.lex:get_rel(e.rel)
        if rel and objs[1] then
          h.rel, h.rel_obj = rel.id, rel
          h.roles[vp.voice == "passive" and other(e.subj) or e.subj] = snp
          h.roles[vp.voice == "passive" and e.subj or other(e.subj)] = objs[1]
          addf(h, "relation_verb", 0.4, "statement over relation verb")
          break
        end
      end
      F.mark_pron(h, snp)
      out[#out + 1] = h
    end
  end
end

return F
