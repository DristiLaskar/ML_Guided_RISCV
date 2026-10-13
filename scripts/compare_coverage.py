"""
compare_coverage.py -- honest comparison of BASELINE (pure random) vs GUIDED stimulus.

Reads  results/eval/baseline_s*_tests.csv  and  results/eval/guided_s*_tests.csv
(one pair per held-out seed), measures the simulation cycles needed to reach
X% of the legal coverage bins, and reports distribution statistics across seeds
instead of a single cherry-picked seed.

Writes results/summary.md, results/summary.csv, results/coverage_closure_comparison.png
"""
import glob
import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy.stats import mannwhitneyu

RES = "results"
TOTAL_BINS = 65            # legal bins in tb_core.v (69 slots - 4 illegal)
LEVELS = [50, 75, 90, 95, 100]
BCOLS = [f"b{s}" for s in range(69)]


def load_runs(kind):
    runs = []
    for f in sorted(glob.glob(f"{RES}/eval/{kind}_s*_tests.csv")):
        runs.append(pd.read_csv(f))
    if not runs:
        raise SystemExit(f"no {kind} runs found - run scripts/run_flow.py first")
    return runs


def cycles_to_reach(df, n_bins):
    hit = df[df.cum_bins >= n_bins]
    if hit.empty:
        return None, None
    r = hit.iloc[0]
    return int(r.cum_cycles), int(r.test) + 1


def stats(runs, level):
    n = math.ceil(TOTAL_BINS * level / 100.0)
    out = [cycles_to_reach(r, n) for r in runs]
    cyc = [c for c, _ in out]
    return cyc


def curve_on_grid(df, grid):
    idx = np.searchsorted(df.cum_cycles.values, grid, side="right") - 1
    vals = np.where(idx >= 0, df.cum_bins.values[np.clip(idx, 0, None)], 0)
    return vals


