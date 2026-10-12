-- asi.nlu.morph: English inflection generation + conservative reverse guessing for UNKNOWN words.
-- Known lexicon words are lemmatised by lookup in a generated form table (see lexicon.lua), not by suffix stripping.
local M = {}

local IRREG_VERB = {
  be = { "was", "been", "being", "is", { "am", "are", "were" } }, have = { "had", "had" }, do_ = { "did", "done" },
  go = { "went", "gone" }, begin = { "began", "begun" }, buy = { "bought", "bought" }, build = { "built", "built" },
  bring = { "brought", "brought" }, choose = { "chose", "chosen" }, come = { "came", "come" }, draw = { "drew", "drawn" },
  drive = { "drove", "driven" }, eat = { "ate", "eaten" }, fall = { "fell", "fallen" }, feel = { "felt", "felt" },
  find = { "found", "found" }, fly = { "flew", "flown" }, forget = { "forgot", "forgotten" }, get = { "got", "gotten" },
  give = { "gave", "given" }, grow = { "grew", "grown" }, hold = { "held", "held" }, keep = { "kept", "kept" },
  know = { "knew", "known" }, lead = { "led", "led" }, leave = { "left", "left" }, lose = { "lost", "lost" },
  make = { "made", "made" }, mean = { "meant", "meant" }, meet = { "met", "met" }, pay = { "paid", "paid" },
  put = { "put", "put" }, read = { "read", "read" }, run = { "ran", "run" }, say = { "said", "said" }, see = { "saw", "seen" },
  sell = { "sold", "sold" }, send = { "sent", "sent" }, set = { "set", "set" }, show = { "showed", "shown" },
  speak = { "spoke", "spoken" }, spend = { "spent", "spent" }, take = { "took", "taken" }, teach = { "taught", "taught" },
  tell = { "told", "told" }, think = { "thought", "thought" }, understand = { "understood", "understood" }, win = { "won", "won" },
  write = { "wrote", "written" }, withdraw = { "withdrew", "withdrawn" }, overtake = { "overtook", "overtaken" },
  undertake = { "undertook", "undertaken" }, bear = { "bore", "born" }, become = { "became", "become" }, hit = { "hit", "hit" },
  cut = { "cut", "cut" }, let = { "let", "let" }, shut = { "shut", "shut" }, spread = { "spread", "spread" }, stand = { "stood", "stood" },
  sit = { "sat", "sat" }, lay = { "laid", "laid" }, rise = { "rose", "risen" }, throw = { "threw", "thrown" }, wear = { "wore", "worn" },
  break_ = { "broke", "broken" }, catch = { "caught", "caught" }, fight = { "fought", "fought" }, hang = { "hung", "hung" },
  hide = { "hid", "hidden" }, lend = { "lent", "lent" }, ride = { "rode", "ridden" }, ring = { "rang", "rung" }, seek = { "sought", "sought" },
  shoot = { "shot", "shot" }, sing = { "sang", "sung" }, sleep = { "slept", "slept" }, swim = { "swam", "swum" }, steal = { "stole", "stolen" },
  strike = { "struck", "struck" }, swear = { "swore", "sworn" }, tear = { "tore", "torn" }, wake = { "woke", "woken" }, wind = { "wound", "wound" },
  underlie = { "underlay", "underlain" }, outperform = nil, bind = { "bound", "bound" }, deal = { "dealt", "dealt" }, dig = { "dug", "dug" },
  feed = { "fed", "fed" }, forgive = { "forgave", "forgiven" }, freeze = { "froze", "frozen" }, light = { "lit", "lit" }, shake = { "shook", "shaken" },
  shrink = { "shrank", "shrunk" }, sink = { "sank", "sunk" }, slide = { "slid", "slid" }, split = { "split", "split" }, spin = { "spun", "spun" },
  stick = { "stuck", "stuck" }, sweep = { "swept", "swept" }, swing = { "swung", "swung" }, lie = { "lay", "lain" }, quit = { "quit", "quit" },
  cost = { "cost", "cost" }, burst = { "burst", "burst" }, bet = { "bet", "bet" }, beat = { "beat", "beaten" }, bend = { "bent", "bent" },
  forecast = { "forecast", "forecast" }, upset = { "upset", "upset" }, undergo = { "underwent", "undergone" }, overcome = { "overcame", "overcome" },
  withhold = { "withheld", "withheld" }, rebuild = { "rebuilt", "rebuilt" }, redo = { "redid", "redone" }, rewrite = { "rewrote", "rewritten" },
  mistake = { "mistook", "mistaken" }, override = { "overrode", "overridden" }, partake = { "partook", "partaken" },
}
-- keys with trailing underscore stand for Lua keywords
local function norm_key(k) return (k:gsub("_$", "")) end

