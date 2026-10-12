# Held-out log

The `test` split (data/eval/test.cases) was authored before the engine was ever run on it and is frozen by SHA-256 in `data/eval/MANIFEST.json`
(`lua5.4 tools/manifest.lua check` fails if it is edited). It is meant to be run ONCE for the official held-out figure.

| event | split | note |
|---|---|---|
| authored | test | written before any evaluation run on it; categories chosen to mirror the directive's list (not the dev templates); includes entities and relation words absent from the dev set and out-of-lexicon constructions |
