# Performance and scaling

Measured by `tools/run_perf.lua`. `work` is the interpreter's deterministic work counter (identical on every machine); wall time and memory are from
the machine that produced this file and show growth only.

## Interpretation cost vs message length (single message, N sentences)

| sentences | bytes | work | work/sentence | wall (s) |
|---|---|---|---|---|
| 1 | 30 | 113 | 113 | 0.004 |
| 6 | 255 | 748 | 125 | 0.038 |
| 24 | 1023 | 2995 | 125 | 0.042 |
| 96 | 4095 | 11983 | 125 | 0.165 |
| 384 | 16383 | 47935 | 125 | 0.873 |

## Conversation memory: cost of the final request vs conversation length

| turns | memory items | work (final request) | wall total (s) | heap (KB) |
|---|---|---|---|---|
| 10 | 12 | 141 | 0.02 | 30 |
| 100 | 104 | 141 | 0.19 | 152 |
| 500 | 520 | 141 | 0.86 | 606 |
| 1000 | 1045 | 141 | 1.89 | 1200 |

## Dataset ingestion and question answering vs dataset size

| records | ingest wall (s) | heap (KB) | assertions | question work (median) | question wall (ms, median) | correct / answerable |
|---|---|---|---|---|---|---|
| 192 | 0.41 | 2179 | 120 | 114 | 9.2 | 40 / 40 |
| 961 | 2.70 | 11581 | 666 | 115 | 9.2 | 50 / 50 |
| 4808 | 15.96 | 50248 | 3000 | 116 | 13.1 | 46 / 46 |
| 19233 | 65.10 | 190827 | 12000 | 118 | 23.2 | 46 / 46 |

