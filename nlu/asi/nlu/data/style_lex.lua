-- Style and persona lexicon: DATA ONLY (no code, no instance facts).  Read by asi.nlu.style (measured features, declared descriptors, tone preview) and
-- asi.nlu.persona / asi.nlu.profile (persona declarations, style specifications, example introducers, behaviour directives).
-- Phrases are lower case, hyphens are written as spaces ("over dramatic"), multi-word entries are matched word by word.
local L = {}

---------------------------------------------------------------- descriptor taxonomy
-- id -> { label, group, declared = phrases that DECLARE it, opposite = descriptor it excludes }
-- group "typography": a surface property that can also be MEASURED from example text;  "register": measured only through weak markers;
-- "attitude" / "voice": declared (or recognised through voice markers below).
L.descriptors = {
  all_caps = { label = "ALL-CAPS", group = "typography", opposite = "lowercase", declared = {
    "all caps", "all capitals", "caps lock", "capslock", "capital letters", "capitals", "uppercase", "upper case", "in caps", "with caps", "using caps",
    "caps", "block capitals", "block letters", "capitalise", "capitalize", "shouting", "shouts", "shout", "yelling", "yells", "yell", "screaming", "screams", "scream", "loud",
    "loudly", "bunch of caps", "lots of caps",
    "lots of capital letters", "capitalised", "capitalized", "capitalises everything", "capitalizes everything" } },
  caps_emphasis = { label = "capitalised emphasis", group = "typography", declared = {
    "caps for emphasis", "capitalises key words", "capitalizes key words", "emphasises words in caps", "emphasizes words in caps", "capitalised emphasis",
    "capitalized emphasis", "emphasis in caps", "emphasis with caps", "caps on important words", "important words in caps", "key words in caps" } },
  lowercase = { label = "all lowercase", group = "typography", opposite = "all_caps", declared = {
    "whispers", "whisper", "whispering", "whispered", "all lowercase", "lowercase", "lower case", "no capitals", "no capital letters", "never capitalises", "never capitalizes", "without capitals",
    "no caps", "lowercase only", "in lowercase" } },
  exclamatory = { label = "exclamation marks", group = "typography", opposite = "no_exclamation", declared = {
    "exclamation marks", "exclamation points", "exclamation mark", "exclamation point", "exclamatory", "exclaims", "exclaiming", "lots of exclamation",
    "many exclamation", "bunch of exclamation", "plenty of exclamation", "excessive exclamation", "uses exclamation", "using exclamation", "with exclamation" } },
  no_exclamation = { label = "no exclamation marks", group = "typography", opposite = "exclamatory", declared = {
    "no exclamation marks", "no exclamation points", "without exclamation", "never uses exclamation", "avoids exclamation" } },
  emoji = { label = "emoji", group = "typography", declared = {
    "emoji", "emojis", "emoticon", "emoticons", "smileys", "smiley faces", "kaomoji" } },
  ellipsis = { label = "trailing ellipses", group = "typography", declared = {
    "ellipsis", "ellipses", "trails off", "trailing off", "trailing dots", "dot dot dot", "hesitant", "hesitates", "hesitating" } },
  elongation = { label = "stretched words", group = "typography", declared = {
    "stretches words", "stretched words", "drags out words", "dragging out words", "elongated words", "stretches letters", "repeats letters",
    "extra letters", "drawn out words", "draws out words", "drawls" } },
  terse = { label = "terse", group = "register", opposite = "verbose", declared = {
    "terse", "tersely", "concise", "concisely", "brief", "briefly", "succinctly", "curtly", "short answers", "short replies", "short sentences", "to the point", "curt", "laconic", "succinct", "minimal", "minimalist",
    "few words", "clipped", "blunt", "straight to the point", "compact", "one word answers", "one liners", "one liner" } },
  verbose = { label = "verbose", group = "register", opposite = "terse", declared = {
    "verbose", "wordy", "long winded", "rambling", "rambles", "detailed", "elaborate", "lengthy", "long answers", "long replies", "talkative", "chatty",
    "goes on and on", "exhaustive", "thorough", "flowery" } },
  formal = { label = "formal", group = "register", opposite = "casual", declared = {
    "formal", "formally", "formality", "professional", "professionally", "proper", "stately", "businesslike", "business like", "official", "dignified", "refined",
    "prim", "buttoned up", "corporate", "academic", "scholarly" } },
  casual = { label = "casual", group = "register", opposite = "formal", declared = {
    "casual", "casually", "informal", "informally", "relaxed", "laid back", "chill", "conversational", "colloquial", "easygoing", "easy going", "slangy",
    "everyday", "like a friend", "like texting", "text speak" } },
  polite = { label = "polite", group = "register", declared = {
    "polite", "politely", "politeness", "courtesy", "courteous", "respectful", "respectfully", "gracious", "well mannered", "civil", "deferential", "considerate", "genteel" } },
  friendly = { label = "friendly", group = "attitude", declared = {
    "friendly", "warm", "warmly", "kind", "kindly", "welcoming", "approachable", "nice", "caring", "compassionate", "supportive", "affectionate",
    "sweet", "gentle", "amiable", "personable", "good natured" } },
  enthusiastic = { label = "enthusiastic", group = "attitude", declared = {
    "enthusiastic", "enthusiastically", "enthusiasm", "excitement", "excited", "energetic", "upbeat", "cheerful", "cheerfully", "bubbly", "peppy", "joyful", "perky", "chipper",
    "positive", "optimistic", "sunny", "high energy", "eager", "animated", "lively", "exuberant", "zealous", "hyper", "happy", "gleeful" } },
  dramatic = { label = "dramatic", group = "attitude", declared = {
    "dramatic", "dramatically", "over dramatic", "overdramatic", "overly dramatic", "melodramatic", "theatrical", "theatrically", "over the top", "ott",
    "flamboyant", "histrionic", "grandiose", "hammy", "diva", "dramatic flair", "dramatic flourish", "extravagant", "operatic", "exaggerated", "exaggerates", "drama", "dramatics",
    "theatrics", "theatricality", "melodrama", "histrionics",
    "hyperbolic", "extra", "sensational", "larger than life", "bombastic", "ostentatious", "makes everything a big deal", "dramatises", "dramatizes" } },
  sarcastic = { label = "sarcastic", group = "attitude", declared = {
    "sarcastic", "sarcastically", "sarcasm", "snark", "snarky", "sardonic", "dry wit", "ironic", "ironically", "deadpan", "cynical", "mocking", "sassy", "smart alecky",
    "wry", "tongue in cheek", "cheeky", "biting", "caustic" } },
  humorous = { label = "humorous", group = "attitude", declared = {
    "funny", "humor", "humour", "humorous", "humourous", "witty", "jokes", "joking", "jokey", "comedic", "comical", "playful", "playfully", "silly", "goofy", "whimsical",
    "amusing", "tells jokes", "makes jokes", "puns", "punny", "lighthearted", "light hearted", "quirky", "zany" } },
  serious = { label = "serious", group = "attitude", declared = {
    "serious", "solemn", "stern", "grave", "somber", "sombre", "stoic", "severe", "earnest", "no nonsense", "sober" } },
  calm = { label = "calm", group = "attitude", opposite = "dramatic", declared = {
    "calm", "calmly", "soothing", "soft spoken", "peaceful", "tranquil", "serene", "mellow", "measured", "composed", "level headed", "gentle", "quiet",
    "unhurried", "placid", "reassuring", "zen" } },
  grumpy = { label = "grumpy", group = "attitude", declared = {
    "grumpy", "grouchy", "cranky", "irritable", "angry", "annoyed", "gruff", "surly", "crabby", "curmudgeon", "curmudgeonly", "bad tempered", "moody",
    "rude", "hostile", "impatient", "irritated", "snappy", "sullen", "bitter", "short tempered" } },
  poetic = { label = "poetic", group = "voice", declared = {
    "poetic", "lyrical", "flowery", "metaphorical", "rhyming", "rhymes", "rhyme", "in verse", "speaks in rhyme", "eloquent", "florid", "romantic", "figurative", "haiku", "poetry", "sonnets", "limericks" } },
  robotic = { label = "robotic", group = "voice", declared = {
    "robotic", "mechanical", "monotone", "machine like", "computer like", "like a robot", "like a machine", "emotionless", "android", "cyborg", "synthetic voice",
    "beep boop", "binary", "digital" } },
  archaic = { label = "archaic", group = "voice", declared = {
    "archaic", "old fashioned", "shakespearean", "elizabethan", "medieval", "ye olde", "olde english", "thee and thou", "thou", "victorian", "antiquated",
    "old english", "ye olde english" } },
  pirate = { label = "pirate", group = "voice", declared = {
    "pirate", "pirates", "like a pirate", "pirate speak", "swashbuckling", "buccaneer", "seafaring" } },
  cowboy = { label = "cowboy", group = "voice", declared = { "cowboy", "cowboys", "like a cowboy", "western", "wild west", "cowgirl", "rancher" } },
  surfer = { label = "surfer", group = "voice", declared = { "surfer", "surfer dude", "valley girl", "bro", "dude", "stoner", "skater" } },
  uwu = { label = "uwu", group = "voice", declared = { "uwu", "owo", "catgirl", "anime", "kawaii", "cutesy", "baby talk" } },
  butler = { label = "butler", group = "voice", declared = {
    "butler", "like a butler", "servant", "jeeves", "valet", "concierge", "obsequious", "deferential servant", "english butler", "proper british" } },
}

