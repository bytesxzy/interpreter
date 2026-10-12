-- asi.nlu.temporal: numbers, dates, intervals, relative time, persistence markers over lexer units.
-- Pure function of the analysis (+ optional opts.now = {y,m,d}); no clock access => deterministic and replayable.
-- Comparable key: K = y*10000 + m*100 + d  (monotone for negative years too).
local U = require("asi.nlu.util")

local T = {}

---------------------------------------------------------------- keys
function T.key(y, m, d) return y * 10000 + (m or 0) * 100 + (d or 0) end
function T.lo_key(p) return T.key(p.y, p.m or 1, p.d or 1) end
function T.hi_key(p)
  local m, d = p.m or 12, p.d
  if not d then
    local dim = { 31, ((p.y % 4 == 0 and p.y % 100 ~= 0) or p.y % 400 == 0) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    d = dim[m]
  end
  return T.key(p.y, m, d)
end
function T.overlaps(alo, ahi, blo, bhi)
  alo, blo = alo or -math.huge, blo or -math.huge
  ahi, bhi = ahi or math.huge, bhi or math.huge
  return alo <= bhi and blo <= ahi
end
-- parse "YYYY", "YYYY-MM", "YYYY-MM-DD" (optionally with time suffix) into {y,m,d,precision}
function T.parse_iso(s)
  if type(s) ~= "string" then return nil end
  local y, m, d = s:match("^(%-?%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then return { y = tonumber(y), m = tonumber(m), d = tonumber(d), precision = "day" } end
  y, m = s:match("^(%-?%d%d%d%d)%-(%d%d)$")
  if y then return { y = tonumber(y), m = tonumber(m), precision = "month" } end
  y = s:match("^(%-?%d%d%d%d)$")
  if y then return { y = tonumber(y), precision = "year" } end
end

---------------------------------------------------------------- vocabulary
local MONTH = { january = 1, jan = 1, february = 2, feb = 2, march = 3, mar = 3, april = 4, apr = 4, may = 5, june = 6, jun = 6,
  july = 7, jul = 7, august = 8, aug = 8, september = 9, sep = 9, sept = 9, october = 10, oct = 10, november = 11, nov = 11,
  december = 12, dec = 12 }
local WEEKDAY = { monday = 1, tuesday = 2, wednesday = 3, thursday = 4, friday = 5, saturday = 6, sunday = 7 }
local SMALL = { zero = 0, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
  eleven = 11, twelve = 12, thirteen = 13, fourteen = 14, fifteen = 15, sixteen = 16, seventeen = 17, eighteen = 18, nineteen = 19 }
local TENS = { twenty = 20, thirty = 30, forty = 40, fifty = 50, sixty = 60, seventy = 70, eighty = 80, ninety = 90 }
local MAG = { thousand = 1000, million = 1000000, billion = 1000000000, trillion = 1000000000000 }
local ORD_SMALL = { first = 1, second = 2, third = 3, fourth = 4, fifth = 5, sixth = 6, seventh = 7, eighth = 8, ninth = 9, tenth = 10,
  eleventh = 11, twelfth = 12, thirteenth = 13, fourteenth = 14, fifteenth = 15, sixteenth = 16, seventeenth = 17, eighteenth = 18,
  nineteenth = 19, twentieth = 20, thirtieth = 30, fortieth = 40, fiftieth = 50, sixtieth = 60, seventieth = 70, eightieth = 80,
  ninetieth = 90, hundredth = 100, thousandth = 1000 }
local DECADE_WORD = { twenties = 20, thirties = 30, forties = 40, fifties = 50, sixties = 60, seventies = 70, eighties = 80, nineties = 90 }
local TIME_UNIT = { second = "second", seconds = "second", minute = "minute", minutes = "minute", hour = "hour", hours = "hour",
  day = "day", days = "day", week = "week", weeks = "week", fortnight = "fortnight", month = "month", months = "month",
  quarter = "quarter", quarters = "quarter", year = "year", years = "year", decade = "decade", decades = "decade",
  century = "century", centuries = "century" }
local TEMP_PREP = U.set({ "in", "during", "since", "until", "till", "before", "after", "by", "from", "to", "circa", "around", "between",
  "through", "throughout", "of", "within", "over", "as", "prior", "following", "c", "approximately", "about", "and", "or", "than" })
local LABEL_NOUN = U.set({ "dataset", "data", "version", "edition", "report", "release", "model", "census", "survey", "study", "table",
  "file", "document", "paper", "budget", "figures", "numbers", "statement", "statements", "archive", "snapshot", "update", "build",
  "season", "election", "olympics", "games", "cup", "championship", "tournament", "conference", "prize", "award", "annual", "fiscal",
  "yearbook", "almanac", "ranking", "rankings", "index", "list", "catalog", "catalogue", "corpus", "benchmark", "revision", "draft" })

local PRESENT_WORDS = U.set({ "now", "currently", "presently", "nowadays", "today", "current", "latest", "ongoing", "existing" })
local PAST_WORDS = U.set({ "formerly", "previously", "former", "previous", "historically", "historical", "historic", "ancient",
  "past", "earlier", "original", "originally", "once", "old", "defunct", "bygone", "erstwhile", "ex" })
local FUTURE_WORDS = U.set({ "future", "upcoming", "soon", "planned", "forthcoming", "tomorrow", "eventually", "prospective" })

---------------------------------------------------------------- helpers over units
local function fm(units, i) local u = units[i]; return u and u.form or nil end

-- integer value of a plain integer number unit (digits), else nil
local function int_at(units, i)
  local u = units[i]
  if not u or u.kind ~= "number" or u.unit or u.numval == nil then return nil end
  local v = math.tointeger(u.numval)
  return v
end

-- ordinal value starting at unit i -> value, number_of_units  (handles "twenty-first")
local function ord_at(units, i)
  local u = units[i]
  if not u then return nil end
  if u.kind == "ordinal" then return math.tointeger(u.ordinal), 1 end
  if u.hy and u.hy_first and TENS[u.form] then
    local nx = units[i + 1]
    if nx and nx.hy and nx.hy_last and ORD_SMALL[nx.form] and ORD_SMALL[nx.form] < 10 then return TENS[u.form] + ORD_SMALL[nx.form], 2 end
  end
  if u.kind == "word" and ORD_SMALL[u.form] and not (u.hy and u.hy_last) then return ORD_SMALL[u.form], 1 end
end

---------------------------------------------------------------- civil-date arithmetic (Hinnant)
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
local function civil_from_days(z)
  z = z + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  return y, m, d
end
local function dim(y, m)
  return ({ 31, ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
end
-- add n units to a {y,m,d} date -> {y,m,d}
function T.add(p, n, unit)
  if unit == "day" then local y, m, d = civil_from_days(days_from_civil(p.y, p.m, p.d) + n); return { y = y, m = m, d = d } end
  if unit == "week" then return T.add(p, 7 * n, "day") end
  if unit == "fortnight" then return T.add(p, 14 * n, "day") end
  local months = ({ month = 1, quarter = 3, year = 12, decade = 120, century = 1200 })[unit]
  if not months then return nil end
  local total = p.y * 12 + (p.m - 1) + months * n
  local y, m = total // 12, total % 12 + 1
  return { y = y, m = m, d = math.min(p.d, dim(y, m)) }
end

-- cardinal number words starting at i -> value, next_i
local function numwords_at(units, i)
  local total, cur, consumed, j = 0, 0, false, i
  local last_big = false
  while true do
    local w = fm(units, j)
    local u = units[j]
    if not w or (u.kind ~= "word" and u.kind ~= "number") or u.kind == "number" then break end
    if SMALL[w] then
      if consumed and cur % 10 ~= 0 and cur < 100 and not (cur >= 100) and cur ~= 0 and not (cur % 100 >= 20 and cur % 10 == 0) then break end
      cur = cur + SMALL[w]; consumed = true; last_big = false
    elseif TENS[w] then
      if consumed and cur % 100 ~= 0 then break end
      cur = cur + TENS[w]; consumed = true; last_big = false
    elseif w == "hundred" and (consumed or fm(units, j - 1) == "a") then
      cur = (cur == 0 and 1 or cur) * 100; consumed = true; last_big = true
    elseif MAG[w] and (consumed or fm(units, j - 1) == "a") then
      total = total + (cur == 0 and 1 or cur) * MAG[w]; cur = 0; consumed = true; last_big = true
    elseif w == "and" and consumed and last_big and (SMALL[fm(units, j + 1) or ""] or TENS[fm(units, j + 1) or ""]) then
      -- "one hundred and five"
    elseif w == "a" and (fm(units, j + 1) == "hundred" or MAG[fm(units, j + 1) or ""] or fm(units, j + 1) == "dozen") then
      -- handled by the following word
      if consumed then break end
    elseif w == "dozen" and (consumed or fm(units, j - 1) == "a") then
      cur = (cur == 0 and 1 or cur) * 12; consumed = true; last_big = true
    else break end
    j = j + 1
  end
  if not consumed then return nil end
  -- strip trailing "and"/"a" that were consumed without a number after them
  while j > i and (fm(units, j - 1) == "and" or fm(units, j - 1) == "a") do j = j - 1 end
  if j == i then return nil end
  return total + cur, j
end

---------------------------------------------------------------- expression construction
local function span(an, i, j)
  local a, b = an.units[i], an.units[j]
  return a.s, b.e
end

local function mkexpr(an, kind, i, j, extra)
  local s, e = span(an, i, j)
  local ex = { kind = kind, u1 = i, u2 = j, s = s, e = e, text = an.original:sub(s, e) }
  for k, v in pairs(extra or {}) do ex[k] = v end
  return ex
end

local function point_bounds(p)
  return T.lo_key(p), T.hi_key(p)
end

local function set_bounds(ex, p)
  ex.lo_p, ex.hi_p = p, p
  ex.lo, ex.hi = point_bounds(p)
  ex.precision = p.precision
end

local function valid_day(y, m, d)
  if m < 1 or m > 12 or d < 1 then return false end
  local dim = { 31, ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return d <= dim[m]
end

---------------------------------------------------------------- the pass
function T.annotate(an, opts)
  opts = opts or {}
  local units = an.units
  local N = #units
  local exprs, numbers = {}, {}
  local used = {} -- unit index -> expression (first writer wins by priority order)
  local now = opts.now
  local function claim(ex)
    for k = ex.u1, ex.u2 do if used[k] then return false end end
    for k = ex.u1, ex.u2 do used[k] = ex end
    exprs[#exprs + 1] = ex
    return true
  end

  ---- numbers (digits already carry numval; add number words + ordinals)
  local i = 1
  while i <= N do
    local u = units[i]
    if u.kind == "number" and u.numval ~= nil and not u.year_skip then
      numbers[#numbers + 1] = { u1 = i, u2 = i, value = u.numval, kind = "digit", unit = u.unit, text = u.raw }
      i = i + 1
    elseif u.kind == "ordinal" then
      numbers[#numbers + 1] = { u1 = i, u2 = i, value = u.ordinal, kind = "ordinal", text = u.raw }
      i = i + 1
    elseif u.kind == "word" then
      local o, ospan = ord_at(units, i) -- ordinals first so "twenty-first" is 21, not cardinal 20 + ordinal 1
      local v, j
      if not o then v, j = numwords_at(units, i) end
      if o then
        local last = i + ospan - 1
        numbers[#numbers + 1] = { u1 = i, u2 = last, value = o, kind = "ordinal", text = an.original:sub(units[i].s, units[last].e) }
        for k = i, last do units[k].ordinal = o end
        i = last + 1
      elseif v then
        local ent = { u1 = i, u2 = j - 1, value = v, kind = "cardinal", text = an.original:sub(units[i].s, units[j - 1].e) }
        if u.form == "one" then ent.maybe_pronoun = true end
        numbers[#numbers + 1] = ent
        for k = i, j - 1 do units[k].numval = units[k].numval or v; units[k].numword = true end
        i = j
      else i = i + 1 end
    else i = i + 1 end
  end
  an.numbers = numbers

  local function year_ok(v) return v and v >= 1000 and v <= 2999 end

  ---- dates / periods, highest-priority patterns first
  for idx = 1, N do
    local u = units[idx]
    if not used[idx] then
      local ex
      -- token-level date forms
      if u.kind == "isodate" then
        local p = T.parse_iso(u.raw)
        if p and valid_day(p.y, p.m, p.d) then
          ex = mkexpr(an, "date", idx, idx, {}); set_bounds(ex, p)
        end
      elseif u.kind == "slashdate" then
        local a, b, c = u.raw:match("^(%d+)/(%d+)/(%d+)$")
        if a then
          a, b, c = tonumber(a), tonumber(b), tonumber(c)
          if #u.raw:match("^(%d+)") == 4 then ex = mkexpr(an, "date", idx, idx, {}); set_bounds(ex, { y = a, m = b, d = c, precision = "day" })
          else
            if c < 100 then c = c + (c < 50 and 2000 or 1900) end
            local opts2 = {}
            if a > 12 and b <= 12 then opts2 = { { y = c, m = b, d = a } }
            elseif b > 12 and a <= 12 then opts2 = { { y = c, m = a, d = b } }
            elseif a <= 12 and b <= 12 then opts2 = { { y = c, m = a, d = b }, { y = c, m = b, d = a } } end
            if #opts2 >= 1 and valid_day(opts2[1].y, opts2[1].m, opts2[1].d) then
              local p = opts2[1]; p.precision = "day"
              ex = mkexpr(an, "date", idx, idx, { ambiguous = #opts2 > 1 or nil })
              set_bounds(ex, p)
              if #opts2 > 1 then ex.alts = { { y = c, m = opts2[2].m, d = opts2[2].d, precision = "day" } }; ex.note = "mm/dd vs dd/mm unresolved" end
            end
          end
        end
      elseif u.kind == "dotdate" then
        local d, m, y = u.raw:match("^(%d+)%.(%d+)%.(%d+)$")
        if d and valid_day(tonumber(y), tonumber(m), tonumber(d)) then
          ex = mkexpr(an, "date", idx, idx, {}); set_bounds(ex, { y = tonumber(y), m = tonumber(m), d = tonumber(d), precision = "day" })
        end
      elseif u.kind == "decade" then
        if u.decade then
          ex = mkexpr(an, "decade", idx, idx, { lo = T.key(u.decade, 1, 1), hi = T.key(u.decade + 9, 12, 31), precision = "decade" })
        else
          ex = mkexpr(an, "decade", idx, idx, { precision = "decade", unresolved = "century unknown", decade2 = u.decade2 })
        end
      elseif u.kind == "time" then
        local h, mi, ap = u.raw:match("^(%d+):?(%d*)[%s]*([aApP][mM]?)")
        ex = mkexpr(an, "time", idx, idx, { precision = "time" })
        if h then
          h = tonumber(h)
          if ap and (ap:lower():sub(1, 1) == "p") and h < 12 then h = h + 12 elseif ap and ap:lower():sub(1, 1) == "a" and h == 12 then h = 0 end
          ex.hour, ex.minute = h, tonumber(mi) or 0
        else
          local hh, mm = u.raw:match("^(%d+):(%d+)")
          ex.hour, ex.minute = tonumber(hh), tonumber(mm)
        end
      end
      if ex then claim(ex) end
    end
  end

  -- month-name / day-led / quarter / century / BC-AD / year patterns
  local function month_val(idx)
    local w = fm(units, idx)
    local m = w and MONTH[w]
    if not m then return nil end
    local u = units[idx]
    if u.kind ~= "word" and u.kind ~= "abbrev" then return nil end
    return m, u
  end
  local function is_may_modal(idx, next_is_num)
    -- "may" is a month only with a following day/year or a temporal preposition before it
    if fm(units, idx) ~= "may" then return false end
    if next_is_num then return false end
    local prev = fm(units, idx - 1)
    if prev and (prev == "in" or prev == "during" or prev == "since" or prev == "until" or prev == "by" or prev == "of" or prev == "from"
      or prev == "before" or prev == "after" or prev == "last" or prev == "next" or prev == "this" or prev == "early" or prev == "late" or prev == "mid") then
      return false
    end
    return not units[idx].cap or idx == 1 or units[idx].line_start or true
  end

  for idx = 1, N do
    if not used[idx] then
      local ex
      local m = month_val(idx)
      local u = units[idx]
      -- Month [D] [,] [Y] / Month Y
      if m and (u.cap or u.kind == "abbrev" or (fm(units, idx - 1) and (TEMP_PREP[fm(units, idx - 1)] or false))) then
        local j = idx
        local d, y
        local nx = idx + 1
        local dv, dspan = int_at(units, nx), 1
        if not dv then dv, dspan = ord_at(units, nx) end
        if dv and dv >= 1 and dv <= 31 then
          -- Month D (a 4-digit "May 2020" fails the <=31 test and falls through to the year branch)
          d = dv; j = nx + (dspan or 1) - 1
          local ny = j + 1
          local yv = int_at(units, ny)
          if year_ok(yv) then y = yv; j = ny end
        elseif year_ok(int_at(units, nx)) then
          y = int_at(units, nx); j = nx
        end
        if idx == 1 or not (fm(units, idx) == "may" and not d and not y and is_may_modal(idx, false)) then
          if d or y or (u.cap or TEMP_PREP[fm(units, idx - 1) or ""]) then
            if fm(units, idx) == "may" and not d and not y and not TEMP_PREP[fm(units, idx - 1) or ""] then
              -- bare "May" with no cue: leave as an alternative reading
              u.alt_month = m
            else
              if d and y and not valid_day(y, m, d) then d = nil; j = idx + (y and 1 or 0) end
              local p = { y = y, m = m, d = d, precision = d and "day" or (y and "month" or "month_of_year") }
              ex = mkexpr(an, "date", idx, j, {})
              if y then set_bounds(ex, p) else ex.month = m; ex.precision = "month_of_year"; ex.kind = "month" end
              if d and not y then ex.day = d; ex.kind = "date_noyear" end
            end
          end
        end
      end
      -- D(th) [of] Month [,] [Y]
      if not ex then
        local dv, dspan = ord_at(units, idx)
        if not dv and units[idx].kind == "number" then dv, dspan = int_at(units, idx), 1 end
        if dv and dv >= 1 and dv <= 31 then
          local nx = idx + (dspan or 1)
          if fm(units, nx) == "of" then nx = nx + 1 end
          local mm = month_val(nx)
          if mm and (units[nx].cap or units[nx].kind == "abbrev" or fm(units, nx) ~= "may") then
            local j, y = nx, nil
            local yv = int_at(units, nx + 1)
            if year_ok(yv) then y = yv; j = nx + 1 end
            if y and valid_day(y, mm, dv) then
              ex = mkexpr(an, "date", idx, j, {}); set_bounds(ex, { y = y, m = mm, d = dv, precision = "day" })
            elseif not y then
              ex = mkexpr(an, "date_noyear", idx, j, { month = mm, day = dv, precision = "day_of_year" })
            end
          end
        end
      end
      -- quarters / fiscal / half
      if not ex then
        local w = u.form
        local q = w:match("^q([1-4])$")
        local h = w:match("^h([12])$")
        local fy = w:match("^fy(%d%d%d%d)$") or (w == "fy" and int_at(units, idx + 1) and tostring(int_at(units, idx + 1)))
        if q or h then
          local yv = int_at(units, idx + 1)
          local lo_m, hi_m = (q and ((tonumber(q) - 1) * 3 + 1) or ((tonumber(h) - 1) * 6 + 1)), (q and (tonumber(q) * 3) or (tonumber(h) * 6))
          if year_ok(yv) then
            ex = mkexpr(an, "quarter", idx, idx + 1, { precision = "quarter" })
            ex.lo, ex.hi = T.key(yv, lo_m, 1), T.hi_key({ y = yv, m = hi_m })
          else
            ex = mkexpr(an, "quarter", idx, idx, { precision = "quarter", unresolved = "year missing", months = { lo_m, hi_m } })
          end
        elseif fy and year_ok(tonumber(fy)) then
          local yv = tonumber(fy)
          ex = mkexpr(an, "fiscal_year", idx, w == "fy" and idx + 1 or idx, { precision = "year", note = "fiscal calendar not assumed; treated as calendar year" })
          ex.lo, ex.hi = T.key(yv, 1, 1), T.key(yv, 12, 31)
        end
      end
      -- N-th century [BC|AD]
      if not ex then
        local ov, ospan = ord_at(units, idx)
        if ov and fm(units, idx + (ospan or 1)) == "century" then
          local j = idx + (ospan or 1)
          local bc = false
          local nx = fm(units, j + 1)
          if nx == "bc" or nx == "bce" then bc = true; j = j + 1 elseif nx == "ad" or nx == "ce" then j = j + 1 end
          local lo_y, hi_y
          if bc then lo_y, hi_y = -(ov * 100), -((ov - 1) * 100 + 1) else lo_y, hi_y = (ov - 1) * 100 + 1, ov * 100 end
          local start = idx
          local pre = fm(units, idx - 1)
          local mod = (pre == "early" or pre == "mid" or pre == "late") and pre or nil
          if mod then start = idx - 1
            local span_y = hi_y - lo_y
            if mod == "early" then hi_y = lo_y + 33 elseif mod == "late" then lo_y = hi_y - 33 else lo_y, hi_y = lo_y + 33, hi_y - 33 end
          end
          local s_i = units[start] and start or idx
          ex = mkexpr(an, "century", s_i, j, { precision = "century", lo = T.key(lo_y, 1, 1), hi = T.key(hi_y, 12, 31), century = ov, bc = bc or nil })
        end
      end
      -- N BC/BCE/AD/CE and AD N
      if not ex then
        local yv = int_at(units, idx)
        local nx = fm(units, idx + 1)
        if yv and yv > 0 and yv < 10000 and (nx == "bc" or nx == "bce") then
          ex = mkexpr(an, "year", idx, idx + 1, { precision = "year", lo = T.key(-yv, 1, 1), hi = T.key(-yv, 12, 31), year = -yv, role = "scope", era = "bc" })
        elseif yv and yv > 0 and yv < 10000 and (nx == "ad" or nx == "ce") then
          ex = mkexpr(an, "year", idx, idx + 1, { precision = "year", lo = T.key(yv, 1, 1), hi = T.key(yv, 12, 31), year = yv, role = "scope", era = "ad" })
        elseif (fm(units, idx) == "ad") and int_at(units, idx + 1) then
          local y2 = int_at(units, idx + 1)
          ex = mkexpr(an, "year", idx, idx + 1, { precision = "year", lo = T.key(y2, 1, 1), hi = T.key(y2, 12, 31), year = y2, role = "scope", era = "ad" })
        end
      end
      -- "9 am" / "3 pm"
      if not ex and units[idx].kind == "number" then
        local hv, ap = int_at(units, idx), fm(units, idx + 1)
        if hv and hv >= 1 and hv <= 12 and (ap == "am" or ap == "pm") then
          local h = hv
          if ap == "pm" and h < 12 then h = h + 12 elseif ap == "am" and h == 12 then h = 0 end
          ex = mkexpr(an, "time", idx, idx + 1, { precision = "time", hour = h, minute = 0 })
        end
      end
      -- plain year
      if not ex and units[idx].kind == "number" then
        local yv = int_at(units, idx)
        if year_ok(yv) and not units[idx].signed and not (units[idx].numtext and units[idx].numtext:find("[%.e]")) then
          local prev = fm(units, idx - 1)
          local nxt = fm(units, idx + 1)
          local role, conf = "ambiguous", 0.45
          if nxt and LABEL_NOUN[nxt] then role, conf = "label", 0.7
          elseif prev and TEMP_PREP[prev] and prev ~= "and" and prev ~= "or" and prev ~= "than" and prev ~= "of" then role, conf = "scope", 0.9
          elseif prev == "and" and exprs[#exprs] and exprs[#exprs].op_hint == "between" then role, conf = "scope", 0.85
          elseif prev == "of" and (fm(units, idx - 2) == "year" or fm(units, idx - 2) == "end" or fm(units, idx - 2) == "start") then role, conf = "scope", 0.85
          elseif nxt and (nxt == "to" or nxt == "through" or nxt == "until" or nxt == "till") and year_ok(int_at(units, idx + 2)) then role, conf = "scope", 0.8
          elseif units[idx].line_start or not prev then role, conf = "ambiguous", 0.5 end
          if nxt and (nxt == "people" or nxt == "users" or nxt == "employees" or nxt == "dollars" or nxt == "units" or nxt == "items"
            or nxt == "customers" or nxt == "words" or nxt == "times" or nxt == "miles" or nxt == "feet" or nxt == "meters" or nxt == "km") then
            role, conf = "quantity", 0.2
          end
          if role ~= "quantity" then
            ex = mkexpr(an, "year", idx, idx, { precision = "year", year = yv, lo = T.key(yv, 1, 1), hi = T.key(yv, 12, 31), role = role, confidence = conf })
          end
        end
      end
      -- number-word decades ("the nineties")
      if not ex and DECADE_WORD[fm(units, idx) or ""] and fm(units, idx - 1) == "the" then
        ex = mkexpr(an, "decade", idx, idx, { precision = "decade", unresolved = "century unknown", decade2 = DECADE_WORD[fm(units, idx)] })
      end
      if ex then claim(ex) end
    end
  end

  ---- relative / present-past-future / durations / persistence markers
  local REL_UNIT = { year = true, month = true, week = true, quarter = true, decade = true, century = true, day = true }
  if now then now = { y = now.y, m = now.m or 1, d = now.d or 1 } end
  local function period(p, unit) -- bounds of the calendar period containing p
    if unit == "day" then local k = T.key(p.y, p.m, p.d); return k, k end
    if unit == "week" or unit == "fortnight" then
      local z = days_from_civil(p.y, p.m, p.d)
      local wd = (z + 3) % 7 -- 0 = Monday
      local y1, m1, d1 = civil_from_days(z - wd)
      local y2, m2, d2 = civil_from_days(z - wd + 6)
      return T.key(y1, m1, d1), T.key(y2, m2, d2)
    end
    if unit == "month" then return T.key(p.y, p.m, 1), T.hi_key({ y = p.y, m = p.m }) end
    if unit == "quarter" then local q0 = (p.m - 1) // 3 * 3 + 1; return T.key(p.y, q0, 1), T.hi_key({ y = p.y, m = q0 + 2 }) end
    if unit == "year" then return T.key(p.y, 1, 1), T.key(p.y, 12, 31) end
    if unit == "decade" then local d0 = p.y // 10 * 10; return T.key(d0, 1, 1), T.key(d0 + 9, 12, 31) end
    if unit == "century" then local c = (p.y - 1) // 100; return T.key(c * 100 + 1, 1, 1), T.key((c + 1) * 100, 12, 31) end
  end
  local function set_resolved(ex, lo, hi)
    if lo then ex.lo, ex.hi, ex.eff_lo, ex.eff_hi, ex.resolved = lo, hi, lo, hi, true else ex.resolved = false end
  end
  local function resolve_offset(ex, off, unit) -- this/last/next X, yesterday/tomorrow, N units ago
    if not now then ex.resolved = false; return end
    local p = T.add(now, off, unit)
    if not p then ex.resolved = false; return end
    set_resolved(ex, period(p, unit))
  end
  local function resolve_duration(ex) -- "the last 5 years" / "in 10 days": anchored interval around now
    if not now then ex.resolved = false; return end
    local k_now = T.key(now.y, now.m, now.d)
    if ex.scope == "future" then local p = T.add(now, ex.n, ex.unit); if p then set_resolved(ex, k_now, T.key(p.y, p.m, p.d)) end
    elseif ex.scope == "past" then local p = T.add(now, -ex.n, ex.unit); if p then set_resolved(ex, T.key(p.y, p.m, p.d), k_now) end end
  end
  for idx = 1, N do
    if not used[idx] then
      local w, ex = units[idx].form, nil
      local w2, w3 = fm(units, idx + 1), fm(units, idx + 2)
      if (w == "this" or w == "last" or w == "next" or w == "previous" or w == "past" or w == "coming" or w == "current") and w2 and REL_UNIT[w2] then
        local off = (w == "this" or w == "current") and 0 or ((w == "next" or w == "coming") and 1 or -1)
        ex = mkexpr(an, "relative", idx, idx + 1, { relative = w .. "_" .. w2, offset = off, unit = w2, scope = off == 0 and "present" or (off < 0 and "past" or "future") })
        resolve_offset(ex, off, w2)
      elseif (w == "the" and (w2 == "past" or w2 == "last" or w2 == "previous") and (numwords_at(units, idx + 2) or int_at(units, idx + 2))) then
        -- "the past 5 years" / "the last three months"
        local v, j = numwords_at(units, idx + 2)
        if not v then v, j = int_at(units, idx + 2), idx + 3 end
        local unit = TIME_UNIT[fm(units, j) or ""]
        if v and unit then
          ex = mkexpr(an, "duration", idx, j, { n = v, unit = unit, anchored = "now", scope = "past", relative = "past_n" })
          resolve_duration(ex)
        end
      elseif (w == "last" or w == "past" or w == "previous" or w == "next" or w == "coming") and (numwords_at(units, idx + 1) or int_at(units, idx + 1)) then
        local v, j = numwords_at(units, idx + 1)
        if not v then v, j = int_at(units, idx + 1), idx + 2 end
        local unit = TIME_UNIT[fm(units, j) or ""]
        if v and unit then
          ex = mkexpr(an, "duration", idx, j, { n = v, unit = unit, anchored = "now", scope = (w == "next" or w == "coming") and "future" or "past", relative = "n_units" })
          resolve_duration(ex)
        end
      elseif numwords_at(units, idx) or int_at(units, idx) then
        local v, j = numwords_at(units, idx)
        if not v then v, j = int_at(units, idx), idx + 1 end
        local unit = TIME_UNIT[fm(units, j) or ""]
        if v and unit and fm(units, j + 1) == "ago" then
          ex = mkexpr(an, "relative", idx, j + 1, { relative = "ago", n = v, unit = unit, scope = "past" })
          resolve_offset(ex, -v, unit)
        elseif v and unit and (fm(units, idx - 1) == "for" or fm(units, idx - 1) == "within" or fm(units, idx - 1) == "over" or fm(units, idx - 1) == "in") then
          local prep = fm(units, idx - 1)
          ex = mkexpr(an, "duration", idx, j, { n = v, unit = unit, scope = prep == "in" and "future" or (prep == "within" and "past" or nil) })
          if ex.scope then ex.anchored = "now"; resolve_duration(ex) end
        elseif v and unit and fm(units, j - 1) and (w == "a" or true) and (units[idx].numword or units[idx].kind == "number") and unit and (fm(units, idx - 1) == "after" or fm(units, idx - 1) == "before") then
          ex = mkexpr(an, "duration", idx, j, { n = v, unit = unit })
        end
      end
      if not ex then
        local phrase3 = (w or "") .. " " .. (w2 or "") .. " " .. (w3 or "")
        local phrase2 = (w or "") .. " " .. (w2 or "")
        if phrase3 == "at the moment" or phrase3 == "as of now" or phrase3 == "up to date" then
          ex = mkexpr(an, "marker", idx, idx + 2, { scope = "present", relative = "now" })
        elseif phrase2 == "right now" or phrase2 == "at present" or phrase2 == "these days" or phrase2 == "to date" or phrase2 == "so far" then
          ex = mkexpr(an, "marker", idx, idx + 1, { scope = "present", relative = "now" })
        elseif phrase3 == "in the past" or phrase3 == "back then" or phrase2 == "back then" then
          ex = mkexpr(an, "marker", idx, (phrase2 == "back then") and idx + 1 or idx + 2, { scope = "past", relative = "past" })
        elseif phrase3 == "in the future" or phrase3 == "going forward" or phrase2 == "going forward" then
          ex = mkexpr(an, "marker", idx, (phrase2 == "going forward") and idx + 1 or idx + 2, { scope = "future", relative = "future", persist = phrase2 == "going forward" or nil })
        elseif phrase3 == "from now on" or phrase3 == "from here on" or phrase3 == "for the rest" or phrase3 == "until further notice" then
          ex = mkexpr(an, "persist", idx, idx + 2, { scope = "future", persist = true })
        elseif w == "henceforth" or w == "hereafter" or w == "henceforward" then
          ex = mkexpr(an, "persist", idx, idx, { scope = "future", persist = true })
        elseif w == "yesterday" or w == "today" or w == "tomorrow" then
          local off = (w == "yesterday") and -1 or (w == "tomorrow" and 1 or 0)
          ex = mkexpr(an, "relative", idx, idx, { relative = w, offset = off, unit = "day", scope = off == 0 and "present" or (off < 0 and "past" or "future") })
          resolve_offset(ex, off, "day")
        elseif PRESENT_WORDS[w] and (w == "now" or w == "currently" or w == "presently" or w == "nowadays") then
          ex = mkexpr(an, "marker", idx, idx, { scope = "present", relative = "now" })
        elseif (w == "recently" or w == "lately") then
          ex = mkexpr(an, "marker", idx, idx, { scope = "recent", relative = "recent" })
        elseif PAST_WORDS[w] and (w == "formerly" or w == "previously" or w == "historically" or w == "originally" or w == "once") then
          ex = mkexpr(an, "marker", idx, idx, { scope = "past", relative = "past" })
        elseif WEEKDAY[w] and units[idx].cap then
          ex = mkexpr(an, "weekday", idx, idx, { weekday = WEEKDAY[w] })
        end
      end
      if ex then claim(ex) end
    end
  end

  ---- adjective-style scope markers (not claimed as expressions; attached as unit features for the semantic layer)
  for idx = 1, N do
    local w = units[idx].form
    if not used[idx] and units[idx].kind == "word" then
      if (w == "current" or w == "present") then units[idx].temporal_scope = "present"
      elseif PAST_WORDS[w] and w ~= "old" and w ~= "once" and w ~= "ex" and w ~= "past" and w ~= "earlier" then units[idx].temporal_scope = "past"
      elseif FUTURE_WORDS[w] then units[idx].temporal_scope = "future" end
    end
  end

  ---- operators: look left of each date-like expression, and merge "between X and Y" / "X to Y" / "X-Y" ranges
  table.sort(exprs, function(a, b) return a.u1 < b.u1 end)
  local OP = {
    ["in"] = "in", during = "in", throughout = "in", within = "in", over = "in", on = "in", at = "in",
    before = "before", ["until"] = "until", till = "until", by = "by", ["up"] = nil,
    after = "after", since = "since", following = "after", from = "from",
    around = "approx", circa = "approx", c = "approx", approximately = "approx", about = "approx",
    ["between"] = "between",
  }
  local function has_date_bounds(ex) return ex.lo ~= nil and ex.hi ~= nil end
  local k = 1
  while k <= #exprs do
    local ex = exprs[k]
    local dated = ex.kind == "date" or ex.kind == "year" or ex.kind == "month" or ex.kind == "decade" or ex.kind == "century" or ex.kind == "quarter" or ex.kind == "fiscal_year"
    if dated then
      local p1, p2 = fm(units, ex.u1 - 1), fm(units, ex.u1 - 2)
      local op, op_u = nil, nil
      if p1 and OP[p1] then op, op_u = OP[p1], ex.u1 - 1
      elseif p1 == "to" and p2 == "up" then op, op_u = "until", ex.u1 - 2
      elseif p1 == "than" and (p2 == "earlier" or p2 == "later") then op, op_u = (p2 == "earlier") and "before" or "after", ex.u1 - 2
      elseif p1 == "to" and p2 == "prior" then op, op_u = "before", ex.u1 - 2
      elseif p1 == "of" and p2 == "as" then op, op_u = "as_of", ex.u1 - 2
      elseif p1 == "the" and p2 and OP[p2] then op, op_u = OP[p2], ex.u1 - 2 end
      if (op == "from" or op == "between") then
        -- find the closing X "to|and|until|through|-" Y
        local nxt = exprs[k + 1]
        if nxt and nxt.u1 > ex.u2 then
          local between = {}
          for z = ex.u2 + 1, nxt.u1 - 1 do between[#between + 1] = units[z].form end
          local joiner = table.concat(between, " ")
          local pre = units[nxt.u1].pre or ""
          local ok = (op == "between" and joiner == "and") or (op == "from" and (joiner == "to" or joiner == "until" or joiner == "till" or joiner == "through" or joiner == "and"))
            or (joiner == "" and pre:find("dash") ~= nil)
          if ok and has_date_bounds(ex) and has_date_bounds(nxt) then
            ex.range_end = nxt
            ex.hi = nxt.hi
            ex.kind = "interval"
            ex.u2 = nxt.u2; ex.e = nxt.e
            ex.text = an.original:sub(ex.s, ex.e)
            ex.op = op == "between" and "between" or "from_to"
            ex.u1 = op_u; ex.s = units[op_u].s; ex.text = an.original:sub(ex.s, ex.e)
            table.remove(exprs, k + 1)
            for z = ex.u1, ex.u2 do used[z] = ex end
            ex.role = "scope"
            ex.eff_lo, ex.eff_hi = ex.lo, ex.hi
            goto continue
          end
        end
        ex.op = (op == "between") and "between_open" or "from"
        ex.op_u = op_u
      elseif op then
        ex.op = op; ex.op_u = op_u
        ex.u1 = op_u; ex.s = units[op_u].s; ex.text = an.original:sub(ex.s, ex.e)
        for z = ex.u1, ex.u2 do used[z] = ex end
      else
        -- bare dash range "2010-2015"
        local nxt = exprs[k + 1]
        if nxt and nxt.u1 == ex.u2 + 1 and has_date_bounds(ex) and has_date_bounds(nxt) and units[nxt.u1].pre and units[nxt.u1].pre:find("dash") and (ex.kind == "year" or ex.kind == "date") then
          ex.range_end = nxt; ex.hi = nxt.hi; ex.kind = "interval"; ex.u2 = nxt.u2; ex.e = nxt.e
          ex.text = an.original:sub(ex.s, ex.e); ex.op = "from_to"; ex.role = "scope"
          ex.eff_lo, ex.eff_hi = ex.lo, ex.hi
          table.remove(exprs, k + 1)
          for z = ex.u1, ex.u2 do used[z] = ex end
          goto continue
        end
      end
      -- derive the effective interval from the operator
      if ex.kind ~= "interval" and has_date_bounds(ex) then
        local o = ex.op
        ex.eff_lo, ex.eff_hi = ex.lo, ex.hi
        if o == "before" then ex.eff_lo, ex.eff_hi = nil, ex.lo - 1
        elseif o == "until" or o == "by" then ex.eff_lo, ex.eff_hi = nil, ex.hi
        elseif o == "after" then ex.eff_lo, ex.eff_hi = ex.hi + 1, nil
        elseif o == "since" or o == "from" then ex.eff_lo, ex.eff_hi = ex.lo, nil end
      elseif ex.kind == "interval" then ex.eff_lo, ex.eff_hi = ex.lo, ex.hi end
      if ex.kind == "year" and ex.role == "ambiguous" and ex.op and ex.op ~= "approx" then ex.role = "scope"; ex.confidence = 0.9 end
    end
    ::continue::
    k = k + 1
  end

  -- "approx" widens year-precision points by +-2 years (documented heuristic)
  for _, ex in ipairs(exprs) do
    if ex.op == "approx" and ex.eff_lo and ex.eff_hi and ex.precision == "year" then
      ex.eff_lo = ex.eff_lo - 20000; ex.eff_hi = ex.eff_hi + 20000; ex.widened = true
    end
  end

  an.temporal = exprs
  an.temporal_now = now
  return exprs, numbers
end

return T
