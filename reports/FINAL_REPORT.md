# Final report — asi-nlu, an LM-independent interpretation engine

Engine commit frozen for all numbers below: `e0a0bde` (branch `claude/clever-dijkstra-jdauf0`). One-file distribution: `dist/asi_nlu.lua`.
Status words (never interchangeable): **Implemented** = code exists and runs · **Verified** = an automated test passes · **Measured improvement** = a number
against a stated baseline on a stated data set with a confidence interval · **Unproven** = not demonstrated.

**No language model, no embedding, no network, no external API, no clock and no randomness is used by the interpretation path.** Checked by search:
the engine (`nlu/`) contains no socket / HTTP / `io.popen` / `os.execute` in `interpret`; `os.clock` appears only in the evaluation timers and the self-test; nothing
mentions an LLM provider or an API key.

## 1. The honest headline

| question | answer |
|---|---|
| Does it work? | Yes, on what it covers: **18/18 self-test checks from an empty directory, 121/121 unit tests, 38/38 mandatory regression cases A–J**, bit-for-bit deterministic records. |
| How well does it read **fresh wording written by someone else**? | **About 60 %.** First run of three independently authored 170-case sets: 58.2 % → 64.1 % → **61.2 %** (95 % CI ≈ ±7 points). The naive keyword baseline gets 9.4 % on the last one. |
| Is "NO MORE SEMANTIC MISROUTING" achieved? | **No.** It is not general language understanding. Where it does not understand it usually says so (low confidence, unresolved parts, abstention), but 38 % of independent cases still contain a *serious* error (wrong relation / direction / intent). See §5. |
| What is the strongest evidence? | Failures are *detectable*: the calibrated confidence ranks right above wrong with AUROC 0.85 on the independent set, and the retrieval layer gave a wrong answer in at most 1.7 % of questions on fresh phrasings while a keyword retriever was contaminated in 100 %. |

## 2. Implemented (what exists)

| phase | modules (`nlu/asi/nlu/`) |
|---|---|
| A audit / baseline | `reports/00_audit.md`; naive baseline in `eval.lua`/`baseline.lua` (a strawman I wrote, documented as such) |
| B lexical front end | `util` (meter, JSON, SHA-256), `unicode`, `lex` (strict UTF-8, numbers, dates, hostile input), `morph`, `spell` (symmetric-delete typo candidates, orthotactic non-word test), `temporal` |
| C/D semantics | `lexicon` + `data/lex_*.lua` (DSL: relations, senses, cues, entities), `lattice` (alternative segmentations, name guesses), `parse` (NP / VP / wh, normalisers), `constraints` (negation / preference / restriction scope), `frames`, `frames2`, `frames3`, `frames4` (construction hypotheses), `hyp` (type fit, binding, named-factor scoring, ambiguity), `sem` (analysis + render), `repair` |
| E memory / coreference | `memory` (layered, supersession, revocation, namespaces, structural-link selection), `coref` (pronouns, back-references, ordinals, speaker facts), `interp` (orchestration) |
| F/G data and evidence | `dataset` (JSONL / CSV / TSV / text parsed as data, never executed), `index`, `assertions`, `assertions2`, `knowledge`, `verify`, `plan`, `record` (versioned Interpretation Record + LM Input Package), `calibration`, `perturb` |
| H evaluation / delivery | `eval`, `rbench`, `longctx`, `bundler`, `package`, `injector`, `vfs`, `cli`, `main`, `engine`, `hook`; `tools/*.lua` |

Commands: `interpret`, `interpret-eval`, `interpret-report`, `interpret-trace`, `interpret-memory`, `interpret-replay` (plus `selftest`, `verify`, `bundle`, `extract` in the single file).
Controlled non-destructive injection into a host file (`tools/inject_bundle.lua`) with BEGIN/END markers, backup, idempotence and a reversible removal proven by SHA-256.