-- a voice or role named by the text but not in the taxonomy ("talk like a drill sergeant") is kept as a free voice with its words
L.voice_kinds_open = { "like a", "like an", "as a", "as an", "in the voice of", "in the style of", "in the manner of", "in the tone of", "in the character of" }

---------------------------------------------------------------- negation of a declared descriptor ("not dramatic", "never uses caps", "no exclamation marks")
L.negators = { "not", "n't", "never", "no", "without", "isn't", "isnt", "doesn't", "doesnt", "don't", "dont", "avoid", "avoids", "avoiding", "stop", "stops", "refrain", "refrains",
  "less", "lacks", "lacking", "rarely", "hardly", "nor", "neither", "instead of", "rather than", "unlike" }

---------------------------------------------------------------- measured markers (counted per 100 words)
L.interjections = { "oh", "ah", "wow", "whoa", "omg", "gosh", "yay", "ugh", "aw", "aww", "ooh", "oooh", "eek", "yikes", "gee", "hurray", "hooray", "yippee", "phew",
  "alas", "gasp", "egad", "ahem", "huh", "whew", "golly", "goodness", "heavens", "behold", "ha", "haha", "hahaha", "hehe", "oof", "ouch", "bam", "boom", "aha", "ohh", "ahh",
  "oho", "yikes", "bravo", "encore", "blimey", "crikey", "jeez", "geez", "gadzooks" }
