# Confidence calibration (interpretation correctness)

Target: P(all gold fields of a case are satisfied) given the raw `semantic_raw` score (posterior of the winning hypothesis).
Data: gold cases of the dev and val splits (single-turn, 6 perturbed variants per case plus the original; deterministic seed 11).
Perturbations (see `asi.nlu.perturb`): typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.
The frozen test split is NOT used. Dev gold was used to tune the interpreter, so dev/original accuracy is optimistic by construction; the perturbed
variants are what give the calibration data its errors. The calibration is valid only for this distribution of inputs.

## Fit on dev variants, evaluate on val variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 558 | 0.887 | 0.1715 | 0.1259 | 0.7375 | 0.586 |
| temperature/Platt | 558 | 0.887 | 0.1017 | 0.1010 | 0.3793 | 0.586 |
| isotonic on semantic_raw | 558 | 0.887 | 0.1217 | 0.0922 | 0.3267 | 0.586 |
| logistic over interpretation features | 558 | 0.887 | 0.0581 | 0.0704 | 0.2685 | 0.813 |

Logistic weights (standardised features): semantic_raw=+0.89, coverage=+1.60, repaired=+0.00, n_repairs=+0.00, unknown_lowercase=-0.13, open_relation=-0.51, ambiguous=+0.00, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.01, bias=+1.85

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.362 | 0.673 | 0.000-0.484 |
| 2 | 56 | 0.553 | 0.857 | 0.484-0.608 |
| 3 | 56 | 0.644 | 0.875 | 0.608-0.702 |
| 4 | 56 | 0.740 | 0.929 | 0.703-0.767 |
| 5 | 56 | 0.788 | 0.982 | 0.769-0.815 |
| 6 | 55 | 0.845 | 0.946 | 0.817-0.878 |
| 7 | 56 | 0.909 | 0.964 | 0.880-0.928 |
| 8 | 56 | 0.948 | 0.964 | 0.932-0.975 |
| 9 | 56 | 0.994 | 0.750 | 0.979-1.000 |
| 10 | 56 | 1.000 | 0.929 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.253 | 0.382 | 0.000-0.634 |
| 2 | 56 | 0.739 | 0.839 | 0.637-0.778 |
| 3 | 56 | 0.820 | 0.929 | 0.780-0.843 |
| 4 | 56 | 0.871 | 0.911 | 0.843-0.896 |
| 5 | 56 | 0.909 | 0.982 | 0.897-0.916 |
| 6 | 55 | 0.924 | 1.000 | 0.916-0.932 |
| 7 | 56 | 0.940 | 0.964 | 0.932-0.948 |
| 8 | 56 | 0.953 | 0.929 | 0.949-0.955 |
| 9 | 56 | 0.958 | 0.964 | 0.955-0.960 |
| 10 | 56 | 0.964 | 0.964 | 0.960-0.965 |

## Fit on val variants, evaluate on dev variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 637 | 0.832 | 0.1160 | 0.1319 | 0.6477 | 0.681 |
| temperature/Platt | 637 | 0.832 | 0.0982 | 0.1424 | 0.4640 | 0.681 |
| isotonic on semantic_raw | 637 | 0.832 | 0.1408 | 0.1179 | 0.4125 | 0.681 |
| logistic over interpretation features | 637 | 0.832 | 0.0534 | 0.0945 | 0.3299 | 0.817 |

Logistic weights (standardised features): semantic_raw=+0.48, coverage=+1.14, repaired=+0.00, n_repairs=-0.14, unknown_lowercase=-0.37, open_relation=-0.43, ambiguous=+0.00, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.13, bias=+2.48

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.305 | 0.476 | 0.000-0.496 |
| 2 | 64 | 0.555 | 0.672 | 0.497-0.608 |
| 3 | 64 | 0.648 | 0.875 | 0.610-0.686 |
| 4 | 63 | 0.734 | 0.921 | 0.686-0.770 |
| 5 | 64 | 0.804 | 0.938 | 0.771-0.844 |
| 6 | 64 | 0.867 | 0.891 | 0.845-0.893 |
| 7 | 63 | 0.909 | 0.905 | 0.894-0.919 |
| 8 | 64 | 0.941 | 0.844 | 0.919-0.982 |
| 9 | 64 | 0.997 | 0.797 | 0.983-1.000 |
| 10 | 64 | 1.000 | 1.000 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.357 | 0.191 | 0.002-0.809 |
| 2 | 64 | 0.871 | 0.812 | 0.809-0.897 |
| 3 | 64 | 0.911 | 0.781 | 0.897-0.921 |
| 4 | 63 | 0.930 | 0.873 | 0.922-0.940 |
| 5 | 64 | 0.946 | 0.922 | 0.940-0.952 |
| 6 | 64 | 0.956 | 0.922 | 0.952-0.959 |
| 7 | 63 | 0.962 | 0.952 | 0.959-0.965 |
| 8 | 64 | 0.967 | 0.969 | 0.965-0.970 |
| 9 | 64 | 0.971 | 0.953 | 0.970-0.972 |
| 10 | 64 | 0.974 | 0.938 | 0.972-0.977 |

## Original vs perturbed accuracy

| split | original | perturbed |
|---|---|---|
| dev | 95/95 = 1.000 | 435/542 = 0.803 |
| val | 82/82 = 1.000 | 413/476 = 0.868 |

Saved model: `data/calibration/interp_v1.json` (logistic over 11 features, 1195 samples, digest 0c879c32088ffaff).
