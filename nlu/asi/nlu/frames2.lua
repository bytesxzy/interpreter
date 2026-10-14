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
    local nx = C(S, k + 1)
    if c and c.single and not c.masked and (c.unit.form == "me" or c.unit.form == "for" or c.unit.form == "about" or c.unit.form == "up"
      or c.unit.form == "out" or c.unit.form == "regarding" or c.unit.form == "on" and false) then
      used[#used + 1] = k; k = k + 1
    -- "tell me MORE / MORE ABOUT / A BIT MORE ABOUT / EVERYTHING ABOUT X": the quantity word asks for more of the same
    elseif c and c.single and not c.masked and (c.unit.form == "more" or c.unit.form == "everything" or c.unit.form == "anything" or c.unit.form == "all") and nx and nx.single and nx.unit.form == "about" and not barrier(nx) then
      used[#used + 1] = k; used[#used + 1] = k + 1; k = k + 2
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
    -- locative relative clause:  "the country where Mount Fuji is"  ->  located_in(from=Mount Fuji, to=<target>)
    if c.single and c.unit.form == "where" and lex:get_rel("located_in") then
      local done
      for _, np in ipairs(P.parse_np(S, k + 1)) do
        local bc = C(S, np.nxt)
        if bc and bc.single and not bc.masked and (cat(bc, "aux_be") or cat(bc, "clitic_s")) then
          -- "where O is headquartered" (stative verb with a preposition): the place plays the OTHER role of that relation
          for _, vp in ipairs(P.parse_vp(S, np.nxt, { aux_hint = nil })) do
            if vp.voice == "passive" then
              for _, e in ipairs(vp.analysis.entries) do
                local r = lex:get_rel(e.rel)
                if r and e.prep and not r.open then
                  filters[#filters + 1] = { kind = "relation", rel = r.id, target_role = other(e.subj), value = np, chunks = { k, vp.c2 },
                    span = { first = k, last = vp.c2 }, locative_clause = true }
                  k = vp.nxt
                  done = true
                  break
                end
              end
            end
            if done then break end
          end
          if done then break end
          filters[#filters + 1] = { kind = "relation", rel = "located_in", target_role = "to", value = np, chunks = { k, np.nxt },
            span = { first = k, last = np.nxt }, locative_clause = true }
          k = np.nxt + 1
          done = true
          break
        end
        -- "where O has its head office": a support verb + a possessed location-valued noun
        for _, vp in ipairs(P.parse_vp(S, np.nxt, {})) do
          for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
            local dc = C(S, onp.c1)
            if onp.head_kind == "relnoun" and not onp.of_arg and dc and dc.single and (cat(dc, "poss_det") or cat(dc, "det")) and onp.c1 < onp.nxt - 1 then
              for _, o in ipairs(F.relnp_options(S, onp)) do
                local supported = (vp.lemma == "have" and o.rel.support_have) or false
                for _, e in ipairs(vp.analysis.entries or {}) do if e.support and e.rel == o.rel.id then supported = true end end
                if supported and o.rel.locus and o.ask_role == "to" then
                  filters[#filters + 1] = { kind = "relation", rel = o.rel.id, target_role = "to", value = np, chunks = { k, onp.nxt - 1 },
                    span = { first = k, last = onp.nxt - 1 }, locative_clause = true }
                  k = onp.nxt
                  done = true
                  break
                end
              end
            end
            if done then break end
          end
          if done then break end
        end
        if done then break end
      end
      if done then goto continue_filters end
    end
    -- relativiser
    local rel_marker
    if c.single and (c.unit.form == "that" or c.unit.form == "which" or c.unit.form == "who") then rel_marker = true; k = k + 1 end
    -- copular relative clause: "the city that IS / FUNCTIONS AS the capital of K"
    if rel_marker and C(S, k) and C(S, k).single and cat(C(S, k), "aux_be") and not C(S, k).masked then
      local done
      for _, np in ipairs(P.parse_np(S, k + 1)) do
        if np.head_kind == "relnoun" then
          for _, o in ipairs(F.relnp_options(S, np)) do
            if o.arg and o.rel and not o.rel.open then
              filters[#filters + 1] = { kind = "relation", rel = o.rel.id, target_role = o.ask_role, value = o.arg, chunks = { start, np.c2 },
                span = { first = start, last = np.nxt - 1 }, copular_relative = true }
              k = np.nxt
              done = true
              break
            end
          end
        end
        if done then break end
      end
      if done then goto continue_filters end
    end
    -- object relative clause, with or without a relativiser:  "the companies (that) Google acquired",  "the startups Sequoia Capital has invested in"
    -- the subject is a proper name; the verb is followed only by (a stranded preposition and) the end of the clause, so the target set fills the gap
    if not (rel_marker and C(S, k) and C(S, k).single and cat(C(S, k), "aux_be")) then
      local done
      for _, snp in ipairs(P.parse_np(S, k, { no_of = true })) do
        if snp.head_kind == "entity" or (snp.head_kind == "unknown" and snp.head and snp.head.cap) then
          for _, vp in ipairs(P.parse_vp(S, snp.nxt, {})) do
            if vp.voice == "active" then
              for _, e in ipairs(vp.analysis.entries) do
                local rel = lex:get_rel(e.rel)
                if rel and not e.support and not e.as_only and not rel.open then
                  local nxt, ok = vp.nxt, true
                  if e.prep then
                    local pc2 = C(S, nxt)
                    if pc2 and pc2.single and not pc2.masked and pc2.unit.form == e.prep then nxt = nxt + 1 else ok = false end
                  end
                  local fc = C(S, nxt)
                  local gap_end = (nxt > limit_idx) or (fc ~= nil and (fc.pre ~= nil or fc.temporal ~= nil or (fc.single and (cat(fc, "conj") or cat(fc, "prep")))))
                  if ok and gap_end then
                    filters[#filters + 1] = { kind = "relation", rel = rel.id, target_role = other(e.subj), value = snp, chunks = { start, nxt - 1 },
                      span = { first = start, last = nxt - 1 }, adv = vp.tscope, polarity = vp.neg and "negative" or "positive", object_relative = true }
                    k = nxt; done = true; progressed = true
                    break
                  end
                end
              end
            end
            if done then break end
          end
        end
        if done then break end
      end
      if done then goto continue_filters end
    end
    -- verb phrase (participial or relative)
    -- with a relativiser ("that currently offer ...") any finite form is fine; without one only participles can modify a noun
    local tmp = rel_marker and P.parse_vp(S, k, {}) or P.parse_vp(S, k, { participle_ok = true })
    for _, vp in ipairs(tmp) do
      for _, e in ipairs(vp.analysis.entries) do
        local rel = lex:get_rel(e.rel)
        if rel and not e.as_only then
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
        if f == "in" or f == "near" or f == "around" or f == "within" or f == "across" or f == "on" or f == "at" or f == "throughout" or f == "outside" or f == "inside" then
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
    ::continue_filters::
  end
  return filters, k
end

---------------------------------------------------------------- multi-hop chains
-- A known argument that is itself a relational NP ("the founder of Example Labs") or a type noun modified by a relative clause
-- ("the country where Mount Fuji is", "the company that acquired Beta Systems") is expanded into ordered lookup steps with
-- typed intermediate variables:  steps[1] runs first; the hypothesis' own relation consumes the last variable.
local function lex_rel(S, id) return S.lex:get_rel(id) end

local function relativizer(c)
  return c and c.single and not c.masked and (c.unit.form == "that" or c.unit.form == "which" or c.unit.form == "who" or c.unit.form == "where")
end

function F.expand_chain(S, h)
  if h.chain_done or not h.known_role or not h.rel then return end
  h.chain_done = true
  local top_np = h.roles[h.known_role]
  if not top_np or top_np.head_kind == "pronoun" then return end
  local steps = {}
  local used_extra = {}
  local last_chunk = top_np.c2

  local function build(np, depth)
    if depth > 3 or not np then return nil end
    if np.head_kind == "relnoun" then
      for _, o in ipairs(F.relnp_options(S, np)) do
        if o.arg then
          local inner = build(o.arg, depth + 1)
          steps[#steps + 1] = { rel = o.rel.id, rel_obj = o.rel, known_role = o.known_role, known = inner and inner.var_np or o.arg, ask_role = o.ask_role,
            result_type = o.rel[o.ask_role], source_np = np }
          return { var_np = { head_kind = "var", var = "?" .. #steps, type = o.rel[o.ask_role], step = #steps, u1 = np.u1, u2 = np.u2, c1 = np.c1, c2 = np.c2,
            mods = {}, score = 0, notes = {} } }
        end
      end
    elseif (np.head_kind == "typenoun" or np.head_kind == "unknown") and relativizer(C(S, np.nxt)) then
      local filters, k = F.parse_filters(S, np.nxt, np)
      local made
      for _, f in ipairs(filters) do
        if f.kind == "relation" then
          local rel = lex_rel(S, f.rel)
          if rel then
            local ntype = np.senses and np.senses[1] and np.senses[1].type
            steps[#steps + 1] = { rel = rel.id, rel_obj = rel, known_role = other(f.target_role), known = f.value, ask_role = f.target_role,
              result_type = ntype or rel[f.target_role], source_np = np, via_clause = true }
            for i = f.span.first, f.span.last do used_extra[i] = true end
            last_chunk = math.max(last_chunk, f.span.last)
            made = #steps
          end
        end
      end
      if made then
        local ntype = np.senses and np.senses[1] and np.senses[1].type
        return { var_np = { head_kind = "var", var = "?" .. made, type = ntype or steps[made].result_type, step = made, u1 = np.u1, u2 = np.u2, c1 = np.c1,
          c2 = np.c2, mods = {}, score = 0, notes = {} } }
      end
    end
    return nil
  end

  local res = build(top_np, 0)
  if res and #steps > 0 then
    local var = res.var_np
    var.u1, var.c1 = top_np.u1, top_np.c1
    var.c2 = math.max(last_chunk, top_np.c2)
    var.u2 = S.chunks[var.c2].u2
    var.steps = steps
    h.chain = steps
    h.roles[h.known_role] = var
    for i = top_np.c1, var.c2 do h.used[i] = true end
    for i in pairs(used_extra) do h.used[i] = true end
    h.factors[#h.factors + 1] = { name = "multi_hop", v = 0.3, note = #steps .. "-step chain before " .. h.rel }
    -- "the location of X's headquarters": a location-valued noun is answered by its own value; a second 'located_in' hop is redundant unless the
    -- question asks for a narrower kind of place ("in which COUNTRY is ...")
    local top = steps[#steps]
    local wt = h.wh and h.wh.type
    if h.rel == "located_in" and top and top.rel_obj.locus and top.ask_role == "to" and (not wt or wt == "place" or wt == "location" or S.lex:compat(top.rel_obj.to, wt) >= 0.9) then
      h.factors[#h.factors + 1] = { name = "redundant_location_hop", v = -0.9, note = "the noun's own relation already gives a location; a second located_in hop is redundant" }
    end
  end
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
        F.option_factors(h, o)
        if np.temporal_scope then h.temporal_scope = np.temporal_scope end
        if np.superlative then h.ordering = { superlative = np.superlative } end
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
    -- "Name the person who set up O." / "Give me the city where O keeps its head office.": a definite SINGULAR description with one relative clause asks
    -- for the one referent -- a lookup of the clause's relation, not a search for a set
    if np.head_kind == "typenoun" and not np.plural and np.det == "the" and (act == "retrieve" or act == "inform") then
      local filters, kf = F.parse_filters(S, np.nxt, np)
      local f = filters[1]
      if #filters == 1 and f.kind == "relation" and f.value and kf > S.last then
        local drel = S.lex:get_rel(f.rel)
        if drel and not drel.open then
          local h = base("request:description")
          h.rel, h.rel_obj = drel.id, drel
          h.roles[other(f.target_role)] = f.value
          h.known_role, h.ask = other(f.target_role), f.target_role
          h.ask_type = drel[f.target_role]
          h.op, h.intent, h.requires_evidence = "lookup", "factual_lookup", true
          h.wh_type = np.senses and np.senses[1] and np.senses[1].type or nil
          for i = f.span.first, f.span.last do h.used[i] = true end
          addf(h, "description_lookup", 0.9, "definite singular description with one relative clause names a single referent")
          F.mark_pron(h, f.value)
          out[#out + 1] = h
        end
      end
    end
    -- "give me a SUMMARY of the figures", "send me an overview of the results": a task noun requested through a retrieval verb is a task
    local hf = np.head and np.head.single and np.head.unit and np.head.unit.form
    if hf and (S.lex:cats(hf) or {}).tasknoun and (act == "retrieve" or act == "inform" or act == "task") then
      local h = base("request:task_nominal")
      h.op, h.intent = "task", "task"
      h.task_verb, h.object, h.requires_context = hf, np.of_arg or np, true
      addf(h, "task_noun", 0.9, "'" .. hf .. "' names a task (summary, analysis, overview ...) requested through the verb '" .. tostring(lemma) .. "'")
      out[#out + 1] = h
    end
    -- plural typenoun => search for a set;  singular typenoun after find/list => search too;  concept/unknown => define/describe
    local plural = np.plural
    -- "Find/Show/List <noun>" requests items of that kind, also when the noun is not in the lexicon
    -- a bare plural noun phrase with a locative / relative filter and no verb ("Cinemas in Karsholm, please.") is a search as well
    local bare_filtered = false
    if not act and np.head_kind == "unknown" and plural then
      local fl, kf0 = F.parse_filters(S, np.nxt, np)
      local only_fillers = true
      for i = kf0, S.last do local ci = C(S, i); if not (ci and ci.single and (cat(ci, "polite") or cat(ci, "discourse") or cat(ci, "ignorable"))) then only_fillers = false end end
      bare_filtered = #fl > 0 and only_fillers
    end
    if ((np.head_kind == "typenoun") and (plural or act == "retrieve")) or (np.head_kind == "unknown" and act == "retrieve") or bare_filtered then
      local h = base("request:search")
      if np.head_kind == "unknown" then addf(h, "unknown_target_type", -0.1, "search target type is not in the lexicon") end
      -- a target that swallows a named entity plus a lowercase word ("the companies Google acquired") has swallowed a clause, not named a set
      if np.head_kind == "unknown" and np.head and np.head.single and not np.head.cap then
        for _, md in ipairs(np.mods or {}) do
          if md.kind == "entity_mod" then addf(h, "target_swallows_clause", -0.8, "the target phrase contains a named entity followed by a lowercase word: a clause, not a noun phrase"); break end
        end
      end
      h.op, h.intent, h.requires_evidence = "search", "search", true
      local filters, kf = F.parse_filters(S, np.nxt, np)
      finish_target_h(S, h, np, kf, filters)
      addf(h, "search_target", 0.5, "typed target set")
      if #filters > 0 then addf(h, "filters_parsed", 0.15 * #filters, #filters .. " filter(s) from relative/participial clauses") end
      out[#out + 1] = h
    end
    local h = base("request:concept")
    if act == "retrieve" and (np.head_kind == "unknown" or (np.head_kind == "typenoun" and plural)) then addf(h, "retrieval_verb_not_definition", -0.6, "a retrieval verb asks for items, not a definition") end
    if act == "inform" and lemma == "explain" then h.op, h.intent = "explain", "explanation"
    elseif act == "inform" and lemma == "describe" then h.op, h.intent = "describe", "entity_description"
    else h.op, h.intent = "define", "definition" end
    h.concept = np
    h.requires_evidence = true
    if np.head_kind == "unknown" then addf(h, "unknown_term", -0.15, "term not in the lexicon") end
    if np.of_arg then addf(h, "concept_of_arg", -0.4, "a non-relational concept noun with an 'of' argument is a weaker structure than a relational noun") end
    out[#out + 1] = h
  elseif np.head_kind == "pronoun" or np.head_kind == "ordinal_ref" then
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

F.from_object_np = from_object_np
F.resource_slot = resource_slot

---------------------------------------------------------------- bare NP (fragment)  "capital of France"  "france capital?"  "Mercury"
function F.np_only(S, out)
  if S.wrapper and #S.wrapper.kinds > 0 then return end -- wrapper-led requests are handled by F.request
  for _, np in ipairs(P.parse_np(S, S.first)) do
    from_object_np(S, out, np, nil, "fragment", {}, "fragment")
    -- "Chile - capital" / "Egypt, capital?" : the argument comes first, the relational noun after a separator
    if np.head_kind == "entity" and not np.of_arg and not np.possessor then
      local nx = C(S, np.nxt)
      if nx and nx.pre and (nx.pre:find("comma") or nx.pre:find("dash") or nx.pre:find("colon")) and not nx.masked then
        for _, rn in ipairs(P.parse_np(S, np.nxt)) do
          if rn.head_kind == "relnoun" and not rn.of_arg and not rn.possessor then
            local cp = U.shallow(rn)
            cp.of_arg, cp.comma_arg = np, true
            cp.c1, cp.u1 = np.c1, np.u1
            from_object_np(S, out, cp, nil, "fragment", {}, "fragment")
            break
          end
        end
      end
    end
    -- "capital, France": a relational noun whose argument follows across a comma
    if np.head_kind == "relnoun" and not np.of_arg and not np.possessor then
      local nx = C(S, np.nxt)
      if nx and nx.pre and nx.pre:find("comma") and not nx.masked then
        for _, arg in ipairs(P.parse_np(S, np.nxt)) do
          if arg.head_kind == "entity" then
            local cp = U.shallow(np)
            cp.of_arg, cp.comma_arg, cp.nxt, cp.u2, cp.c2 = arg, true, arg.nxt, arg.u2, arg.c2
            from_object_np(S, out, cp, nil, "fragment", {}, "fragment")
            break
          end
        end
      end
    end
  end
end

-- a sentence that is nothing but an exclusion / preference / restriction clause ("Exclude universities.", "Don't include reposts.")
function F.segment_only(S, out)
  local segs = S.segs or {}
  if #segs == 0 then return end
  for k = S.first, S.last do
    local c = C(S, k)
    if not c.masked and not P.is_function_chunk(S, c) then return end
  end
  local sg = segs[1]
  local h = newh(S, "segment_only:" .. sg.kind, "instruction", "instruction_update", "instruct")
  h.instruction = { verb = sg.cue, act = (sg.kind == "exclusion") and "exclude" or "constraint", kind = sg.kind }
  h.polarity = (sg.kind == "exclusion") and "negative" or "positive"
  addf(h, "segment_only", 0.9, "the whole sentence is a " .. sg.kind .. " clause")
  out[#out + 1] = h
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

---------------------------------------------------------------- "What does X mean?" / "What does X stand for?"
function F.what_means(S, out)
  local lex = S.lex
  for _, wh in ipairs(P.parse_wh(S, S.first)) do
    if wh.wh == "what" and not wh.np and not wh.adverbial then
      local ac = C(S, wh.nxt)
      local aux_ok = ac and ac.single and cat(ac, "aux_do") and not ac.masked
      if aux_ok or S.embedded then
        for _, np in ipairs(P.parse_np(S, aux_ok and wh.nxt + 1 or wh.nxt)) do
          local vc = C(S, np.nxt)
          local n = vc and lex:cue_at("definition_verb", S.units, vc.u1)
          if n then
            local h = newh(S, "what_means:definition", "question", "definition", "define")
            use(h, wh.c1, wh.c2); if aux_ok then use(h, wh.nxt) end; use_np(h, np)
            local consumed, k = 0, np.nxt
            while C(S, k) and consumed < n do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); h.used[k] = true; k = k + 1 end
            h.concept = np
            h.requires_evidence = true
            addf(h, "definition_question", 0.9, "'what does X mean' asks for the meaning of X")
            F.mark_pron(h, np)
            out[#out + 1] = h
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- recall questions about the conversation itself
-- "What did we decide about the inventory service?"  "Why did we pick that for billing?"  "Remind me what I said about X."
local RECALL_PREP = U.set({ "about", "on", "regarding", "for", "with", "to", "over", "around", "concerning" })
function F.recall(S, out)
  local lex = S.lex
  local c0 = C(S, S.first)
  if not c0 then return end
  local k = S.first
  local intro = lex:cue_at("recall_intro", S.units, c0.u1)
  local intro_used = {}
  if intro then
    local consumed = 0
    while C(S, k) and consumed < intro do consumed = consumed + (C(S, k).u2 - C(S, k).u1 + 1); intro_used[#intro_used + 1] = k; k = k + 1 end
  end
  for _, wh in ipairs(P.parse_wh(S, k)) do
    local nk = wh.nxt
    local aux = C(S, nk)
    local has_aux = aux and aux.single and (cat(aux, "aux_do") or cat(aux, "aux_have")) and not aux.masked
    if has_aux then nk = nk + 1 end
    local sc = C(S, nk)
    local pf = sc and sc.single and sc.unit.form
    if pf == "we" or pf == "i" or pf == "you" then
      for _, vp in ipairs(P.parse_vp(S, nk + 1, { aux_hint = has_aux and "do" or nil })) do
        local v = lex.verbs[vp.lemma]
        -- the construction itself (wh + do-support + first/second person subject) marks a question about the conversation; the verb only has to
        -- be one that people use about what was said, chosen, proposed or planned
        if v and (v.act == "discourse" or v.act == "inform" or v.act == "focus" or v.act == "constraint" or v.act == "task") then
          local topic, object
          local ek = vp.nxt
          local ec = C(S, ek)
          if ec and ec.single and RECALL_PREP[ec.unit.form] and not ec.masked then
            for _, np in ipairs(P.parse_np(S, ek + 1)) do topic = np break end
            if topic then ek = topic.nxt end
          else
            for _, np in ipairs(P.parse_np(S, ek)) do object = np break end
            if object then
              ek = object.nxt
              local pc = C(S, ek)
              if pc and pc.single and RECALL_PREP[pc.unit.form] and not pc.masked then
                for _, np in ipairs(P.parse_np(S, ek + 1)) do topic = np break end
                if topic then ek = topic.nxt end
              end
            end
          end
          local h = newh(S, "recall:wh", "question", "conversation_recall", "recall")
          for _, u in ipairs(intro_used) do h.used[u] = true end
          use(h, wh.c1, wh.c2)
          if has_aux then use(h, wh.nxt) end
          use(h, nk); for i = vp.c1, vp.c2 do h.used[i] = true end
          if wh.np then F.use_np(h, wh.np) end
          if topic then use_np(h, topic) end
          if object then use_np(h, object) end
          h.recall = { verb = vp.lemma, wh = wh.wh, participant = pf, topic = topic or object, object = object }
          h.subject = topic or object
          h.requires_context = true
          if h.subject then F.mark_pron(h, h.subject) end
          addf(h, "recall_construction", 0.9, "wh-question about what the participants said or decided ('" .. pf .. " " .. vp.lemma .. "')")
          out[#out + 1] = h
        end
      end
    end
  end
end

---------------------------------------------------------------- basis clause
-- "..., considering the correction I made earlier"  /  "... given the revised budget"  /  "... taking X into account"
-- The NP is an input the request must respect; it is kept as a (possibly context-dependent) argument, never dropped.
function F.attach_basis(S, h)
  if h.basis ~= nil or not h.speech_act or h.speech_act == "statement" then return end
  local lex = S.lex
  for k = S.first, S.last do
    local c = C(S, k)
    if c and not c.masked and not h.used[k] and c.single and lex:cue_at("basis", S.units, c.u1) == 1 then
      local form = c.unit.form
      local nxt = C(S, k + 1)
      if not (form == "given" and nxt and nxt.single and nxt.unit.form == "that") then
        for _, np in ipairs(P.parse_np(S, k + 1)) do
          local c1, c2 = C(S, np.nxt), C(S, np.nxt + 1)
          local closed = c1 and c2 and c1.single and c2.single and c1.unit.form == "into" and c2.unit.form == "account"
          if form ~= "taking" or closed then
            h.basis = { cue = form, np = np }
            h.used[k] = true; use_np(h, np)
            if closed then h.used[np.nxt] = true; h.used[np.nxt + 1] = true end
            addf(h, "basis_clause", 0.3, "'" .. form .. "' introduces a basis the request must take into account")
            F.mark_pron(h, np)
            return
          end
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

-- "version 3.2", "the file sales_q3_final.csv", "figure 12": a number / identifier / file name inside a resource phrase is its value
function F.literal_value(S, np)
  if not np then return nil end
  for ci = np.c1, np.c2 do
    local c = C(S, ci)
    if c and c.single and not c.masked and c ~= np.head then
      local u = c.unit
      if c.literal or u.kind == "ident" or (u.kind == "number" and u.numval ~= nil and not c.temporal and not u.ordinal) then return { word = c.text, label = c.text } end
    end
  end
  local hc = np.head
  if hc and hc.single then
    local u = hc.unit
    if hc.literal or u.kind == "ident" then return { word = hc.text, label = hc.text } end
    if u.kind == "number" and u.numval ~= nil and not hc.temporal and not u.ordinal then return { word = hc.text, label = hc.text } end
  end
  return nil
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
  if corr_n then
    correction = true; skip_units(corr_n)
    -- several markers may open one sentence: "Wait, no, I meant ...", "Correction: I meant ...", "Sorry, quick fix: ..."
    for _ = 1, 3 do
      local cn = C(S, k)
      local n2 = cn and not cn.masked and lex:cue_at("correction", S.units, cn.u1)
      if n2 then skip_units(n2)
      elseif cn and cn.single and not cn.masked and (cn.unit.form == "no" or cn.unit.form == "yes" or cn.unit.form == "okay" or cn.unit.form == "ok" or cn.unit.form == "well" or cn.unit.form == "so") then skipped[#skipped + 1] = k; k = k + 1
      else break end
    end
  end
  c = C(S, k)
  if c and lex:cue_at("persist", S.units, c.u1) then persist = true; skip_units(lex:cue_at("persist", S.units, c.u1)) end
  -- a correction / retraction clause anywhere before the instruction ("I got that wrong before, so please switch ...", "Disregard what I said, and go with ...")
  local preamble_to
  if not correction then
    for kk = S.first, S.last do
      local ck = C(S, kk)
      if ck and not ck.masked and (lex:cue_at("correction", S.units, ck.u1) or lex:cue_at("revoke", S.units, ck.u1)) then correction = true; preamble_to = kk break end
    end
  end
  c = C(S, k)
  -- temporal persist marker already lexed as a temporal chunk ("From now on", "Going forward")
  while c and c.temporal and (c.temporal.kind == "persist" or c.temporal.persist) do persist = true; skipped[#skipped + 1] = k; k = k + 1; c = C(S, k) end
  c = C(S, k)
  if not c or c.masked then return end
  -- a persistence marker anywhere in the sentence ("Use the 2025 dataset from now on.") makes the instruction standing
  for _, ch in ipairs(S.chunks) do
    if ch.temporal and (ch.temporal.kind == "persist" or ch.temporal.persist) then persist = true end
  end
  local REPLACE_VERBS = U.set({ "replace", "swap", "substitute", "change", "exchange" })
  local PARTICLE_EXCLUDERS = U.set({ "keep", "leave", "take", "filter", "screen", "weed", "cut", "strike", "rule", "block", "hide", "push", "sort" })
  -- one clause: [please|just|then|also]* VERB [to|with|over to] NP        (also "replace THAT with NP")
  local function try_clause(k0, prefix_used, allow_ing)
    local kk = k0
    local pre = {}
    while C(S, kk) and C(S, kk).single and not C(S, kk).masked and (cat(C(S, kk), "polite") or cat(C(S, kk), "adv") or (cat(C(S, kk), "conj") and kk > k0 - 1 and C(S, kk).unit.form ~= "if")) do
      pre[#pre + 1] = kk; kk = kk + 1
    end
    local cv = C(S, kk)
    if not (cv and cv.single and not cv.masked) then return end
    local analyses = P.verb_analyses(S, cv)
    -- "Actually, MAKE THAT the 2020 figures": a replacement phrased with "make that / it / this"
    local make_pron
    if cv.unit.form == "make" or cv.unit.form == "turn" then
      local pr = C(S, kk + 1)
      if pr and pr.single and not pr.masked and not barrier(pr) and (pr.unit.form == "that" or pr.unit.form == "it" or pr.unit.form == "this") then
        analyses = { { lemma = "make", form = "base", act = "constraint", entries = {} } }
        make_pron = kk + 1
      end
    end
    -- "Going forward, ONLY COUNT the audited figures": with "only", a retrieval verb restricts what is used
    local only_pre = false
    for _, pk in ipairs(pre) do if C(S, pk).unit.form == "only" then only_pre = true end end
    for _, a in ipairs(analyses) do
      local act_ok = a.act == "constraint" or a.act == "exclude" or a.act == "include" or (only_pre and (a.act == "retrieve" or a.act == "inform"))
      if (a.form == "base" or (allow_ing and a.form == "ing")) and act_ok then
        local nk = kk + 1
        local fill = {}
        if make_pron then fill[#fill + 1] = make_pron; nk = make_pron + 1 end
        local nc = C(S, nk)
        -- "switch to X" / "go with X" / "stick with X" / "switch over to X"
        if nc and nc.single and (nc.unit.form == "over") and C(S, nk + 1) and C(S, nk + 1).unit.form == "to" then fill[#fill + 1] = nk; nk = nk + 1; nc = C(S, nk) end
        if nc and nc.single and (nc.unit.form == "to" or nc.unit.form == "with" or nc.unit.form == "on" or nc.unit.form == "from") then fill[#fill + 1] = nk; nk = nk + 1 end
        local tries = {}
        if REPLACE_VERBS[a.lemma] then
          -- "replace THAT with the 2021 dataset": the replacement is the second noun phrase
          for _, np1 in ipairs(P.parse_np(S, nk)) do
            local wc = C(S, np1.nxt)
            if wc and wc.single and (wc.unit.form == "with" or wc.unit.form == "by") then
              for _, np2 in ipairs(P.parse_np(S, np1.nxt + 1)) do tries[#tries + 1] = { np = np2, extra = { np1 = np1, joiner = np1.nxt } } end
            end
          end
        end
        if #tries == 0 then for _, np in ipairs(P.parse_np(S, nk)) do tries[#tries + 1] = { np = np } end end
        for _, tr in ipairs(tries) do
          local np = tr.np
          if np.head_kind == "pronoun" then
            -- "I meant the 2024 dataset, so please switch to THAT": the pronoun stands for the resource named earlier in the same sentence
            for k2 = S.first, kk - 1 do
              local found
              for _, np2 in ipairs(P.parse_np(S, k2)) do
                if resource_slot(S, np2) and np2.nxt <= kk then found = np2 break end
              end
              if found then tr.antecedent_np = found; break end
            end
          end
          local act_eff = a.act
          if only_pre and (a.act == "retrieve" or a.act == "inform") then
            act_eff = "constraint"
            if not resource_slot(S, tr.antecedent_np or np) then goto next_try end   -- "Only list companies ..." is a request, not a restriction of a resource
          end
          local ptc = C(S, np.nxt)
          -- "swap the earlier dataset OUT": the object is what is being removed, not the new value
          if REPLACE_VERBS[a.lemma] and ptc and ptc.single and not ptc.masked and (ptc.unit.form == "out" or ptc.unit.form == "off") then goto next_try end
          -- "KEEP hospitals OUT of ...", "LEAVE X OUT", "FILTER X OUT": a particle after the object turns the verb into an exclusion
          if PARTICLE_EXCLUDERS[a.lemma] and ptc and ptc.single and not ptc.masked and (ptc.unit.form == "out" or ptc.unit.form == "off" or ptc.unit.form == "away") then
            act_eff = "exclude"
            tr.particle = np.nxt
          end
          local h = newh(S, "instruction:" .. act_eff, "instruction", "instruction_update", "instruct")
          if tr.particle then h.used[tr.particle] = true end
          for _, s_ in ipairs(skipped) do h.used[s_] = true end
          for _, s_ in ipairs(prefix_used or {}) do h.used[s_] = true end
          -- a retraction / correction clause that precedes the instruction is explained by the correction marker itself
          if preamble_to and kk > preamble_to then for i2 = S.first, kk - 1 do if i2 ~= kk then h.used[i2] = true end end end
          for _, s_ in ipairs(pre) do h.used[s_] = true end
          use(h, kk); for _, f in ipairs(fill) do h.used[f] = true end; use_np(h, np)
          if tr.extra then use_np(h, tr.extra.np1); h.used[tr.extra.joiner] = true end
          local vnp = tr.antecedent_np or np
          if tr.antecedent_np then use_np(h, vnp) end
          local slot = resource_slot(S, vnp)
          local value
          if vnp.temporal_mod then value = { year = vnp.temporal_mod.year, label = vnp.temporal_mod.text, expr = vnp.temporal_mod }
          else
            for _, m in ipairs(vnp.mods) do if m.kind == "mod" or m.kind == "ordinal" then value = value or { word = m.form, label = m.text } end end
          end
          value = value or F.literal_value(S, vnp)
          h.instruction = { verb = a.lemma, act = act_eff, np = vnp, slot = slot, value = value, correction = correction, persist = persist }
          if act_eff == "exclude" then h.polarity = "negative" end
          h.correction, h.persist = correction, persist
          if slot then addf(h, "resource_slot", 0.5, "instruction targets the '" .. slot .. "' slot") end
          if correction then addf(h, "correction_cue", 0.4, "explicit correction marker") end
          if persist then addf(h, "persist_cue", 0.3, "applies from now on") end
          F.mark_pron(h, np)
          out[#out + 1] = h
          ::next_try::
        end
      end
    end
  end
  try_clause(k, nil, S.wrapper and S.wrapper.progressive)
  -- later clauses: "..., and go with the 2022 dataset", "..., so please switch over to the 2021 dataset", "Sorry: use the 2020 dataset"
  for kk = k + 1, S.last do
    local ck = C(S, kk)
    if ck and not ck.masked then
      local pc = C(S, kk - 1)
      local after_conj = pc and pc.single and cat(pc, "conj") and not pc.masked
      if (ck.pre and (ck.pre:find("comma") or ck.pre:find("colon") or ck.pre:find("semi"))) or after_conj then
        if not (correction and false) then try_clause(kk, nil, false) end
      end
    end
  end
  -- "The 2023 dataset is the one I actually want you to use from now on." / "... is the one to use": a resource named as THE ONE to use
  if #out == 0 then
    for _, np in ipairs(P.parse_np(S, k)) do
      local slot = resource_slot(S, np)
      local cb = C(S, np.nxt)
      if slot and cb and cb.single and cat(cb, "aux_be") and not cb.masked then
        local one_k
        for j = np.nxt + 1, math.min(S.last, np.nxt + 4) do
          local cj = C(S, j)
          if cj and cj.single and (cj.unit.form == "one") then one_k = j break end
        end
        if one_k then
          for j = one_k + 1, S.last do
            local cj = C(S, j)
            local verb
            if cj and cj.single and not cj.masked then
              for _, a in ipairs(P.verb_analyses(S, cj)) do
                if a.form == "base" and (a.act == "constraint") then verb = a end
              end
            end
            if verb then
              local h = newh(S, "instruction:the_one_to_use", "instruction", "instruction_update", "instruct")
              for _, s_ in ipairs(skipped) do h.used[s_] = true end
              use_np(h, np); for i = np.nxt, S.last do if not (C(S, i).temporal and not (C(S, i).temporal.persist or C(S, i).temporal.kind == "persist")) then h.used[i] = true end end
              local value
              if np.temporal_mod then value = { year = np.temporal_mod.year, label = np.temporal_mod.text, expr = np.temporal_mod }
              else for _, m in ipairs(np.mods) do if m.kind == "mod" or m.kind == "ordinal" then value = value or { word = m.form, label = m.text } end end end
              h.instruction = { verb = verb.lemma, act = "constraint", np = np, slot = slot, value = value, correction = correction, persist = persist }
              h.correction, h.persist = correction, persist
              addf(h, "resource_slot", 0.5, "the sentence names a '" .. slot .. "' as the one to use")
              if correction then addf(h, "correction_cue", 0.4, "explicit correction marker") end
              if persist then addf(h, "persist_cue", 0.3, "applies from now on") end
              out[#out + 1] = h
              break
            end
          end
        end
      end
    end
  end
  -- A resource value stated as a fact about the resource, not as an imperative:
  --   "The 2025 dataset replaces the one I named before."        (the subject is the NEW value)
  --   "The right dataset is 2026."  "The dataset should be 2026 not what I said before."  "The one you should be using from now on is 2026."
  do
    local REPLACERS = U.set({ "replace", "replaces", "replacing", "supersede", "supersedes", "override", "overrides", "overrule", "overrules", "supplant", "supplants", "trump", "trumps" })
    local CORRECT_ADJ = U.set({ "right", "correct", "proper", "actual", "real", "true", "intended", "new", "updated", "current" })
    local function value_of_np(np)
      if np.temporal_mod then return { year = np.temporal_mod.year, label = np.temporal_mod.text, expr = np.temporal_mod } end
      if np.head_kind == "temporal" and np.head.temporal then return { year = np.head.temporal.year, label = np.head.temporal.text or P.span_text(S, np) } end
      if np.head_kind == "number" then return { word = P.span_text(S, np), label = P.span_text(S, np) } end
      if np.count then return { word = tostring(np.count), label = tostring(np.count) } end
      return nil
    end
    local any_resource
    for kk = S.first, S.last do
      local ck = C(S, kk)
      if ck and ck.single and S.lex:resource(ck.unit.form) then any_resource = S.lex:resource(ck.unit.form) end
    end
    -- candidate clause starts: the sentence start and every position after a comma / semicolon / colon / conjunction
    local starts = { k }
    for kk = k + 1, S.last do
      local ck, pc = C(S, kk), C(S, kk - 1)
      if ck and not ck.masked and ((ck.pre and (ck.pre:find("comma") or ck.pre:find("semi") or ck.pre:find("colon"))) or (pc and pc.single and cat(pc, "conj") and not pc.masked)) then starts[#starts + 1] = kk end
    end
    local np_list = {}
    for _, st in ipairs(starts) do for _, np in ipairs(P.parse_np(S, st)) do np_list[#np_list + 1] = np end end
    for _, np in ipairs(np_list) do
      local slot = resource_slot(S, np) or ((np.head and np.head.single and np.head.unit.form == "one") and any_resource) or nil
      local cb = C(S, np.nxt)
      -- (a) "the 2025 dataset replaces the one I named before"
      if slot and cb and cb.single and not cb.masked and REPLACERS[cb.unit.form] then
        local val = value_of_np(np)
        if val then
          local h = newh(S, "instruction:subject_replaces", "instruction", "instruction_update", "instruct")
          for _, s_ in ipairs(skipped) do h.used[s_] = true end
          use_np(h, np); h.used[np.nxt] = true
          for i = np.nxt + 1, S.last do if not C(S, i).masked then h.used[i] = true end end
          h.instruction = { verb = "replace", act = "constraint", np = np, slot = slot, value = val, correction = true, persist = persist }
          h.correction, h.persist = true, persist
          addf(h, "resource_slot", 0.5, "the sentence says which '" .. slot .. "' replaces the earlier one")
          addf(h, "replacement_statement", 0.5, "'" .. cb.unit.form .. "' marks the subject as the new value")
          out[#out + 1] = h
        end
      end
      -- (b) "the right dataset is 2026", "the dataset should be 2026 not what I said before", "the one you should be using from now on is 2026"
      if slot then
        local bk = np.nxt
        -- skip a relative clause after "the one": "... you should be using from now on"
        if np.head and np.head.single and np.head.unit.form == "one" then
          local jj = bk
          while C(S, jj) and not (C(S, jj).single and cat(C(S, jj), "aux_be") and C(S, jj + 1) and value_of_np((P.parse_np(S, jj + 1))[1] or {}) ) and jj < S.last do jj = jj + 1 end
          bk = jj
        end
        local bc = C(S, bk)
        -- optional modal: "should be", "must be", "needs to be", "will be"
        local mk = bk
        while C(S, mk) and C(S, mk).single and not C(S, mk).masked and (cat(C(S, mk), "modal") or cat(C(S, mk), "adv") or C(S, mk).unit.form == "to" or C(S, mk).unit.form == "need" or C(S, mk).unit.form == "needs") and mk < S.last do mk = mk + 1 end
        local bc2 = C(S, mk)
        if bc2 and bc2.single and not bc2.masked and cat(bc2, "aux_be") then
          for _, vnp in ipairs(P.parse_np(S, mk + 1)) do
            local val = value_of_np(vnp)
            if val then
              local adj_correct = false
              for _, md in ipairs(np.mods) do if md.form and CORRECT_ADJ[md.form:lower()] then adj_correct = true end end
              local h = newh(S, "instruction:resource_is_value", "instruction", "instruction_update", "instruct")
              for _, s_ in ipairs(skipped) do h.used[s_] = true end
              use_np(h, np); use_np(h, vnp)
              for i = np.nxt, vnp.c1 do h.used[i] = true end
              for i = vnp.nxt, S.last do if not C(S, i).masked then h.used[i] = true end end
              h.instruction = { verb = "be", act = "constraint", np = np, slot = slot, value = val, correction = correction or adj_correct, persist = persist }
              h.correction, h.persist = correction or adj_correct, persist
              addf(h, "resource_slot", 0.5, "the sentence states which '" .. slot .. "' is the right one")
              addf(h, "resource_is_value", 0.5, "a resource noun is equated with a value")
              out[#out + 1] = h
              break
            end
          end
        end
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

-- Exclusions and prohibitions that are NOT plain imperatives (F.instruction handles "Leave out X.", "Do not include X.", "Keep X out of ..."):
--   passive / deontic   "Universities need to be excluded."  "Reposts should be left out."  "X are not to be included."  "make sure X are left out of the list"
--   modal active        "The results should exclude X."  "Results must not contain any X."  "My brief says to exclude X."
--   progressive         "We are ruling out X for this exercise."  "I'm leaving out X."
--   wishes              "I don't want any X in the results."  "I'd rather not see any X."  "I'd really like X excluded."  "I'd rather you skipped X."
--   states of affairs   "Anything involving X is off limits."  "No X in the output, please."
--   a pronoun object    "If you come across any X, just drop them from the results."
-- Each yields an instruction_update hypothesis shaped like the imperative ones, so memory treats it identically (a standing prohibition).
local DEONTIC_WORDS = U.set({ "should", "must", "shall", "ought", "need", "needs", "needed", "supposed", "required", "expected" })
local DIRECTIVE_WORDS = U.set({ "please", "ensure", "sure", "remember", "mind", "must", "should", "shall", "ought", "need", "needs", "needed", "want", "wants", "wanted", "prefer",
  "rather", "always", "never", "require", "required", "requirement", "rule", "insist", "important", "essential", "crucial", "necessary", "wish" })
local CHAIN_WORDS = U.set({ "to", "get", "gets", "got", "be", "been", "being", "is", "are", "was", "were", "am", "do", "does", "did", "rather", "just", "really", "please", "kindly",
  "also", "then", "still", "actually", "simply", "now", "not", "never", "n't", "should", "must", "shall", "ought", "need", "needs", "needed", "supposed", "required", "expected",
  "have", "has", "had", "will", "would", "can", "could", "may", "might", "going", "'d", "'ll", "'re", "'m", "'s", "'ve", "gotta", "always", "definitely", "absolutely", "all" })
local OFF_LIMITS = { { "off", "limits" }, { "off", "the", "table" }, { "out", "of", "scope" }, { "out", "of", "bounds" }, { "banned" }, { "forbidden" }, { "prohibited" },
  { "taboo" }, { "unwanted" }, { "not", "wanted" }, { "irrelevant" }, { "not", "relevant" }, { "excluded" }, { "out" }, { "off", "limit" } }
local INDEF_LINK = U.set({ "involving", "with", "about", "from", "containing", "concerning", "featuring", "mentioning", "regarding", "on", "of", "by", "related", "relating" })
local OUTPUT_NOUNS = U.set({ "results", "result", "output", "outputs", "list", "lists", "answer", "answers", "response", "responses", "report", "summary", "table", "search", "findings" })
local WISH_VERBS = U.set({ "want", "wants", "wanted", "need", "needs", "needed", "like", "likes", "prefer", "prefers", "wish", "expect", "require", "requires", "insist" })
local PERCEPTION_VERBS = U.set({ "see", "have", "get", "receive", "hear", "find", "want", "need", "like", "include", "use", "show", "contain", "list", "return", "mention", "feature",
  "display", "give", "output", "surface", "produce", "present", "report", "read", "spot", "notice", "add", "incorporate" })
local INSTRUCT_VERBS = U.set({ "says", "said", "say", "asks", "asked", "ask", "tells", "told", "tell", "requires", "required", "instructs", "instructed", "decided", "agreed", "wants", "wanted",
  "needs", "needed", "want", "need", "prefer", "prefers", "wish", "plan", "plans", "idea", "goal", "aim" })

function F.exclusion_clause(S, out)
  if S.sentence and S.sentence.question_mark then return end
  -- the constraint-segment masks (set because exclusion cue words such as "exclude" / "rule out" are in the sentence) hide exactly the words this frame reads:
  -- lift them while scanning, restore them afterwards
  local saved
  for i, ch in ipairs(S.chunks) do if ch.masked then saved = saved or {}; saved[i] = ch.mask_kind or true end end
  if saved then
    for i in pairs(saved) do S.chunks[i].masked = nil end
    S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
  end
  local ok, err = pcall(F.exclusion_clause_scan, S, out)
  if saved then
    for i, kind in pairs(saved) do S.chunks[i].masked = true; S.chunks[i].mask_kind = kind ~= true and kind or nil end
    S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {}
  end
  if not ok then error(err, 0) end
end

function F.exclusion_clause_scan(S, out)
  local function form_of(c) return c and c.single and c.unit and c.unit.form or nil end
  local directive, persist = false, false
  for k = S.first, S.last do
    local c = C(S, k)
    if c and not c.masked then
      local f = form_of(c)
      if f and DIRECTIVE_WORDS[f] then directive = true end
      if c.temporal and (c.temporal.kind == "persist" or c.temporal.persist) then directive, persist = true, true end
    end
  end
  -- "Someone asked whether universities should be excluded": a REPORTED question or a third party's debate is not an instruction to the system
  local QUESTION_REPORT = U.set({ "whether", "asked", "asks", "asking", "wondered", "wonders", "wondering", "debated", "debating", "argued", "arguing", "questioned", "discussed", "discussing", "unclear", "unsure" })
  local reported_question_at = {}
  do
    local seen_q = false
    for k = S.first, S.last do
      local c = C(S, k)
      local f = c and c.single and c.unit and c.unit.form
      if f and QUESTION_REPORT[f] then seen_q = true end
      if f == "if" and k > S.first then seen_q = true end
      reported_question_at[k] = seen_q
    end
  end
  local seen = {}
  local function emit(frame, np, used_from, used_to, verb, more_used)
    local key = np.c1 .. ":" .. np.c2 .. ":" .. frame
    if seen[key] then return end
    -- the construction must not sit inside a reported question / conditional (the imperative-with-pronoun case below is the one place "if" is expected)
    if frame ~= "pronoun_object" and reported_question_at[used_from] then return end
    seen[key] = true
    local h = newh(S, "instruction:" .. frame, "instruction", "instruction_update", "instruct")
    for i = used_from, used_to do if C(S, i) then h.used[i] = true end end
    for _, u in ipairs(more_used or {}) do h.used[u] = true end
    use_np(h, np)
    h.instruction = { verb = verb, act = "exclude", np = np, correction = false, persist = persist }
    h.polarity = "negative"
    h.persist = persist
    addf(h, "exclusion_clause", 0.9, "an exclusion is stated (" .. frame .. ")")
    if directive then addf(h, "directive_context", 0.2, "the sentence carries a directive marker") end
    if persist then addf(h, "persist_cue", 0.3, "applies from now on") end
    F.mark_pron(h, np)
    out[#out + 1] = h
  end
  -- the NP that ends right before chunk `e` (longest first)
  local function np_ending_before(e)
    for i = S.first, e - 1 do
      for _, np in ipairs(P.parse_np(S, i)) do if np.nxt == e then return np end end
    end
  end
  -- "any X", "all X": the quantifier is part of the determiner; the target is the NP after it
  for kv = S.first, S.last do
    local c = C(S, kv)
    if c and not c.masked and (c.single or c.kind == "mwe") then
      for _, a in ipairs(P.verb_analyses(S, c)) do
        local is_excl = a.act == "exclude"
        local is_percep = a.act == "include" or PERCEPTION_VERBS[a.lemma] == true
        if is_excl or is_percep then
          -- the verb group in front of the verb
          local j = kv - 1
          local forms, has_neg, has_be, deontic, rather = {}, false, false, false, false
          while j >= S.first and C(S, j) and C(S, j).single and not C(S, j).masked and not barrier(C(S, j)) and CHAIN_WORDS[form_of(C(S, j))] and kv - j <= 6 do
            local f = form_of(C(S, j))
            if f == "do" and forms[1] == "do" then break end      -- "whatever you DO don't include X": two do's are two clauses
            table.insert(forms, 1, f)
            if P.is_neg(C(S, j)) or f == "never" then has_neg = true end
            if f == "be" or f == "been" or f == "being" or f == "is" or f == "are" or f == "was" or f == "were" or f == "am" or f == "get" or f == "gets" or f == "got" or f == "'re" or f == "'m" then has_be = true end
            if DEONTIC_WORDS[f] then deontic = true end
            if f == "rather" then rather = true end
            j = j - 1
          end
          local chain_first = j + 1
          for i, f in ipairs(forms) do
            if f == "to" and i > 1 and (forms[i - 1] == "have" or forms[i - 1] == "has" or forms[i - 1] == "had" or forms[i - 1] == "going" or forms[i - 1] == "ought") then deontic = true end
          end
          local subj_form = j >= S.first and form_of(C(S, j)) or nil
          local subj_pron = subj_form == "we" or subj_form == "i" or subj_form == "you"
          local after, verb_end = kv + 1, kv
          local nc = C(S, after)
          if is_excl and c.kind ~= "mwe" and nc and nc.single and not nc.masked and not barrier(nc) and (nc.unit.form == "out" or nc.unit.form == "off") then after = after + 1; verb_end = after - 1 end
          local to_before = forms[#forms] == "to"
          local imperative_chain = true       -- nothing but do / not / please-like words in front: a plain imperative, F.instruction's business
          for _, f in ipairs(forms) do
            if not (f == "do" or f == "does" or f == "did" or f == "not" or f == "n't" or f == "never" or f == "please" or f == "just" or f == "kindly" or f == "also" or f == "then" or f == "always" or f == "really" or f == "definitely" or f == "absolutely" or f == "now") then imperative_chain = false end
          end
          if subj_pron then imperative_chain = false end

          -- (1) passive: NP be/get ... excluded
          if is_excl and (a.form == "pp" or a.form == "past") and has_be and not has_neg then
            local np = np_ending_before(chain_first)
            if np and (deontic or directive or rather or persist) then emit("passive", np, np.c1, verb_end) end
          end
          -- (1b) a negated passive of an include-like verb: "X are not to be included", "X should not be shown", "X must not appear"
          if is_percep and not is_excl and (a.form == "pp" or a.form == "past") and has_be and has_neg and (deontic or to_before or directive) then
            local np = np_ending_before(chain_first)
            if np then emit("negated_passive", np, np.c1, verb_end) end
          end
          -- (2) modal / infinitive active: "the results should exclude X", "my brief says to exclude X"
          if is_excl and a.form == "base" and not has_neg and not imperative_chain then
            local pv = j >= S.first and C(S, j)
            local instruct_prev = pv and pv.single and INSTRUCT_VERBS[form_of(pv)] or false
            if deontic or (to_before and (instruct_prev or directive)) then
              -- "My brief says to exclude X": the introducing clause is part of the directive
              for _, np in ipairs(P.parse_np(S, after)) do emit("modal", np, instruct_prev and S.first or chain_first, np.c2, a.lemma); break end
            end
          end
          -- (3) progressive with a first/second-person subject: "We are ruling out X"
          if is_excl and a.form == "ing" and has_be and subj_pron and not has_neg then
            for _, np in ipairs(P.parse_np(S, after)) do emit("progressive", np, j, np.c2, a.lemma); break end
          end
          -- (4) subjunctive wish: "I'd rather you skipped X"
          if is_excl and (a.form == "past" or a.form == "base") and subj_form == "you" then
            local before1, before2 = form_of(C(S, j - 1)), form_of(C(S, j - 2))
            if before1 == "rather" or before2 == "rather" or before1 == "prefer" or before1 == "wish" then
              for _, np in ipairs(P.parse_np(S, after)) do emit("subjunctive", np, j - 1, np.c2, a.lemma); break end
            end
          end
          -- (5) negated include-like verbs: "Results must not contain any X", "I don't want any X", "I'd rather not see any X"
          if is_percep and not is_excl and a.form == "base" and has_neg and not imperative_chain then
            if deontic or rather or (subj_pron and WISH_VERBS[a.lemma]) or (subj_pron and rather) then
              for _, np in ipairs(P.parse_np(S, after)) do emit("negated_wish", np, chain_first, np.c2, a.lemma); break end
            end
          end
          -- (5b) a negated imperative that is not the first clause: "..., but whatever you do don't include X"
          if is_percep and not is_excl and a.form == "base" and has_neg and imperative_chain and chain_first > S.first then
            for _, np in ipairs(P.parse_np(S, after)) do emit("negated_imperative", np, chain_first, np.c2, a.lemma); break end
          end
          -- (6) wish + participle: "I'd really like X excluded", "we need X left out"
          if WISH_VERBS[a.lemma] and not has_neg then
            for _, np in ipairs(P.parse_np(S, kv + 1)) do
              local k2 = np.nxt
              local tc, bc = C(S, k2), C(S, k2 + 1)
              if tc and tc.single and form_of(tc) == "to" and bc and bc.single and cat(bc, "aux_be") then k2 = k2 + 2 end
              local vc = C(S, k2)
              if vc and (vc.single or vc.kind == "mwe") and not vc.masked then
                for _, a2 in ipairs(P.verb_analyses(S, vc)) do
                  if a2.act == "exclude" and (a2.form == "pp" or a2.form == "past") then emit("wish_participle", np, kv, k2, a2.lemma) end
                end
              end
            end
          end
          -- (7) imperative exclusion whose object is a pronoun: "If you come across any X, just drop THEM from the results"
          if is_excl and a.form == "base" and imperative_chain and not has_neg then
            for _, np in ipairs(P.parse_np(S, after)) do
              if np.head_kind == "pronoun" and np.pron and (np.pron.form == "them" or np.pron.form == "those" or np.pron.form == "it") then
                -- the antecedent: the nearest earlier noun phrase (not a pronoun) before this clause
                local ante
                for e = kv - 1, S.first, -1 do
                  for i = e, S.first, -1 do
                    for _, np2 in ipairs(P.parse_np(S, i)) do
                      if np2.nxt == e + 1 and np2.head_kind ~= "pronoun" and (np2.head_kind == "typenoun" or np2.head_kind == "unknown" or np2.head_kind == "entity") then ante = ante or np2 end
                    end
                    if ante then break end
                  end
                  if ante then break end
                end
                if ante then emit("pronoun_object", ante, kv, np.c2, a.lemma, { np.c1 }) end
              end
              break
            end
          end
        end
      end
    end
  end
  -- (8) states of affairs: "Anything involving X is off limits."
  for kb = S.first + 1, S.last do
    local bc = C(S, kb)
    if bc and bc.single and not bc.masked and cat(bc, "aux_be") then
      for _, pat in ipairs(OFF_LIMITS) do
        local ok = true
        for i, w in ipairs(pat) do
          local ck = C(S, kb + i)
          if not (ck and ck.single and not ck.masked and form_of(ck) == w) then ok = false break end
        end
        if ok then
          local np = np_ending_before(kb)
          local target = np
          -- "anything involving X": the indefinite only introduces the target
          for i = S.first, kb - 1 do
            local ci = C(S, i)
            local fi = form_of(ci)
            if fi == "anything" or fi == "everything" or fi == "anyone" or fi == "all" then
              local link = C(S, i + 1)
              if link and link.single and INDEF_LINK[form_of(link)] then
                local k3 = i + 2
                if form_of(link) == "related" or form_of(link) == "relating" then if form_of(C(S, i + 2)) == "to" then k3 = i + 3 end end
                for _, np2 in ipairs(P.parse_np(S, k3)) do if np2.nxt == kb then target = np2; break end end
              end
            end
          end
          if target then emit("off_limits", target, target.c1, kb + #pat) end
          break
        end
      end
    end
  end
  -- (9) "No X in the output, please."
  do
    local c0 = C(S, S.first)
    if c0 and c0.single and not c0.masked and form_of(c0) == "no" then
      for _, np in ipairs(P.parse_np(S, S.first + 1)) do
        local pc = C(S, np.nxt)
        if pc and pc.single and cat(pc, "prep") and not pc.masked then
          for _, np2 in ipairs(P.parse_np(S, np.nxt + 1)) do
            if np2.head and OUTPUT_NOUNS[np2.head.single and np2.head.unit.form or ""] then emit("no_x_in_output", np, S.first, np2.c2) end
          end
        end
      end
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
      -- "Results must not contain X", "universities should be excluded": a deontic verb group is a directive, not an assertion of fact
      for i = snp.nxt, vp.c2 do
        local ci = C(S, i)
        local fi = ci and ci.single and ci.unit and ci.unit.form
        if fi == "must" or fi == "should" or fi == "shall" or fi == "ought" then addf(h, "deontic_not_assertion", -0.9, "a verb group with '" .. fi .. "' is a directive, not a statement of fact"); break end
      end
      h.statement = { subj = snp, vp = vp, lemma = vp.lemma, neg = vp.neg }
      if objs[1] then use_np(h, objs[1]); h.statement.obj = objs[1] end
      for _, e in ipairs(vp.analysis.entries) do
        local rel = S.lex:get_rel(e.rel)
        if rel and objs[1] and not rel.open then
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