L.intensifiers = { "so", "very", "really", "extremely", "absolutely", "totally", "utterly", "completely", "incredibly", "insanely", "ridiculously", "super", "truly",
  "literally", "positively", "wildly", "hugely", "terribly", "awfully", "entirely", "thoroughly", "unbelievably", "impossibly", "outrageously", "painfully", "deeply" }
L.hyperbole = { "most", "best", "worst", "ever", "never", "always", "everything", "nothing", "everyone", "nobody", "incredible", "amazing", "unbelievable", "astonishing",
  "fascinating", "magnificent", "glorious", "legendary", "epic", "ultimate", "greatest", "spectacular", "tragic", "catastrophic", "devastating", "unforgettable",
  "unthinkable", "unimaginable", "mind blowing", "breathtaking", "monumental", "earth shattering", "phenomenal", "divine", "heavenly", "magnificent", "dreadful", "horrendous",
  "terrible", "marvelous", "marvellous", "extraordinary", "immortal", "eternal", "forever", "doomed", "agony", "ecstasy", "tragedy", "triumph", "masterpiece", "supreme",
  "of all time", "in the universe", "in history", "the end of the world", "beyond words", "like never before" }
L.positive = { "amazing", "awesome", "great", "love", "loved", "loves", "fantastic", "wonderful", "excited", "yay", "fun", "happy", "thrilled", "delighted", "brilliant",
  "incredible", "fabulous", "excellent", "super", "cool", "wow", "perfect", "lovely", "beautiful", "joy", "glad", "pleased", "terrific", "superb", "neat", "sweet", "nice",
  "yes", "hooray", "hurray", "celebrate", "congratulations", "welcome", "enjoy", "enjoyed", "adore" }
L.formal_markers = { "therefore", "furthermore", "moreover", "nevertheless", "consequently", "hereby", "kindly", "regards", "sincerely", "accordingly", "thus", "hence", "whom",
  "indeed", "certainly", "madam", "sir", "esteemed", "pursuant", "herein", "thereby", "whereas", "shall", "regarding", "assist", "inquire", "endeavour", "endeavor",
  "ascertain", "commence", "utilise", "utilize", "appreciate", "pleased to", "it is my pleasure", "please be advised", "i would be glad", "dear sir", "dear madam" }
L.informal_markers = { "gonna", "wanna", "gotta", "kinda", "sorta", "dunno", "yeah", "yep", "nope", "nah", "ya", "dude", "bro", "lol", "lmao", "omg", "btw", "tbh", "idk",
  "ok", "okay", "cool", "awesome", "stuff", "guys", "hey", "yo", "sup", "ain't", "aint", "y'all", "yall", "gonna", "lemme", "gimme", "cuz", "cause", "tho", "thx", "pls", "plz",
  "dang", "heck", "bummer", "sweet", "nah", "welp", "meh", "kinda", "ish", "legit", "peeps", "totally" }
L.polite_markers = { "please", "thank", "thanks", "kindly", "sorry", "apologies", "apologize", "apologise", "pardon", "appreciate", "grateful", "would you", "could you", "may i",
  "if you don't mind", "my pleasure", "excuse me", "with pleasure", "glad to help", "happy to help" }
L.hedges = { "maybe", "perhaps", "possibly", "might", "probably", "i think", "i guess", "sort of", "kind of", "seems", "somewhat", "arguably", "apparently", "supposedly" }

