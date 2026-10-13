"""
train_coverage_model.py -- learn which stimulus settings hit the RARE coverage bins.

Data (all produced by the Verilog testbench, one CSV row per generated test):
  * BASELINE runs  (results/train/baseline_s*_tests.csv)
        Pure random stimulus.  Used ONLY to measure how rare each coverage bin is:
        p_bin = fraction of tests that hit the bin.
  * EXPLORE runs   (results/train/explore_s*_tests.csv)
        Every test uses a randomly drawn "knob vector"
        (9 opcode weights, P(dependent operand), P(re-used memory address)).
        These rows are the supervised training set:
            X = the 11 knobs        y = did this test hit many RARE bins?

Model
  DecisionTreeClassifier (interpretable: we print the learned rules and the
  feature importances).  Generalisation is measured with k-fold cross-validated
  ROC-AUC on the EXPLORE data -- 0.5 would mean "no better than guessing".

Guidance
  Score a large pool of candidate knob vectors with the tree, keep the ones in the
  highest-scoring leaves, and write K diverse vectors to results/knobs.txt.  The
  GUIDED testbench draws one of these K vectors per test (diversity matters:
  concentrating on a single vector would starve the non-rare bins).
"""
import argparse
import glob
import os

import numpy as np
import pandas as pd
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.tree import DecisionTreeClassifier, export_text

KNOB_COLS = [f"w{i}" for i in range(9)] + ["p_dep", "p_mem"]
OPNAMES = ["ADD", "SUB", "AND", "OR", "ADDI", "LW", "SW", "BEQ", "BNE"]
NSLOT = 69


def slot_legal(s):
    """Same rule as tb_core.v: ADDI(4)/LW(5) have no operand-B forwarding path."""
    if s < 36 and (s % 4) in (1, 3) and (s // 4) in (4, 5):
        return False
    return True


def slot_name(s):
    paths = ["A_exmem", "B_exmem", "A_memwb", "B_memwb"]
    if s < 36:
        return f"fwd_{OPNAMES[s // 4]}_{paths[s % 4]}"
    if s < 38:
        return f"memwb_fwd_loaddata_{'AB'[s - 36]}"
    if s < 47:
        return f"loaduse_stall_{OPNAMES[s - 38]}"
    if s < 51:
        return ["BEQ_taken", "BEQ_nottaken", "BNE_taken", "BNE_nottaken"][s - 47]
    if s < 55:
        return "fwdbr_" + ["BEQ_taken", "BEQ_nottaken", "BNE_taken", "BNE_nottaken"][s - 51]
    if s < 57:
        return f"wb_bypass_{'AB'[s - 55]}"
    if s < 66:
        return f"flush_squashes_{OPNAMES[s - 57]}"
    return ["mem_SW_then_LW_sameaddr", "mem_SW_then_SW_sameaddr", "mem_LW_then_SW_sameaddr"][s - 66]


LEGAL = np.array([slot_legal(s) for s in range(NSLOT)])
BCOLS = [f"b{s}" for s in range(NSLOT)]


def load(pattern):
    files = sorted(glob.glob(pattern))
    if not files:
        raise SystemExit(f"no files match {pattern}")
    return pd.concat([pd.read_csv(f) for f in files], ignore_index=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default="results/train/baseline_s*_tests.csv")
    ap.add_argument("--explore", default="results/train/explore_s*_tests.csv")
    ap.add_argument("--rare-p", type=float, default=0.10,
                    help="a bin is RARE if pure-random tests hit it with probability below this")
    ap.add_argument("--k", type=int, default=16, help="number of knob vectors written for GUIDED mode")
    ap.add_argument("--out", default="results/knobs.txt")
    ap.add_argument("--report", default="results/model_report.txt")
    args = ap.parse_args()

    base = load(args.baseline)
    expl = load(args.explore)
    lines = []

    def say(s=""):
        print(s)
        lines.append(s)

    # ---- 1. which bins are rare under pure-random stimulus?
    p_bin = (base[BCOLS].values > 0).mean(axis=0)
    rare = np.where(LEGAL & (p_bin < args.rare_p))[0]
    say(f"Baseline tests: {len(base)}   Explore tests: {len(expl)}")
    say(f"Legal bins: {LEGAL.sum()}   RARE bins (p < {args.rare_p}): {len(rare)}")
    for s in rare[np.argsort(p_bin[rare])]:
        say(f"  bin {s:2d} {slot_name(s):32s} p(random test hits) = {p_bin[s]:.3f}")

    # ---- 2. supervised data: knobs -> number of rare bins hit by that test
    X = expl[KNOB_COLS].values.astype(float)
    rare_hits = (expl[[f"b{s}" for s in rare]].values > 0).sum(axis=1)
    thr = max(1, int(np.percentile(rare_hits, 75)))
    y = (rare_hits >= thr).astype(int)
    say(f"\nLabel: test hits >= {thr} rare bins   (positive rate {y.mean():.2f})")

    clf = DecisionTreeClassifier(max_depth=4, min_samples_leaf=25, class_weight="balanced",
                                 random_state=0)
    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=0)
    auc = cross_val_score(clf, X, y, cv=cv, scoring="roc_auc")
    say(f"5-fold CV ROC-AUC of the decision tree: {auc.mean():.3f} +/- {auc.std():.3f}  (0.5 = chance)")
    clf.fit(X, y)

    say("\nFeature importances:")
    for name, imp in sorted(zip(KNOB_COLS, clf.feature_importances_), key=lambda z: -z[1]):
        label = name if not name.startswith("w") else f"{name}({OPNAMES[int(name[1:])]})"
        say(f"  {label:12s} {imp:.3f}")
    say("\nLearned rules:")
    say(export_text(clf, feature_names=KNOB_COLS))

    # ---- 3. guidance: sample candidates, keep the best leaves, write K diverse vectors
    rng = np.random.default_rng(0)
    N = 50000
    cand = np.column_stack([rng.integers(0, 61, size=(N, 9)),
                            rng.integers(0, 86, size=N),
                            rng.integers(0, 86, size=N)])
    cand[cand[:, :9].sum(axis=1) == 0, 0] = 1
    score = clf.predict_proba(cand)[:, 1]
    best = cand[score >= score.max() - 1e-9]
    say(f"Candidates scored: {N};  in best leaf(s): {len(best)}  (predicted P(high-yield) = {score.max():.2f})")
    pick = best[rng.choice(len(best), size=min(args.k, len(best)), replace=False)]

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        f.write(f"{len(pick)}\n")
        for row in pick:
            f.write(" ".join(str(int(v)) for v in row) + "\n")
    say(f"\nWrote {len(pick)} knob vectors to {args.out}  (mean knobs below)")
    for name, v in zip(KNOB_COLS, pick.mean(axis=0)):
        label = name if not name.startswith("w") else f"{name}({OPNAMES[int(name[1:])]})"
        say(f"  {label:12s} {v:6.1f}   (explore mean {X[:, KNOB_COLS.index(name)].mean():5.1f})")

    with open(args.report, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
