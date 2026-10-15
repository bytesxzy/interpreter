# Confidence calibration (interpretation correctness)

Target: P(all gold fields of a case are satisfied) given the raw `semantic_raw` score (posterior of the winning hypothesis).
Data: gold cases of the dev and val splits (single-turn, 6 perturbed variants per case plus the original; deterministic seed 11).
Perturbations (see `asi.nlu.perturb`): typos in non-entity words, filler words, lower-casing, dropped punctuation, dropped determiners.
The frozen test split is NOT used. Dev gold was used to tune the interpreter, so dev/original accuracy is optimistic by construction; the perturbed
variants are what give the calibration data its errors. The calibration is valid only for this distribution of inputs.

## Fit on dev variants, evaluate on val variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 558 | 0.892 | 0.1718 | 0.1240 | 0.6740 | 0.595 |
| temperature/Platt | 558 | 0.892 | 0.1145 | 0.0961 | 0.3603 | 0.595 |
| isotonic on semantic_raw | 558 | 0.892 | 0.1296 | 0.0887 | 0.3192 | 0.595 |
| logistic over interpretation features | 558 | 0.892 | 0.0582 | 0.0697 | 0.2677 | 0.825 |

Logistic weights (standardised features): semantic_raw=+0.61, coverage=+1.47, repaired=+0.00, n_repairs=+0.00, unknown_lowercase=-0.18, open_relation=-0.50, ambiguous=-0.16, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.01, bias=+1.95

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.351 | 0.654 | 0.000-0.502 |
| 2 | 56 | 0.537 | 0.893 | 0.502-0.577 |
| 3 | 56 | 0.633 | 0.929 | 0.579-0.678 |
| 4 | 56 | 0.712 | 0.911 | 0.678-0.770 |
| 5 | 56 | 0.813 | 0.946 | 0.771-0.845 |
| 6 | 55 | 0.865 | 0.946 | 0.846-0.883 |
| 7 | 56 | 0.905 | 0.982 | 0.885-0.923 |
| 8 | 56 | 0.943 | 0.946 | 0.924-0.959 |
| 9 | 56 | 0.985 | 0.964 | 0.959-0.999 |
| 10 | 56 | 1.000 | 0.750 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 55 | 0.243 | 0.382 | 0.000-0.658 |
| 2 | 56 | 0.742 | 0.821 | 0.659-0.792 |
| 3 | 56 | 0.833 | 0.946 | 0.792-0.865 |
| 4 | 56 | 0.882 | 1.000 | 0.866-0.896 |
| 5 | 56 | 0.907 | 0.929 | 0.896-0.921 |
| 6 | 55 | 0.929 | 1.000 | 0.921-0.936 |
| 7 | 56 | 0.940 | 0.946 | 0.936-0.942 |
| 8 | 56 | 0.947 | 0.964 | 0.942-0.951 |
| 9 | 56 | 0.952 | 0.964 | 0.951-0.954 |
| 10 | 56 | 0.958 | 0.964 | 0.954-0.960 |

## Fit on val variants, evaluate on dev variants

| scoring | n | accuracy | ECE | Brier | log-loss | AUROC |
|---|---|---|---|---|---|---|
| raw (uncalibrated) | 637 | 0.841 | 0.1194 | 0.1337 | 0.6253 | 0.658 |
| temperature/Platt | 637 | 0.841 | 0.0965 | 0.1345 | 0.4424 | 0.658 |
| isotonic on semantic_raw | 637 | 0.841 | 0.1569 | 0.1221 | 0.4108 | 0.658 |
| logistic over interpretation features | 637 | 0.841 | 0.0616 | 0.0937 | 0.3269 | 0.816 |

Logistic weights (standardised features): semantic_raw=+0.46, coverage=+1.11, repaired=+0.00, n_repairs=+0.00, unknown_lowercase=-0.38, open_relation=-0.42, ambiguous=+0.00, fuzzy_entity=+0.00, min_entity=+0.00, unresolved_ref=+0.00, no_interpretation=-0.14, bias=+2.55

Reliability of the RAW score on the evaluation set:

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.339 | 0.556 | 0.000-0.504 |
| 2 | 64 | 0.559 | 0.688 | 0.505-0.611 |
| 3 | 64 | 0.658 | 0.906 | 0.611-0.693 |
| 4 | 63 | 0.748 | 0.857 | 0.700-0.809 |
| 5 | 64 | 0.843 | 0.922 | 0.811-0.862 |
| 6 | 64 | 0.881 | 0.938 | 0.863-0.897 |
| 7 | 63 | 0.910 | 0.936 | 0.898-0.920 |
| 8 | 64 | 0.944 | 0.844 | 0.920-0.971 |
| 9 | 64 | 0.994 | 0.766 | 0.971-1.000 |
| 10 | 64 | 1.000 | 1.000 | 1.000-1.000 |

Reliability after logistic calibration (evaluation set, not used for fitting):

| bin | n | mean confidence | accuracy | range |
|---|---|---|---|---|
| 1 | 63 | 0.454 | 0.238 | 0.002-0.824 |
| 2 | 64 | 0.880 | 0.781 | 0.832-0.906 |
| 3 | 64 | 0.922 | 0.844 | 0.907-0.931 |
| 4 | 63 | 0.939 | 0.857 | 0.931-0.945 |
| 5 | 64 | 0.951 | 0.938 | 0.945-0.956 |
| 6 | 64 | 0.961 | 0.922 | 0.956-0.965 |
| 7 | 63 | 0.966 | 0.984 | 0.965-0.968 |
| 8 | 64 | 0.969 | 0.969 | 0.968-0.971 |
| 9 | 64 | 0.972 | 0.953 | 0.971-0.975 |
| 10 | 64 | 0.975 | 0.922 | 0.975-0.976 |

## Original vs perturbed accuracy

| split | original | perturbed |
|---|---|---|
| dev | 95/95 = 1.000 | 441/542 = 0.814 |
| val | 82/82 = 1.000 | 416/476 = 0.874 |

Saved model: `data/calibration/interp_v1.json` (logistic over 11 features, 1195 samples, digest 0cfcd904d996ce9f).