local DOUBLE = { refer = true, occur = true, commit = true, prefer = true, control = true, submit = true, admit = true, permit = true,
  regret = true, equip = true, defer = true, transfer = true, compel = true, expel = true, propel = true, rebel = true, excel = true,
  patrol = true, enrol = true, fulfil = true, begin = true, forget = true, omit = true, upset = true }

local IRREG_NOUN = { person = "people", man = "men", woman = "women", child = "children", foot = "feet", tooth = "teeth",
  mouse = "mice", goose = "geese", datum = "data", criterion = "criteria", analysis = "analyses", basis = "bases", crisis = "crises",
  thesis = "theses", phenomenon = "phenomena", index = "indices", matrix = "matrices", appendix = "appendices", formula = "formulae",
  life = "lives", leaf = "leaves", wolf = "wolves", knife = "knives", half = "halves", self = "selves", shelf = "shelves",
  medium = "media", bacterium = "bacteria", stimulus = "stimuli", cactus = "cacti", fungus = "fungi", nucleus = "nuclei",
  alumnus = "alumni", hypothesis = "hypotheses", diagnosis = "diagnoses", series = "series", species = "species", sheep = "sheep",
  fish = "fish", deer = "deer", aircraft = "aircraft", news = "news", staff = "staff", research = "research", information = "information" }
local UNCOUNTABLE = { data = true, information = true, research = true, news = true, software = true, hardware = true, staff = true }

local VOWELS = "aeiou"
local function is_vowel(c) return VOWELS:find(c, 1, true) ~= nil end
local function cvc(w)
  local n = #w
  if n < 3 then return false end
  local a, b, c = w:sub(n - 2, n - 2), w:sub(n - 1, n - 1), w:sub(n, n)
  if is_vowel(c) or c == "w" or c == "x" or c == "y" then return false end
  if not is_vowel(b) or is_vowel(a) then return false end
  return true
end
local function monosyllabic(w)
  local groups = 0
  local prev = false
  for ch in w:gmatch(".") do
    local v = is_vowel(ch) or ch == "y"
    if v and not prev then groups = groups + 1 end
    prev = v
  end
  return groups <= 1
end

function M.third_person(v)
  if v:find("[sxz]$") or v:find("ch$") or v:find("sh$") or v:find("o$") then return v .. "es" end
  if v:find("[^aeiou]y$") then return v:sub(1, -2) .. "ies" end
  return v .. "s"
end

local function doubled(v) return cvc(v) and (monosyllabic(v) or DOUBLE[v]) end

function M.past(v)
  if v:find("e$") then return v .. "d" end
  if v:find("[^aeiou]y$") then return v:sub(1, -2) .. "ied" end
  if doubled(v) then return v .. v:sub(-1) .. "ed" end
  return v .. "ed"
end

function M.gerund(v)
  if v:find("ie$") then return v:sub(1, -3) .. "ying" end
  if v:find("e$") and not v:find("ee$") and not v:find("ye$") and not v:find("oe$") then return v:sub(1, -2) .. "ing" end
  if doubled(v) then return v .. v:sub(-1) .. "ing" end
  return v .. "ing"
end

