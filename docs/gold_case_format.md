# Gold case format (for people who write evaluation cases)

A gold file is a UTF-8 text file. One case per line: `ID | category | text | gold`. Blank lines and lines starting with `#` are ignored.
`gold` is a list of `key=value` items separated by `;`. A case passes only if EVERY item it lists matches the engine's reading; items you do not list are not checked.
Write only what the sentence unambiguously means - gold is a statement about what a careful human reader would conclude, not about how a program might work.

## Multi-turn cases
`text` may hold a conversation: `U: first user turn // A: assistant turn // U: the request being judged`. Speakers are `U:` (user), `A:` (assistant), `D:` (document).
The gold applies to the LAST turn and may use the context keys (`ref`, `ctx`, `active`, `sel`, `dep`, `unres`).

## Items
| key | meaning |
|---|---|
| `act` | speech act of the request: `question`, `request`, `statement`, `command` |
| `intent` | `factual_lookup`, `search`, `instruction_update`, `verification` (yes/no check of a claim), `definition`, `comparison`, `entity_description`, `causal_explanation`, `explanation`, `task`, `statement`, `conversation_recall`, `unknown` |
| `rel` / `rel!` | the relation asked about (ids in the inventory below); `rel!=capital` means "the relation must NOT be capital" (use it for decoys such as "capital punishment") |
| `from`, `to` | the arguments of the relation. `from` is the known / holder side, `to` the value side of the relation's signature (see inventory: `capital` is from=territory to=city, so in "Which country has Paris as its capital?" the known side is `to=Paris` and the asked side is `from`). Value syntax `text`, `text:type`, or `text:type:id` (`*` = anything). Types: country, city, organization, company, person, place, ... |
| `subject`, `concept`, `target`, `focus`, `object` | same value syntax: the subject of a description request, the concept being defined, the thing a search/negation targets, ... |
| `ask` | which side of the relation the answer fills: `to` (usual) or `from` |
| `atype` | the type of the requested answer: `city`, `country`, `person`, `company`, `number`, `date`, `agent`, ... |
| `temporal` | `current_unspecified`, `present`, `past`, `future` |
| `tc` | temporal constraints, comma separated: `as_of:2020` (state as of a year), `in:2015`, `before:2010`, `after:2010`, `since:2010`, `until:2010`, `between:2010-2015`, `label:2020` (a dataset label), `derived:2020` |
| `neg` | negative constraints, comma separated; `scope:key`, e.g. `type:university` (exclude universities), `topic:employment`, `entity:germany`, `description:city`; `type:company+hires:intern` = companies filtered by a relation; `none` = the request contains no negation |
| `pos` | positive constraints: `geo:Germany`, `relation:offers`, `temporal:founded_on`, `has:remote work`, `numeric:population>1000000` (a numeric restriction on a relation's value: relation id, optional operator `>` `>=` `<` `<=` `=` `~` and bound) |
| `pref` | stated preferences (substring of the preference text) |
| `src` | a source/resource restriction: `dataset:2020` |
| `amb` | `resolved` (one clear reading) or `ambiguous` (several readings the text does not decide between) |
| `alts` | for ambiguous mentions: the candidate entity ids separated by `|` |
| `ctx` | context dependencies of the request: `pronoun`, `ordinal_reference`, `comparison_set`, `backref`, or `none` |
| `dep` | primary dependency of the request on the conversation: `self_contained`, `recent_message`, `ambiguous_missing_context`, `earlier_context` (the engine's class `earlier_project_context`, accepted as an alias), `user_correction` |
| `items` | the enumerated items of a comparison / list request, in order, separated by `|` |
| `inst` | an instruction to the system: `slot=dataset,value=2025,corr=1,persist=1` (`corr=1` it corrects an earlier instruction, `persist=1` it keeps applying, `verb=use`) |
| `ref` | reference resolution in the last turn: `mention>antecedent text`, or `mention>unresolved`, `mention>ambiguous`, `mention>resolved` |
| `active`, `inactive` | slot values that must be active / must not be active after the turn: `dataset:2025` |
| `sel` | conversation items that must (`+fragment`) or must not (`-fragment`) have been recalled |
| `unres` | number of unresolved requirements the request leaves open |
| `pol` | polarity: `positive` or `negative` (a negated question or claim) |
| `evid` | `1` if answering needs external evidence, `0` if it does not |
| `status` | `ok`, `no_interpretation` (use for text that is not interpretable at all) |

## Relation inventory (relation id: from-type -> to-type, label)
```
capital                political_territory -> city            (capital city)
financial_center / cultural_center / economic_center / administrative_capital / legislative_capital / judicial_capital / commercial_center : kinds of capital
head_of_state          political_territory -> person          prime_minister   country -> person
population / area      place -> number                        height            entity -> number
currency               country -> currency                    official_language country -> language
continent_of           country -> continent                   located_in        place|organization|event|person -> place
moons                  planet -> celestial_body               diameter / orbital_period   celestial_body|planet -> number
founder                organization -> agent                  founded_on        organization -> date
ceo                    company -> person                      leader            organization -> person
headquarters           organization -> city                   member_of         agent -> organization
parent_org             organization -> organization           acquirer          organization -> organization   (X acquirer Y: Y acquired X)
acquired_on            organization -> date                   investor          organization -> agent
employees              organization -> number                 revenue           organization -> money
industry               organization -> topic                  offers            organization -> service
seeks                  agent -> concept                       hires             organization -> role
partner                organization -> organization           employer          person -> organization
title                  person -> role                         nationality       person -> country
spouse                 person -> person                       birth_place       person -> place
birth_date / death_date person -> date                        age               agent -> number
author                 work -> person                         publisher         work -> organization
creator                work|product -> agent                  developer         software -> agent
inventor               product -> person                      discoverer        entity -> agent
release                agent -> product                       published_on      work -> date
price                  product -> money                       type_of           entity -> concept
successor / predecessor entity -> entity                      cause             concept|event -> concept|event
requirement            entity -> entity                       supported_by      claim|concept -> document
part_of                entity -> entity                       atomic_number     chemical_element -> number
symbol                 chemical_element -> text
```
Direction matters: for a relation `R: from -> to`, "the R of X" has `from=X`, `ask=to`; "which things have Y as their R" has `to=Y`, `ask=from`.
`acquirer: organization -> organization`: "Which company acquired Fennimore?" is `from=Fennimore; ask=to` (the acquirer is the value); "Which companies has Wexcombe bought?" is `to=Wexcombe; ask=from`.

## Categories used so far
`basic_factual`, `direction`, `negation`, `temporal`, `ambiguous`, `comparative`, `multiword`, `geographic`, `instruction`, `intent`, `malformed`, `minimal_pair`, `multi_turn`, `noise`, `typo`, `unusual`.
Entities you invent (companies, people, places that cannot be in any dictionary) are welcome - the engine must handle names it has never seen.
