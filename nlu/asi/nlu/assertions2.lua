-- asi.nlu.assertions2: clause-level fact mining for the assertion extractor (extends asi.nlu.assertions).
-- Real text rarely states a fact as a sentence of its own: it appears in an appositive ("Officials in P, the capital of K, said ..."), a relative clause
-- ("K, whose capital is P, ..."), a fronted participle ("Founded by X, Y has grown ..."), a purpose clause ("X returned home to found Y"), after a reporting frame
-- ("we learned that P is the capital of K"), after a fronted adverbial ... The patterns here find such localised constructions anywhere in a sentence, and
-- `mine` re-runs the whole-sentence patterns on sub-clauses when the sentence as written yields nothing.  Every pattern builds the same candidate records
-- as asi.nlu.assertions (rel, roles, used noun phrases); roles come from the relation lexicon's direction and type compatibility, never from word proximity.
local U = require("asi.nlu.util")
local P = require("asi.nlu.parse")
local F = require("asi.nlu.frames2")
require("asi.nlu.frames4")   -- the question frames share their phrase helpers (credit cues, locus options) on the same table

local X = {}
local cat = P.cat
local function C(S, k) return S.chunks[k] end
local function other(role) return role == "to" and "from" or "to" end
local H = {}   -- helpers injected by asi.nlu.assertions (copula_at ...)
function X.init(h) for k, v in pairs(h) do H[k] = v end end

local function name_np(np)
  return (np.head_kind == "entity" or (np.head_kind == "unknown" and np.head and np.head.cap)) and not np.poss_det and not np.det
end
local function has_pre(c, tag) return c ~= nil and c.pre ~= nil and c.pre:find(tag) ~= nil end
local function opens(c) return has_pre(c, "comma") or has_pre(c, "paren_open") or has_pre(c, "dash") end
local function closed_after(S, nxt)
  local nc = C(S, nxt)
  return nxt > S.last or (nc ~= nil and nc.pre ~= nil and (nc.pre:find("comma") or nc.pre:find("dash") or nc.pre:find("paren_close") or nc.pre:find("semi") or nc.pre:find("colon")))
end

local function cand(rel, pattern, used_np, roles, end_chunk, extra)
  local a = { rel = rel.id, rel_obj = rel, pattern = pattern, used_np = used_np, neg = false, tense = "present", roles = roles, end_chunk = end_chunk, local_pattern = true }
  for k, v in pairs(extra or {}) do a[k] = v end
  return a
end

-- a value that is a common noun rather than a name (the currency "tolar", the language "Zorish") is allowed for these relation value types
local COMMON_VALUE = U.set({ "currency", "language", "topic", "service", "role", "concept" })
local function value_ok(rel, ask_role, np)
  if name_np(np) then return true end
  return np.head_kind == "unknown" and COMMON_VALUE[rel[ask_role] or ""] == true and not np.plural
end