-- returns map form -> {feat,...} for a verb lemma: base, 3sg, past, pp, ing
function M.verb_forms(lemma)
  local first, rest = lemma:match("^(%S+)(.*)$") -- multiword verbs inflect only the first word
  local irr = IRREG_VERB[first] or IRREG_VERB[first .. "_"]
  local forms = {}
  local function add(f, feat) forms[#forms + 1] = { form = f .. rest, feat = feat } end
  add(first, "base")
  if irr then
    if first ~= "be" then add(M.third_person(first), "3sg") end
    add(irr[1], "past"); add(irr[2], "pp")
    add(irr[3] or M.gerund(first), "ing")
    if first == "be" then add("is", "3sg"); add("am", "1sg"); add("are", "pl"); add("were", "past_pl") end
  else
    add(M.third_person(first), "3sg")
    local p = M.past(first)
    add(p, "past"); add(p, "pp")
    add(M.gerund(first), "ing")
  end
  return forms
end

function M.noun_forms(lemma)
  local first_words, last = lemma:match("^(.-)(%S+)$")
  local plural
  if IRREG_NOUN[last] then plural = IRREG_NOUN[last]
  elseif UNCOUNTABLE[last] then plural = nil
  elseif last:find("[^aeiou]y$") then plural = last:sub(1, -2) .. "ies"
  elseif last:find("[sxz]$") or last:find("ch$") or last:find("sh$") then plural = last .. "es"
  else plural = last .. "s" end
  local out = { { form = lemma, feat = "sg" } }
  if plural and plural ~= last then out[#out + 1] = { form = first_words .. plural, feat = "pl" } end
  return out
end

function M.adj_forms(lemma)
  local out = { { form = lemma, feat = "base" } }
  local comp, sup
  if lemma:find("e$") then comp, sup = lemma .. "r", lemma .. "st"
  elseif lemma:find("[^aeiou]y$") then comp, sup = lemma:sub(1, -2) .. "ier", lemma:sub(1, -2) .. "iest"
  elseif cvc(lemma) and monosyllabic(lemma) then comp, sup = lemma .. lemma:sub(-1) .. "er", lemma .. lemma:sub(-1) .. "est"
  else comp, sup = lemma .. "er", lemma .. "est" end
  local irreg = { good = { "better", "best" }, bad = { "worse", "worst" }, far = { "farther", "farthest" }, little = { "less", "least" },
    many = { "more", "most" }, much = { "more", "most" } }
  if irreg[lemma] then comp, sup = irreg[lemma][1], irreg[lemma][2] end
  out[#out + 1] = { form = comp, feat = "comp" }
  out[#out + 1] = { form = sup, feat = "sup" }
  return out
end

-- Conservative suffix guesses for words that are NOT in the lexicon. Returns candidates {lemma, pos, feat, conf}.
function M.guess(form)
  local out = {}
  local function add(l, pos, feat, conf) out[#out + 1] = { lemma = l, pos = pos, feat = feat, conf = conf } end
  if #form >= 5 and form:find("ing$") then
    local stem = form:sub(1, -4)
    add(stem, "verb", "ing", 0.5)
    add(stem .. "e", "verb", "ing", 0.4)
    if stem:sub(-1) == stem:sub(-2, -2) then add(stem:sub(1, -2), "verb", "ing", 0.4) end
  end
  if #form >= 4 and form:find("ied$") then add(form:sub(1, -4) .. "y", "verb", "past", 0.5)
  elseif #form >= 4 and form:find("ed$") then
    local stem = form:sub(1, -3)
    add(stem, "verb", "past", 0.5)
    add(stem .. "e", "verb", "past", 0.4)
    if stem:sub(-1) == stem:sub(-2, -2) then add(stem:sub(1, -2), "verb", "past", 0.4) end
  end
  local es_plural = form:find("[sxz]es$") or form:find("[cs]hes$")
  if #form >= 4 and form:find("ies$") then add(form:sub(1, -4) .. "y", "noun", "pl", 0.5); add(form:sub(1, -4) .. "y", "verb", "3sg", 0.4)
  elseif #form >= 4 and es_plural then
    add(form:sub(1, -3), "noun", "pl", 0.5); add(form:sub(1, -3), "verb", "3sg", 0.4)
  elseif #form >= 4 and form:find("s$") and not form:find("ss$") and not form:find("us$") and not form:find("is$") then
    add(form:sub(1, -2), "noun", "pl", 0.5); add(form:sub(1, -2), "verb", "3sg", 0.4)
  end
  return out
end

M.IRREGULAR_VERBS = (function() local t = {}; for k in pairs(IRREG_VERB) do t[norm_key(k)] = true end; return t end)()

return M
