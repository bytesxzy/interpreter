package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
T.setup_path()
local U = require("asi.nlu.util")
local Lex = require("asi.nlu.lex")
local Spell = require("asi.nlu.spell")

local function kinds(an) local r = {}; for _, t in ipairs(an.tokens) do r[#r + 1] = t.kind end; return r end
local function texts(an) local r = {}; for _, t in ipairs(an.tokens) do r[#r + 1] = t.text end; return r end
local function forms(an) local r = {}; for _, u in ipairs(an.units) do r[#r + 1] = u.form end; return r end
local function find_tok(an, text) for _, t in ipairs(an.tokens) do if t.text == text then return t end end end

-- invariant that must hold for EVERY input: the original is preserved and every token/unit slices exactly
local function check_invariants(s, an)
  T.eq(an.original, s, "original preserved byte-for-byte")
  for _, t in ipairs(an.tokens) do
    T.eq(s:sub(t.s, t.e), t.text, "token offset mismatch for " .. t.text)
    T.ok(t.s <= t.e and t.cs <= t.ce, "ordered offsets")
  end
  for i = 2, #an.tokens do T.ok(an.tokens[i].s > an.tokens[i - 1].e, "tokens must not overlap") end
  for _, u in ipairs(an.units) do T.eq(s:sub(u.s, u.e), s:sub(u.s, u.e)); T.ok(u.s >= 1 and u.e <= #s) end
end

T.test("simple question: words, offsets, sentence", function()
  local s = "What is the capital of France?"
  local an = Lex.analyze(s)
  check_invariants(s, an)
  T.eq(texts(an), { "What", "is", "the", "capital", "of", "France", "?" })
  T.eq(forms(an), { "what", "is", "the", "capital", "of", "france" })
  T.eq(#an.sentences, 1)
  T.ok(an.sentences[1].question_mark)
  local fr = find_tok(an, "France")
  T.eq(fr.s, 24); T.eq(fr.e, 29); T.ok(fr.cap)
end)

T.test("case is preserved in raw, folded for comparison", function()
  local an = Lex.analyze("France france FRANCE")
  for _, u in ipairs(an.units) do T.eq(u.form, "france") end
  T.eq(an.units[1].raw, "France"); T.eq(an.units[2].raw, "france"); T.eq(an.units[3].raw, "FRANCE")
  T.ok(an.tokens[3].allcaps and not an.tokens[1].allcaps)
end)

T.test("US vs us remain distinguishable", function()
  local an = Lex.analyze("Is the US bigger than us?")
  local a, b = find_tok(an, "US"), find_tok(an, "us")
  T.ok(a.allcaps and not b.allcaps)
  T.eq(an.units[3].raw, "US"); T.eq(an.units[3].form, "us")
  T.ok(an.units[3].acr and not an.units[6].acr)
end)

T.test("shouting is detected so caps are not mistaken for acronyms", function()
  local an = Lex.analyze("WHAT IS THE CAPITAL OF FRANCE?")
  T.ok(an.sentences[1].shout)
  local an2 = Lex.analyze("What is NASA doing?")
  T.ok(not an2.sentences[1].shout)
end)

T.test("contractions split surface-exactly with normalised parts", function()
  local s = "I don't know; they can't, won't, shouldn't, cannot go. What's up? It's Tom's."
  local an = Lex.analyze(s)
  check_invariants(s, an)
  T.eq(forms(an), { "i", "do", "not", "know", "they", "can", "not", "will", "not", "should", "not", "can", "not", "go",
    "what", "'s", "up", "it", "'s", "tom", "'s" })
  local nt = an.tokens[3]
  T.eq(nt.text, "n't"); T.ok(nt.neg_clitic)
  T.eq(#an.cues.negation, 5, "5 negation cues: don't can't won't shouldn't cannot")
  local s_tok = find_tok(an, "'s")
  T.eq(s_tok.readings, { "is", "has", "poss", "us" })
end)

T.test("plural possessive vs closing quote", function()
  local an = Lex.analyze("The students' books are here.")
  T.ok(find_tok(an, "students").poss_plural)
  local an2 = Lex.analyze("He said 'hello' and left.")
  for _, t in ipairs(an2.tokens) do T.ok(not t.poss_plural) end
  T.eq(forms(an2), { "he", "said", "hello", "and", "left" })
end)

T.test("hyphenated compounds keep one token but expose parts as units", function()
  local s = "long-term memory and state-of-the-art systems"
  local an = Lex.analyze(s)
  check_invariants(s, an)
  T.eq(texts(an), { "long-term", "memory", "and", "state-of-the-art", "systems" })
  T.eq(forms(an), { "long", "term", "memory", "and", "state", "of", "the", "art", "systems" })
  T.ok(an.tokens[1].compound and #an.tokens[4].parts == 4)
  -- same match units for hyphenated and spaced spelling => phrase matching is robust to the variation
  T.eq(forms(Lex.analyze("long term memory")), { "long", "term", "memory" })
end)

T.test("numbers, currency, percent, units, ordinals, decades", function()
  local an = Lex.analyze("It cost $1,234.56 (5%) for 10GB in the 21st century, the 1990s and '90s; 3.14, -5, +3, 1e6, 5k, $5M")
  local function by(text) return find_tok(an, text) end
  T.eq(by("$1,234.56").value, 1234.56); T.eq(by("$1,234.56").currency_symbol, "$")
  T.eq(by("5%").unit, "percent")
  T.eq(by("10GB").unit, "gb")
  T.eq(by("21st").kind, "ordinal"); T.eq(by("21st").ordinal, 21)
  T.eq(by("1990s").kind, "decade"); T.eq(by("1990s").decade, 1990)
  T.eq(by("'90s").kind, "decade"); T.eq(by("'90s").decade2, 90)
  T.eq(by("3.14").value, 3.14); T.eq(by("-5").value, -5); T.eq(by("+3").value, 3)
  T.eq(by("1e6").value, 1e6); T.eq(by("5k").value, 5000); T.eq(by("$5M").value, 5e6)
end)

T.test("ranges are not signed numbers; alnum identifiers are not numbers", function()
  local an = Lex.analyze("2010-2015 and 3D, 4K, COVID-19, GPT-4, B-52")
  T.eq(texts(an)[1], "2010"); T.eq(texts(an)[2], "-"); T.eq(texts(an)[3], "2015")
  T.eq(find_tok(an, "3D").kind, "word")
  T.ok(find_tok(an, "COVID-19").compound)
  T.eq(find_tok(an, "GPT-4").kind, "word")
end)

T.test("structured references", function()
  local s = "see https://example.com/a_(b), mail user@example.com, #123, @bob, #tag, /usr/bin/lua, C:\\Users\\x, 10.1000/xyz123, arXiv:2101.00001."
  local an = Lex.analyze(s)
  check_invariants(s, an)
  T.eq(find_tok(an, "https://example.com/a_(b)").kind, "url")
  T.eq(find_tok(an, "user@example.com").kind, "email")
  T.eq(find_tok(an, "#123").kind, "ref")
  T.eq(find_tok(an, "@bob").kind, "handle")
  T.eq(find_tok(an, "#tag").kind, "hashtag")
  T.eq(find_tok(an, "/usr/bin/lua").kind, "path")
  T.eq(find_tok(an, "C:\\Users\\x").kind, "path")
  T.eq(find_tok(an, "10.1000/xyz123").kind, "doi")
  T.eq(find_tok(an, "arXiv:2101.00001").kind, "ref")
  T.ok(find_tok(an, "https://example.com/a_(b)").case_sensitive)
end)

T.test("code identifiers stay atomic and case-sensitive", function()
  local an = Lex.analyze("Call getUserName() or snake_case_var in os.path.join; C++ and C# and asi.reason.hpr")
  for _, id in ipairs({ "getUserName()", "snake_case_var", "os.path.join", "C++", "C#", "asi.reason.hpr" }) do
    local t = find_tok(an, id)
    T.ok(t and t.kind == "ident" and t.case_sensitive, id)
  end
  -- case-sensitive identifiers keep raw case in the match form
  local u
  for _, x in ipairs(an.units) do if x.raw == "getUserName()" then u = x end end
  T.eq(u.form, "getUserName()")
end)

T.test("abbreviations and initials do not end sentences", function()
  local an = Lex.analyze("Dr. Smith met J. R. R. Tolkien in the U.S. on Jan. 5. He left.")
  T.eq(#an.sentences, 2, "Dr./J./U.S./Jan. must not split")
  T.eq(find_tok(an, "Dr.").kind, "abbrev")
  T.eq(find_tok(an, "J.").kind, "initial")
  T.eq(an.units[1].form, "dr")
  local an2 = Lex.analyze("We sell shoes, bags, etc. They sell more.")
  T.eq(#an2.sentences, 2, "etc. followed by a sentence starter ends the sentence")
  local an3 = Lex.analyze("Apple Inc. is large. It grew.")
  T.eq(#an3.sentences, 2)
end)

T.test("single-letter names end a sentence when a sentence starter follows (regression: 'Company A. Who founded it?')", function()
  local an = Lex.analyze("I'm researching Company A. Who founded it?")
  T.eq(#an.sentences, 2)
  T.eq(find_tok(an, "A").kind, "word")
  local an2 = Lex.analyze("J. R. R. Tolkien wrote it. He left.")
  T.eq(#an2.sentences, 2, "initials still do not split")
  T.eq(find_tok(an2, "J.").kind, "initial")
end)

T.test("sentence segmentation: ?!, ellipsis, quotes, newlines, bullets", function()
  T.eq(#Lex.analyze("Really?! Yes. No...").sentences, 3)
  T.eq(#Lex.analyze("He said \"Go!\" Then he left.").sentences, 2)
  T.eq(#Lex.analyze("She asked, \"Is it?\" she said.").sentences, 1)
  T.eq(#Lex.analyze("First paragraph.\n\nSecond paragraph without period").sentences, 2)
  T.eq(#Lex.analyze("A hard-wrapped line that\ncontinues here.").sentences, 1)
  T.eq(#Lex.analyze("- one\n- two\n- three").sentences, 3)
  T.eq(#Lex.analyze("Costs 3.5 million. Next.").sentences, 2)
end)

T.test("unicode: folding, scripts, unsegmented text is flagged not split", function()
  local an = Lex.analyze("Zürich Łódź Москва 東京 naïve")
  T.eq(forms(an), { "zurich", "lodz", "москва", "東京", "naive" })
  T.ok(find_tok(an, "東京").unsegmented)
  T.eq(find_tok(an, "Москва").script, "cyrillic")
  T.ok(Lex.capabilities().unsupported)
end)

T.test("invalid UTF-8 is reported and preserved, never dropped or repaired in place", function()
  local s = "caf\xE9 is bad \xFF\xFE end"
  local an = Lex.analyze(s)
  check_invariants(s, an)
  T.ok(not an.utf8.valid)
  T.ok(an.utf8.n_invalid >= 3)
  local bad = 0
  for _, t in ipairs(an.tokens) do if t.invalid then bad = bad + 1 end end
  T.ok(bad >= 2)
  T.ok(an.notes[1]:find("invalid UTF%-8"))
end)

T.test("control characters, NUL, zero-width and BOM", function()
  local s = "\239\187\191Fr\226\128\139ance\0 is\1 here\r\nnext"
  local an = Lex.analyze(s)
  check_invariants(s, an)
  T.ok(an.utf8.bom)
  local fr
  for _, t in ipairs(an.tokens) do if t.fold == "france" then fr = t end end
  T.ok(fr, "zero-width space inside a word must not defeat matching")
  T.ok(fr.has_zw)
  T.ok(an.utf8.controls >= 2)
end)

T.test("malformed inputs never crash", function()
  local cases = { "", " ", "\n\n\n", "?", "...", "'", '"', "\"\"\"", "((((", "))))", "-", "--- ---", "\t\t", "a", "1", ".5", "5.",
    "@", "#", "http://", "://", "a@b", string.rep("a", 5000), string.rep("-", 3000), string.rep("(", 1000), "$$$$", "%%%",
    "'''", "\xC3", "\xE2\x82", string.rep("é", 3000), string.rep("1,", 500), "1,2,3,4", "a.b.c.d.e.f", "😀😀😀 😀", "e\u{0301}\u{0301}\u{0301}" }
  for _, s in ipairs(cases) do
    local ok, an = pcall(Lex.analyze, s)
    T.ok(ok, "crashed on " .. T.show(s:sub(1, 20)) .. " : " .. tostring(an))
    check_invariants(s, an)
  end
  local an = Lex.analyze(nil)
  T.eq(an.status, "rejected")
  local an2 = Lex.analyze(42)
  T.eq(an2.status, "rejected")
end)

T.test("fuzz: random byte soup keeps all invariants", function()
  local rng = U.rng(12345)
  local alphabet = { "a", "B", " ", "\n", ".", ",", "'", "\"", "-", "1", "9", "$", "%", "(", ")", "é", "世", "😀", "\xFF", "\0", "_", "/", "@", "#", ":" }
  for _ = 1, 300 do
    local n = rng:int(0, 60)
    local parts = {}
    for i = 1, n do parts[i] = rng:pick(alphabet) end
    local s = table.concat(parts)
    local ok, an = pcall(Lex.analyze, s)
    T.ok(ok, "crash on fuzz input " .. T.show(s) .. ": " .. tostring(an))
    check_invariants(s, an)
  end
end)

T.test("size limit yields an explicit limited status, original retained", function()
  local s = string.rep("word ", 1000)
  local an = Lex.analyze(s, { max_bytes = 100 })
  T.eq(an.status, "limited")
  T.eq(an.original, s)
  T.ok(an.analyzed_bytes <= 100)
  T.ok(#an.tokens <= 25)
end)

T.test("work budget exhaustion is explicit, not a silent truncation", function()
  local m = U.meter(50)
  local an = Lex.analyze(string.rep("hello world ", 100), { meter = m })
  T.eq(an.status, "limited")
  T.ok(an.notes[#an.notes]:find("budget"))
end)

T.test("determinism: identical input gives identical analysis", function()
  local s = "Who founded Example Labs in 2015, not Acme Corp.?"
  local a = U.json_encode(Lex.analyze(s).tokens)
  local b = U.json_encode(Lex.analyze(s).tokens)
  T.eq(a, b)
end)

T.test("cue flags: negation, comparative, superlative, conditional, quantifier", function()
  local an = Lex.analyze("Find the newest results, excluding reposts, but not older ones, if any exist; every user is faster than none.")
  local function has(list, form) for _, c in ipairs(list) do if c.form == form then return true end end return false end
  T.ok(has(an.cues.negation, "excluding") and has(an.cues.negation, "not") and has(an.cues.negation, "none"))
  T.ok(has(an.cues.superlative, "newest"))
  T.ok(has(an.cues.comparative, "older") and has(an.cues.comparative, "faster") and has(an.cues.comparative, "than"))
  T.ok(has(an.cues.conditional, "if"))
  T.ok(has(an.cues.quantifier, "every"))
end)

T.test("spelling alternatives are suggestions only; known words and short words untouched", function()
  local sp = Spell.new()
  sp:add_all({ "capital", "france", "germany", "punishment", "city", "population", "founder" }, 3, "lex")
  sp:add("france", 5, "entity")
  local an = Lex.analyze("captial of Frnace and cty with popluation", { spell = sp })
  local byraw = {}
  for _, u in ipairs(an.units) do byraw[u.raw] = u end
  T.eq(byraw["captial"].alts[1].form, "capital")
  T.eq(byraw["Frnace"].alts[1].form, "france")
  T.ok(byraw["popluation"].alts[1].form == "population")
  T.ok(byraw["cty"].alts == nil or #byraw["cty"].alts == 0, "3-letter words get no suggestions")
  T.ok(byraw["of"].alts == nil)
  T.eq(byraw["captial"].form, "captial", "original form is not overwritten")
  -- known word never corrected
  local an2 = Lex.analyze("capital", { spell = sp })
  T.ok(an2.units[1].alts == nil and not an2.units[1].unknown)
end)

T.test("spell index finds the right neighbours without scanning the vocabulary", function()
  local sp = Spell.new()
  local rng = U.rng(7)
  for i = 1, 3000 do
    local w = {}
    for k = 1, rng:int(5, 10) do w[k] = string.char(rng:int(97, 122)) end
    sp:add(table.concat(w), 1)
  end
  sp:add("information", 9)
  local s = sp:suggest("infromation")
  T.ok(#s >= 1 and s[1].form == "information" and s[1].dist == 1)
  T.eq(#sp:suggest("information"), 0)
end)

T.test("apostrophe-less contractions expand for matching while the surface text stays intact", function()
  local Lex = require("asi.nlu.lex")
  local an = Lex.analyze("whats the capital? I dont know. Im sure. IM me.")
  local forms = {}
  for _, u in ipairs(an.units) do forms[#forms + 1] = u.form end
  T.eq(forms, { "what", "is", "the", "capital", "i", "do", "not", "know", "i", "am", "sure", "im", "me" })
  T.eq(an.original, "whats the capital? I dont know. Im sure. IM me.")
  -- the expanded units share the original byte span
  T.eq(an.units[1].s, 1); T.eq(an.units[1].e, 5); T.eq(an.units[2].s, 1); T.eq(an.units[2].e, 5)
  -- negation cue is recognised for the expanded "not"
  local neg = false
  for _, u in ipairs(an.units) do if u.form == "not" and u.neg_clitic then neg = true end end
  T.ok(neg)
end)

os.exit(T.report("lex") and 0 or 1)