def main():
    base, guid = load_runs("baseline"), load_runs("guided")
    budget = max(r.cum_cycles.iloc[-1] for r in base + guid)
    union = (pd.concat(base + guid)[BCOLS].sum() > 0).sum()

    rows, md = [], []
    md.append(f"# Coverage closure: pure random vs ML-guided (held-out seeds)\n")
    md.append(f"* seeds per mode: **{len(base)}**, tests per run: **{len(base[0])}** "
              f"(~{int(np.mean([r.cum_cycles.iloc[-1] for r in base]))} cycles)")
    md.append(f"* legal coverage bins: **{TOTAL_BINS}** (bins hit by at least one run: {union} incl. illegal slots, if any)")
    md.append("* metric: simulation cycles until the cumulative coverage first reaches X% of the legal bins; "
              "`n/N` = number of seeds that reached it within the run budget\n")
    md.append("| target | random median | random mean | guided median | guided mean | median speed-up | "
              "reached (rnd/guided) | Mann-Whitney p |")
    md.append("|---|---|---|---|---|---|---|---|")
    for lv in LEVELS:
        b, g = stats(base, lv), stats(guid, lv)
        bf = [x if x is not None else budget + 1 for x in b]      # censor un-reached runs
        gf = [x if x is not None else budget + 1 for x in g]
        bm, gm = float(np.median(bf)), float(np.median(gf))
        bmean = float(np.mean([x for x in b if x is not None])) if any(x is not None for x in b) else float("nan")
        gmean = float(np.mean([x for x in g if x is not None])) if any(x is not None for x in g) else float("nan")
        p = mannwhitneyu(bf, gf, alternative="two-sided").pvalue
        nb = sum(x is not None for x in b)
        ng = sum(x is not None for x in g)
        sp = bm / gm if gm > 0 else float("nan")
        md.append(f"| {lv}% ({math.ceil(TOTAL_BINS*lv/100)} bins) | {bm:.0f} | {bmean:.0f} | {gm:.0f} | {gmean:.0f} | "
                  f"{sp:.2f}x | {nb}/{len(base)} , {ng}/{len(guid)} | {p:.3g} |")
        rows.append(dict(level=lv, random_median=bm, random_mean=bmean, guided_median=gm,
                         guided_mean=gmean, speedup_median=sp, p_value=p,
                         reached_random=nb, reached_guided=ng))
    pd.DataFrame(rows).to_csv(f"{RES}/summary.csv", index=False)

    # ---- per-bin rarity under each mode (how often does a test hit the bin?)
    pb = (pd.concat(base)[BCOLS].values > 0).mean(axis=0)
    pg = (pd.concat(guid)[BCOLS].values > 0).mean(axis=0)
    from train_coverage_model import LEGAL, slot_name  # noqa: E402
    md.append("\n## Per-test hit probability of the rarest bins\n")
    md.append("| bin | random | guided |\n|---|---|---|")
    order = [s for s in np.argsort(pb) if LEGAL[s]][:12]
    for s in order:
        md.append(f"| {slot_name(s)} | {pb[s]:.3f} | {pg[s]:.3f} |")

    # ---- cost of obtaining the training data
    tr = sorted(glob.glob(f"{RES}/train/explore_s*_tests.csv")) + sorted(glob.glob(f"{RES}/train/baseline_s*_tests.csv"))
    if tr:
        tc = sum(pd.read_csv(f).cum_cycles.iloc[-1] for f in tr)
        b100 = [x for x in stats(base, 100) if x is not None]
        g100 = [x for x in stats(guid, 100) if x is not None]
        md.append("\n## Cost of the training data\n")
        md.append(f"Training data = {len(tr)} runs, {tc} simulated cycles (generated once; in a real flow this is "
                  f"coverage history from earlier regressions).")
        if b100 and g100:
            save = np.median(b100) - np.median(g100)
            if save > 0:
                md.append(f"Median saving per closure run to 100%: {save:.0f} cycles -> training cost is "
                          f"recovered after ~{tc/save:.1f} re-runs of the regression.")
            else:
                md.append("Guided stimulus does not save cycles to 100% at the median, so the training cost is not recovered.")
    open(f"{RES}/summary.md", "w").write("\n".join(md) + "\n")

    # ---- plot
    b100 = [x for x in stats(base, 100) if x is not None]
    xmax = int(1.5 * np.median(b100)) if b100 else budget
    grid = np.linspace(0, min(budget, xmax), 400)
    fig, ax = plt.subplots(1, 2, figsize=(13, 4.8))
    for name, runs, col in (("Random", base, "tab:blue"), ("ML-guided", guid, "tab:orange")):
        C = np.array([curve_on_grid(r, grid) for r in runs]) / TOTAL_BINS * 100
        ax[0].plot(grid, np.median(C, axis=0), color=col, label=f"{name} (median of {len(runs)} seeds)")
        ax[0].fill_between(grid, np.percentile(C, 25, axis=0), np.percentile(C, 75, axis=0),
                           color=col, alpha=0.2)
        ax[1].plot(grid, np.median(C, axis=0), color=col, label=name)
        ax[1].fill_between(grid, np.percentile(C, 25, axis=0), np.percentile(C, 75, axis=0), color=col, alpha=0.2)
    ax[0].set_xlabel("simulation cycles"); ax[0].set_ylabel("functional coverage (% of 65 legal bins)")
    ax[0].set_title("Coverage closure (median, IQR band)"); ax[0].grid(alpha=.3); ax[0].legend()
    ax[0].set_xlim(0, grid[-1]); ax[1].set_xlim(0, grid[-1]); ax[1].set_ylim(90, 100.5)
    ax[1].set_xlabel("simulation cycles"); ax[1].set_title("Zoom: last 10% of coverage"); ax[1].grid(alpha=.3)
    plt.tight_layout()
    plt.savefig(f"{RES}/coverage_closure_comparison.png", dpi=140)


if __name__ == "__main__":
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