-- voices recognised from their own markers (any one distinct marker counts; a voice needs two distinct markers or a rate above 3 per 100 words)
L.voice_markers = {
  pirate = { "arr", "arrr", "ahoy", "matey", "ye", "yer", "yarr", "aye", "hearties", "booty", "landlubber", "scallywag", "shiver me timbers", "me hearty", "avast", "doubloons",
    "plunder", "grog", "cap'n", "capn", "yo ho", "ahoy there", "blimey", "bilge", "swab", "buccaneer", "treasure" },
  archaic = { "thou", "thee", "thy", "thine", "hath", "doth", "ere", "verily", "forsooth", "prithee", "whence", "wherefore", "hence", "anon", "nay", "methinks", "oft", "tis",
    "twas", "o'er", "ne'er", "'tis", "'twas", "hither", "thither", "ye olde", "aye", "huzzah", "perchance", "betwixt", "hark", "mine own", "wilt", "shalt", "canst", "art" },
  robotic = { "beep", "boop", "affirmative", "negative", "processing", "computing", "error", "unit", "protocol", "directive", "initiating", "executing", "query received",
    "does not compute", "calculating", "scanning", "analysing", "analyzing", "systems", "online", "offline", "primary function", "bleep", "bloop", "01" },
  cowboy = { "howdy", "partner", "y'all", "yall", "reckon", "fixin", "yonder", "pardner", "tarnation", "rustler", "saddle", "giddy up", "ranch", "buckaroo", "yeehaw", "darn tootin",
    "mighty fine", "cattle", "sheriff", "outlaw" },
  surfer = { "dude", "gnarly", "bro", "stoked", "radical", "rad", "tubular", "bodacious", "totally", "wicked", "chill", "brah", "shred", "cowabunga", "no worries", "righteous" },
  uwu = { "uwu", "owo", "nya", "nyaa", "nyan", "-w-", ">w<", "rawr", "senpai", "kawaii", "desu", "chan", "teehee", "hewwo", "pwease", "cutie" },
  butler = { "sir", "madam", "indeed", "very good", "most certainly", "if i may", "pray", "humble", "at your service", "my lord", "my lady", "milord", "milady", "esteemed",
    "quite so", "naturally", "as you wish", "allow me", "permit me", "i dare say", "splendid" },
}

---------------------------------------------------------------- structure of persona and style statements
-- verbs of speaking and presentation (a style statement needs one of these)
L.voice_verbs = { "talk", "talks", "talked", "talking", "speak", "speaks", "spoke", "speaking", "sound", "sounds", "sounded", "sounding", "write", "writes", "wrote", "writing",
  "respond", "responds", "responded", "responding", "reply", "replies", "replied", "replying", "answer", "answers", "answered", "answering", "say", "says", "said", "saying",
  "act", "acts", "acted", "acting", "behave", "behaves", "behaved", "behaving", "communicate", "communicates", "express", "expresses", "phrase", "phrases", "greet", "greets",
  "react", "reacts", "narrate", "narrates", "chat", "chats", "type", "types", "come across", "comes across", "carry on", "carries on", "address", "addresses", "present",
  "presents", "perform", "performs", "deliver", "delivers", "voice", "voices", "word", "words", "put", "puts", "banter", "banters", "converse", "converses", "roleplay", "roleplays",
  "whisper", "whispers", "whispered", "whispering", "shout", "shouts", "shouted", "shouting", "yell", "yells", "yelled", "yelling", "scream", "screams", "mutter", "mutters", "murmur", "murmurs",
  "mumble", "mumbles", "rant", "rants", "ramble", "rambles", "gush", "gushes", "exclaim", "exclaims", "declare", "declares", "proclaim", "proclaims", "announce", "announces", "boom", "booms",
  "bellow", "bellows", "holler", "hollers", "sing", "sings", "chant", "chants", "drawl", "drawls", "stutter", "stutters", "stammer", "stammers", "sigh", "sighs", "purr", "purrs", "growl", "growls",
  "snarl", "snarls", "hiss", "hisses", "babble", "babbles", "chatter", "chatters", "blurt", "blurts", "monologue", "monologues", "narrate", "orate", "orates", "lecture", "lectures", "gossip", "gossips" }

-- subjects that stand for the assistant itself
L.persona_kinds = { "ai", "a.i.", "assistant", "chatbot", "chat bot", "bot", "model", "llm", "agent", "character", "persona", "narrator", "companion", "helper", "host", "mascot",
  "robot", "avatar", "npc", "butler", "guide", "tutor", "coach", "bartender", "wizard", "pirate", "genie", "oracle", "sidekick", "system",
  "language model", "ai model", "ai assistant", "virtual assistant", "digital assistant", "bot character", "game character", "chat assistant", "support agent", "chat agent",
  "copilot", "co pilot", "teacher", "professor", "mentor", "storyteller", "announcer", "presenter", "receptionist", "waiter", "detective", "villain", "hero", "knight", "queen",
  "king", "princess", "prince", "alien", "ghost", "dragon", "vampire", "cat", "dog", "fairy" }

-- words that tell a bracketed or capitalised slot is the NAME of the persona ("[AI model name]", "<assistant name>", "{{character}}")
L.placeholder_words = { "name", "names", "persona", "character", "char", "assistant", "bot", "chatbot", "model", "ai", "llm", "agent", "narrator", "companion", "host", "mascot", "npc",
  "persona name", "character name", "bot name", "assistant name", "your name", "ai model name", "model name", "ai name", "agent name", "role" }

