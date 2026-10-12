package.path = (arg[0]:match("^(.*)/tests/[^/]*$") or ".") .. "/tests/?.lua;" .. package.path
local T = require("t")
T.setup_path()
local UC = require("asi.nlu.unicode")

T.test("strict decode flags every invalid byte and never drops data", function()
  local d = UC.decode("a\255b\xC0\xAFc\xED\xA0\x80d\xF4\x90\x80\x80")
  -- 0xFF, 0xC0 0xAF (overlong), surrogate ED A0 80, >10FFFF all invalid
  T.ok(#d.invalid >= 4)
  local rebuilt = {}
  for i = 1, d.n do rebuilt[#rebuilt + 1] = d.bs[i] end
  T.eq(d.bs[1], 1)
  T.eq(d.be[d.n], #"a\255b\xC0\xAFc\xED\xA0\x80d\xF4\x90\x80\x80", "byte offsets cover the whole input")
  local ok = UC.decode("héllo 😀 世界")
  T.eq(#ok.invalid, 0)
  T.eq(ok.n, 10)
  T.eq(ok.cp[2], 0xE9)
  T.eq(ok.bs[3], 4) -- é is 2 bytes
end)

T.test("truncated multibyte sequences are flagged", function()
  local d = UC.decode("ab\xE4\xB8")
  T.ok(#d.invalid >= 1)
end)

T.test("case folding across supported scripts", function()
  T.eq(UC.fold("FRANCE"), "france")
  T.eq(UC.fold("Zürich"), "zurich")
  T.eq(UC.fold("ÉCOLE"), "ecole")
  T.eq(UC.fold("École Polytechnique"), "ecole polytechnique")
  T.eq(UC.fold("Łódź"), "lodz")
  T.eq(UC.fold("Straße"), "strasse")
  T.eq(UC.fold("ΑΘΗΝΑ"), "αθηνα")
  T.eq(UC.fold("ΜΆΪΟΣ"), "μαιοσ")
  T.eq(UC.fold("Москва"), "москва")
  T.eq(UC.fold("ЁЖ"), "ёж")
  T.eq(UC.fold("Việt Nam"), "viet nam")
  T.eq(UC.fold("ﬁne ﬂow"), "fine flow")
  T.eq(UC.fold("ＦＲＡＮＣＥ"), "france") -- fullwidth
  T.eq(UC.fold("naïve"), "naive")
  T.eq(UC.fold("e\u{0301}cole"), "ecole", "decomposed accent stripped in folded form")
end)

T.test("unsupported scripts are passed through, not corrupted", function()
  T.eq(UC.fold("東京"), "東京")
  T.eq(UC.fold("שלום"), "שלום")
  T.eq(UC.script(utf8.codepoint("東")), "han")
  T.eq(UC.script(utf8.codepoint("я")), "cyrillic")
  T.eq(UC.script(utf8.codepoint("α")), "greek")
  T.ok(UC.unsegmented.han)
end)

T.test("US vs us stay distinguishable at the code point level", function()
  T.ok(UC.is_upper(("U"):byte()) and UC.is_lower(("s"):byte()))
  T.ok(not UC.is_upper(("u"):byte()))
end)

T.test("class table", function()
  T.eq(UC.class(32), "Z")
  T.eq(UC.class(0xA0), "Z")
  T.eq(UC.class(0x200B), "C")
  T.eq(UC.class(0x2014), "P")
  T.eq(UC.class(0x20AC), "S")
  T.eq(UC.class(0x0301), "M")
  T.eq(UC.class(0x0663), "N")
  T.eq(UC.digit_value(0x0663), 3)
  T.eq(UC.digit_value(0xFF17), 7)
end)

T.test("capabilities are declared", function()
  T.ok(#UC.capabilities.unsupported > 0)
end)

os.exit(T.report("unicode") and 0 or 1)
