# Confidence calibration (interpretation correctness)

Target: P(all gold fields of a case are satisfied) given the raw `semantic_raw` score (posterior of the winning hypothesis).
Data: gold cases of the dev and val splits (single-turn, 6 perturbed variants per case plus the original; deterministic seed 11).
Perturbations (see `asi.nlu.perturb`): typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.
The frozen test split is NOT used. Dev gold was used to tune the interpreter, so dev/original accuracy is optimistic by construction; the perturbed
variants are what give the calibration data its errors. The calibration is valid only for this distribution of inputs.

## Fit on dev variants, evaluate on val variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 558 | 0.573 | 0.1558 | 0.2215 | 1.7372 | 0.671 |
| temperature/Platt | 558 | 0.573 | 0.2121 | 0.2286 | 0.6541 | 0.671 |
| isotonic | 558 | 0.573 | 0.2898 | 0.1844 | 0.5442 | 0.671 |

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.000 | 0.000 | 0.000-0.000 |
| 2 | 56 | 0.181 | 0.250 | 0.000-0.451 |
| 3 | 56 | 0.527 | 0.482 | 0.451-0.604 |
| 4 | 56 | 0.642 | 0.571 | 0.609-0.678 |
| 5 | 56 | 0.709 | 0.821 | 0.678-0.750 |
| 6 | 55 | 0.770 | 0.946 | 0.750-0.790 |
| 7 | 56 | 0.828 | 0.839 | 0.790-0.865 |
| 8 | 56 | 0.908 | 0.821 | 0.871-0.935 |
| 9 | 56 | 0.984 | 0.482 | 0.935-1.000 |
| 10 | 56 | 1.000 | 0.518 | 1.000-1.000 |

Reliability after isotonic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.023 | 0.000 | 0.023-0.023 |
| 2 | 56 | 0.159 | 0.161 | 0.023-0.364 |
| 3 | 56 | 0.464 | 0.143 | 0.364-0.476 |
| 4 | 56 | 0.482 | 0.946 | 0.476-0.524 |
| 5 | 56 | 0.665 | 0.214 | 0.524-0.703 |
| 6 | 55 | 0.703 | 0.255 | 0.703-0.703 |
| 7 | 56 | 0.703 | 1.000 | 0.703-0.703 |
| 8 | 56 | 0.703 | 1.000 | 0.703-0.703 |
| 9 | 56 | 0.703 | 1.000 | 0.703-0.703 |
| 10 | 56 | 0.703 | 1.000 | 0.703-0.703 |

## Fit on val variants, evaluate on dev variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 637 | 0.554 | 0.1552 | 0.2367 | 1.5836 | 0.678 |
| temperature/Platt | 637 | 0.554 | 0.1933 | 0.2256 | 0.6466 | 0.678 |
| isotonic | 637 | 0.554 | 0.2625 | 0.1953 | 0.5658 | 0.678 |

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.000 | 0.000 | 0.000-0.000 |
| 2 | 64 | 0.292 | 0.391 | 0.000-0.504 |
| 3 | 64 | 0.582 | 0.500 | 0.506-0.653 |
| 4 | 63 | 0.678 | 0.476 | 0.654-0.701 |
| 5 | 64 | 0.736 | 0.719 | 0.702-0.775 |
| 6 | 64 | 0.810 | 0.750 | 0.776-0.849 |
| 7 | 63 | 0.876 | 0.746 | 0.852-0.899 |
| 8 | 64 | 0.921 | 0.891 | 0.899-0.961 |
| 9 | 64 | 0.993 | 0.203 | 0.961-1.000 |
| 10 | 64 | 1.000 | 0.859 | 1.000-1.000 |

Reliability after isotonic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.035 | 0.000 | 0.035-0.035 |
| 2 | 64 | 0.284 | 0.359 | 0.035-0.500 |
| 3 | 64 | 0.518 | 0.203 | 0.500-0.520 |
| 4 | 63 | 0.656 | 0.397 | 0.520-0.743 |
| 5 | 64 | 0.743 | 0.000 | 0.743-0.743 |
| 6 | 64 | 0.743 | 0.578 | 0.743-0.743 |
| 7 | 63 | 0.743 | 1.000 | 0.743-0.743 |
| 8 | 64 | 0.743 | 1.000 | 0.743-0.743 |
| 9 | 64 | 0.743 | 1.000 | 0.743-0.743 |
| 10 | 64 | 0.743 | 1.000 | 0.743-0.743 |

## Original vs perturbed accuracy

| split | original | perturbed |
|---|---|---|
| dev | 95/95 = 1.000 | 258/542 = 0.476 |
| val | 82/82 = 1.000 | 238/476 = 0.500 |

Saved model: `data/calibration/interp_v1.json` (isotonic, 1195 samples, 5 steps, digest 414e9916febf8a78).
