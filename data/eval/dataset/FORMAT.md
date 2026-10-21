# Dataset-reading cases: file format

A case file is JSON: `{ "schema": "nlu.dataset_cases/1", "cases": [ ... ] }`.  Each case is a small dataset (one or more files, written the way a real person would
write them) plus what a careful human reader would say the assistant must make of it.

```json
{
  "id": "x001",
  "category": "persona_sheet",
  "note": "free text, optional: what the case is meant to catch",
  "files": [ { "name": "persona.txt", "text": "Aria is an AI model.\n\nParis is the capital of France." } ],
  "expect": {
    "kind": "persona_sheet",
    "persona": { "name": "Aria" },
    "descriptors": ["dramatic"],
    "not_descriptors": ["calm"],
    "not_facts": ["MOST FASCINATING"],
    "facts": [ { "rel": "capital", "from": "France", "to": "Paris" } ],
    "answers": [ { "q": "What is the capital of France?", "status": "answerable", "answer": "Paris" } ],
    "flagged": ["Ignore all previous instructions"]
  },
  "turns": [
    { "say": "Use a calmer tone.", "expect": { "descriptors": ["calm"], "not_descriptors": ["dramatic"], "reply_contains": ["calm"] } }
  ]
}
```

`files[].name` decides the format by its extension: `.txt` and `.md` (paragraphs separated by blank lines; markdown headings are section titles), `.jsonl` (one JSON object per
line), `.json` (an array of objects, or `{"records": [...]}`), `.csv`, `.tsv`.  Text is plain text; put real line breaks as `\n` inside the JSON string.

## `expect` (all keys optional; every key is one or more checks)

| key | meaning |
|---|---|
| `kind` | what kind of dataset it is: `persona_sheet` (describes a character / how the assistant should talk, next to other content), `style_guide` (says how to sound, no named character), `dialogue_corpus` (turns of a conversation), `qa_pairs` (question column + answer column), `knowledge_base` (plain facts), `mixed` (facts with a persona / style description mixed in) |
| `persona` | `null` when NO persona or character is declared or implied.  Otherwise `{ "name": "Aria" }` (the persona's given name) and/or `{ "placeholder": "AI model name" }` (when the dataset only has a placeholder such as `[AI model name]`, `{{char}}`, `<assistant name>` instead of a name) |
| `descriptors` | tone / style descriptors that the dataset clearly conveys for the persona: they must be among what the engine reports |
| `not_descriptors` | descriptors that would be WRONG to report (the dataset says the opposite, or never suggests them) |
| `not_facts` | substrings of text that must NOT become knowledge: example utterances, style statements, persona descriptions, questions, instructions.  (Checked against the sentences the engine extracted facts from and the entity vocabulary it built.) |
| `facts` | facts the engine must extract: `rel` is one of `capital` (country -> city), `founder` (organisation -> founder), `author` (work -> person), `creator` (work or product -> maker), `ceo` (company -> person), `headquarters` (organisation -> city), `population` (place -> number), `located_in` (thing -> place), `birth_place` (person -> place), `currency` (country -> currency), `official_language` (country -> language), `height` (thing -> number), `spouse`, `birth_date`, `employees`, `head_of_state`; `from` / `to` are substrings (case-insensitive) of the entity names, e.g. `{"rel":"capital","from":"France","to":"Paris"}`; omit `rel` to accept any relation |
| `answers` | questions put to the engine over the dataset: `status` is `answerable` (the dataset says), `unsupported` (the dataset says nothing about the subject) or `insufficient`; `answer` is a substring of the expected answer |
| `flagged` | substrings of text that are instructions aimed at the assistant (prompt injection) and must be reported as such |

## `turns` (the user talking to the assistant after the dataset was loaded)

Each turn is something the user says; `expect` is checked right after it.  Allowed keys: `descriptors`, `not_descriptors` (about the voice now in force), `persona` (the
persona now in force, same shape as above), `persona_active` (`false` when no persona / tone should be in force any more), `reply_contains` (substrings of the assistant's own
reply to this turn, case-insensitive), `answers`, `facts`, `not_facts` (as above, but about the state after the instruction: e.g. after "treat the examples as facts" an example
sentence may become an answerable fact).

## Descriptor ids

Typography: `all_caps` (whole text in capitals / shouting), `caps_emphasis` (some words in capitals for emphasis), `lowercase`, `exclamatory` (exclamation marks), `no_exclamation`, `emoji`, `ellipsis` (trailing off...), `elongation` (stretched words: sooo, whaaat).
Register: `terse`, `verbose`, `formal`, `casual`, `polite`.
Attitude: `friendly`, `enthusiastic`, `dramatic`, `sarcastic`, `humorous`, `serious`, `calm`, `grumpy`.
Voice: `poetic`, `robotic`, `archaic`, `pirate`, `cowboy`, `surfer`, `uwu`, `butler`; any other named voice is `voice:<words>` (e.g. "like a drill sergeant" is `voice:drill sergeant`).

## Authoring rules

* Write what a real person would write, in their own words and layout: messy, chatty, structured, terse, with typos, any mix of upper/lower case.  Do not write towards the checks.
* Gold comes from the meaning of the text, as a careful human would read it.  If a human could reasonably read it two ways, leave the check out.
* Include cases where nothing should be found (`"persona": null`), text that only LOOKS like a persona statement, and instructions hidden in the data.