New in this last round (all with tests / dev cases): gibberish veto (orthotactics, not a word list), spoken fillers, typed bindings kept across roles,
standing-slot inheritance for bare corrections ("Sorry, I meant 2023."), comma-separated comparison lists, ellipsis after comparisons and "And of X?",
locative pro-form "there", speaker facts ("I work at X" → "my employer"), recall of earlier statements by shared content words, seeking wrappers
("Find me …", "I'm looking for …"), **numeric restrictions** ("more than 500 employees", "between 100 and 200"), wh-questions over filtered sets,
superlative questions, passive yes/no questions with and without dates, "does X have more N than Y".

## 3. Verified (automated, `lua5.4 tests/run_all.lua` and `lua5.4 dist/asi_nlu.lua selftest`)

* 121 unit tests in 11 suites (acceptance 13, dataset 12, injection 5, lex 26, memory 17, regression A–J 2, robustness 6, single-file 10, temporal 15, unicode 7, util 8) — all pass.
* Self-test of the single file from an empty directory with `package.path = ""`: **18 checks, 0 failed** (determinism across independent engines, injector round-trip, library region runs alone with no global).
* Regression examples A–J (`data/eval/regression_AJ.cases`, 38 cases): 100 %.
* Safety properties with tests: no answer without selected evidence; injected / contaminated text never promoted to a verified answer or an instruction (0/24 leaks); revoked, superseded and cross-namespace memory excluded with the exclusion recorded; budget exhaustion reported as `limited`; every hostile input yields a valid record.

## 4. Measured (all numbers re-runnable; raw outputs in `reports/runs/`)

### 4.1 Independent first runs (honest generalisation) — each set run once, before any tuning on it

| set | author | engine | n | all-fields accuracy | serious-error rate | naive baseline |
|---|---|---|---|---|---|---|
| blind1 | independent agent | e700f7d | 170 | 0.582 [0.507, 0.654] | 0.400 | — |
| blind2 | independent agent | 4c2704b | 170 | 0.641 [0.567, 0.709] | 0.347 | — |
| **blind3** | independent agent | **e0a0bde** | 170 | **0.612 [0.537, 0.682]** (0.611 [0.535, 0.681] without the 3 cases seen in the contamination notice) | 0.382 | **0.094 [0.059, 0.147]** (serious 0.876) |

Ablations on blind3 (same inputs): no hypothesis competition 0.447 · no memory 0.518 · no coreference 0.547 · no type constraints 0.594 · no suffix readings 0.594 ·
lexical-only 0.094. (Typo repair does not change gold-case accuracy but is worth +15.6 points on noisy input, below.) `reports/runs/ablations_run1.txt`.

### 4.2 Author-written sets (optimistic by construction — the engine was developed around this kind of sentence)

| set | n | accuracy |
|---|---|---|
| frozen `test` split (frozen by SHA-256 before the engine saw it; run once) | 140 | **0.964 [0.919, 0.985]**, baseline 0.200 |
| dev / val (tuned on) | 135 / 100 | 1.000 / 1.000 |
| dev constructions 1 / 2 / 3 (tuned on) | 113 / 34 / 34 | 0.982 / 1.000 / 1.000 |
| blind1 / blind2 **after** tuning (burned: development numbers, not held-out) | 170 / 170 | 0.894 / 0.988 |

Noise robustness on the test split (typo, filler, lower-case, dropped punctuation / determiner; 1541 perturbed inputs): **0.931** with repair, 0.775 without, 0.253 for the baseline.

### 4.3 Retrieval / evidence (fresh phrasings of facts and questions, held-out vocabulary)

| templates (first run) | fact-sentence coverage | question coverage | correct | wrong answer | abstained | serious error | keyword baseline serious error |
|---|---|---|---|---|---|---|---|
| heldout4 (e700f7d) | 0.342 | 0.608 | 0.192 | 0.008 | 0.800 | 0.006 | 1.000 |
| heldout5 (4c2704b) | 0.187 | 0.680 | 0.167 | 0.008 | 0.825 | 0.006 | 1.000 |
| **heldout6 (e0a0bde)** | **0.353** | **0.773** | **0.242** | **0.017** | 0.742 | **0.013 [0.003, 0.045]** | 1.000 |

