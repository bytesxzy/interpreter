# Performance and scaling

Measured by `tools/run_perf.lua`. `work` is the interpreter's deterministic work counter (identical on every machine); wall time and memory are from
the machine that produced this file and show growth only.

## Interpretation cost vs message length (single message, N sentences)

| sentences | bytes | work | work/sentence | wall (s) |
|---|---|---|---|---|
| 1 | 30 | 217 | 217 | 0.004 |
| 6 | 255 | 1381 | 230 | 0.017 |
| 24 | 1023 | 5527 | 230 | 0.078 |
| 96 | 4095 | 22111 | 230 | 0.263 |
| 384 | 16383 | 88447 | 230 | 1.219 |

## Conversation memory: cost of the final request vs conversation length

| turns | memory items | work (final request) | wall total (s) | heap (KB) |
|---|---|---|---|---|
| 10 | 12 | 246 | 0.03 | 35 |
| 100 | 104 | 246 | 0.26 | 173 |
| 500 | 520 | 246 | 1.22 | 671 |
| 1000 | 1045 | 246 | 2.20 | 1310 |

## Dataset ingestion and question answering vs dataset size

| records | ingest wall (s) | heap (KB) | assertions | question work (median) | question wall (ms, median) | correct / answerable |
|---|---|---|---|---|---|---|
| 192 | 0.50 | 2162 | 104 | 218 | 7.4 | 40 / 40 |
| 961 | 3.05 | 11483 | 586 | 219 | 9.5 | 50 / 50 |
| 4808 | 16.72 | 49747 | 2600 | 222 | 9.3 | 46 / 46 |
| 19233 | 80.11 | 188809 | 10400 | 222 | 16.6 | 46 / 46 |

