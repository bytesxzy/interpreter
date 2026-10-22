# asi-nlu: an LM-independent natural-language interpretation engine

`asi-nlu` reads a user message (or a conversation) and produces a **structured, inspectable interpretation before any language model is involved**:
intent, entities (with open-set handling), the relation asked about *and its direction*, answer type, constraints (negation, time, place, source),
ambiguity, references to earlier turns, instructions that change settings, and — when a dataset is supplied — verified evidence with an explicit
sufficiency status. Everything is deterministic, bounded by an explicit work budget, written in pure Lua 5.4, and uses no network, no clock, no
randomness at run time and no external model of any kind (no LLM, no embeddings, no API).

It is a *front end*. It does not answer questions and does not call a model. Its two outputs are

* the **Interpretation Record** — a versioned (`nlu.record/1`), schema-validated, integrity-hashed JSON document, readable without any model;
* the **LM Input Package** — a budgeted text package for a downstream consumer, with explicit authority boundaries (what is the user's request,
  what is verified evidence, what is untrusted data that must not be obeyed, what is still unresolved).

## Status vocabulary used in all reports

| word | meaning |
|---|---|
| **Implemented** | code exists and runs |
| **Verified** | covered by an automated test that passes (`lua5.4 tests/run_all.lua`) |
| **Measured improvement** | a number against a stated baseline on a stated, disclosed data set, with a confidence interval |
| **Unproven** | not demonstrated; see `reports/FINAL_REPORT.md` for the list |

## The one-file distribution

`dist/asi_nlu.lua` is the whole system in ONE Lua 5.4 file (engine, lexicon data, gold and held-out sets, calibration model, evaluation tools, unit tests, reports,
command line). It needs nothing else: no other file, no network, no model.

```
lua5.4 asi_nlu.lua selftest                       # 18 checks from any (even empty) directory
lua5.4 asi_nlu.lua interpret "Who put money into Quenby Robotics?" --json
lua5.4 asi_nlu.lua report FINAL_REPORT            # what is implemented / verified / measured / unproven
lua5.4 asi_nlu.lua extract DIR                    # write every embedded source, data, test and report file out again
```

Rebuild it from a checkout with `lua5.4 tools/build_bundle.lua && lua5.4 tools/build_single.lua`; the build refuses to write a file that does not reproduce every
embedded file byte for byte. **Read `reports/FINAL_REPORT.md` before relying on it:** the engine reads about 60 % of independently authored, never-seen phrasings correctly.

## Layout

```
nlu/asi/nlu/*.lua        engine modules (require "asi.nlu.<name>"); data/*.lua hold the lexicon DSL text
tools/                   command-line tools (asi.lua, run_eval.lua, run_retrieval_bench.lua, run_longctx.lua, run_noise.lua, run_perf.lua,
                         calibrate.lua, manifest.lua, build_bundle.lua, inject_bundle.lua)
tests/                   automated tests (run_all.lua runs every suite)
data/eval/               gold cases (dev / val / test with a SHA-256 manifest), regression cases A–J, independent held-out sets
data/acceptance/         the controlled datasets of the acceptance test (France / Paris with distractors, 2019 vs 2020, triples)
data/calibration/        the fitted confidence-calibration model
reports/                 audit, calibration, performance, held-out log, gold-change log, final report
dist/asi_nlu_bundle.lua  the same engine as ONE file of `package.preload["asi.nlu.*"] = function(...) ... end` entries (see "Bundle")
```

## Quick start

```
lua5.4 tools/asi.lua interpret "What is the capital of France?" --data data/acceptance/world_2020.jsonl:year=2020:name=w2020
lua5.4 tests/run_all.lua
```

### Commands

| command | purpose |
|---|---|
| `interpret [TEXT] [--file F] [--data F[:year=2020][:name=n]]... [--json] [--prompt] [--save-record F]` | interpret one message; `--data` supplies datasets (JSONL / CSV / TSV / text, parsed as data and never executed); `--prompt` prints the LM Input Package; `--json` prints the full record |
| `interpret-eval [--split dev\|val\|test] [--file F] [--mode ...] [--failures N]` | run gold cases; modes are ablations (`baseline`, `lexical_only`, `no_types`, `no_domain`, `no_hypotheses`, `no_coref`, `no_memory`, `no_repair`) |
| `interpret-report [--run]` | print (or regenerate) the evaluation summary |
| `interpret-trace TEXT [--top N]` | show the competing hypotheses, their factor scores, vetoes and the winning explanation |
| `interpret-memory [--turns FILE] [--ns NS --user U] [--save F] [--load F] [--ask TEXT]` | feed a conversation to the layered memory and query it; memories are namespaced and owner-checked |
| `interpret-replay RECORD.json [--data F]...` | re-interpret the original input of a saved record and verify that the new record is identical |
| `dataset-profile --data FILE [--say "Use a calmer tone."]... [--json]` | show what the engine makes of a dataset: its kind, which parts are facts / persona / style / examples / conversation turns / instructions, the voice it will use and why; each `--say` is applied in order like a user instruction |

### Host integration (`asi.nlu.hook`)