---------------------------------------------------------------- appositives:  NAME , RELNP-of-X ,     RELNP-of-X [adjuncts] , NAME
local function apposition_anywhere(self, S, ctx, out)
  for k = S.first, S.last do
    local ck = C(S, k)
    if ck and not ck.masked then
      for _, np1 in ipairs(P.parse_np(S, k)) do
        -- (a) NAME , the capital of X ,    /    NAME (the capital of X)
        if np1.nxt <= S.last and opens(C(S, np1.nxt)) then
          for _, np2 in ipairs(P.parse_np(S, np1.nxt)) do
            if np2.head_kind == "relnoun" and np2.of_arg and closed_after(S, np2.nxt) then
              for _, o in ipairs(F.relnp_options(S, np2)) do
                if o.arg and o.rel and not o.rel.open and value_ok(o.rel, o.ask_role, np1) and not (np1.head_kind == "relnoun") then
                  out[#out + 1] = cand(o.rel, "apposition_local", { np1, np2 }, { [o.known_role] = o.arg, [o.ask_role] = np1 }, np2.nxt)
                end
              end
            end
          end
        end
        -- (b) the founder of X [for years|since 1990] , NAME
        if np1.head_kind == "relnoun" and np1.of_arg then
          local j = np1.nxt
          local cj = C(S, j)
          -- one adjunct before the comma: a temporal expression, or "for|since|in NP"
          if cj and not opens(cj) and j <= S.last then
            if cj.temporal and cj.temporal.kind ~= "marker" then j = j + 1
            elseif cj.single and cat(cj, "prep") and not cj.masked then
              for _, pnp in ipairs(P.parse_np(S, j + 1)) do j = pnp.nxt; break end
            end
            cj = C(S, j)
          end
          if cj and j <= S.last and opens(cj) and not has_pre(cj, "paren_open") then
            for _, np2 in ipairs(P.parse_np(S, j)) do
              if name_np(np2) then
                for _, o in ipairs(F.relnp_options(S, np1)) do
                  if o.arg and o.rel and not o.rel.open and value_ok(o.rel, o.ask_role, np2) then
                    out[#out + 1] = cand(o.rel, "apposition_local", { np1, np2 }, { [o.known_role] = o.arg, [o.ask_role] = np2 }, np2.nxt)
                  end
                end
              end
            end
          end
        end
        -- (c) Chief executive NAME of ORG        (a title in front of a name, then "of" and the organisation)
        if name_np(np1) or (np1.head_kind == "entity" and #(np1.mods or {}) > 0) then
          local titles = {}
          for _, m in ipairs(np1.mods or {}) do
            if m.chunk then for _, ne in ipairs(m.chunk.relnouns or {}) do titles[#titles + 1] = ne end end
          end
          local oc = C(S, np1.nxt)
          if #titles > 0 and oc and oc.single and not oc.masked and oc.unit.form == "of" and not opens(oc) then
            for _, org in ipairs(P.parse_np(S, np1.nxt + 1)) do
              if name_np(org) then
                for _, ne in ipairs(titles) do
                  local rel = S.lex:get_rel(ne.rel)
                  if rel and not rel.open and ne.role == "to" then
                    out[#out + 1] = cand(rel, "title_of", { np1, org }, { from = org, to = np1 }, org.nxt)
                  end
                end
                break
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- NAME , whose RELNOUN is VALUE
local function whose_clause(self, S, ctx, out)
  for k = S.first, S.last do
    for _, snp in ipairs(P.parse_np(S, k)) do
      local wc = C(S, snp.nxt)
      if name_np(snp) and wc and wc.single and not wc.masked and wc.unit.form == "whose" and has_pre(wc, "comma") then
        for _, rnp in ipairs(P.parse_np(S, snp.nxt + 1)) do
          if rnp.head_kind == "relnoun" and not rnp.of_arg and not rnp.possessor and H.copula_at then
            local cp = H.copula_at(S, rnp.nxt)
            if cp then
              local vk = cp.nxt
              local pc = C(S, vk)
              if pc and pc.single and not pc.masked and cat(pc, "prep") and (pc.unit.form == "in" or pc.unit.form == "at") then vk = vk + 1 end
              for _, vnp in ipairs(P.parse_np(S, vk)) do
                if closed_after(S, vnp.nxt) then
                  for _, e in ipairs(rnp.relnouns) do
                    local rel = S.lex:get_rel(e.rel)
                    if rel and not rel.open and value_ok(rel, e.role, vnp) then
                      out[#out + 1] = cand(rel, "whose_clause", { snp, rnp, vnp }, { [other(e.role)] = snp, [e.role] = vnp }, vnp.nxt, { copula = cp })
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- "its founder, NAME"   /   "NAME, its chief executive"
-- the possessive pronoun stands for the nearest earlier entity of a type the relation allows
local function possessive_apposition(self, S, ctx, out)
  local lex = S.lex
  local function holder_before(pos, avoid, rel, holder_role)
    for k = pos - 1, S.first, -1 do
      for _, np in ipairs(P.parse_np(S, k)) do
        if np.nxt <= pos and np ~= avoid and name_np(np) and np.c2 == (C(S, k) and np.c2) then
          local ty
          for _, cd in ipairs(np.cands or {}) do ty = ty or cd.type end
          if np.head and np.head.names and np.head.names[1] then ty = ty or np.head.names[1].type_guess end
          if lex:compat(ty, rel[holder_role]) > -1.0 then return np end
        end
      end
    end
  end
  for k = S.first, S.last do
    local ck = C(S, k)
    if ck and ck.single and not ck.masked and cat(ck, "poss_det") and (ck.unit.form == "its" or ck.unit.form == "his" or ck.unit.form == "her" or ck.unit.form == "their") then
      for _, rnp in ipairs(P.parse_np(S, k)) do
        if rnp.head_kind == "relnoun" and not rnp.of_arg then
          -- (a) its founder , NAME      (b) NAME , its chief executive
          local nc = C(S, rnp.nxt)
          local value, holder_pos
          if nc and has_pre(nc, "comma") then
            for _, np2 in ipairs(P.parse_np(S, rnp.nxt)) do if name_np(np2) then value = np2; holder_pos = k; break end end
          end
          local bc = C(S, k)
          if not value and bc and k > S.first and has_pre(bc, "comma") then
            for k2 = k - 1, S.first, -1 do
              for _, np0 in ipairs(P.parse_np(S, k2)) do
                if np0.nxt == k and name_np(np0) then value = np0; holder_pos = k2; break end
              end
              if value then break end
            end
          end
          if value then
            for _, e in ipairs(rnp.relnouns) do
              local rel = lex:get_rel(e.rel)
              if rel and not rel.open and value_ok(rel, e.role, value) then
                local holder = holder_before(math.min(holder_pos, value.c1 or holder_pos), value, rel, other(e.role))
                if holder then
                  out[#out + 1] = cand(rel, "possessive_apposition", { holder, rnp, value }, { [other(e.role)] = holder, [e.role] = value }, math.max(rnp.nxt, value.nxt))
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- participial and purpose constructions
-- "Founded by X, Y has grown ..."
local function fronted_passive_by(self, S, ctx, out)
  for _, vp in ipairs(P.parse_vp(S, S.first, { participle_ok = true })) do
    if vp.voice == "passive" then
      local bc = C(S, vp.nxt)
      if bc and bc.single and not bc.masked and bc.unit.form == "by" then
        for _, np1 in ipairs(P.parse_np(S, vp.nxt + 1)) do
          local j = np1.nxt
          local cj = C(S, j)
          -- an adjunct between the by-phrase and the comma ("in 1999")
          if cj and cj.temporal and not has_pre(cj, "comma") then j = j + 1; cj = C(S, j) end
          if cj and has_pre(cj, "comma") and name_np(np1) then
            for _, np2 in ipairs(P.parse_np(S, j)) do
              if name_np(np2) then
                for _, e in ipairs(vp.analysis.entries or {}) do
                  local rel = S.lex:get_rel(e.rel)
                  if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                    out[#out + 1] = cand(rel, "fronted_passive", { np1, np2 }, { [other(e.subj)] = np2, [e.subj] = np1 }, np2.nxt, { vp = vp, neg = vp.neg })
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

-- "Having founded O, P spent the next decade ..."
local function having_clause(self, S, ctx, out)
  local c0 = C(S, S.first)
  if not (c0 and c0.single and c0.unit.form == "having") then return end
  for _, vp in ipairs(P.parse_vp(S, S.first)) do
    if vp.voice == "active" and vp.perfect then
      for _, e in ipairs(vp.analysis.entries or {}) do
        local rel = S.lex:get_rel(e.rel)
        if rel and not rel.open and not e.prep and not e.support and not e.as_only then
          for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
            local cj = C(S, onp.nxt)
            if cj and has_pre(cj, "comma") and name_np(onp) then
              for _, snp in ipairs(P.parse_np(S, onp.nxt)) do
                if name_np(snp) then
                  out[#out + 1] = cand(rel, "having_clause", { snp, onp }, { [e.subj] = snp, [other(e.subj)] = onp }, onp.nxt, { vp = vp, neg = vp.neg, tense = "past" })
                end
              end
            end
          end
        end
      end
    end
  end
end

-- "P returned home to found O."  /  "that is how P came to found O."
local TO_VERBS = U.set({ "came", "come", "returned", "went", "moved", "managed", "proceeded", "went" })
local function purpose_infinitive(self, S, ctx, out)
  for k = S.first, S.last do
    for _, snp in ipairs(P.parse_np(S, k)) do
      if name_np(snp) and snp.nxt < S.last then
        local verb_seen = false
        for j = snp.nxt, math.min(S.last - 1, snp.nxt + 6) do
          local cj = C(S, j)
          if not cj or cj.masked or (j > snp.nxt and has_pre(cj, "comma")) then break end
          if cj.single and TO_VERBS[cj.unit.form] then verb_seen = true end
          if cj.single and (P.is_neg(cj) or cj.unit.form == "failed" or cj.unit.form == "unable") then break end
          local tc = C(S, j + 1)
          if verb_seen and cj.single and cj.unit.form == "to" and tc and tc.single and not tc.masked then
            for _, a in ipairs(P.verb_analyses(S, tc)) do
              if a.form == "base" then
                for _, e in ipairs(a.entries or {}) do
                  local rel = S.lex:get_rel(e.rel)
                  if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                    for _, onp in ipairs(P.parse_np(S, j + 2)) do
                      if name_np(onp) then
                        out[#out + 1] = cand(rel, "purpose_infinitive", { snp, onp }, { [e.subj] = snp, [other(e.subj)] = onp }, onp.nxt, { tense = "past" })
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

-- "Credit for founding O goes to P."   "We have P to thank for founding O."
local function credit_pattern(self, S, ctx, out)
  local lex = S.lex
  for k = S.first, S.last - 3 do
    local c = C(S, k)
    local function verb_obj(vk)
      -- VERB-ing NP  at chunk vk
      local vc = C(S, vk)
      local res = {}
      if vc and vc.single and not vc.masked then
        for _, a in ipairs(P.verb_analyses(S, vc)) do
          if a.form == "ing" then
            for _, e in ipairs(a.entries or {}) do
              local rel = lex:get_rel(e.rel)
              if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                for _, onp in ipairs(P.parse_np(S, vk + 1)) do res[#res + 1] = { e = e, rel = rel, onp = onp } end
              end
            end
          end
        end
      end
      return res
    end
    if c and c.single and (c.unit.form == "credit" or c.unit.form == "thanks") then
      local fc = C(S, k + 1)
      if fc and fc.single and fc.unit.form == "for" then
        for _, vo in ipairs(verb_obj(k + 2)) do
          local gc = C(S, vo.onp.nxt)
          local tc = C(S, vo.onp.nxt + 1)
          if gc and gc.single and (gc.unit.form == "goes" or gc.unit.form == "belongs" or gc.unit.form == "goes") and tc and tc.single and tc.unit.form == "to" then
            for _, snp in ipairs(P.parse_np(S, vo.onp.nxt + 2)) do
              if name_np(snp) and name_np(vo.onp) then
                out[#out + 1] = cand(vo.rel, "credit_goes_to", { snp, vo.onp }, { [vo.e.subj] = snp, [other(vo.e.subj)] = vo.onp }, snp.nxt, { tense = "past" })
              end
            end
          end
        end
      end
    end
    -- we have P to thank for founding O
    if c and c.single and (c.unit.form == "have" or c.unit.form == "has") then
      for _, snp in ipairs(P.parse_np(S, k + 1)) do
        local t1, t2, t3 = C(S, snp.nxt), C(S, snp.nxt + 1), C(S, snp.nxt + 2)
        if name_np(snp) and t1 and t2 and t3 and t1.single and t2.single and t3.single and t1.unit.form == "to" and t2.unit.form == "thank" and t3.unit.form == "for" then
          for _, vo in ipairs(verb_obj(snp.nxt + 3)) do
            if name_np(vo.onp) then
              out[#out + 1] = cand(vo.rel, "thank_for", { snp, vo.onp }, { [vo.e.subj] = snp, [other(vo.e.subj)] = vo.onp }, vo.onp.nxt, { tense = "past" })
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- appositive relative with an object gap, parenthetical passive
-- "O, the group that P established, voted ..."     "O (established by P) opened its doors"     "O, founded by P, ..."
local function appositive_clauses(self, S, ctx, out)
  for k = S.first, S.last do
    for _, snp in ipairs(P.parse_np(S, k)) do
      local oc = C(S, snp.nxt)
      if name_np(snp) and snp.nxt <= S.last and oc and opens(oc) then
        -- (a) passive participle with a by-agent
        for _, vp in ipairs(P.parse_vp(S, snp.nxt, { participle_ok = true })) do
          if vp.voice == "passive" then
            local bc = C(S, vp.nxt)
            if bc and bc.single and not bc.masked and bc.unit.form == "by" then
              for _, ag in ipairs(P.parse_np(S, vp.nxt + 1)) do
                if name_np(ag) and closed_after(S, ag.nxt) then
                  for _, e in ipairs(vp.analysis.entries or {}) do
                    local rel = S.lex:get_rel(e.rel)
                    if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                      out[#out + 1] = cand(rel, "appositive_passive", { snp, ag }, { [other(e.subj)] = snp, [e.subj] = ag }, ag.nxt, { vp = vp, neg = vp.neg })
                    end
                  end
                end
              end
            end
          end
        end
        -- (b) the group that P established  (object relative clause)
        for _, dnp in ipairs(P.parse_np(S, snp.nxt)) do
          local rc = C(S, dnp.nxt)
          if (dnp.head_kind == "typenoun" or dnp.head_kind == "unknown") and rc and rc.single and not rc.masked and (rc.unit.form == "that" or rc.unit.form == "which") then
            for _, sub in ipairs(P.parse_np(S, dnp.nxt + 1)) do
              if name_np(sub) then
                for _, vp in ipairs(P.parse_vp(S, sub.nxt)) do
                  if vp.voice == "active" and closed_after(S, vp.nxt) then
                    for _, e in ipairs(vp.analysis.entries or {}) do
                      local rel = S.lex:get_rel(e.rel)
                      if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                        out[#out + 1] = cand(rel, "appositive_relative_gap", { snp, sub }, { [other(e.subj)] = snp, [e.subj] = sub }, vp.nxt, { vp = vp, neg = vp.neg, tense = "past" })
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- fronted locative holder:  "In K the currency is the X."   "In K, the capital is C."
local function fronted_holder(self, S, ctx, out)
  local c0 = C(S, S.first)
  if not (c0 and c0.single and not c0.masked and cat(c0, "prep") and (c0.unit.form == "in" or c0.unit.form == "across" or c0.unit.form == "throughout")) then return end
  for _, hnp in ipairs(P.parse_np(S, S.first + 1)) do
    if name_np(hnp) then
      for _, rnp in ipairs(P.parse_np(S, hnp.nxt)) do
        if rnp.head_kind == "relnoun" and not rnp.of_arg and not rnp.possessor and H.copula_at then
          local cp = H.copula_at(S, rnp.nxt)
          if cp then
            for _, vnp in ipairs(P.parse_np(S, cp.nxt)) do
              for _, e in ipairs(rnp.relnouns) do
                local rel = S.lex:get_rel(e.rel)
                if rel and not rel.open and value_ok(rel, e.role, vnp) and S.lex:compat(hnp.cands and hnp.cands[1] and hnp.cands[1].type, rel[other(e.role)]) > -1.0 then
                  out[#out + 1] = cand(rel, "fronted_holder", { hnp, rnp, vnp }, { [other(e.role)] = hnp, [e.role] = vnp }, vnp.nxt, { copula = cp })
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- "K has its own currency, the X."
local function have_appositive(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if name_np(snp) then
      for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
        if vp.lemma == "have" and vp.voice == "active" then
          local k = vp.nxt
          local pc = C(S, k)
          if pc and pc.single and cat(pc, "poss_det") then
            local oc = C(S, k + 1)
            local nk = k
            if oc and oc.single and (oc.unit.form == "own") then nk = k end
            for _, onp in ipairs(P.parse_np(S, nk)) do
              if onp.head_kind == "relnoun" and not onp.of_arg and has_pre(C(S, onp.nxt), "comma") then
                for _, vnp in ipairs(P.parse_np(S, onp.nxt)) do
                  if closed_after(S, vnp.nxt) then
                    for _, o in ipairs(F.relnp_options(S, onp)) do
                      if o.rel and not o.rel.open and o.rel.support_have and o.ask_role == "to" and value_ok(o.rel, "to", vnp) then
                        out[#out + 1] = cand(o.rel, "have_appositive", { snp, onp, vnp }, { from = snp, to = vnp }, vnp.nxt, { vp = vp })
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- attribution idioms in statements
-- "P is credited with founding O."  "P is credited with having established O."  "P is the person behind the founding of O."  "P deserves the credit for starting O."
local function credit_statement(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if name_np(snp) then
      for _, cue in ipairs(F.credit_cues(S, snp.nxt)) do
        for _, tg in ipairs(F.credit_targets(S, cue.nxt)) do
          if name_np(tg.obj) then
            out[#out + 1] = cand(tg.rel, "credit_statement", { snp, tg.obj }, { [tg.agent] = snp, [other(tg.agent)] = tg.obj }, tg.obj.nxt, { tense = "past" })
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- "Official filings list P as the person who established O."
local AS_LISTERS = U.set({ "list", "lists", "listed", "name", "names", "named", "identify", "identifies", "identified", "describe", "describes", "described", "cite", "cites", "cited",
  "present", "presents", "presented", "introduce", "introduces", "introduced", "record", "records", "recorded", "register", "registers", "registered", "show", "shows", "shown",
  "credit", "credits", "credited", "recognise", "recognize", "recognises", "recognizes", "recognised", "recognized", "regard", "regards", "regarded", "consider", "considers",
  "considered", "treat", "treats", "treated", "know", "knows", "known", "call", "calls", "called", "mention", "mentions", "mentioned", "acknowledge", "acknowledges", "acknowledged" })
local function as_relative(self, S, ctx, out)
  for k = S.first, S.last do
    local vc = C(S, k)
    if vc and vc.single and not vc.masked and AS_LISTERS[vc.unit.form] then
      for _, pnp in ipairs(P.parse_np(S, k + 1)) do
        local ac = C(S, pnp.nxt)
        if name_np(pnp) and ac and ac.single and not ac.masked and ac.unit.form == "as" then
          for _, tnp in ipairs(P.parse_np(S, pnp.nxt + 1, { no_of = true })) do
            local rc = C(S, tnp.nxt)
            if not name_np(tnp) and rc and rc.single and not rc.masked and (rc.unit.form == "who" or rc.unit.form == "that" or rc.unit.form == "which") then
              for _, vp in ipairs(P.parse_vp(S, tnp.nxt + 1)) do
                if vp.voice == "active" then
                  for _, e in ipairs(vp.analysis.entries or {}) do
                    local rel = S.lex:get_rel(e.rel)
                    if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                      for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
                        if name_np(onp) then
                          out[#out + 1] = cand(rel, "as_relative", { pnp, onp }, { [e.subj] = pnp, [other(e.subj)] = onp }, onp.nxt,
                            { vp = vp, neg = vp.neg, tense = (vp.vform == "past" or vp.perfect) and "past" or "present" })
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- "O is the organisation that P founded."
local function copular_object_relative(self, S, ctx, out)
  if not H.copula_at then return end
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if name_np(snp) then
      local cp = H.copula_at(S, snp.nxt)
      if cp then
        for _, dnp in ipairs(P.parse_np(S, cp.nxt, { no_of = true })) do
          local rc = C(S, dnp.nxt)
          if not name_np(dnp) and (dnp.head_kind == "typenoun" or dnp.head_kind == "unknown" or dnp.head_kind == "concept") and rc and rc.single and not rc.masked
            and (rc.unit.form == "that" or rc.unit.form == "which") then
            for _, sub in ipairs(P.parse_np(S, dnp.nxt + 1)) do
              if name_np(sub) then
                for _, vp in ipairs(P.parse_vp(S, sub.nxt)) do
                  if vp.voice == "active" and closed_after(S, vp.nxt) then
                    for _, e in ipairs(vp.analysis.entries or {}) do
                      local rel = S.lex:get_rel(e.rel)
                      if rel and not rel.open and not e.prep and not e.support and not e.as_only then
                        out[#out + 1] = cand(rel, "copular_object_relative", { snp, sub }, { [other(e.subj)] = snp, [e.subj] = sub }, vp.nxt,
                          { copula = cp, vp = vp, neg = cp.neg or vp.neg, tense = (vp.vform == "past" or vp.perfect) and "past" or "present" })
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- placement statements about locus relations (headquarters)
--   "C is home to the headquarters of O."  "C hosts the headquarters of O."  "C is where O is headquartered."
--   "Industry sources place the headquarters of O in C."  "O lists C as the site of its headquarters."  "Based in C, O ..."
local PLACE_FORMS = U.set({ "place", "places", "placed", "put", "puts", "locate", "locates", "located", "situate", "situates", "situated", "site", "sites", "sited", "base", "bases", "based",
  "position", "positions", "positioned", "establish", "establishes", "established", "set", "sets" })
local SITE_NOUNS = U.set({ "site", "seat", "home", "location", "base", "address", "place", "centre", "center", "venue" })
local function locus_statement(self, S, ctx, out)
  local lex = S.lex
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if name_np(snp) then
      -- (a) C is home to the headquarters of O.
      local cp = H.copula_at and H.copula_at(S, snp.nxt)
      if cp then
        local n = F.first_phrase(S, cp.nxt, F.HOME_PHRASES)
        if n then
          for _, onp in ipairs(P.parse_np(S, n)) do
            if onp.head_kind == "relnoun" then
              for _, o in ipairs(F.locus_options(S, onp)) do
                out[#out + 1] = cand(o.rel, "locus_home", { snp, onp }, { [o.known_role] = o.arg, [o.ask_role] = snp }, onp.nxt, { copula = cp })
              end
            end
          end
        end
        -- (c) C is where O is headquartered.
        local wc = C(S, cp.nxt)
        if wc and wc.single and not wc.masked and wc.unit.form == "where" then
          for _, onp in ipairs(P.parse_np(S, cp.nxt + 1)) do
            if name_np(onp) then
              for _, vp in ipairs(P.parse_vp(S, onp.nxt, { participle_ok = true })) do
                for _, e in ipairs(vp.analysis.entries or {}) do
                  local rel = lex:get_rel(e.rel)
                  if rel and not rel.open and e.prep and not e.support then
                    out[#out + 1] = cand(rel, "locus_where", { snp, onp }, { [e.subj] = onp, [other(e.subj)] = snp }, vp.nxt, { vp = vp, copula = cp, neg = vp.neg })
                  end
                end
              end
            end
          end
        end
      end
      -- (b) C hosts the headquarters of O.
      for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
        if vp.voice == "active" and F.HOST_LEMMAS[vp.lemma] then
          for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
            if onp.head_kind == "relnoun" then
              for _, o in ipairs(F.locus_options(S, onp)) do
                out[#out + 1] = cand(o.rel, "locus_host", { snp, onp }, { [o.known_role] = o.arg, [o.ask_role] = snp }, onp.nxt, { vp = vp, neg = vp.neg })
              end
            end
          end
        end
      end
      -- (e) O lists C as the site of its headquarters.
      for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
        if vp.voice == "active" and AS_LISTERS[vp.lemma] or (vp.voice == "active" and AS_LISTERS[C(S, vp.c1).unit and C(S, vp.c1).unit.form or ""]) then
          for _, pnp in ipairs(P.parse_np(S, vp.nxt)) do
            local ac = C(S, pnp.nxt)
            if name_np(pnp) and ac and ac.single and ac.unit.form == "as" then
              local m = pnp.nxt + 1
              local dc = C(S, m)
              if dc and dc.single and cat(dc, "det") then m = m + 1 end
              local sc, oc = C(S, m), C(S, m + 1)
              if sc and oc and sc.single and oc.single and SITE_NOUNS[sc.unit.form] and oc.unit.form == "of" then
                for _, onp in ipairs(P.parse_np(S, m + 2)) do
                  if onp.head_kind == "relnoun" and onp.poss_det and not onp.of_arg then
                    for _, e in ipairs(onp.relnouns) do
                      local rel = lex:get_rel(e.rel)
                      if rel and not rel.open and rel.locus and e.role == "to" then
                        out[#out + 1] = cand(rel, "locus_listed", { snp, pnp, onp }, { from = snp, to = pnp }, onp.nxt, { vp = vp, neg = vp.neg })
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  -- (d) Industry sources place the headquarters of O in C.
  for k = S.first, S.last - 3 do
    local vc = C(S, k)
    if vc and vc.single and not vc.masked and PLACE_FORMS[vc.unit.form] then
      for _, onp in ipairs(P.parse_np(S, k + 1)) do
        if onp.head_kind == "relnoun" then
          local pc = C(S, onp.nxt)
          if pc and pc.single and not pc.masked and (pc.unit.form == "in" or pc.unit.form == "at") then
            for _, vnp in ipairs(P.parse_np(S, onp.nxt + 1)) do
              if name_np(vnp) then
                for _, o in ipairs(F.locus_options(S, onp)) do
                  out[#out + 1] = cand(o.rel, "locus_placed", { onp, vnp }, { [o.known_role] = o.arg, [o.ask_role] = vnp }, vnp.nxt)
                end
              end
            end
          end
        end
      end
    end
  end
end

-- "Based in C, O is a regular name in the business pages."  "Headquartered in C, O operates ..."  (a fronted participle with a locative complement)
local function fronted_locative_participle(self, S, ctx, out)
  for _, vp in ipairs(P.parse_vp(S, S.first, { participle_ok = true })) do
    local pc = C(S, vp.nxt)
    if pc and pc.single and not pc.masked and cat(pc, "prep") then
      for _, np1 in ipairs(P.parse_np(S, vp.nxt + 1)) do
        local cj = C(S, np1.nxt)
        if cj and has_pre(cj, "comma") and name_np(np1) then
          for _, np2 in ipairs(P.parse_np(S, np1.nxt)) do
            if name_np(np2) then
              for _, e in ipairs(vp.analysis.entries or {}) do
                local rel = S.lex:get_rel(e.rel)
                if rel and not rel.open and e.prep == pc.unit.form and not e.support and not e.as_only then
                  out[#out + 1] = cand(rel, "fronted_locative", { np1, np2 }, { [e.subj] = np2, [other(e.subj)] = np1 }, np2.nxt, { vp = vp, neg = vp.neg })
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- posts:  "The post of chief executive at O is held by P."  "P holds the post of chief executive at O."
local HELD = U.set({ "held", "occupied", "filled", "taken", "assumed", "exercised", "retained", "kept" })
local ROLE_HOLD = U.set({ "hold", "occupy", "fill", "assume", "take", "have", "retain" })
local BELONG = U.set({ "belongs", "goes", "falls", "passes", "lies", "rests" })
local BELONG_PREP = U.set({ "to", "with" })
local function post_holder(self, S, ctx, out)
  -- subject = the post noun phrase
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if snp.head_kind == "relnoun" and (snp.of_arg or snp.possessor) then
      for _, o in ipairs(F.relnp_options(S, snp)) do
        if o.entry and o.entry.rolesuffix and o.arg and o.ask_role == "to" then
          local cp = H.copula_at and H.copula_at(S, snp.nxt)
          if cp then
            local hc, bc = C(S, cp.nxt), C(S, cp.nxt + 1)
            if hc and bc and hc.single and bc.single and not hc.masked and HELD[hc.unit.form] and bc.unit.form == "by" then
              for _, vnp in ipairs(P.parse_np(S, cp.nxt + 2)) do
                if name_np(vnp) then out[#out + 1] = cand(o.rel, "post_held_by", { snp, vnp }, { from = o.arg, to = vnp }, vnp.nxt, { copula = cp, neg = cp.neg }) end
              end
            end
          end
          local bc, pc = C(S, snp.nxt), C(S, snp.nxt + 1)
          if bc and pc and bc.single and pc.single and not bc.masked and BELONG[bc.unit.form] and BELONG_PREP[pc.unit.form] then
            for _, vnp in ipairs(P.parse_np(S, snp.nxt + 2)) do
              if name_np(vnp) then out[#out + 1] = cand(o.rel, "post_belongs_to", { snp, vnp }, { from = o.arg, to = vnp }, vnp.nxt) end
            end
          end
        end
      end
    end
  end
  -- subject = the holder
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if name_np(snp) then
      for _, vp in ipairs(P.parse_vp(S, snp.nxt)) do
        if vp.voice == "active" and ROLE_HOLD[vp.lemma] then
          for _, onp in ipairs(P.parse_np(S, vp.nxt)) do
            if onp.head_kind == "relnoun" and (onp.of_arg or onp.possessor) then
              for _, o in ipairs(F.relnp_options(S, onp)) do
                if o.entry and o.entry.rolesuffix and o.arg and o.ask_role == "to" then
                  out[#out + 1] = cand(o.rel, "holds_post", { snp, onp }, { from = o.arg, to = snp }, onp.nxt, { vp = vp, neg = vp.neg, tense = (vp.vform == "past" or vp.perfect) and "past" or "present" })
                end
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- "The capital city of K goes by the name of C."
local function goes_by(self, S, ctx, out)
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if snp.head_kind == "relnoun" and (snp.of_arg or snp.possessor) then
      local gc, bc = C(S, snp.nxt), C(S, snp.nxt + 1)
      if gc and bc and gc.single and bc.single and not gc.masked and (gc.unit.form == "goes" or gc.unit.form == "went") and bc.unit.form == "by" then
        local k = snp.nxt + 2
        k = F.phrase_at(S, k, "the name of") or F.phrase_at(S, k, "the name") or k
        for _, vnp in ipairs(P.parse_np(S, k)) do
          if name_np(vnp) then
            for _, o in ipairs(F.relnp_options(S, snp)) do
              if o.arg and o.rel and not o.rel.open and value_ok(o.rel, o.ask_role, vnp) then
                out[#out + 1] = cand(o.rel, "goes_by", { snp, vnp }, { [o.known_role] = o.arg, [o.ask_role] = vnp }, vnp.nxt)
              end
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- event nouns:  "The founding of O by P ..."  "The creation of O is attributed to P."  "O is the creation of P."
local ATTRIB_PHRASES = { "attributed to", "credited to", "due to", "down to", "owed to", "the work of", "the doing of", "the achievement of", "the brainchild of", "the handiwork of",
  "the responsibility of", "the accomplishment of" }
local function nominal_agent(self, S, ctx, out)
  local idx = F.deverbal_index(S.lex)
  for k = S.first, S.last do
    for _, np in ipairs(P.parse_np(S, k)) do
      local hf = np.head and np.head.single and np.head.unit.form
      if hf and idx[hf] and np.of_arg and name_np(np.of_arg) then
        local c1 = C(S, np.nxt)
        if c1 and c1.single and not c1.masked and c1.unit.form == "by" then
          for _, vnp in ipairs(P.parse_np(S, np.nxt + 1)) do
            if name_np(vnp) then
              for _, d in ipairs(idx[hf]) do
                out[#out + 1] = cand(d.rel, "nominal_by", { np, vnp }, { [d.agent] = vnp, [other(d.agent)] = np.of_arg }, vnp.nxt, { tense = "past" })
              end
            end
          end
        end
        local cp = H.copula_at and H.copula_at(S, np.nxt)
        if cp then
          local n = F.first_phrase(S, cp.nxt, ATTRIB_PHRASES)
          if n then
            for _, vnp in ipairs(P.parse_np(S, n)) do
              if name_np(vnp) then
                for _, d in ipairs(idx[hf]) do
                  out[#out + 1] = cand(d.rel, "nominal_attributed", { np, vnp }, { [d.agent] = vnp, [other(d.agent)] = np.of_arg }, vnp.nxt, { copula = cp, neg = cp.neg, tense = "past" })
                end
              end
            end
          end
        end
      end
    end
  end
  -- "O is the creation of P."
  for _, snp in ipairs(P.parse_np(S, S.first)) do
    if name_np(snp) then
      local cp = H.copula_at and H.copula_at(S, snp.nxt)
      if cp then
        for _, np in ipairs(P.parse_np(S, cp.nxt)) do
          local hf = np.head and np.head.single and np.head.unit.form
          if hf and idx[hf] and np.of_arg and name_np(np.of_arg) and (hf == "creation" or hf == "invention" or hf == "discovery" or hf == "brainchild") then
            for _, d in ipairs(idx[hf]) do
              out[#out + 1] = cand(d.rel, "creation_of", { snp, np }, { [d.agent] = np.of_arg, [other(d.agent)] = snp }, np.nxt, { copula = cp, neg = cp.neg, tense = "past" })
            end
          end
        end
      end
    end
  end
end

X.patterns = { apposition_anywhere, whose_clause, possessive_apposition, fronted_passive_by, having_clause, purpose_infinitive, credit_pattern, appositive_clauses,
  fronted_holder, have_appositive, credit_statement, as_relative, copular_object_relative, locus_statement, fronted_locative_participle, post_holder, goes_by, nominal_agent }

---------------------------------------------------------------- clause mining
local HEDGE = U.set({ "not", "no", "never", "nor", "n't", "deny", "denied", "denies", "rumor", "rumour", "rumoured", "rumored", "allegedly", "reportedly", "supposedly", "possibly",
  "perhaps", "maybe", "might", "could", "would", "may", "if", "whether", "doubt", "doubts", "myth", "false", "untrue", "wrong", "fake", "hoax", "pretend", "imagine", "suppose",
  "wish", "hope", "hoped", "wonder", "wonders", "unlikely", "probably", "claim", "claims", "claimed", "alleged", "former", "formerly", "ex", "once", "used", "previously" })
local SUBORD = U.set({ "that", "because", "since", "while", "whereas", "although", "though", "when", "where", "after", "before", "once", "so", "and", "but", "yet", "then", "which", "who", "as" })

local function span_clean(S, from, to)
  for i = from, to do
    local c = C(S, i)
    if c and c.single and c.unit and HEDGE[c.unit.form] then return false end
  end
  return true
end

-- verbs whose "that"-clause is presupposed true even when the matrix clause is negated ("Not many people know that P founded O")
local FACTIVE = U.set({ "know", "knows", "knew", "known", "realize", "realise", "realizes", "realises", "realized", "realised", "notice", "notices", "noticed", "remember", "remembers",
  "remembered", "learn", "learns", "learned", "learnt", "see", "sees", "saw", "seen", "show", "shows", "showed", "shown", "prove", "proves", "proved", "proven", "confirm", "confirms",
  "confirmed", "reveal", "reveals", "revealed", "acknowledge", "acknowledges", "acknowledged", "admit", "admits", "admitted", "mention", "mentions", "mentioned", "note", "notes",
  "noted", "recall", "recalls", "recalled", "understand", "understands", "understood", "discover", "discovers", "discovered", "remind", "reminds", "reminded", "aware", "evident", "clear", "find", "finds", "found", "finding" })
local FIRST_PERSON = U.set({ "i", "we", "me", "my", "our" })

-- the words before the clause are harmless when they only frame a presupposed fact: negation is tolerated, but not by a first person ("I don't know that ...")
local function factive_prefix(S, from, to)
  local verb = C(S, to - 1)
  local neg, first_person, factive = false, false, false
  for i = from, to - 1 do
    local c = C(S, i)
    if c and c.single and c.unit then
      local f = c.unit.form
      if f == "not" or f == "no" or f == "never" or f == "n't" or f == "nobody" or f == "few" then neg = true end
      if FIRST_PERSON[f] then first_person = true end
      if HEDGE[f] and not (f == "not" or f == "no" or f == "never" or f == "n't") then return false end
    end
  end
  if verb and verb.single and verb.unit and FACTIVE[verb.unit.form] then factive = true end
  return factive and not (neg and first_person)
end

-- candidate clause starts (chunk indices) after the first chunk; `that` after a factive verb keeps the whole matrix clause out of the hedge check
local function clause_starts(S)
  local out = {}
  for k = S.first + 1, S.last do
    local c = C(S, k)
    if c and not c.masked then
      if has_pre(c, "comma") or has_pre(c, "colon") or has_pre(c, "dash") then
        if c.single and SUBORD[c.unit.form] and k < S.last then out[#out + 1] = k + 1 else out[#out + 1] = k end
      elseif c.single and SUBORD[c.unit.form] and k < S.last and (c.unit.form == "that" or c.unit.form == "because" or c.unit.form == "since" or c.unit.form == "when" or c.unit.form == "after" or c.unit.form == "once") then
        out[#out + 1] = k + 1
        if c.unit.form == "that" and factive_prefix(S, S.first, k) then S.factive_start = S.factive_start or {}; S.factive_start[k + 1] = true end
      end
    end
  end
  return out
end

local function clause_ends(S, s, last0)
  local out = { last0 }
  for b = s + 2, last0 do
    local c = C(S, b)
    if c and not c.masked and (has_pre(c, "comma") or (c.single and (c.unit.form == "and" or c.unit.form == "but" or c.unit.form == "while" or c.unit.form == "which" or c.unit.form == "because" or c.unit.form == "so" or c.unit.form == "although"))) then
      out[#out + 1] = b - 1
    end
  end
  return out
end

-- the one name the words before a sub-clause mention: a possessive inside the sub-clause ("... that ITS currency is the X") refers to it
local function prefix_topic(S, upto)
  local found, count, seen = nil, 0, {}
  for k = S.first, upto do
    local c = C(S, k)
    if c and not c.masked then
      for _, np in ipairs(P.parse_np(S, k)) do
        if name_np(np) and np.c1 == k then
          local key = np.head and np.head.form or tostring(k)
          if not seen[key] then seen[key] = true; count = count + 1; found = np end
          break
        end
      end
    end
  end
  if count == 1 then return found end
end

-- patterns: the assertion extractor's own whole-sentence patterns (re-run on sub-clauses)
function X.mine(self, S, ctx, cands, patterns)
  local first0, last0 = S.first, S.last
  local tried = 0
  local function try_span(s, e)
    if e - s < 2 then return false end
    local prefix_ok = (S.factive_start and S.factive_start[s]) or span_clean(S, first0, s - 1)
    if not prefix_ok or not span_clean(S, e + 1, last0) then return false end
    local topic = (not S.topic) and prefix_topic(S, s - 1) or nil
    S.first, S.last = s, e
    if topic then S.topic = topic; S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {} end
    local before = #cands
    for _, pat in ipairs(patterns) do pat(self, S, ctx, cands) end
    for i = before + 1, #cands do cands[i].span = { s, e } end
    if topic then S.topic = nil; S.np_memo, S.vp_memo, S.wh_memo = {}, {}, {} end
    return #cands > before
  end
  for _, s in ipairs(clause_starts(S)) do
    for _, e in ipairs(clause_ends(S, s, last0)) do
      tried = tried + 1
      if tried > 16 then S.first, S.last = first0, last0; return end
      if try_span(s, e) then
        for _, a in ipairs(cands) do a.mined = true end
        S.first, S.last = first0, last0
        return
      end
    end
  end
  -- the leading clause alone, when text follows it after a comma / conjunction
  for _, e in ipairs(clause_ends(S, first0, last0)) do
    if e < last0 then
      tried = tried + 1
      if tried > 20 then break end
      if try_span(first0, e) then for _, a in ipairs(cands) do a.mined = true end; break end
    end
  end
  S.first, S.last = first0, last0
end

return X
