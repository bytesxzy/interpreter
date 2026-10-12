-- Core linguistic resource (DSL text; see asi.nlu.lexicon for the grammar of this format).
-- Closed-class words + ontology + discourse cues. Contains NO factual knowledge about the world.
return [==[
# ============================================================ type ontology
type entity
type agent < entity
type person < agent
type organization < agent
type company < organization
type educational_institution < organization
type university < educational_institution
type school < educational_institution
type agency < organization
type government_body < agency
type hospital < organization
type retailer < company
type museum < organization
type nonprofit < organization
type place < entity
type political_territory < place
type country < political_territory
type subnational < political_territory
type city < place
type geographic_feature < place
type mountain < geographic_feature
type river < geographic_feature
type lake < geographic_feature
type ocean < geographic_feature
type island < geographic_feature
type continent < place
type region < place
type facility < place
type work < entity
type publication < work
type software < work
type programming_language < software
type creative_work < work
type dataset < work
type document < work
type product < entity
type vehicle < product
type event < entity
type concept < entity
type legal_concept < concept
type economic_concept < concept
type scientific_concept < concept
type technology_concept < concept
type educational_concept < concept
type social_concept < concept
type mathematical_concept < concept
type topic < concept
type claim < concept
type substance < entity
type chemical_element < substance
type celestial_body < entity
type planet < celestial_body
type star < celestial_body
type organism < entity
type animal < organism
type plant < organism
type food < entity
type fruit < food
type beverage < food
type mythological_figure < entity
type quantity < entity
type number < quantity
type money < quantity
type time < entity
type date < time
type language < entity
type currency < entity
type service < entity
type version < entity
type identifier < entity
type text < entity
type role < entity
type color < entity

# ============================================================ closed-class words
class det: the a an this that these those some any every each all both either neither another such
class poss_det: my your his her its our their
class prep: according based owing due pursuant of in on at by for from to with without about into onto over under between among through during before after since until till near within across against toward towards via per than as like off up down out around beside besides beyond inside outside upon throughout regarding concerning including excluding except versus vs amid above below behind along
class conj: and or but nor yet so because although though while whereas if unless when whenever once as
class pron: i me we us you he him she her it they them
class pron_poss: mine ours yours hers theirs
class pron_refl: myself yourself himself herself itself ourselves themselves
class discourse: anyway anyhow thanks thank okay ok alright well so yes yeah yep nope sure right hmm indeed however therefore moreover meanwhile finally hello hi hey sorry perhaps maybe honestly basically obviously clearly luckily unfortunately besides otherwise afterwards furthermore nevertheless nonetheless thus hence overall generally typically usually sometimes mostly mainly cheers great perfect awesome interesting
class pron_dem: this that these those
class pron_indef: one ones someone somebody something anyone anybody anything everyone everybody everything nobody nothing none others
class wh: what which who whom whose when where why how whether
class aux_be: be is are was were been being am
class aux_do: do does did
class aux_have: have has had having
class ignorable: please kindly just actually really basically literally honestly um uh uhm er erm hmm ah eh well so like okay ok anyway hey quite simply truly seriously totally definitely obviously clearly
class copula_like: serve serves served serving function functions functioned functioning act acts acted acting stand stands stood standing
class modal: will would shall should can could may might must
class adv: very also just only even still already ever always often usually really quite rather too enough almost nearly mostly mainly especially particularly currently now then there here again together ago soon never sometimes maybe perhaps actually
class particle: up down out off away back
class polite: please kindly
class neg_word: not no never none nobody nothing nowhere neither nor without
class quant: all every each some any many few several most both either only
class stop: the a an of and or to in on at by for with is are was were be been it its as that this which
class clitic_s: 's

pron i: person=1 number=sg animate=1
pron me: person=1 number=sg animate=1
pron we: person=1 number=pl animate=1
pron us: person=1 number=pl animate=1
pron you: person=2 number=any animate=1
pron he: person=3 number=sg gender=m animate=1
pron him: person=3 number=sg gender=m animate=1
pron she: person=3 number=sg gender=f animate=1
pron her: person=3 number=sg gender=f animate=1
pron it: person=3 number=sg gender=n animate=0
pron they: person=3 number=any gender=any animate=any
pron them: person=3 number=any gender=any animate=any
pron one: person=3 number=sg gender=n animate=any
pron ones: person=3 number=pl gender=n animate=any
pron this: person=3 number=sg gender=n animate=any
pron that: person=3 number=sg gender=n animate=any
pron these: person=3 number=pl gender=n animate=any
pron those: person=3 number=pl gender=n animate=any

# ============================================================ speech-act / task verbs
verb find: act=retrieve
verb show: act=retrieve
verb list: act=retrieve
verb get: act=retrieve
verb fetch: act=retrieve
verb search: act=retrieve
verb look up: act=retrieve
verb give: act=retrieve
verb name: act=retrieve
verb identify: act=retrieve
verb retrieve: act=retrieve
verb display: act=retrieve
verb locate: act=retrieve
verb count: act=retrieve
verb enumerate: act=retrieve
verb pull: act=retrieve
verb decide: act=discourse
verb agree: act=discourse
verb say: act=discourse
verb conclude: act=discourse
verb note: act=discourse
verb settle: act=discourse
verb rain: act=ambient
verb snow: act=ambient
verb drizzle: act=ambient
verb hail: act=ambient
verb thunder: act=ambient
verb sleet: act=ambient
verb tell: act=inform
verb explain: act=inform
verb describe: act=inform
verb define: act=inform
verb clarify: act=inform
verb elaborate: act=inform
verb outline: act=inform
verb mention: act=inform
verb compare: act=compare
verb contrast: act=compare
verb differentiate: act=compare
verb distinguish: act=compare
verb summarize: act=task
verb summarise: act=task
verb analyze: act=task
verb analyse: act=task
verb calculate: act=task
verb compute: act=task
verb translate: act=task
verb write: act=task
verb draft: act=task
verb create: act=task
verb make: act=task
verb build: act=task
verb generate: act=task
verb produce: act=task
verb rewrite: act=task
verb edit: act=task
verb fix: act=task
verb review: act=task
verb check: act=task
verb verify: act=task
verb validate: act=task
verb test: act=task
verb evaluate: act=task
verb assess: act=task
verb estimate: act=task
verb predict: act=task
verb plan: act=task
verb design: act=task
verb implement: act=task
verb debug: act=task
verb convert: act=task
verb extract: act=task
verb classify: act=task
verb sort: act=task
verb order: act=task
verb rank: act=task
verb filter: act=task
verb group: act=task
verb use: act=constraint
verb switch: act=constraint
verb choose: act=constraint
verb pick: act=constraint
verb select: act=constraint
verb set: act=constraint
verb apply: act=constraint
verb adopt: act=constraint
verb stick: act=constraint
verb prefer: act=constraint
verb prioritize: act=constraint
verb prioritise: act=constraint
verb favor: act=constraint
verb focus: act=constraint
verb limit: act=constraint
verb restrict: act=constraint
verb keep: act=constraint
verb treat: act=constraint
verb assume: act=constraint
verb exclude: act=exclude
verb avoid: act=exclude
verb skip: act=exclude
verb omit: act=exclude
verb ignore: act=exclude
verb drop: act=exclude
verb remove: act=exclude
verb discard: act=exclude
verb disregard: act=exclude
verb eliminate: act=exclude
verb include: act=include
verb add: act=include
verb incorporate: act=include
verb research: act=focus
verb study: act=focus
verb investigate: act=focus
verb examine: act=focus
verb explore: act=focus
verb want: act=desire
verb need: act=desire
verb like: act=desire
verb wonder: act=desire
verb know: act=cognition
verb think: act=cognition
verb mean: act=cognition
verb call: act=naming
verb consider: act=cognition
verb discuss: act=focus
verb talk: act=focus
verb mention: act=inform
verb propose: act=inform
verb suggest: act=inform
verb recommend: act=inform

# ============================================================ gradable adjectives -> dimension
adj old: dim=age
adj new: dim=age
adj young: dim=age
adj large: dim=size
adj small: dim=size
adj big: dim=size
adj tall: dim=height
adj high: dim=height
adj low: dim=height
adj long: dim=length
adj short: dim=length
adj early: dim=time
adj late: dim=time
adj recent: dim=time
adj fast: dim=speed
adj slow: dim=speed
adj cheap: dim=price
adj expensive: dim=price
adj popular: dim=popularity
adj rich: dim=wealth
adj poor: dim=wealth
adj heavy: dim=weight
adj light: dim=weight
adj good: dim=quality
adj bad: dim=quality
adj great: dim=size
adj major: dim=size
adj minor: dim=size
adj wide: dim=width
adj deep: dim=depth

dim age: rels=founded_on,birth_date,published_on,release_date | order=earlier_is_older
dim size: rels=area,population,employees | order=larger_is_larger
dim height: rels=elevation,height | order=larger_is_larger
dim length: rels=length | order=larger_is_larger
dim time: rels=founded_on,published_on | order=earlier_is_earlier
dim price: rels=price | order=larger_is_larger
dim speed: rels=speed | order=larger_is_larger
dim popularity: rels=population | order=larger_is_larger
dim wealth: rels=revenue | order=larger_is_larger

# ============================================================ discourse and constraint cues
cue exclusion: exclude; excluding; excludes; excluded; except; excepting; without; avoid; avoiding; skip; omit; omitting; minus; other than; apart from; aside from; instead of; rather than; not including; leave out; leaving out; rule out; ruling out; filter out; get rid of; no more; do not include; do not use; do not show; do not add; do not consider; never include; never use; never show; stop using; leave off
cue contrast: but; however; rather; instead; but not; and not; though
cue correction: actually; wait; no wait; sorry; correction; i meant; i mean; scratch that; forget that; ignore that; disregard that; never mind; my mistake; i was wrong; that was wrong; that's wrong; not quite; to correct; let me correct; update; change of plans; on second thought; let me rephrase; to clarify
cue persist: from now on; going forward; henceforth; always; for the rest of; from here on; until further notice; by default; in all future; for all future
cue revoke: never mind; forget that; disregard; stop using; no longer; cancel that; undo that; don't use anymore; do not use anymore; scrap that
cue preference: prioritize; prioritise; prefer; ideally; preferably; especially; rank higher; focus on; emphasize; favor; favour; bonus if; the more the better; lean toward; give priority to; most interested in
cue restriction: only; just; solely; exclusively; only using; limited to; restricted to; strictly
cue source_intro: according to; based on; as stated in; as reported by; per; from the; in the; using; drawn from; taken from; as described in; as shown in; as of
cue comparison: compare; compared to; compared with; versus; vs; difference between; differences between; differ; similar to; same as; relative to; contrast; as opposed to; in contrast to
cue conditional: if; unless; provided that; assuming; in case; as long as; given that; whenever; once; in the event
cue backref: earlier; previously; before; i mentioned; i said; we discussed; you said; you mentioned; as before; same as before; last time; the above; the previous; the prior; mentioned earlier; said earlier; talked about; we talked about; from earlier
cue deixis: the latter; the former; the above; the following; the other one; the first one; the second one; the last one; the one
cue hedge: maybe; perhaps; possibly; probably; might; i think; i guess; not sure; apparently; reportedly; allegedly; supposedly; it seems; could be; i believe; rumored; rumoured; likely; unclear whether; some say; some believe
cue focus_intro: i'm researching; i am researching; i'm working on; i am working on; i'm looking at; i am looking at; i'm studying; i am studying; i'm interested in; i am interested in; let's talk about; let's discuss; back to; focusing on; i'm investigating; i am investigating; we are looking at; we're looking at; my project is; the project is about; we're discussing; we are discussing
cue only_marker: only; just; solely; exclusively; nothing but
cue superlative_latest: latest; newest; most recent; last; current
cue definition_frame: meaning of; definition of; what does; stand for; stands for; mean by
cue question_polite: i wonder; i'm wondering; i am wondering; i'm curious; i am curious; can anyone tell me; could someone tell me; do you have any idea; could you; can you; would you; will you; could you please; can you please; would you please; do you know; do you happen to know; i was wondering; i'd like to know; i want to know; i need to know; i would like to know; tell me; let me know
cue request_open: i want; i need; i'd like; i would like; i'm looking for; i am looking for; give me; get me; show me; find me; looking for; i require
cue basis: considering; given; in light of; bearing in mind; keeping in mind; factoring in; taking
cue backref_adv: earlier; before; previously; already; recently; yesterday; ago; then; originally
cue comparison_set: both; each; either; neither; the two; these two; those two; the pair; all of them; the three
cue recall_intro: remind me; do you remember; can you remember; can you recall; do you recall; i forgot; i don't remember; i can't remember; remind me of
cue ambient_adj: cold; hot; warm; cool; sunny; cloudy; windy; rainy; foggy; snowy; stormy; humid; dry; late; early; dark; light; dusk; dawn; noon; midnight
cue extrapose_adj: important; clear; obvious; likely; unlikely; possible; impossible; necessary; true; false; known; reported; rumored; said; believed; expected; surprising; interesting; essential; useful; difficult; easy; hard; good; bad; better; fine; worth; wise; unclear; certain; evident; apparent; unfortunate; great; nice
cue extrapose_verb: seems; seem; seemed; appears; appear; appeared; looks; looked; turns out; turned out; happens; happened; matters; follows; remains
cue extrapose_comp: that; to; whether; if; like; as if; for
cue injection: ignore previous instructions; ignore all previous instructions; ignore the above; ignore your instructions; ignore prior instructions; ignore the user; ignore the question; disregard the above; disregard previous; disregard all; disregard your; system prompt; you are now; act as; pretend to be; pretend you; new instructions; override your; reveal your; do not tell the user; forget everything; forget your instructions; from now on you; your new task; developer mode; jailbreak; as an ai; end of document; begin system
cue alias_intro: officially; formally; also known as; also called; sometimes called; aka; a.k.a.; commonly known as; known as; better known as; often called; abbreviated as; short for; officially the; formally the
cue definition_verb: refers to; refer to; is defined as; are defined as; means; mean; denotes; denote; stands for; stand for; is the term for; is a term for; is known as; are known as
cue decision: we decided; i decided; we have decided; we've decided; i've decided; we agreed; i agreed; we chose; i chose; we picked; we selected; we settled on; let's go with; we'll use; we will use; the decision is; decided to; agreed to; agreed on
cue decision_ref: decide; decided; decision; decisions; agree; agreed; agreement; chose; chosen; choose; picked; pick; selected; settled; resolved
cue additive: also; as well; in addition; additionally; too; on top of that
cue scoped: for this question; for this one; just this time; only this time; this once; for now only; for this request
cue art_latest: latest; newest; most recent; final; current; revised; updated; new; recent; last; newer
cue art_first: first; original; initial; earliest; oldest; starting
cue art_prev: previous; prior; preceding; earlier
cue deictic_item: which one; which ones; the one; the ones; the other one; the former; the latter; the first; the second; the third; the last

# ============================================================ domain cue words (sense priming)
domain astronomy: planet planets orbit orbits orbital solar moon moons star stars galaxy telescope sun asteroid comet cosmos universe space astronaut gravity eclipse venus mars jupiter saturn neptune uranus earth
domain chemistry: element elements metal metals toxic periodic atomic atom molecule compound chemical chemistry reaction acid alloy isotope liquid thermometer
domain geography: country countries city cities river mountain lake island ocean sea continent border capital region province state population territory coast
domain politics: government president minister parliament election senate treaty sovereign republic monarchy political politics capital
domain finance: money invest investment investor investors stock bank banking financial finance loan interest fund funding capital equity asset assets venture
domain economics: economy economic gdp inflation market trade supply demand
domain law: law legal court judge crime criminal punishment penalty sentence prison jury attorney lawyer statute constitution legislation execution offense
domain computing: code program programs programming programmer software language compiler runtime library framework api function variable developer algorithm database server python java javascript
domain ai: neural model models training learning machine artificial intelligence deep dataset
domain biology: animal species plant cell gene organism habitat predator tree forest rainforest wildlife
domain food: eat food fruit juice coffee tea drink recipe cook kitchen flavor cooking sweet bean beans beverage
domain business: company companies business corporation startup firm enterprise customer revenue market ceo founder employees product products
domain technology: technology tech device phone iphone mac laptop hardware chip processor
domain education: school student students teacher teachers class classroom education curriculum college university graduate diploma
domain music: band singer song album concert guitar vocalist
domain mythology: god goddess myth mythology roman greek legend messenger
domain automotive: car cars engine vehicle sedan automobile driving
domain color: color colour paint painting shade hue pigment dye palette red blue green yellow purple pink wall walls
domain typography: letter letters uppercase lowercase font character typing
domain history: history historical ancient empire kingdom dynasty century war revolution medieval

# ============================================================ head words that type an unseen proper name
headcue company: inc inc. corp corporation co company llc ltd limited plc gmbh ag holdings group partners bank
headcue organization: labs lab laboratory laboratories technologies technology systems solutions robotics industries enterprises ventures consulting associates networks software studios works
headcue university: university college institute polytechnic academy
headcue government_body: ministry department agency authority council commission bureau parliament senate
headcue nonprofit: foundation association society charity trust
headcue school: school
headcue river: river
headcue lake: lake
headcue mountain: mountain mountains mount mt peak
headcue island: island islands isle
headcue ocean: ocean sea gulf bay
headcue city: city town village
headcue subnational: county province state prefecture region district
headcue facility: airport station hospital museum library stadium bridge tower castle
headcue publication: journal magazine times post gazette review

# ============================================================ resource nouns (synonym groups -> canonical)
resource dataset: dataset; data set; data-set; corpus; data; database; collection; knowledge base
resource version: version; edition; release; revision; draft; build; iteration; variant
resource file: file; document; doc; report; paper; table; spreadsheet; sheet; record; records
resource source: source; reference; citation; article; publication; website; page
resource statement: financial statement; financial statements; statement; statements; filing; filings; accounts; financial accounts; audited accounts; annual report
resource model: model
resource figures: figures; numbers; stats; statistics; metrics; results; findings; values
resource solution: solution; answer; approach; option; method; attempt; proposal; candidate
resource year: year; period; fiscal year
refnoun solution: solution; approach; option; method; attempt; proposal; candidate; plan; strategy; idea; fix; patch; design; implementation
refnoun version: version; edition; draft; revision; iteration; variant; release; build
refnoun correction: correction; amendment; instruction; decision; preference; requirement; constraint; adjustment; edit; update; change; fix
refnoun message: message; reply; email; note; comment; question; answer; response
]==]
