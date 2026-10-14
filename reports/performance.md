# Performance and scaling

Measured by `tools/run_perf.lua`. `work` is the interpreter's deterministic work counter (identical on every machine); wall time and memory are from
the machine that produced this file and show growth only.

## Interpretation cost vs message length (single message, N sentences)

| sentences | bytes | work | work/sentence | wall (s) |
|---|---|---|---|---|
| 1 | 30 | 205 | 205 | 0.004 |
| 6 | 255 | 1309 | 218 | 0.044 |
| 24 | 1023 | 5239 | 218 | 0.045 |
| 96 | 4095 | 20959 | 218 | 0.262 |
| 384 | 16383 | 83839 | 218 | 1.077 |

## Conversation memory: cost of the final request vs conversation length

| turns | memory items | work (final request) | wall total (s) | heap (KB) |
|---|---|---|---|---|
| 10 | 12 | 234 | 0.02 | 35 |
| 100 | 104 | 234 | 0.26 | 173 |
| 500 | 520 | 234 | 1.22 | 671 |
| 1000 | 1045 | 234 | 2.55 | 1310 |

## Dataset ingestion and question answering vs dataset size

| records | ingest wall (s) | heap (KB) | assertions | question work (median) | question wall (ms, median) | correct / answerable |
|---|---|---|---|---|---|---|
| 192 | 0.52 | 2162 | 104 | 206 | 9.6 | 40 / 40 |
| 961 | 3.45 | 11483 | 586 | 207 | 9.8 | 50 / 50 |
| 4808 | 18.19 | 49747 | 2600 | 210 | 13.2 | 46 / 46 |
| 19233 | 80.05 | 188809 | 10400 | 210 | 21.3 | 46 / 46 |

