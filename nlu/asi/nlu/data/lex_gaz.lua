-- Seed gazetteer: names and types only. It contains NO relational facts (no capitals, no founders, no dates).
-- Same-name entities of different types are separate entries on purpose: resolution must choose among them.
return [==[
entities country: Afghanistan; Albania; Algeria; Andorra; Angola; Antigua and Barbuda; Argentina; Armenia; Australia; Austria; Azerbaijan; Bahamas; Bahrain; Bangladesh; Barbados; Belarus; Belgium; Belize; Benin; Bhutan; Bolivia; Bosnia and Herzegovina; Botswana; Brazil; Brunei; Bulgaria; Burkina Faso; Burundi; Cabo Verde; Cambodia; Cameroon; Canada; Central African Republic; Chad; Chile; China; Colombia; Comoros; Congo; Costa Rica; Croatia; Cuba; Cyprus; Czech Republic; Democratic Republic of the Congo; Denmark; Djibouti; Dominica; Dominican Republic; Ecuador; Egypt; El Salvador; Equatorial Guinea; Eritrea; Estonia; Eswatini; Ethiopia; Fiji; Finland; France; Gabon; Gambia; Georgia; Germany; Ghana; Greece; Grenada; Guatemala; Guinea; Guinea-Bissau; Guyana; Haiti; Honduras; Hungary; Iceland; India; Indonesia; Iran; Iraq; Ireland; Israel; Italy; Ivory Coast; Jamaica; Japan; Jordan; Kazakhstan; Kenya; Kiribati; Kosovo; Kuwait; Kyrgyzstan; Laos; Latvia; Lebanon; Lesotho; Liberia; Libya; Liechtenstein; Lithuania; Luxembourg; Madagascar; Malawi; Malaysia; Maldives; Mali; Malta; Marshall Islands; Mauritania; Mauritius; Mexico; Micronesia; Moldova; Monaco; Mongolia; Montenegro; Morocco; Mozambique; Myanmar; Namibia; Nauru; Nepal; Netherlands; New Zealand; Nicaragua; Niger; Nigeria; North Korea; North Macedonia; Norway; Oman; Pakistan; Palau; Palestine; Panama; Papua New Guinea; Paraguay; Peru; Philippines; Poland; Portugal; Qatar; Romania; Russia; Rwanda; Saint Kitts and Nevis; Saint Lucia; Saint Vincent and the Grenadines; Samoa; San Marino; Sao Tome and Principe; Saudi Arabia; Senegal; Serbia; Seychelles; Sierra Leone; Singapore; Slovakia; Slovenia; Solomon Islands; Somalia; South Africa; South Korea; South Sudan; Spain; Sri Lanka; Sudan; Suriname; Sweden; Switzerland; Syria; Taiwan; Tajikistan; Tanzania; Thailand; Timor-Leste; Togo; Tonga; Trinidad and Tobago; Tunisia; Turkey; Turkmenistan; Tuvalu; Uganda; Ukraine; United Arab Emirates; United Kingdom; United States; Uruguay; Uzbekistan; Vanuatu; Vatican City; Venezuela; Vietnam; Yemen; Zambia; Zimbabwe
alias country.united_states: United States of America; USA; US; U.S.; U.S.A.
alias country.united_kingdom: UK; U.K.; Great Britain; Britain
alias country.russia: Russian Federation
alias country.north_korea: DPRK
alias country.czech_republic: Czechia
alias country.myanmar: Burma
alias country.eswatini: Swaziland
alias country.vatican_city: Vatican; Holy See
alias country.netherlands: Holland
alias country.united_arab_emirates: UAE
alias country.democratic_republic_of_the_congo: DR Congo; DRC
alias country.timor_leste: East Timor
alias country.ivory_coast: Cote d'Ivoire
alias country.cabo_verde: Cape Verde

entities continent: Africa; Antarctica; Asia; Europe; North America; South America; Oceania
entities ocean: Atlantic Ocean; Pacific Ocean; Indian Ocean; Arctic Ocean; Southern Ocean
entities subnational: Alabama; Alaska; Arizona; Arkansas; California; Colorado; Connecticut; Delaware; Florida; Hawaii; Idaho; Illinois; Indiana; Iowa; Kansas; Kentucky; Louisiana; Maine; Maryland; Massachusetts; Michigan; Minnesota; Mississippi; Missouri; Montana; Nebraska; Nevada; New Hampshire; New Jersey; New Mexico; New York; North Carolina; North Dakota; Ohio; Oklahoma; Oregon; Pennsylvania; Rhode Island; South Carolina; South Dakota; Tennessee; Texas; Utah; Vermont; Virginia; Washington; West Virginia; Wisconsin; Wyoming; Bavaria; Ontario; Quebec; Catalonia; Scotland; Wales; England
entity subnational.georgia_us: subnational | names=Georgia | domain=geography; politics
entities city: Paris; London; Berlin; Rome; Madrid; Lisbon; Vienna; Athens; Warsaw; Prague; Budapest; Brussels; Amsterdam; Stockholm; Oslo; Copenhagen; Helsinki; Dublin; Moscow; Kyiv; Istanbul; Ankara; Cairo; Nairobi; Lagos; Johannesburg; Cape Town; Tokyo; Osaka; Beijing; Shanghai; Hong Kong; Seoul; Bangkok; Jakarta; Mumbai; New Delhi; Delhi; Dubai; Tehran; Baghdad; Riyadh; Sydney; Melbourne; Canberra; Auckland; Wellington; Toronto; Ottawa; Vancouver; Montreal; Los Angeles; Chicago; Houston; San Francisco; Boston; Seattle; Miami; Mexico City; Buenos Aires; Santiago; Lima; Bogota; Brasilia; Sao Paulo; Rio de Janeiro; Havana; Lyon; Marseille; Munich; Hamburg; Milan; Barcelona; Edinburgh; Manchester; Birmingham; Zurich; Geneva; Vichy; Versailles
entity city.new_york_city: city | names=New York City; New York; NYC | domain=geography
entity city.washington_dc: city | names=Washington D.C.; Washington DC; Washington | domain=geography; politics
entity city.cambridge_uk: city | names=Cambridge | domain=geography; education
entity city.cambridge_ma: city | names=Cambridge | domain=geography; education
entity city.singapore: city | names=Singapore | domain=geography
entity geographic_feature.mount_fuji: mountain | names=Mount Fuji; Mt. Fuji; Fuji | domain=geography
entity geographic_feature.mount_everest: mountain | names=Mount Everest; Everest | domain=geography
entity river.nile: river | names=Nile; Nile River | domain=geography
entity river.amazon_river: river | names=Amazon River; Amazon | domain=geography
entity region.amazon_rainforest: region | names=Amazon rainforest; Amazon basin; Amazon | domain=geography; biology

# ------------------------------------------------------------ deliberately polysemous names
entity planet.mercury: planet | names=Mercury | domain=astronomy
entity element.mercury: chemical_element | names=Mercury; mercury; Hg | domain=chemistry
entity myth.mercury: mythological_figure | names=Mercury | domain=mythology
entity person.freddie_mercury: person | names=Freddie Mercury | domain=music
entity planet.venus: planet | names=Venus | domain=astronomy
entity myth.venus: mythological_figure | names=Venus | domain=mythology
entity planet.mars: planet | names=Mars | domain=astronomy
entity planet.saturn: planet | names=Saturn | domain=astronomy
entity company.saturn_cars: company | names=Saturn | domain=automotive; business
entity planet.earth: planet | names=Earth | domain=astronomy; geography
entity planet.jupiter: planet | names=Jupiter | domain=astronomy
entity company.apple: company | names=Apple; Apple Inc.; Apple Computer | domain=technology; business
entity fruit.apple: fruit | names=apple; apples | domain=food; biology
entity lang.java: programming_language | names=Java | domain=computing
entity island.java: island | names=Java | domain=geography
entity beverage.java: beverage | names=java | domain=food
entity lang.python: programming_language | names=Python | domain=computing
entity animal.python: animal | names=python; pythons | domain=biology
entity company.amazon: company | names=Amazon; Amazon.com | domain=business; technology
entity animal.jaguar: animal | names=jaguar; jaguars | domain=biology
entity company.jaguar: company | names=Jaguar | domain=business; automotive
entity animal.turkey: animal | names=turkey; turkeys | domain=biology; food
entity person.george_washington: person | names=George Washington | domain=history; politics
entity company.oracle: company | names=Oracle | domain=technology; business
entity company.shell: company | names=Shell | domain=business
entity company.google: company | names=Google | domain=technology; business
entity company.microsoft: company | names=Microsoft | domain=technology; business
entity company.tesla: company | names=Tesla | domain=technology; automotive; business
entity company.ibm: company | names=IBM | domain=technology; business
entity company.meta: company | names=Meta; Meta Platforms | domain=technology; business
entity color.orange: color | names=orange | domain=color; design; art; paint
entity fruit.orange: fruit | names=orange; oranges | domain=food; biology
entity company.orange_telecom: company | names=Orange | domain=business; technology
]==]
