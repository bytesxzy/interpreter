# Confidence calibration (interpretation correctness)

Target: P(all gold fields of a case are satisfied) given the raw `semantic_raw` score (posterior of the winning hypothesis).
Data: gold cases of the dev and val splits (single-turn, 6 perturbed variants per case plus the original; deterministic seed 11).
Perturbations (see `asi.nlu.perturb`): typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.
The frozen test split is NOT used. Dev gold was used to tune the interpreter, so dev/original accuracy is optimistic by construction; the perturbed
variants are what give the calibration data its errors. The calibration is valid only for this distribution of inputs.

## Fit on dev variants, evaluate on val variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 558 | 0.894 | 0.1565 | 0.1157 | 0.6513 | 0.609 |
| temperature/Platt | 558 | 0.894 | 0.1039 | 0.0959 | 0.3607 | 0.609 |
| isotonic on semantic_raw | 558 | 0.894 | 0.1140 | 0.0891 | 0.3183 | 0.609 |
| logistic over interpretation features | 558 | 0.894 | 0.0646 | 0.0707 | 0.2713 | 0.818 |

Logistic weights (standardised features): semantic_raw=+0.72, coverage=+1.48, repaired=+0.00, n_repairs=+0.00, unknown_lowercase=-0.16, open_relation=-0.50, ambiguous=-0.21, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.01, bias=+1.90

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.357 | 0.654 | 0.000-0.502 |
| 2 | 56 | 0.551 | 0.875 | 0.503-0.615 |
| 3 | 56 | 0.666 | 0.929 | 0.615-0.701 |
| 4 | 56 | 0.759 | 0.911 | 0.702-0.807 |
| 5 | 56 | 0.834 | 0.946 | 0.807-0.858 |
| 6 | 55 | 0.874 | 0.964 | 0.858-0.893 |
| 7 | 56 | 0.911 | 0.982 | 0.893-0.934 |
| 8 | 56 | 0.948 | 0.946 | 0.934-0.964 |
| 9 | 56 | 0.990 | 0.893 | 0.969-1.000 |
| 10 | 56 | 1.000 | 0.839 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.215 | 0.400 | 0.000-0.565 |
| 2 | 56 | 0.696 | 0.839 | 0.569-0.766 |
| 3 | 56 | 0.833 | 0.946 | 0.792-0.867 |
| 4 | 56 | 0.885 | 0.982 | 0.868-0.901 |
| 5 | 56 | 0.915 | 0.946 | 0.903-0.926 |
| 6 | 55 | 0.933 | 0.982 | 0.926-0.939 |
| 7 | 56 | 0.944 | 0.946 | 0.939-0.948 |
| 8 | 56 | 0.950 | 0.964 | 0.948-0.955 |
| 9 | 56 | 0.956 | 0.964 | 0.955-0.956 |
| 10 | 56 | 0.961 | 0.964 | 0.956-0.963 |

## Fit on val variants, evaluate on dev variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 637 | 0.830 | 0.1074 | 0.1314 | 0.6334 | 0.686 |
| temperature/Platt | 637 | 0.830 | 0.1038 | 0.1424 | 0.4633 | 0.686 |
| isotonic on semantic_raw | 637 | 0.830 | 0.1648 | 0.1265 | 0.4398 | 0.686 |
| logistic over interpretation features | 637 | 0.830 | 0.0683 | 0.0997 | 0.3422 | 0.829 |

Logistic weights (standardised features): semantic_raw=+0.50, coverage=+1.10, repaired=+0.00, n_repairs=+0.00, unknown_lowercase=-0.35, open_relation=-0.42, ambiguous=+0.00, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.13, bias=+2.59

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.347 | 0.476 | 0.000-0.507 |
| 2 | 64 | 0.560 | 0.672 | 0.509-0.611 |
| 3 | 64 | 0.660 | 0.891 | 0.611-0.700 |
| 4 | 63 | 0.754 | 0.857 | 0.701-0.812 |
| 5 | 64 | 0.842 | 0.906 | 0.814-0.860 |
| 6 | 64 | 0.879 | 0.953 | 0.860-0.898 |
| 7 | 63 | 0.911 | 0.936 | 0.899-0.921 |
| 8 | 64 | 0.949 | 0.812 | 0.922-0.982 |
| 9 | 64 | 0.997 | 0.797 | 0.983-1.000 |
| 10 | 64 | 1.000 | 1.000 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.438 | 0.206 | 0.002-0.825 |
| 2 | 64 | 0.877 | 0.672 | 0.825-0.902 |
| 3 | 64 | 0.918 | 0.875 | 0.902-0.931 |
| 4 | 63 | 0.938 | 0.873 | 0.932-0.945 |
| 5 | 64 | 0.952 | 0.906 | 0.946-0.956 |
| 6 | 64 | 0.962 | 0.969 | 0.956-0.966 |
| 7 | 63 | 0.967 | 0.952 | 0.966-0.967 |
| 8 | 64 | 0.969 | 0.969 | 0.967-0.971 |
| 9 | 64 | 0.973 | 0.938 | 0.971-0.976 |
| 10 | 64 | 0.976 | 0.938 | 0.976-0.976 |

## Original vs perturbed accuracy

| split | original | perturbed |
|---|---|---|
| dev | 95/95 = 1.000 | 434/542 = 0.801 |
| val | 82/82 = 1.000 | 417/476 = 0.876 |

Saved model: `data/calibration/interp_v1.json` (logistic over 11 features, 1195 samples, digest 04ce1deae9c7691e).
