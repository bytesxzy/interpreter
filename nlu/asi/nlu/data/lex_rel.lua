-- Relation inventory: typed, role-directed relations and their lexicalisations. NO instance facts live here.
--   from = the holder / known side ("country" in capital)       to = the value side ("city" in capital)
--   noun=  nouns that DENOTE the `to` role ("the capital of X")  noun_from= nouns that denote the `from` role ("subsidiary of X")
--   verb=  lemma/subj=to|from[/prep=P]: which role the grammatical subject plays; with prep the construction is stative (X is VERB-ed P Y)
return [==[
# ------------------------------------------------------------ geography and politics
rel capital: from=political_territory to=city | noun=capital; capital city | kinds=financial:financial_center; cultural:cultural_center; economic:economic_center; administrative:administrative_capital; legislative:legislative_capital; judicial:judicial_capital; commercial:commercial_center; political:capital; national:capital; official:capital | label=capital city
rel financial_center: from=political_territory to=city | noun=financial center; financial centre; financial hub | derived=capital | label=financial center
rel cultural_center: from=political_territory to=city | noun=cultural center; cultural centre; cultural hub | derived=capital | label=cultural center
rel economic_center: from=political_territory to=city | noun=economic center; economic centre; economic hub | derived=capital | label=economic center
rel administrative_capital: from=political_territory to=city | noun=administrative capital | derived=capital | label=administrative capital
rel legislative_capital: from=political_territory to=city | noun=legislative capital | derived=capital | label=legislative capital
rel judicial_capital: from=political_territory to=city | noun=judicial capital | derived=capital | label=judicial capital
rel commercial_center: from=political_territory to=city | noun=commercial center; commercial centre; commercial hub | derived=capital | label=commercial center
rel head_of_state: from=political_territory to=person | noun=head of state; president; monarch; king; queen; ruler | label=head of state
rel prime_minister: from=country to=person | noun=prime minister; premier | label=prime minister
rel population: from=place to=number | noun=population; inhabitants; number of inhabitants; number of residents | attr=1 | label=population
rel area: from=place to=number | noun=area; surface area; land area | attr=1 | label=area
rel currency: from=country to=currency | noun=currency | label=currency
rel official_language: from=country to=language | noun=official language; national language | label=official language
rel continent_of: from=country to=continent | noun=continent | label=continent
rel height: from=entity to=number | noun=height; elevation; altitude | attr=1 | label=height
rel located_in: from=place,organization,event,person to=place | noun=location | verb=locate/subj=from/prep=in; situate/subj=from/prep=in | where=located_in | label=location
rel moons: from=planet to=celestial_body | noun=moon; satellite | label=moons
rel diameter: from=celestial_body to=number | noun=diameter | attr=1 | label=diameter
rel orbital_period: from=planet to=number | noun=orbital period | attr=1 | label=orbital period

# ------------------------------------------------------------ organisations and people
rel founder: from=organization to=agent | noun=founder; co-founder; cofounder | verb=found/subj=to; establish/subj=to; start/subj=to; set up/subj=to; launch/subj=to; incorporate/subj=to | when=founded_on | label=founder
rel founded_on: from=organization to=date | noun=founding date; founding year; foundation date; date of founding; year of founding | label=founding date
rel ceo: from=company to=person | noun=ceo; chief executive officer; chief executive | label=CEO
rel leader: from=organization to=person | noun=leader; head; chief | verb=lead/subj=to; head/subj=to; run/subj=to; manage/subj=to | label=leader
rel headquarters: from=organization to=city | noun=headquarters; head office; hq; main office | verb=headquarter/subj=from/prep=in; base/subj=from/prep=in | label=headquarters
rel member_of: from=agent to=organization | noun_from=member | verb=belong/subj=from/prep=to; join/subj=from | label=membership
rel parent_org: from=organization to=organization | noun=parent company; parent organization; parent; owner | noun_from=subsidiary | verb=own/subj=to | label=parent organization
rel acquirer: from=organization to=organization | noun=acquirer; buyer; purchaser | verb=acquire/subj=to; buy/subj=to; purchase/subj=to; take over/subj=to; absorb/subj=to | when=acquired_on | label=acquirer
rel acquired_on: from=organization to=date | noun=acquisition date; date of acquisition | label=acquisition date
rel investor: from=organization to=agent | noun=investor; backer; funder | verb=invest/subj=to/prep=in; fund/subj=to; finance/subj=to; back/subj=to | label=investor
rel employees: from=organization to=number | noun=employees; staff; headcount; workforce; number of employees; number of staff | how_many=employees | attr=1 | label=employees
rel revenue: from=organization to=money | noun=revenue; sales; turnover; income | attr=1 | label=revenue
rel industry: from=organization to=topic | noun=industry; sector | label=industry
rel offers: from=organization to=service | noun=offering; service | verb=offer/subj=from; provide/subj=from; sell/subj=from; supply/subj=from; deliver/subj=from; specialize/subj=from/prep=in | label=offers
rel seeks: from=agent to=concept | verb=seek/subj=from; want/subj=from; need/subj=from; look/subj=from/prep=for; interest/subj=from/prep=in | label=interested in
rel hires: from=organization to=role | verb=hire/subj=from; recruit/subj=from | label=hires
rel partner: from=organization to=organization | noun=partner; partnership; collaborator | verb=partner/subj=from/prep=with; collaborate/subj=from/prep=with; cooperate/subj=from/prep=with | symmetric=1 | label=partner
rel employer: from=person to=organization | noun=employer | verb=work/subj=from/prep=for; employ/subj=to | label=employer
rel title: from=person to=role | noun=title; job; position | label=title
rel nationality: from=person to=country | noun=nationality; citizenship | label=nationality
rel spouse: from=person to=person | noun=spouse; husband; wife | verb=marry/subj=from | symmetric=1 | label=spouse
rel birth_place: from=person to=place | noun=birthplace; place of birth | verb=bear/subj=from/prep=in | where=birth_place | label=birthplace
rel birth_date: from=person to=date | noun=birthday; date of birth; birth date | when=birth_date | label=birth date
rel death_date: from=person to=date | noun=date of death; death date | verb=die/subj=from | when=death_date | label=death date
rel age: from=agent to=number | noun=age | attr=1 | label=age

# ------------------------------------------------------------ works, products, software
rel author: from=work to=person | noun=author; writer | verb=write/subj=to; author/subj=to | label=author
rel publisher: from=work to=organization | noun=publisher | verb=publish/subj=to | label=publisher
rel creator: from=work,product to=agent | noun=creator; maker; designer | verb=create/subj=to; design/subj=to; make/subj=to; produce/subj=to; paint/subj=to; compose/subj=to; sculpt/subj=to; build/subj=to; craft/subj=to | label=creator
rel developer: from=software to=agent | noun=developer; maintainer; vendor | verb=develop/subj=to | label=developer
rel inventor: from=product to=person | noun=inventor | verb=invent/subj=to | label=inventor
rel discoverer: from=entity to=agent | noun=discoverer | verb=discover/subj=to | label=discoverer
rel release: from=agent to=product | noun=release; product; launch | verb=release/subj=to; launch/subj=to; ship/subj=to; unveil/subj=to | label=release
rel published_on: from=work to=date | noun=publication date; date of publication; release date | when=published_on | label=publication date
rel price: from=product to=money | noun=price; cost | attr=1 | label=price
rel type_of: from=entity to=concept | noun=type; kind; category; genre | label=type

# ------------------------------------------------------------ abstract relations
rel successor: from=entity to=entity | noun=successor | verb=succeed/subj=to; replace/subj=to | label=successor
rel predecessor: from=entity to=entity | noun=predecessor | label=predecessor
rel cause: from=concept,event to=concept,event | noun=cause; reason; origin | verb=cause/subj=to; trigger/subj=to; lead/subj=to/prep=to | label=cause
rel requirement: from=entity to=entity | noun=requirement; prerequisite; dependency | verb=require/subj=from; need/subj=from; depend/subj=from/prep=on | label=requirement
rel supported_by: from=claim,concept to=document | noun=evidence; support | verb=support/subj=to; confirm/subj=to; substantiate/subj=to | label=supported by
rel part_of: from=entity to=entity | noun_from=part; component; constituent | verb=contain/subj=to; comprise/subj=to; include/subj=to | label=part of
rel atomic_number: from=chemical_element to=number | noun=atomic number | attr=1 | label=atomic number
rel symbol: from=chemical_element to=text | noun=symbol | label=chemical symbol
]==]