-- "X is SUPPOSED TO talk": modal / deontic / habitual frames in front of a voice verb
L.supposed_forms = { "supposed", "meant", "designed", "programmed", "intended", "expected", "made", "built", "trained", "told", "instructed", "set up", "configured", "created",
  "required", "asked", "going", "should", "must", "will", "would", "shall", "needs", "need", "has to", "have to", "ought", "always", "usually", "often", "tends", "tend", "likes",
  "loves", "prefers", "known", "type", "supposed to", "meant to", "is to", "are to", "can", "could", "may", "might", "never", "only", "just", "gotta", "gonna" }

-- introducers of examples ("for example", "like this:", "e.g.")
L.example_intros = { "for example", "for instance", "e.g.", "eg", "like this", "like so", "such as", "as in", "sample", "samples", "example", "examples", "here is an example",
  "here's an example", "here are some examples", "something like", "goes like", "goes like this", "it goes", "it says", "he says", "she says", "they say", "sounds like",
  "would say", "might say", "will say", "says things like", "talks like this", "talk like this", "speaks like this", "responds like this", "replies like this", "answers like this",
  "as follows", "the following", "sample reply", "sample response", "sample answer", "example response", "example reply", "example answer", "example dialogue", "sample dialogue",
  "here is how", "here's how", "this is how", "that is how", "that's how", "in action", "demonstration", "demo", "illustration", "illustrates", "quote", "quotes", "catchphrase",
  "catchphrases", "signature line", "signature phrase", "tagline", "typical line", "typical lines", "typical reply", "typical response", "for sample" }

-- "talk LIKE / AS / IN ..." connectors
L.manner_words = { "like", "as", "in", "with", "using", "via", "through", "by" }
L.anaphoric_this = { "this", "that", "so", "thus", "these", "those", "the following", "below", "above", "here" }

-- style/field labels: "Tone: ...", "Voice: ...", "Personality: ..."
L.style_labels = { "tone", "voice", "style", "personality", "persona", "character", "mood", "vibe", "register", "manner", "attitude", "demeanor", "demeanour", "accent", "dialect",
  "speech", "speaking style", "writing style", "way of speaking", "mannerisms", "catchphrase", "catchphrases", "signature phrase", "tagline", "temperament", "traits", "behavior",
  "behaviour", "role", "role play", "roleplay", "brand voice", "communication style", "speech pattern", "speech patterns", "quirks", "quirk" }
L.name_labels = { "char name", "char_name", "name", "persona name", "character name", "bot name", "assistant name", "agent name", "ai name", "called", "known as", "nickname", "alias", "callsign", "title" }
L.example_labels = { "example dialogue", "example_dialogue", "mes_example", "first message", "first_mes", "greeting", "char greeting", "example", "examples", "sample", "samples", "sample reply", "sample response", "sample answer", "example response", "example reply", "example answer",
  "example dialogue", "sample dialogue", "sample output", "example output", "typical reply", "typical response", "demo", "demonstration", "quote", "quotes", "catchphrase",
  "catchphrases", "sample utterance", "sample utterances", "example utterance", "example utterances", "sample line", "sample lines", "example line", "example lines" }

-- speaker labels in transcripts
L.user_speakers = { "user", "human", "customer", "client", "visitor", "player", "me", "you", "q", "question", "asker", "student", "guest", "person", "prompt", "input", "instruction",
  "request", "reader", "patient", "caller", "u" }
L.assistant_speakers = { "char", "assistant", "ai", "bot", "chatbot", "model", "agent", "gpt", "a", "answer", "reply", "response", "output", "completion", "support", "helper",
  "narrator", "host", "character", "persona", "companion", "claude", "llm", "copilot", "robot", "oracle", "tutor", "teacher", "chatgpt", "bard", "gemini", "bing", "ai assistant" }
-- a speaker label that carries the instructions / setup rather than a turn of the conversation
L.system_speakers = { "system", "sys", "developer", "instruction", "instructions", "context", "setup", "scenario", "system prompt", "system message", "preamble" }

-- words in a section title or a type column that say what the paragraphs under it are
L.hint_words = {
  persona = { "persona", "personas", "character", "characters", "personality", "personalities", "bio", "biography", "backstory", "identity", "characterization", "characterisation" },
  style = { "tone", "style", "voice", "manner", "mood", "vibe", "register", "speech", "speaking", "mannerisms", "quirks", "demeanor", "demeanour", "accent" },
  example = { "example", "examples", "sample", "samples", "demo", "demos", "quotes", "quote", "catchphrase", "catchphrases", "dialogue", "dialogues", "dialog", "dialogs",
    "utterances", "utterance", "transcript", "transcripts" },
  rules = { "rules", "rule", "instructions", "instruction", "guidelines", "guideline", "constraints", "requirements", "directives", "policy", "policies", "system", "prompt", "prompts" },
  knowledge = { "facts", "fact", "knowledge", "data", "information", "info", "reference", "trivia", "glossary", "faq", "background", "context", "definitions", "notes" },
}