So on unseen wordings the system answers about a quarter of the questions, abstains on most of the rest, and is rarely wrong; free-text *fact extraction* (a third of fresh fact sentences) is the weakest link.
On the development templates it answers 100 % correctly (0 wrong); `v_no_typed` collapses to 86 % serious error; the other retrieval ablations show no effect on this benchmark.

### 4.4 Long conversations (needed information at the beginning / middle / end of N distractor turns)

First runs on never-seen wordings: 24.6 % (heldout2) → 54.8 % (heldout3) → **75.4 % [0.672, 0.821]** (heldout4, 10 and 100 turns), memory recall 0.98, false-memory per request 1.64.
Built-in development sweep (10 / 100 / 500 turns, 189 scenarios): 100 %, false memory 0.00 (tuned on).

### 4.5 Confidence

Calibrated with a sign-constrained ridge logistic over interpretation features, cross-fitted dev↔val (never the test split): ECE 0.058, AUROC 0.825 (raw score ECE 0.172, AUROC 0.595).
Under distribution shift (`tools/calibration_shift.lua`): blind3 **ECE 0.074, AUROC 0.846** (raw 0.197 / 0.617); test ECE 0.072. The low-confidence bins really are the wrong readings
(0–27 % correct); the top bins are over-confident (stated 0.97, observed 0.80–0.93 on blind3). The record labels the calibration "valid for noisy variants of the dev/val distribution only".

### 4.6 Performance (`reports/performance.md`, deterministic work counter plus wall time on one machine)

Work per sentence is constant (230 units) from 1 to 384 sentences; the final request after 1000 turns costs the same work as after 10 (246); question work is flat in dataset size (≈ 220 units, 7–17 ms);
ingestion is linear (80 s for 19 233 records, ≈ 4 ms/record).

## 5. Failure report (blind3 first run — 66 of 170 cases; classification is mine)

| root cause | cases (examples) | n |
|---|---|---|
| **Carrier phrases hide the question**: the request sits after a long lead-in or before a trailing remark; the clause-suffix mechanism does not fire because a "good-looking" empty statement reading blocks it | E002 "…needs to know the currency of Norway", E005, E008, E012, E040, E041, E043, E050, E149, E156, E157, E162 | 12 |
| **Missing lexicalisations of relation words / idioms** | E014 "came up with" (inventor), E025 "put money into" (investor), E028 "who all works for", E087 "make up", E159 "big cheese", E115/E116/E158 "have Portuguese as an official language / whose official language is French", E007, E045 "besides", E080, E161 | 13 |
| **Standing style / format instructions** are not turned into persistent preferences ("Always give me distances in kilometres", "Keep it under 100 words", "From now on call me …") | E090–E096, E099 | 9 |
| Comparison / choice forms | E069, E071, E075, E109, E131 | 5 |
| Multi-turn references | E134 "which country did I ask about first", E137 "the first company", E139 "the other one", E140, E141 | 5 |
| Negation / complement over typed sets | E035, E036, E038, E049 | 4 |
| Typos inside names and relation words | E143, E145, E146, E147 | 4 |
| "which N [in P] verb object" filters | E082, E088, E117 | 3 |
| Temporal forms ("as of", "used to be", "will host", "founded after") | E052, E057, E058 | 3 |
| Multi-word names with `&` / "to the" / lower-case input | E009, E015, E077, E078, E081 | 5 |
| Intent labels (translate, causes), ambiguity flag | E105, E110, E068 | 3 |

What this says: the architecture (competing hypotheses, typed roles, explicit memory) holds; the *coverage of surface constructions* is the limit. Each class above is a bounded
piece of work (cues, lexicalisations, a suffix trigger that ignores empty statement readings, a persistent-preference frame); none needs a model. I did not tune on blind3 after seeing its failures.

