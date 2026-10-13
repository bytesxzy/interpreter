# Confidence calibration (interpretation correctness)

Target: P(all gold fields of a case are satisfied) given the raw `semantic_raw` score (posterior of the winning hypothesis).
Data: gold cases of the dev and val splits (single-turn, 6 perturbed variants per case plus the original; deterministic seed 11).
Perturbations (see `asi.nlu.perturb`): typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.
The frozen test split is NOT used. Dev gold was used to tune the interpreter, so dev/original accuracy is optimistic by construction; the perturbed
variants are what give the calibration data its errors. The calibration is valid only for this distribution of inputs.

## Fit on dev variants, evaluate on val variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 558 | 0.889 | 0.1761 | 0.1261 | 0.7193 | 0.593 |
| temperature/Platt | 558 | 0.889 | 0.0978 | 0.0990 | 0.3756 | 0.593 |
| isotonic on semantic_raw | 558 | 0.889 | 0.1223 | 0.0918 | 0.3251 | 0.593 |
| logistic over interpretation features | 558 | 0.889 | 0.0653 | 0.0719 | 0.2725 | 0.814 |

Logistic weights (standardised features): semantic_raw=+0.82, coverage=+1.60, repaired=+0.00, n_repairs=+0.00, unknown_lowercase=-0.16, open_relation=-0.52, ambiguous=-0.23, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.01, bias=+1.92

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.359 | 0.673 | 0.000-0.494 |
| 2 | 56 | 0.545 | 0.839 | 0.498-0.603 |
| 3 | 56 | 0.632 | 0.929 | 0.605-0.680 |
| 4 | 56 | 0.727 | 0.911 | 0.688-0.757 |
| 5 | 56 | 0.784 | 0.964 | 0.760-0.814 |
| 6 | 55 | 0.838 | 0.946 | 0.814-0.875 |
| 7 | 56 | 0.898 | 0.964 | 0.875-0.919 |
| 8 | 56 | 0.940 | 0.964 | 0.919-0.969 |
| 9 | 56 | 0.992 | 0.839 | 0.969-1.000 |
| 10 | 56 | 1.000 | 0.857 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.231 | 0.382 | 0.000-0.578 |
| 2 | 56 | 0.695 | 0.857 | 0.589-0.765 |
| 3 | 56 | 0.826 | 0.893 | 0.765-0.867 |
| 4 | 56 | 0.886 | 0.946 | 0.867-0.910 |
| 5 | 56 | 0.921 | 0.982 | 0.910-0.929 |
| 6 | 55 | 0.933 | 1.000 | 0.929-0.938 |
| 7 | 56 | 0.946 | 0.982 | 0.938-0.952 |
| 8 | 56 | 0.957 | 0.911 | 0.953-0.960 |
| 9 | 56 | 0.963 | 0.964 | 0.960-0.965 |
| 10 | 56 | 0.968 | 0.964 | 0.965-0.970 |

## Fit on val variants, evaluate on dev variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 637 | 0.834 | 0.1312 | 0.1299 | 0.6257 | 0.700 |
| temperature/Platt | 637 | 0.834 | 0.1149 | 0.1408 | 0.4592 | 0.700 |
| isotonic on semantic_raw | 637 | 0.834 | 0.1184 | 0.1175 | 0.4103 | 0.700 |
| logistic over interpretation features | 637 | 0.834 | 0.0544 | 0.0925 | 0.3211 | 0.834 |

Logistic weights (standardised features): semantic_raw=+0.46, coverage=+1.13, repaired=+0.00, n_repairs=-0.05, unknown_lowercase=-0.39, open_relation=-0.42, ambiguous=+0.00, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.14, bias=+2.51

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.304 | 0.444 | 0.000-0.500 |
| 2 | 64 | 0.546 | 0.672 | 0.502-0.602 |
| 3 | 64 | 0.631 | 0.859 | 0.603-0.665 |
| 4 | 63 | 0.708 | 0.936 | 0.665-0.753 |
| 5 | 64 | 0.788 | 0.906 | 0.754-0.834 |
| 6 | 64 | 0.857 | 0.938 | 0.834-0.877 |
| 7 | 63 | 0.900 | 0.968 | 0.877-0.917 |
| 8 | 64 | 0.936 | 0.797 | 0.917-0.981 |
| 9 | 64 | 0.996 | 0.812 | 0.983-1.000 |
| 10 | 64 | 1.000 | 1.000 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.359 | 0.206 | 0.002-0.800 |
| 2 | 64 | 0.874 | 0.797 | 0.806-0.901 |
| 3 | 64 | 0.914 | 0.734 | 0.902-0.923 |
| 4 | 63 | 0.933 | 0.889 | 0.923-0.941 |
| 5 | 64 | 0.948 | 0.922 | 0.941-0.953 |
| 6 | 64 | 0.957 | 0.938 | 0.953-0.961 |
| 7 | 63 | 0.964 | 0.968 | 0.961-0.966 |
| 8 | 64 | 0.967 | 0.969 | 0.966-0.970 |
| 9 | 64 | 0.972 | 0.969 | 0.970-0.974 |
| 10 | 64 | 0.975 | 0.938 | 0.974-0.976 |

## Original vs perturbed accuracy

| split | original | perturbed |
|---|---|---|
| dev | 95/95 = 1.000 | 436/542 = 0.804 |
| val | 82/82 = 1.000 | 414/476 = 0.870 |

Saved model: `data/calibration/interp_v1.json` (logistic over 11 features, 1195 samples, digest 27172f30fbd44926).
