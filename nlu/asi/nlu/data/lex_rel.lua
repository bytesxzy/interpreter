-- Relation inventory: typed, role-directed relations and their lexicalisations. NO instance facts live here.
--   from = the holder / known side ("country" in capital)       to = the value side ("city" in capital)
--   noun=  nouns that DENOTE the `to` role ("the capital of X")  noun_from= nouns that denote the `from` role ("subsidiary of X")
--   verb=  lemma/subj=to|from[/prep=P]: which role the grammatical subject plays; with prep the construction is stative (X is VERB-ed P Y)
return [==[
# ------------------------------------------------------------ geography and politics
rel capital: from=political_territory to=city | noun=capital; capital city; seat of government | support=have; call | as=recognize; designate; name; use; consider; regard; treat; choose; list; record; identify; describe; cite; register; present; introduce; show; recognise | kinds=financial:financial_center; cultural:cultural_center; economic:economic_center; administrative:administrative_capital; legislative:legislative_capital; judicial:judicial_capital; commercial:commercial_center; political:capital; national:capital; official:capital | label=capital city
rel financial_center: from=political_territory to=city | noun=financial center; financial centre; financial hub | derived=capital | label=financial center
rel cultural_center: from=political_territory to=city | noun=cultural center; cultural centre; cultural hub | derived=capital | label=cultural center
rel economic_center: from=political_territory to=city | noun=economic center; economic centre; economic hub | derived=capital | label=economic center
rel administrative_capital: from=political_territory to=city | noun=administrative capital | derived=capital | label=administrative capital
rel legislative_capital: from=political_territory to=city | noun=legislative capital | derived=capital | label=legislative capital
rel judicial_capital: from=political_territory to=city | noun=judicial capital | derived=capital | label=judicial capital
rel commercial_center: from=political_territory to=city | noun=commercial center; commercial centre; commercial hub | derived=capital | label=commercial center
rel head_of_state: from=political_territory to=person | noun=head of state; president; monarch; king; queen; ruler | rolesuffix=1 | support=have | as=appoint; name; choose; elect; install; list; record; identify; describe; cite; register; present; introduce; show; recognise | label=head of state
rel prime_minister: from=country to=person | noun=prime minister; premier | rolesuffix=1 | support=have | as=appoint; name; choose; elect; install; list; record; identify; describe; cite; register; present; introduce; show; recognise | label=prime minister
rel population: from=place to=number | noun=population; inhabitants; number of inhabitants; number of residents | count_noun=people; persons; individuals; residents; inhabitants; citizens; folks | count_verb=live/prep=in; reside/prep=in; dwell/prep=in; inhabit; have | attr=1 | label=population
rel area: from=place to=number | noun=area; surface area; land area | attr=1 | label=area
rel currency: from=country to=currency | noun=currency; monetary unit; unit of currency; legal tender; official currency; national currency; local currency; money | support=use; adopt; have; call; pay with; pay in; spend; trade in; transact in; price in | as=recognize; accept; designate; name; treat; issue; introduce; declare; list; record; identify; describe; cite; register; present; show; recognise | label=currency
rel official_language: from=country to=language | noun=official language; national language | label=official language
rel continent_of: from=country to=continent | noun=continent | verb=lie/subj=from/prep=on; lie/subj=from/prep=in; sit/subj=from/prep=on | label=continent
rel height: from=entity to=number | noun=height; elevation; altitude | attr=1 | label=height
rel located_in: from=place,organization,event,person to=place | noun=location | verb=locate/subj=from/prep=in; situate/subj=from/prep=in | where=located_in | label=location
rel moons: from=planet to=celestial_body | noun=moon; satellite | label=moons
rel diameter: from=celestial_body to=number | noun=diameter | attr=1 | label=diameter
rel orbital_period: from=planet to=number | noun=orbital period | attr=1 | label=orbital period

# ------------------------------------------------------------ organisations and people
rel founder: from=organization to=agent | noun=founder; co-founder; cofounder | noun_from=brainchild | verb=found/subj=to; establish/subj=to; start/subj=to; set up/subj=to; launch/subj=to; incorporate/subj=to; create/subj=to; start up/subj=to; form/subj=to | support=have | as=credit; recognize; list; record; identify; describe; cite; register; present; introduce; show; recognise | isa=creator | when=founded_on | deverbal=founding; foundation; creation; establishment; formation; launch; inception; incorporation; setup | label=founder | event=1
rel founded_on: from=organization to=date | noun=founding date; founding year; foundation date; date of founding; year of founding | label=founding date | event=1
rel ceo: from=company to=person | noun=ceo; chief executive officer; chief executive; chief exec | rolesuffix=1 | support=have | as=appoint; name; hire; employ; choose; elect; install; retain; list; record; identify; describe; cite; register; present; introduce; show; recognise | isa=leader | label=CEO
rel leader: from=organization to=person | noun=leader; head; chief; boss; person in charge; head honcho | verb=lead/subj=to; head/subj=to; run/subj=to; manage/subj=to; head up/subj=to; oversee/subj=to; direct/subj=to; be in charge of/subj=to; steer/subj=to; be at the helm of/subj=to; be at the head of/subj=to | support=have | as=appoint; name; choose; elect; install; retain; list; record; identify; describe; cite; register; present; introduce; show; recognise | deverbal=leadership; running; management; direction | label=leader
rel headquarters: from=organization to=city | noun=headquarters; head office; hq; main office; corporate headquarters; home office; main headquarters; headquarters location; head office location; hq location; seat of operations; corporate seat; principal office; principal executive offices; principal place of business; head quarters | verb=headquarter/subj=from/prep=in; base/subj=from/prep=in | support=have | support_np=maintain; keep; operate; establish; set up; open; base; put; build; locate; place; house | locus=1 | label=headquarters
rel member_of: from=agent,political_territory to=organization | noun_from=member | verb=belong/subj=from/prep=to; join/subj=from | label=membership
rel parent_org: from=organization to=organization | noun=parent company; parent organization; parent; owner | noun_from=subsidiary | verb=own/subj=to | label=parent organization
rel acquirer: from=organization to=organization | noun=acquirer; buyer; purchaser | verb=acquire/subj=to; buy/subj=to; purchase/subj=to; take over/subj=to; absorb/subj=to; snap up/subj=to; buy out/subj=to; buy up/subj=to; scoop up/subj=to; swallow up/subj=to; gobble up/subj=to | when=acquired_on | deverbal=acquisition; purchase; takeover; buyout | label=acquirer | event=1
rel acquired_on: from=organization to=date | noun=acquisition date; date of acquisition | label=acquisition date | event=1
rel investor: from=organization to=agent | noun=investor; backer; funder | verb=invest/subj=to/prep=in; fund/subj=to; finance/subj=to; back/subj=to | label=investor | event=1
rel employees: from=organization to=number | noun=employees; staff; headcount; workforce; number of employees; number of staff | how_many=employees | count_noun=people; persons; individuals; workers; staffers; employees; staff | count_verb=work/prep=at; work/prep=for; employ; have | attr=1 | label=employees
rel revenue: from=organization to=money | noun=revenue; sales; turnover; income | attr=1 | label=revenue
rel industry: from=organization to=topic | noun=industry; sector; line of business; field of business | verb=operate/subj=from/prep=in; compete/subj=from/prep=in; work/subj=from/prep=in | label=industry
rel offers: from=organization to=service | noun=offering; service | verb=offer/subj=from; provide/subj=from; sell/subj=from; supply/subj=from; deliver/subj=from; specialize/subj=from/prep=in | label=offers
rel seeks: from=agent to=concept | verb=seek/subj=from; want/subj=from; need/subj=from; look/subj=from/prep=for; interest/subj=from/prep=in | label=interested in
rel hires: from=organization to=role | verb=hire/subj=from; recruit/subj=from | label=hires
rel partner: from=organization to=organization | noun=partner; partnership; collaborator | verb=partner/subj=from/prep=with; collaborate/subj=from/prep=with; cooperate/subj=from/prep=with | symmetric=1 | label=partner
rel employer: from=person to=organization | noun=employer | verb=work/subj=from/prep=for; work/subj=from/prep=at; employ/subj=to | label=employer
rel title: from=person to=role | noun=title; job; position | label=title
rel nationality: from=person to=country | noun=nationality; citizenship | verb=hail/subj=from/prep=from; come/subj=from/prep=from | label=nationality
rel spouse: from=person to=person | noun=spouse; husband; wife | verb=marry/subj=from; marry/subj=from/prep=to | symmetric=1 | label=spouse
rel birth_place: from=person to=place | noun=birthplace; place of birth | verb=bear/subj=from/prep=in | where=birth_place | label=birthplace | event=1
rel birth_date: from=person to=date | noun=birthday; date of birth; birth date | verb=bear/subj=from | when=birth_date | label=birth date | event=1
rel death_date: from=person to=date | noun=date of death; death date | verb=die/subj=from | when=death_date | label=death date | event=1
rel age: from=agent to=number | noun=age | attr=1 | label=age

# ------------------------------------------------------------ works, products, software
rel author: from=work to=person | noun=author; writer | verb=write/subj=to; author/subj=to | isa=creator | deverbal=writing; authorship | label=author | event=1
rel publisher: from=work to=organization | noun=publisher | verb=publish/subj=to | label=publisher | event=1
rel creator: from=work,product to=agent | noun=creator; maker; designer | verb=create/subj=to; design/subj=to; make/subj=to; produce/subj=to; paint/subj=to; compose/subj=to; sculpt/subj=to; build/subj=to; craft/subj=to | deverbal=creation; making; production; design | label=creator | event=1
rel developer: from=software to=agent | noun=developer; maintainer | verb=develop/subj=to | isa=creator | deverbal=development | label=developer | event=1
rel inventor: from=product to=person | noun=inventor | verb=invent/subj=to | isa=creator | deverbal=invention | label=inventor | event=1
rel discoverer: from=entity to=agent | noun=discoverer | verb=discover/subj=to | deverbal=discovery | label=discoverer | event=1
rel release: from=agent to=product | noun=release; product; launch | verb=release/subj=from; launch/subj=from; ship/subj=from; unveil/subj=from | label=release | event=1
rel published_on: from=work to=date | noun=publication date; date of publication; release date | when=published_on | label=publication date | event=1
rel price: from=product to=money | noun=price; cost | verb=cost/subj=from; sell/subj=from/prep=for | howmuch=1 | attr=1 | label=price
rel type_of: from=entity to=concept | noun=type; kind; category; genre | label=type

# ------------------------------------------------------------ abstract relations
rel successor: from=entity to=entity | noun=successor | verb=succeed/subj=to; replace/subj=to | label=successor
rel predecessor: from=entity to=entity | noun=predecessor | label=predecessor
rel cause: from=concept,event to=concept,event | noun=cause; reason; origin | verb=cause/subj=to; trigger/subj=to; lead/subj=to/prep=to | label=cause
rel requirement: from=entity to=entity | noun=requirement; prerequisite; dependency | verb=require/subj=from; need/subj=from; depend/subj=from/prep=on | label=requirement
rel supported_by: from=claim,concept to=document | noun=evidence; support | verb=support/subj=to; confirm/subj=to; substantiate/subj=to | label=supported by
rel part_of: from=entity to=entity | noun_from=part; component; constituent; subdivision; division | verb=contain/subj=to; comprise/subj=to; include/subj=to | label=part of
rel atomic_number: from=chemical_element to=number | noun=atomic number | attr=1 | label=atomic number
rel symbol: from=chemical_element to=text | noun=symbol | label=chemical symbol
]==]