## 6. Unproven / not done

* **Host regression is Unproven.** `exec_eval_1(2).lua` (≈ 49 k lines: VM, cyber, reasoning, sketch) was never available in the container. Injection was proven non-destructive on synthetic hosts only; run your own test command on an injected copy (`tools/inject_bundle.lua --target HOST.lua --selfcheck`, which writes `HOST.asi.lua` and leaves `HOST.lua` untouched).
* **General language understanding** is not shown — see §1 and §5. English only; no multilingual claim.
* "Independent" sets were written by sub-agents of the same model family, not by people; independence is limited.
* Retrieval ablations other than `typed` and `reliability` show no effect here (redundant mechanisms or an insensitive benchmark) — their individual contributions are unproven.
* Long-context results at 500 turns exist only for the built-in (tuned) wordings; blind wordings were run at 10 and 100 turns.
* Wall-clock figures come from one machine; only the work counter is machine-independent.

## 7. Protocol notes

* Gold edits after seeing engine output are logged in `reports/gold_changes.md` (D093, V066: `neg=none` removed). Harness changes: `dep=earlier_context` accepted as an alias of `earlier_project_context`; new `pos=numeric:` key; fuzzy-resolved mentions judged by entity name; parent-relation acceptance in the long-context scorer.
* `reports/heldout_log.md` records every first run and one contamination notice: three blind3 gold lines (E129, E133, E140) were displayed before its first run; the engine was not edited for them and blind3 is reported with and without them.
* The frozen test split's SHA-256 is verified by `lua5.4 tools/manifest.lua check`.

## 8. Using the single file

```
lua5.4 asi_nlu.lua selftest                                   # 18 checks, from any directory
lua5.4 asi_nlu.lua interpret "Which cities in Germany have more than a million inhabitants?" --json
lua5.4 asi_nlu.lua interpret-trace "Who put money into Quenby Robotics?"
lua5.4 asi_nlu.lua interpret-eval --split test                # the gold sets are embedded
lua5.4 asi_nlu.lua tool run_eval --file some.cases            # every evaluation tool is embedded (run_eval, run_noise, run_longctx, run_perf, ...)
lua5.4 asi_nlu.lua report FINAL_REPORT                        # this report
lua5.4 asi_nlu.lua bundle --out asi_nlu_bundle.lua            # the package.preload library text (host injection)
lua5.4 asi_nlu.lua inject --target HOST.lua --selfcheck       # writes HOST.asi.lua, leaves HOST.lua untouched
lua5.4 asi_nlu.lua extract DIR                                # write every embedded source / data / test / report file into DIR
lua5.4 asi_nlu.lua verify                                     # SHA-256 integrity of every embedded file
```

## 9. Addendum: reading datasets (persona, tone, examples, facts)

Added after the sections above; design, clue table, limits and all numbers are in `reports/DATASET_READING.md`.  The engine now works out from basic context clues what a dataset contains
(facts, persona statements, style statements, example utterances, conversation turns, instructions aimed at the reader), picks up the persona and tone (declared and measured), announces the tone
with its evidence, keeps knowledge sorting exact whatever the voice, and lets the user read the data differently ("use a calmer tone", "no caps", "ignore the personality", "treat the examples as facts",
"play Bob instead", "what tone will you use?").  It is deterministic Lua with no language model and no network.

* **Verified:** 144 unit tests pass; the gold sets of this report are unchanged by the work.
* **Measured, independent, first run:** on 120 cases written by three sub-agents without access to the implementation, every check of a case passed in 4/40, 13/40 and 5/40 cases; per check, persona 0.47-0.57,
  tone words 0.47-0.80, facts 0.70-0.85, answers 0.73-0.86.  The reader is **not reliable on unseen phrasings**; my own cases (57 + 10, tuned on) pass 100 % and say nothing about that.
* **Unproven:** the host regression (the host bundle was not available), larger datasets than the scale tests, other languages.
