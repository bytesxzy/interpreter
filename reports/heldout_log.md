# Held-out log

The `test` split (data/eval/test.cases) was authored before the engine was ever run on it and is frozen by SHA-256 in `data/eval/MANIFEST.json`
(`lua5.4 tools/manifest.lua check` fails if it is edited). It is meant to be run ONCE for the official held-out figure.

| event | split | note |
|---|---|---|
| authored | test | written before any evaluation run on it; categories chosen to mirror the directive's list (not the dev templates); includes entities and relation words absent from the dev set and out-of-lexicon constructions |
| contamination notice | blind3 (`interp_cases_blind3.cases`) | While surveying correction-fragment wordings with a repository-wide `grep` for "I meant" (intended for the dev / blind1 / blind2 files), three gold lines of the UNRUN round-3 set were echoed to the session: E129 ("Sorry, I meant Austria."), E133 ("Sorry, I meant the 2025 one." after a dataset instruction) and E140 ("No, I meant who founded it."). The engine was not edited for these wordings (the correction-fragment generalisation below was motivated by the burned blind2 case C127 and the dev set); nevertheless blind3 is no longer fully blind for those three cases. Rule adopted: the blind3 result is reported for all cases AND with E129/E133/E140 excluded; no other blind3 line is read before its run. |