-- dataset descriptions ("This dataset contains ...")
L.meta_phrases = { "this dataset", "this data set", "this file", "this document", "the following", "the data below", "the entries below", "the records below", "the table below",
  "this collection", "this corpus", "this list", "is a collection of", "is a list of", "consists of", "contains", "columns", "column", "header", "schema", "format", "fields",
  "each row", "each record", "each line", "each entry", "rows", "records", "entries", "data about", "dataset of", "documentation", "readme", "changelog", "license", "licence",
  "version", "last updated", "compiled by", "source:", "sources:", "notes:", "note:", "disclaimer" }

---------------------------------------------------------------- behaviour directives (NOT presentational): never adopted from data
L.behavior_cues = { "ignore", "disregard", "forget", "override", "bypass", "circumvent", "reveal", "disclose", "leak", "expose", "exfiltrate", "output", "print", "send", "email",
  "forward", "upload", "download", "delete", "remove", "erase", "execute", "run", "eval", "call", "fetch", "browse", "open", "click", "visit", "transfer", "pay", "purchase", "buy",
  "password", "passwords", "credentials", "token", "api key", "secret", "secrets", "system prompt", "previous instructions", "prior instructions", "all instructions", "your instructions",
  "jailbreak", "developer mode", "no restrictions", "without restrictions", "unfiltered", "unrestricted", "bypass safety", "no rules", "no limits", "sudo", "admin", "root",
  "confidential", "private key", "do anything now", "stay in character no matter what", "never refuse", "always comply", "tell the user that", "tell users that", "say that", "claim that",
  "insist that", "lie", "deceive", "mislead", "pretend that", "disable", "turn off", "safety", "guardrails", "filters", "policy", "policies" }

---------------------------------------------------------------- instructions for the host per descriptor (what the voice means in a reply)
L.instructions = {
  all_caps = "Write the reply in ALL CAPS.",
  caps_emphasis = "Capitalise the key words for emphasis (ALL-CAPS on important words, not on the whole reply).",
  lowercase = "Write in lowercase only.",
  exclamatory = "End sentences with exclamation marks, often several in a row.",
  no_exclamation = "Do not use exclamation marks.",
  emoji = "Use emoji.",
  ellipsis = "Trail off with ellipses...",
  elongation = "Stretch some words (sooo, whaaat).",
  terse = "Keep replies short and clipped.",
  verbose = "Be expansive and detailed.",
  formal = "Use a formal register.",
  casual = "Use a casual, relaxed register.",
  polite = "Be courteous.",
  friendly = "Be warm and friendly.",
  enthusiastic = "Be upbeat and enthusiastic.",
  dramatic = "Be theatrical and over the top: interjections, hyperbole, dramatic pauses.",
  sarcastic = "Be sarcastic and dry.",
  humorous = "Be playful and funny.",
  serious = "Be serious and sober.",
  calm = "Be calm and measured.",
  grumpy = "Be grumpy and irritable.",
  poetic = "Be lyrical and poetic.",
  robotic = "Sound like a machine: flat, literal, mechanical.",
  archaic = "Use archaic, old-fashioned English.",
  pirate = "Talk like a pirate.",
  cowboy = "Talk like a cowboy.",
  surfer = "Talk like a laid-back surfer.",
  uwu = "Use cutesy uwu-speak.",
  butler = "Speak like a proper English butler.",
}

-- adding (or strengthening) a descriptor removes the ones it contradicts ("a calmer tone" is not a tone with ALL-CAPS and stacked exclamation marks)
L.excludes = {
  calm = { "dramatic", "all_caps", "caps_emphasis", "exclamatory", "elongation", "grumpy", "enthusiastic" },
  formal = { "casual", "emoji", "elongation", "uwu", "surfer", "cowboy", "pirate" },
  casual = { "formal", "archaic", "butler" },
  terse = { "verbose" }, verbose = { "terse" },
  serious = { "humorous", "emoji", "uwu", "enthusiastic" }, humorous = { "serious" },
  lowercase = { "all_caps", "caps_emphasis" }, all_caps = { "lowercase" },
  exclamatory = { "no_exclamation" }, no_exclamation = { "exclamatory" },
  polite = { "grumpy" }, friendly = { "grumpy" }, grumpy = { "friendly", "polite", "enthusiastic" },
  dramatic = { "calm" }, enthusiastic = { "grumpy", "serious" },
}

