# Coverage closure: pure random vs ML-guided (held-out seeds)

* seeds per mode: **30**, tests per run: **600** (~19599 cycles)
* legal coverage bins: **65** (bins hit by at least one run: 65 incl. illegal slots, if any)
* metric: simulation cycles until the cumulative coverage first reaches X% of the legal bins; `n/N` = number of seeds that reached it within the run budget

| target | random median | random mean | guided median | guided mean | median speed-up | reached (rnd/guided) | Mann-Whitney p |
|---|---|---|---|---|---|---|---|
| 50% (33 bins) | 136 | 144 | 110 | 107 | 1.23x | 30/30 , 30/30 | 3.18e-06 |
| 75% (49 bins) | 330 | 341 | 236 | 242 | 1.40x | 30/30 , 30/30 | 7.21e-06 |
| 90% (59 bins) | 770 | 743 | 589 | 577 | 1.31x | 30/30 , 30/30 | 0.00141 |
| 95% (62 bins) | 1206 | 1331 | 944 | 1089 | 1.28x | 30/30 , 30/30 | 0.0061 |
| 100% (65 bins) | 6322 | 6473 | 3134 | 4034 | 2.02x | 29/30 , 30/30 | 0.00205 |

## Per-test hit probability of the rarest bins

| bin | random | guided |
|---|---|---|
| mem_LW_then_SW_sameaddr | 0.008 | 0.132 |
| mem_SW_then_SW_sameaddr | 0.009 | 0.152 |
| mem_SW_then_LW_sameaddr | 0.010 | 0.182 |
| loaduse_stall_ADDI | 0.030 | 0.096 |
| loaduse_stall_LW | 0.030 | 0.119 |
| loaduse_stall_OR | 0.055 | 0.140 |
| loaduse_stall_BNE | 0.055 | 0.022 |
| loaduse_stall_BEQ | 0.055 | 0.167 |
| loaduse_stall_SW | 0.056 | 0.129 |
| loaduse_stall_SUB | 0.056 | 0.190 |
| loaduse_stall_ADD | 0.058 | 0.239 |
| loaduse_stall_AND | 0.058 | 0.238 |

## Cost of the training data

Training data = 20 runs, 198233 simulated cycles (generated once; in a real flow this is coverage history from earlier regressions).
Median saving per closure run to 100%: 2860 cycles -> training cost is recovered after ~69.3 re-runs of the regression.
