-- asi.nlu.repair: the bounded "repair" reading of a sentence.
-- A cover (segmentation) is repaired by (1) correcting UNKNOWN words to the lexicon word they are one or two edits away from -- function words,
-- verbs, relation nouns, entity names, and words inside multiword phrases ("official langugae") -- and (2) ignoring filler / disfluency words.
-- The repaired cover is NOT a replacement: it competes with the literal covers, and every hypothesis built on it carries an explicit `repair`
-- penalty (asi.nlu.sem), so the literal reading wins whenever it is at least as good.  Nothing is rewritten: the original text, the unit offsets and
-- the list of repairs are all preserved for provenance.
local U = require("asi.nlu.util")

local R = {}

local POSITION_CLASS_PRIORITY = { wh = 4, aux_do = 3, aux_be = 3, aux_have = 3, modal = 3, prep = 2, det = 2, pron = 2, pron_poss = 2, conj = 1, polite = 1 }
local MIN_CONF, MIN_ENTITY_CONF = 0.45, 0.7
local MAX_WINDOW_BEFORE, MAX_WINDOW_AFTER = 3, 3

-- ranked correction candidates for one unknown unit
local function candidates(lex, u, idx, prev_wh)
  local out = {}
  local fsp = lex:function_spell()
  local maxd = (#u.form <= 5) and 1 or 2
  for _, c in ipairs(fsp:suggest(u.form, { max_edit = maxd, limit = 6 })) do
    local conf = 0.9 - 0.3 * (c.dist - 1) - (c.first_same and 0 or 0.15)
    local prio = POSITION_CLASS_PRIORITY[c.kind] or 0
    if idx == 1 and c.kind == "wh" then prio = prio + 3 end                                              -- a sentence-initial slot wants a wh-word
    if prev_wh and (c.kind == "aux_do" or c.kind == "aux_be") then prio = prio + 3 end                    -- the slot after a wh-phrase wants an auxiliary
    out[#out + 1] = { form = c.form, dist = c.dist, conf = conf, prio = prio, class = c.kind, source = "function" }
  end
  for _, a in ipairs(u.alts or {}) do
    if a.kind ~= "entity" or (u.cap and a.conf >= MIN_ENTITY_CONF) then
      out[#out + 1] = { form = a.form, dist = a.dist, conf = a.conf, prio = 0, class = a.kind, source = "lexicon" }
    end
  end
  table.sort(out, function(x, y)
    if x.dist ~= y.dist then return x.dist < y.dist end
    if x.prio ~= y.prio then return x.prio > y.prio end
    if x.conf ~= y.conf then return x.conf > y.conf end
    return x.form < y.form
  end)
  local keep = {}
  for _, c in ipairs(out) do if c.conf >= MIN_CONF then keep[#keep + 1] = c end end
  return keep
end

-- readings of a (possibly multiword) lexicon match for a corrected span, shaped like the lattice's own readings but flagged fuzzy
local function readings_of(entries, from_raw, conf, units, i, j)
  local rs = {}
  for _, e in ipairs(entries) do
    if e.kind == "entity" and not e.cs then rs[#rs + 1] = { kind = "entity", entry = e, fuzzy = conf, fuzzy_from = from_raw }
    elseif e.kind == "relnoun" or e.kind == "relverb" then
      local ec = U.shallow(e); ec.fuzzy = conf
      rs[#rs + 1] = { kind = e.kind, entry = ec, fuzzy = conf, fuzzy_from = from_raw }
    elseif e.kind == "sense" then rs[#rs + 1] = { kind = "sense", sense = e.sense, num = e.num, fuzzy = conf, fuzzy_from = from_raw } end
  end
  return rs
end

-- multiword phrases that contain unit `ui` once it is replaced by `cand` (e.g. "official langugae" -> "official language")
local function phrase_matches(lex, units, ui, cand, conf, from_raw)
  local best
  local sent = units[ui].sent
  for s = math.max(1, ui - MAX_WINDOW_BEFORE), ui do
    if units[s].sent == sent then
      local win = {}
      for k = s, math.min(#units, ui + MAX_WINDOW_AFTER) do
        if units[k].sent ~= sent then break end
        win[#win + 1] = { form = (k == ui) and cand or units[k].form, pre = units[k].pre }
      end
      for _, m in ipairs(lex:match_at(win, 1)) do
        local e = s + m.j - 1
        if e >= ui and e > s then
          local rs = readings_of(m.entries, from_raw, conf)
          if #rs > 0 and (not best or (e - s) > (best.j - best.i)) then best = { i = s, j = e, readings = rs } end
        end
      end
    end
  end
  return best
end

-- returns a repaired cover { score, spans, repair = true, repairs = {...} } or nil
function R.repair_cover(lex, units, cover, original)
  local spans = cover.spans
  local repairs = {}
  local drop, replace, inserts = {}, {}, {}      -- drop[idx]=true; replace[idx]=span; inserts = multiword spans that supersede several spans
  local unit_span = {}
  for idx, sp in ipairs(spans) do for k = sp.i, sp.j do unit_span[k] = idx end end
  local prev_wh = false
  for idx, sp in ipairs(spans) do
    local u = units[sp.i]
    local multi_name = sp.kind == "name_guess" and sp.j > sp.i and u.kind == "word" and (sp.i == 1 or units[sp.i - 1].sent ~= u.sent)
    if (sp.i == sp.j or multi_name) and u.kind == "word" and not drop[idx] and not replace[idx] then
      local cats = lex:cats(u.form)
      local only_fuzzy = true
      for _, r in ipairs(sp.readings) do if not r.fuzzy and r.kind ~= "name" then only_fuzzy = false end end
      local unknown = (not cats or not next(cats)) and #lex:readings(u.form) == 0 and only_fuzzy
        and ((sp.kind == "word" or sp.kind == "word_sense" or sp.kind == "entity") or (sp.kind == "name_guess" and (multi_name or (sp.readings[1] and sp.readings[1].weak))))
      if cats and cats.ignorable and not (#spans == 1) and sp.i == sp.j then
        repairs[#repairs + 1] = { kind = "ignored", word = u.raw, unit = sp.i }
        drop[idx] = true
      elseif unknown and #u.form >= 3 then
        local cands = candidates(lex, u, idx, prev_wh)
        local chosen = cands[1]
        -- a capitalised sentence-initial word swallowed by a multiword name guess ("Comoare Company A") is split off only for a NON-entity correction
        if chosen and multi_name and chosen.class == "entity" then chosen = nil end
        if chosen and multi_name then
          local rest = sp.readings[1] or {}
          local rr = {}
          for k2, v2 in pairs(rest) do rr[k2] = v2 end
          rr.multiword = (sp.j - 1) > sp.i
          rr.text = original and original:sub(units[sp.i + 1].s, units[sp.j].e) or rr.text
          rr.weak = nil
          inserts[#inserts + 1] = { i = sp.i + 1, j = sp.j, kind = "name_guess", readings = { rr }, score = sp.score, text = rr.text }
          replace[idx] = { i = sp.i, j = sp.i, kind = "word", readings = {}, score = sp.score, text = original and original:sub(u.s, u.e) or u.raw,
            fnword = { from = u.raw, to = chosen.form, dist = chosen.dist, class = chosen.class } }
          repairs[#repairs + 1] = { kind = (chosen.source == "function") and "function_word" or "word", from = u.raw, to = chosen.form, dist = chosen.dist, conf = chosen.conf, unit = sp.i }
          chosen = nil
        end
        if chosen then
          -- a multiword phrase that the correction completes takes priority over the single word
          local ph = phrase_matches(lex, units, sp.i, chosen.form, chosen.conf, u.raw)
          local ok_phrase = false
          if ph then
            local clash = false
            for k = ph.i, ph.j do
              local oi = unit_span[k]
              local os = spans[oi]
              if os.i < ph.i or os.j > ph.j or drop[oi] or replace[oi] then clash = true end
            end
            if not clash then
              for k = ph.i, ph.j do local oi = unit_span[k]; if oi ~= idx then drop[oi] = true end end
              ph.kind, ph.score = "mwe", sp.score
              ph.text = original and original:sub(units[ph.i].s, units[ph.j].e) or ""
              ph.fnword = { from = u.raw, to = chosen.form, dist = chosen.dist, class = chosen.class, phrase = true, unit = sp.i }
              replace[idx] = ph
              ok_phrase = true
              repairs[#repairs + 1] = { kind = "phrase_word", from = u.raw, to = chosen.form, dist = chosen.dist, conf = chosen.conf, unit = sp.i }
            end
          end
          if not ok_phrase then
            local entries = {}
            for _, m in ipairs(lex:match_at({ { form = chosen.form } }, 1)) do
              if m.j == 1 then for _, e in ipairs(m.entries) do entries[#entries + 1] = e end end
            end
            local rs = readings_of(entries, u.raw, chosen.conf)
            -- an entity needs a capitalised surface; a function word / verb needs none
            if chosen.class == "entity" and not u.cap then rs = {} end
            local fn = (lex:cats(chosen.form) and next(lex:cats(chosen.form))) or #lex:readings(chosen.form) > 0 or #rs > 0
            if fn then
              replace[idx] = { i = sp.i, j = sp.j, kind = (#rs > 0) and "word_sense" or "word", readings = rs, score = sp.score, text = sp.text,
                fnword = { from = u.raw, to = chosen.form, dist = chosen.dist, class = chosen.class } }
              repairs[#repairs + 1] = { kind = (chosen.source == "function") and "function_word" or "word", from = u.raw, to = chosen.form, dist = chosen.dist, conf = chosen.conf, unit = sp.i }
            end
          end
        end
      end
    end
    local eff = replace[idx]
    local cc = eff and eff.fnword and lex:cats(eff.fnword.to) or (sp.i == sp.j and lex:cats(u.form)) or nil
    if not drop[idx] then prev_wh = (cc and cc.wh) and true or false end
  end
  if #repairs == 0 then return nil end
  local out = {}
  for idx, sp in ipairs(spans) do
    if not drop[idx] then out[#out + 1] = replace[idx] or sp end
  end
  for _, sp in ipairs(inserts) do out[#out + 1] = sp end
  -- a replacement span may now overlap spans that were dropped for it; order by start unit
  table.sort(out, function(a, b) return a.i < b.i end)
  -- the repaired reading owns a copy of the unit array in which corrected words carry their corrected FORM (offsets, raw text and everything else are
  -- inherited from the original unit), so cue phrases, closed-class lookups and phrase matching all see the corrected word
  local units2 = {}
  for k, u in ipairs(units) do units2[k] = u end
  for _, sp in ipairs(out) do
    if sp.fnword and sp.i == sp.j then
      units2[sp.i] = setmetatable({ form = sp.fnword.to, lower = sp.fnword.to, surface_form = units[sp.i].form, repaired = true }, { __index = units[sp.i] })
    elseif sp.fnword and sp.fnword.phrase then
      local k = sp.fnword.unit
      units2[k] = setmetatable({ form = sp.fnword.to, lower = sp.fnword.to, surface_form = units[k].form, repaired = true }, { __index = units[k] })
    end
  end
  return { score = cover.score, spans = out, repair = true, repairs = repairs, units = units2 }
end

return R
