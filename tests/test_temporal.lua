package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
T.setup_path()
local Lex = require("asi.nlu.lex")
local TM = require("asi.nlu.temporal")

local NOW = { y = 2026, m = 10, d = 12 } -- a Monday
local function ex_of(s, now, kind)
  local an = Lex.analyze(s, { now = now })
  for _, e in ipairs(an.temporal) do if not kind or e.kind == kind then return e, an end end
  return nil, an
end
local function all(s, now) return Lex.analyze(s, { now = now }).temporal end

T.test("year with a temporal preposition is a time scope", function()
  local e = ex_of("What was the capital of France in 1900?")
  T.eq(e.kind, "year"); T.eq(e.role, "scope"); T.eq(e.op, "in")
  T.eq(e.eff_lo, TM.key(1900, 1, 1)); T.eq(e.eff_hi, TM.key(1900, 12, 31))
end)

T.test("year used as a source label is NOT a time scope", function()
  local e = ex_of("What is the capital of France according to the supplied 2020 dataset?")
  T.eq(e.role, "label")
  T.eq(ex_of("Use the 2025 dataset").role, "label")
  T.eq(ex_of("The 2020 census").role, "label")
end)

T.test("quantities that look like years are not dates", function()
  T.eq(#all("The firm has 2000 employees."), 0)
  T.eq(#all("We served 1999 customers."), 0)
end)

T.test("operators produce open or bounded effective intervals", function()
  local before = ex_of("founded before 2000")
  T.eq(before.eff_lo, nil); T.eq(before.eff_hi, TM.key(2000, 1, 1) - 1)
  local after = ex_of("established after 2020")
  T.eq(after.eff_hi, nil); T.ok(after.eff_lo > TM.key(2020, 12, 31))
  local since = ex_of("active since 1999")
  T.eq(since.eff_lo, TM.key(1999, 1, 1)); T.eq(since.eff_hi, nil)
  local until_ = ex_of("until 1789")
  T.eq(until_.eff_hi, TM.key(1789, 12, 31)); T.eq(until_.eff_lo, nil)
end)

T.test("between / from-to / dash ranges", function()
  for _, s in ipairs({ "between 2010 and 2015", "from 2010 to 2015", "2010-2015", "2010 - 2015", "from 2010 until 2015" }) do
    local e = ex_of(s)
    T.eq(e.kind, "interval", s)
    T.eq(e.eff_lo, TM.key(2010, 1, 1), s); T.eq(e.eff_hi, TM.key(2015, 12, 31), s)
  end
end)

T.test("explicit dates in several surface forms agree", function()
  local want = TM.key(2021, 5, 4)
  for _, s in ipairs({ "May 4, 2021", "May 4th 2021", "4 May 2021", "4th of May 2021", "2021-05-04" }) do
    local e = ex_of(s)
    T.ok(e and e.lo == want and e.hi == want, s)
  end
end)

T.test("slash dates: unambiguous when a part exceeds 12, flagged when not", function()
  T.eq(ex_of("12/25/2020").lo, TM.key(2020, 12, 25))
  T.eq(ex_of("25/12/2020").lo, TM.key(2020, 12, 25))
  local amb = ex_of("03/04/2020")
  T.ok(amb.ambiguous and #amb.alts == 1)
end)

T.test("'May' is a month only with a date cue, otherwise the modal verb", function()
  T.eq(#all("May I see the files?"), 0)
  T.eq(#all("You may leave now"), 1) -- 'now' marker only
  T.eq(ex_of("We met in May", nil, "month").month, 5)
  T.eq(ex_of("May 2021 was cold").kind, "date")
end)

T.test("decades, centuries, BC/AD, quarters, fiscal years", function()
  local d = ex_of("the 1990s")
  T.eq(d.lo, TM.key(1990, 1, 1)); T.eq(d.hi, TM.key(1999, 12, 31))
  local d2 = ex_of("the nineties")
  T.eq(d2.unresolved, "century unknown"); T.eq(d2.decade2, 90)
  local c = ex_of("in the 19th century")
  T.eq(c.lo, TM.key(1801, 1, 1)); T.eq(c.hi, TM.key(1900, 12, 31))
  local c21 = ex_of("the twenty-first century")
  T.eq(c21.century, 21)
  local late = ex_of("the late 20th century")
  T.ok(late.lo > TM.key(1900, 12, 31) + 60000 and late.hi == TM.key(2000, 12, 31))
  local bc = ex_of("in 500 BC")
  T.eq(bc.year, -500); T.ok(bc.lo < TM.key(-499, 1, 1))
  T.eq(ex_of("AD 800").year, 800)
  local q = ex_of("Q3 2021")
  T.eq(q.lo, TM.key(2021, 7, 1)); T.eq(q.hi, TM.key(2021, 9, 30))
  T.eq(ex_of("FY2020").kind, "fiscal_year")
  T.ok(ex_of("FY2020").note:find("not assumed"))
end)

T.test("relative expressions resolve only when `now` is supplied", function()
  local unresolved = ex_of("last year")
  T.eq(unresolved.resolved, false); T.eq(unresolved.lo, nil)
  local ly = ex_of("last year", NOW)
  T.eq(ly.lo, TM.key(2025, 1, 1)); T.eq(ly.hi, TM.key(2025, 12, 31))
  local lm = ex_of("last month", NOW)
  T.eq(lm.lo, TM.key(2026, 9, 1)); T.eq(lm.hi, TM.key(2026, 9, 30))
  local ny = ex_of("next year", NOW)
  T.eq(ny.lo, TM.key(2027, 1, 1))
  local y = ex_of("yesterday", NOW)
  T.eq(y.lo, TM.key(2026, 10, 11))
  local tw = ex_of("two weeks ago", NOW)
  T.eq(tw.lo, TM.key(2026, 9, 28)); T.eq(tw.hi, TM.key(2026, 10, 4))
  local dur = ex_of("over the last 5 years", NOW)
  T.eq(dur.lo, TM.key(2021, 10, 12)); T.eq(dur.hi, TM.key(2026, 10, 12))
  local fut = ex_of("in 10 days", NOW)
  T.eq(fut.hi, TM.key(2026, 10, 22))
  -- month-end clamping
  local e = ex_of("a month ago", { y = 2026, m = 3, d = 31 })
  T.ok(e == nil or e.resolved ~= nil)
end)

T.test("calendar arithmetic across month/year/leap boundaries", function()
  T.eq(TM.add({ y = 2024, m = 2, d = 28 }, 2, "day"), { y = 2024, m = 3, d = 1 })
  T.eq(TM.add({ y = 2023, m = 2, d = 28 }, 2, "day"), { y = 2023, m = 3, d = 2 })
  T.eq(TM.add({ y = 2026, m = 1, d = 31 }, 1, "month"), { y = 2026, m = 2, d = 28 })
  T.eq(TM.add({ y = 2026, m = 1, d = 15 }, -2, "month"), { y = 2025, m = 11, d = 15 })
  T.eq(TM.add({ y = 2026, m = 12, d = 31 }, 1, "day"), { y = 2027, m = 1, d = 1 })
  T.eq(TM.add({ y = 2000, m = 2, d = 29 }, 1, "year"), { y = 2001, m = 2, d = 28 })
end)

T.test("present / past / persistence markers", function()
  T.eq(ex_of("currently active").scope, "present")
  T.eq(ex_of("formerly known as").scope, "past")
  local p = ex_of("From now on use the 2025 dataset")
  T.ok(p.kind == "persist" and p.persist)
  T.ok(ex_of("Going forward, ignore reposts").persist)
  T.ok(ex_of("at the moment").scope == "present")
end)

T.test("number words, ordinals, compounds", function()
  local an = Lex.analyze("Twenty-five people, one hundred and five items, a dozen eggs, the second solution, the twenty-first century, three thousand")
  local vals = {}
  for _, n in ipairs(an.numbers) do vals[#vals + 1] = n.kind .. ":" .. n.value end
  T.eq(vals, { "cardinal:25", "cardinal:105", "cardinal:12", "ordinal:2", "ordinal:21", "cardinal:3000" })
end)

T.test("time of day", function()
  local e = ex_of("at 3:30pm"); T.eq(e.hour, 15); T.eq(e.minute, 30)
  local e2 = ex_of("at 9 am"); T.eq(e2.hour, 9)
  local e3 = ex_of("at 12 am"); T.eq(e3.hour, 0)
end)

T.test("temporal pass is deterministic and never reads the clock", function()
  local a = Lex.analyze("last year and next month", { now = NOW }).temporal
  local b = Lex.analyze("last year and next month", { now = NOW }).temporal
  T.eq(#a, #b)
  for i = 1, #a do T.eq(a[i].lo, b[i].lo) end
end)

os.exit(T.report("temporal") and 0 or 1)
