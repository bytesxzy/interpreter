-- Word senses and multiword concepts. These make polysemy EXPLICIT (the interpreter must choose, not default).
-- Concepts carry a type and domain tags; none of this is a factual claim about specific entities.
return [==[
# ------------------------------------------------------------ "capital": relational noun (see lex_rel) vs concept readings
sense capital: capital.finance | pos=n | type=economic_concept | domain=finance; economics | gloss=wealth or assets used to generate income
sense capital: capital.letter | pos=n | type=concept | domain=typography | gloss=an uppercase letter
sense capital punishment: capital_punishment | type=legal_concept | domain=law | gloss=the legal penalty of death
sense capital offense: capital_offense | type=legal_concept | domain=law
sense capital offence: capital_offense | type=legal_concept | domain=law
sense capital crime: capital_crime | type=legal_concept | domain=law
sense capital gains: capital_gains | type=economic_concept | domain=finance
sense capital letter: capital_letter | type=concept | domain=typography
sense financial capital: financial_capital | type=economic_concept | domain=finance | gloss=money and assets used for investment
sense human capital: human_capital | type=economic_concept | domain=economics
sense social capital: social_capital | type=social_concept | domain=sociology
sense venture capital: venture_capital | type=economic_concept | domain=finance; business
sense working capital: working_capital | type=economic_concept | domain=finance; business
sense capital market: capital_market | type=economic_concept | domain=finance
sense capital expenditure: capital_expenditure | type=economic_concept | domain=finance; business

# ------------------------------------------------------------ education, technology, science, society
sense high school: high_school | type=school | domain=education | gloss=a secondary school
sense middle school: middle_school | type=school | domain=education
sense elementary school: elementary_school | type=school | domain=education
sense primary school: primary_school | type=school | domain=education
sense secondary school: secondary_school | type=school | domain=education
sense boarding school: boarding_school | type=school | domain=education
sense program: program.academic | pos=n | type=educational_concept | domain=education | gloss=a course of study offered by an institution
sense graduate school: graduate_school | type=educational_institution | domain=education
sense artificial intelligence: artificial_intelligence | type=technology_concept | domain=ai; computing
sense machine learning: machine_learning | type=technology_concept | domain=ai; computing
sense deep learning: deep_learning | type=technology_concept | domain=ai; computing
sense neural network: neural_network | type=technology_concept | domain=ai; computing
sense natural language processing: natural_language_processing | type=technology_concept | domain=ai; computing
sense reinforcement learning: reinforcement_learning | type=technology_concept | domain=ai; computing
sense large language model: large_language_model | type=technology_concept | domain=ai; computing
sense computer vision: computer_vision | type=technology_concept | domain=ai; computing
sense computer science: computer_science | type=scientific_concept | domain=computing; education
sense data science: data_science | type=scientific_concept | domain=computing
sense software engineering: software_engineering | type=technology_concept | domain=computing
sense open source: open_source | type=technology_concept | domain=computing
sense cloud computing: cloud_computing | type=technology_concept | domain=computing
sense quantum computing: quantum_computing | type=technology_concept | domain=computing
sense long-term memory: long_term_memory | type=scientific_concept | domain=psychology; neuroscience
sense short-term memory: short_term_memory | type=scientific_concept | domain=psychology; neuroscience
sense working memory: working_memory | type=scientific_concept | domain=psychology; neuroscience
sense climate change: climate_change | type=scientific_concept | domain=environment
sense global warming: global_warming | type=scientific_concept | domain=environment
sense supply chain: supply_chain | type=economic_concept | domain=business; economics
sense stock market: stock_market | type=economic_concept | domain=finance
sense interest rate: interest_rate | type=economic_concept | domain=finance; economics
sense gross domestic product: gross_domestic_product | type=economic_concept | domain=economics
sense human rights: human_rights | type=social_concept | domain=law; politics
sense public health: public_health | type=social_concept | domain=health
sense renewable energy: renewable_energy | type=technology_concept | domain=environment
sense industrial revolution: industrial_revolution | type=event | domain=history
sense french revolution: french_revolution | type=event | domain=history
sense cold war: cold_war | type=event | domain=history
sense world war: world_war | type=event | domain=history
sense marketing partnership: marketing_partnership | type=concept | domain=business
sense generative ai: generative_ai | type=technology_concept | domain=ai; computing

# ------------------------------------------------------------ common polysemous nouns
sense bank: bank.finance | pos=n | type=company | domain=finance | gloss=a financial institution
sense bank: bank.river | pos=n | type=geographic_feature | domain=geography | gloss=the land beside a river
sense plant: plant.organism | pos=n | type=plant | domain=biology
sense plant: plant.factory | pos=n | type=facility | domain=business
sense cell: cell.biology | pos=n | type=scientific_concept | domain=biology
sense cell: cell.prison | pos=n | type=facility | domain=law
sense mouse: mouse.animal | pos=n | type=animal | domain=biology
sense mouse: mouse.device | pos=n | type=product | domain=computing
sense spring: spring.season | pos=n | type=time | domain=nature
sense spring: spring.water | pos=n | type=geographic_feature | domain=geography
]==]
