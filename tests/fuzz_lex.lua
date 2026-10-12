-- Large randomized robustness campaign for the lexical layer (not part of the fast suite).
-- usage: lua5.4 tests/fuzz_lex.lua [iterations] [seed]
package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/nlu/?.lua;" .. package.path
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local N = tonumber(arg[1]) or 20000
local rng = U.rng(tonumber(arg[2]) or 2024)
local alphabet = { "a", "B", "z", "Q", " ", " ", "\n", "\r\n", "\t", ".", ",", ";", ":", "'", "\"", "-", "--", "1", "9", "0", ",000", ".5", "e5",
  "$", "%", "(", ")", "[", "]", "{", "}", "é", "ß", "Ł", "世", "界", "😀", "\xFF", "\xC3", "\xE2\x82", "\0", "\1", "_", "/", "\\", "@", "#", "?", "!", "...",
  "…", "’", "“", "”", "n't", "'s", "st", "th", "s", "k", "M", "http://", "www.", ".com", "U.S.", "Dr.", "e.g.", "3:30", "pm", "2020-05-04", "12/25/2020",
  "\u{200B}", "\u{FEFF}", "\u{0301}", "\u{00A0}", "ＦＲ", "Ж", "α", "—", "&", "*", "+", "=", "<", ">", "|", "~", "^", "`" }
local bad = 0
local t0 = os.clock()
for it = 1, N do
  local n = rng:int(0, 80)
  local parts = {}
  for i = 1, n do parts[i] = rng:pick(alphabet) end
  local s = table.concat(parts)
  local count = 0
  debug.sethook(function() count = count + 1; if count > 200 then error("INSTRUCTION BUDGET (hang?)", 0) end end, "", 1000000)
  local ok, an = pcall(Lex.analyze, s)
  debug.sethook()
  local problem
  if not ok then problem = tostring(an)
  else
    if an.original ~= s then problem = "original changed" end
    local prev_e = 0
    for _, t in ipairs(an.tokens) do
      if not problem and s:sub(t.s, t.e) ~= t.text then problem = "offset mismatch " .. t.text end
      if not problem and (t.s <= prev_e) then problem = "overlap/order" end
      if not problem and t.e < t.s then problem = "empty token" end
      prev_e = t.e
    end
    for _, u in ipairs(an.units) do
      if not problem and (u.s < 1 or u.e > #s or u.s > u.e) then problem = "unit offsets" end
    end
    for _, sent in ipairs(an.sentences) do
      if not problem and (sent.s > sent.e) then problem = "sentence offsets" end
    end
  end
  if problem then
    bad = bad + 1
    if bad <= 5 then print(string.format("FAIL #%d %q -> %s", it, s, problem)) end
  end
end
print(string.format("fuzz_lex: %d inputs, %d failures, %.1fs", N, bad, os.clock() - t0))
os.exit(bad == 0 and 0 or 1)