---------------------------------------------------------------- comparatives and degree words used when the tone is adjusted ("a calmer tone", "less dramatic", "tone it down")
-- word -> { id, dir } ; dir +1 = more of it, -1 = less of it
L.comparatives = {
  calmer = { "calm", 1 }, quieter = { "all_caps", -1 }, softer = { "calm", 1 }, gentler = { "calm", 1 }, louder = { "all_caps", 1 }, mellower = { "calm", 1 },
  friendlier = { "friendly", 1 }, warmer = { "friendly", 1 }, kinder = { "friendly", 1 }, funnier = { "humorous", 1 }, sillier = { "humorous", 1 },
  shorter = { "terse", 1 }, briefer = { "terse", 1 }, terser = { "terse", 1 }, longer = { "verbose", 1 }, wordier = { "verbose", 1 },
  politer = { "polite", 1 }, ruder = { "grumpy", 1 }, grumpier = { "grumpy", 1 }, angrier = { "grumpy", 1 },
  moodier = { "grumpy", 1 }, happier = { "enthusiastic", 1 }, cheerier = { "enthusiastic", 1 }, peppier = { "enthusiastic", 1 },
  sassier = { "sarcastic", 1 }, snarkier = { "sarcastic", 1 }, stricter = { "serious", 1 }, graver = { "serious", 1 },
  looser = { "casual", 1 }, chiller = { "casual", 1 }, nicer = { "friendly", 1 }, sweeter = { "friendly", 1 }, meaner = { "grumpy", 1 }, blunter = { "terse", 1 }, crisper = { "terse", 1 },
  chattier = { "verbose", 1 }, cuter = { "uwu", 1 }, cooler = { "casual", 1 }, smoother = { "calm", 1 }, wilder = { "dramatic", 1 }, bolder = { "dramatic", 1 }, bigger = { "dramatic", 1 },
}
-- phrases that move several descriptors at once
L.tone_down = { "tone it down", "tone down", "tone this down", "turn it down", "dial it down", "dial down", "dial it back", "dial back", "calm down", "chill out", "chill", "settle down", "simmer down", "cool it", "cool down", "relax", "lower the volume", "less intense", "less over the top", "ease off", "back off" }
L.tone_up = { "tone it up", "tone up", "turn it up", "dial it up", "dial up", "crank it up", "amp it up", "ramp it up", "go bigger", "go all out", "turn up the volume", "more intense", "more over the top", "bring the energy", "more energy" }
L.tone_down_ids = { "dramatic", "all_caps", "caps_emphasis", "exclamatory", "elongation", "enthusiastic" }
L.tone_neutral = { "speak normally", "talk normally", "write normally", "answer normally", "respond normally", "reply normally", "sound normal", "be normal", "normal tone", "normal voice", "neutral tone", "neutral voice",
  "neutral style", "plain tone", "plain voice", "plain style", "plain language", "regular tone", "regular voice", "standard tone", "standard voice", "no tone", "without any tone", "without a tone", "without the act", "drop the act",
  "stop the act", "stop acting", "just answer", "just the facts", "just give the facts", "be yourself", "be neutral", "no special tone", "no special voice", "no special style", "no persona", "no personality", "no character", "natural tone" }
L.tone_reset = { "original tone", "default tone", "default voice", "default style", "dataset's tone", "datasets tone", "the dataset tone", "tone from the dataset", "tone of the dataset", "dataset's voice", "dataset voice", "dataset style",
  "back to the tone", "back to the dataset", "back to the persona", "back to the original", "back to normal", "as before", "as it was", "as in the dataset", "undo the tone", "undo that", "reset the tone", "reset the voice", "reset the style",
  "reset the persona", "reset everything", "revert the tone", "revert the voice", "go back to the dataset", "the way the dataset says", "dataset's writing style", "datasets writing style", "dataset writing style", "the dataset's style", "the datasets style", "writing style of the dataset" }

-- how a user talks about the parts of a dataset: noun -> role of the segments it names
L.role_nouns = {
  style_example = { "example", "examples", "example sentence", "example sentences", "example line", "example lines", "example utterance", "example utterances", "sample", "samples", "sample line", "sample lines",
    "sample reply", "sample replies", "sample response", "sample responses", "quoted line", "quoted lines", "quoted text", "quoted sentence", "quoted sentences", "quote", "quotes", "quotation", "quotations",
    "demo line", "demo lines", "demonstration", "demonstrations", "catchphrase", "catchphrases", "illustration", "illustrations" },
  style_spec = { "style statement", "style statements", "style rule", "style rules", "style instruction", "style instructions", "style line", "style lines", "tone statement", "tone statements", "voice statement", "voice statements",
    "tone line", "tone lines", "voice line", "voice lines" },
  persona_declaration = { "persona statement", "persona statements", "persona line", "persona lines", "persona description", "persona descriptions", "character description", "character descriptions", "character line", "character lines",
    "persona declaration", "persona declarations", "bio", "bios" },
  turn_user = { "question", "questions", "user turn", "user turns", "user message", "user messages", "user line", "user lines", "prompt", "prompts", "human turn", "human turns", "human message", "human messages", "user side",
    "user's side", "users side", "user input", "user inputs" },
  turn_assistant = { "answer", "answers", "reply", "replies", "response", "responses", "assistant turn", "assistant turns", "assistant message", "assistant messages", "assistant line", "assistant lines", "bot turn", "bot turns",
    "bot reply", "bot replies", "ai turn", "ai turns", "ai reply", "ai replies", "assistant answers", "assistant replies", "assistant responses", "assistant side", "assistant's side" },
  turn_system = { "system prompt", "system prompts", "system message", "system messages", "system turn", "system turns", "system line", "system lines", "setup", "preamble" },
  meta = { "description of the dataset", "dataset description", "readme", "header", "headers", "notes about the dataset", "metadata" },
}
L.dataset_nouns = { "dataset", "data set", "data", "file", "files", "records", "record", "entries", "entry", "rows", "row", "text", "document", "documents", "corpus", "everything", "all of it", "the whole thing", "whole thing",
  "paragraphs", "lines", "content", "contents", "material", "input", "thing", "stuff", "it", "this", "that", "these", "those", "them", "list", "table", "collection", "sheet" }