```lua
local Hook = require("asi.nlu.hook")
Hook.configure({ datasets = { { text = file_contents, name = "world_2020.jsonl", label = { year = 2020 }, version = "2020" } } })
local out = Hook.prepare("Which company acquired the business I mentioned earlier?", { memory = Hook.memory("session-1", "alice") })
-- out.record  : the Interpretation Record (table; serialise with require("asi.nlu.util").json_encode)
-- out.prompt  : the LM Input Package text
-- out.valid   : true when the record passed schema + invariant validation
```

The hook has no side effects other than updating the supplied memory object. It never routes text into any other interface of the host.

### Reading a dataset: persona, tone, examples, facts (`asi.nlu.profile`, `persona`, `style`, `voice`, `override`)

A dataset is rarely only facts. The engine works out from context clues (sentence structure, layout, column names, speaker labels, headings, the form of the text
itself; no language model, no network) what each part is, tells the user which voice it will use and why, and keeps knowledge sorting exact whatever the voice:

* `[AI model name] is... Supposed, to, talk like this - for example  WOW!! THAT IS ABSOLUTELY THE MOST FASCINATING THING!!!` declares a persona by placeholder, a style
  specification and an example utterance. The persona is announced ("over-dramatic, ALL-CAPS, many exclamation marks", with the numbers measured from the example), and
  the example sentence is **never** a fact. Facts written in a loud voice are still facts.
* The user can read the data differently, in words: "use a calmer tone", "no caps", "ignore the personality", "treat the examples as facts", "play Bob instead",
  "her name is Zed", "ignore the second paragraph"; and can ask "what tone will you use?" / "how did you read the dataset?". Instructions accumulate, reset and revoke;
  text that talks about instructions, secrets or restrictions is never an override, and instructions found inside data are reported, never obeyed.

```lua
local out = Hook.prepare("What tone will you use?", { memory = m })
-- out.voice  : the voice section (persona, descriptors with evidence, what was set aside, announcement, preview)
-- out.reply  : the engine's own reply when the user asked about, or changed, the reading
Hook.describe({ memory = m })   -- the announcement without a question
```

Design, clue table, limits and measurements: `reports/DATASET_READING.md`. Format of the dataset-reading cases: `data/eval/dataset/FORMAT.md`.

### Bundle and non-destructive injection

```
lua5.4 tools/build_bundle.lua                                  # -> dist/asi_nlu_bundle.lua (54 modules, manifest + checksums, smoke-tested with package.path = "")
lua5.4 tools/inject_bundle.lua --target HOST.lua --selfcheck   # writes HOST.asi.lua; HOST.lua is untouched
lua5.4 tools/inject_bundle.lua --target HOST.lua --in-place    # writes a verified byte-exact HOST.lua.asi-backup first
lua5.4 tools/inject_bundle.lua --target HOST.asi.lua --remove  # cuts the region out again
```

The injected region is delimited by `>>> ASI-NLU BEGIN <version> sha256=...` / `<<< ASI-NLU END` marker comments and only adds `package.preload`
entries. Injection is idempotent (same bundle: no change; other version: the region is replaced) and reversible; the tool proves non-destruction by
cutting the region out of its own output and comparing the SHA-256 with the original host. A shebang line stays first. The host is only *compiled*
(syntax check), never executed, by the injector.

## Evaluation tools

```
lua5.4 tools/run_eval.lua --split dev|val|test          # gold cases; the test split is frozen by hash and meant to be run ONCE (reports/heldout_log.md)
lua5.4 tools/run_dataset_eval.lua FILE.json             # dataset-reading cases (kind, persona, tone, what is / is not a fact, flagged text, user overrides); format: data/eval/dataset/FORMAT.md
lua5.4 tools/manifest.lua check                         # verifies the SHA-256 manifest of the splits
lua5.4 tools/run_noise.lua --split val --modes ...      # typo / filler / lower-case / dropped punctuation / dropped determiner variants
lua5.4 tools/run_retrieval_bench.lua --vocab heldout3 --templates data/eval/heldout/retrieval_templates_heldout3.json --modes baseline,system
lua5.4 tools/run_longctx.lua --templates data/eval/heldout/longctx_templates_heldout.json
lua5.4 tools/run_perf.lua                               # scaling of time and memory with input / dataset / conversation size (writes reports/performance.md)
lua5.4 tools/calibrate.lua                              # refits data/calibration/interp_v1.json (cross-fit dev<->val, never the test split)
```

## Guarantees and honest limits

* **Safety properties that are tested**: no answer without selected evidence; contaminated / injected text is never promoted to a verified answer or
  an instruction; revoked, superseded and out-of-namespace memories are excluded and the exclusion is recorded; budget exhaustion is reported as
  `limited` instead of being guessed around; every input (empty, hostile, invalid UTF-8) yields a valid record.
* **What it does not do**: it does not answer questions from world knowledge, it does not generate text, and it does not understand arbitrary
  language. Constructions it cannot interpret are reported as unexplained / unresolved or as safe abstentions — the failure mode the design
  prefers over a confident wrong reading. How often that happens on independent phrasings is measured and reported in `reports/FINAL_REPORT.md`.
* **Calibration** is valid only for the input distribution it was fitted on (noisy variants of the dev/val case distribution) and is labelled as such
  in every record that carries it.