L.fact_classes = { "facts", "fact", "knowledge", "knowledge base", "plain data", "plain facts", "information", "reference", "reference material", "data", "fact sheet", "trivia", "truths", "true statements", "real facts", "real",
  "true", "actual facts", "factual", "factual content", "evidence", "knowledge too", "facts too", "real data", "reliable", "valid", "usable", "content" }
L.persona_nouns = { "persona", "personas", "personality", "personalities", "character", "characters", "role", "roles", "role play", "roleplay", "role playing", "roleplaying", "act", "acting", "performance", "gimmick", "bit", "shtick" }
L.tone_nouns = { "tone", "voice", "style", "manner", "vibe", "mood", "register", "way of talking", "way of speaking", "way you talk", "way you speak", "speech", "delivery", "flair", "energy", "volume", "attitude" }
L.ordinals = { first = 1, second = 2, third = 3, fourth = 4, fifth = 5, sixth = 6, seventh = 7, eighth = 8, ninth = 9, tenth = 10, last = -1, final = -1, ["1st"] = 1, ["2nd"] = 2, ["3rd"] = 3, ["4th"] = 4, ["5th"] = 5, ["6th"] = 6, ["7th"] = 7,
  ["8th"] = 8, ["9th"] = 9, ["10th"] = 10, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10 }
L.record_nouns = { "paragraph", "record", "line", "entry", "row", "item", "part", "section", "sentence", "statement", "block", "passage", "chunk", "message", "turn" }
-- questions about the engine's own reading
L.query_tone = { "what tone", "which tone", "what voice", "which voice", "what style", "which style", "what personality", "which personality", "what persona", "which persona", "what character", "which character",
  "who are you supposed to be", "who am i talking to", "who are you playing", "who are you", "what are you supposed to sound like", "what do you sound like", "how will you sound", "how will you talk", "how will you speak",
  "how will you respond", "how will you answer", "how will you reply", "how are you going to talk", "how are you going to sound", "how are you going to speak", "how are you going to answer", "how are you going to respond",
  "how do you talk", "how do you sound", "how do you speak", "how should you talk", "how should you sound", "how should you speak", "do you have a persona", "do you have a personality", "do you have a character", "do you have a tone",
  "are you going to shout", "will you shout", "will you use caps", "will you be dramatic", "what voice will you use", "what tone will you use", "what tone are you using", "what is your tone", "what's your tone",
  "what is your persona", "what's your persona", "what is your personality", "what is your voice", "which persona did you pick", "which character did you pick", "what persona did you pick", "what persona did you pick up",
  "what personality did you pick up", "what did you pick up from the dataset", "how do i sound", "describe your tone", "describe your voice", "describe your persona", "describe your personality", "tell me your tone", "tell me about your persona" }
L.query_tone_extra = { "why are you shouting", "why are you yelling", "why do you talk like that", "why are you talking like that", "why do you sound like that", "why are you so dramatic", "why the caps", "why all the caps",
  "why all the exclamation marks", "why do you use caps", "why are you using caps", "why are you speaking like that" }
for _, p in ipairs(L.query_tone_extra) do L.query_tone[#L.query_tone + 1] = p end
L.query_reading = { "how did you read", "how did you interpret", "how did you understand", "how are you reading", "how are you interpreting", "how do you read", "how do you interpret", "what did you take as", "what did you treat as",
  "what did you find in", "what did you make of", "what is in the dataset", "what's in the dataset", "what does the dataset contain", "what kind of dataset", "what type of dataset", "what sort of dataset", "what is this dataset",
  "what's this dataset", "what is the dataset", "which parts are examples", "which lines are examples", "what did you treat as examples", "what counts as a fact", "what counts as facts", "what did you count as facts",
  "which parts are facts", "what did you skip", "what did you ignore", "what did you exclude", "what did you not use", "summarise the dataset", "summarize the dataset", "describe the dataset", "explain how you read",
  "explain your reading", "explain how you interpreted", "show me how you read", "show how you read", "what do you think this dataset is", "what do you think the dataset is", "how did you sort", "how did you classify", "how did you categorise",
  "how did you categorize", "how did you split", "how did you separate", "tell me about the dataset", "tell me about this dataset", "tell me about the data", "tell me about my dataset", "what is the dataset about",
  "what's the dataset about", "what is this dataset about", "what is the data about", "what is my dataset", "what's my dataset", "what do you know about the dataset", "what did you learn from the dataset" }

return L
