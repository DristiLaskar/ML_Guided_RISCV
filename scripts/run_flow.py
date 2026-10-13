"""
run_flow.py -- one-command, cross-platform driver (needs Icarus Verilog + Python deps).

  python scripts/run_flow.py                # full flow
  python scripts/run_flow.py --quick        # small/fast version (smoke test)
  python scripts/run_flow.py --steps mutants

Steps (in order):
  build    compile rtl/ + tb/ with iverilog (-g2001 = plain Verilog-2001)
  train    run BASELINE + EXPLORE simulations on TRAINING seeds
  model    fit the decision tree, write results/knobs.txt
  eval     run BASELINE and GUIDED on held-out EVALUATION seeds
  compare  statistics + plot (scripts/compare_coverage.py)
  mutants  inject 6 RTL bugs and confirm the scoreboard catches each one
"""
import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
BUILD = "build"
RES = "results"
SRC = ["rtl/pipeline_core.v", "tb/tb_core.v"]
MUTANTS = ["NO_STALL", "NO_FWD_WB", "NO_BYPASS", "FLUSH_ONE", "FWD_R0", "STORE_NOFWD"]


def sh(cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit(f"command failed: {' '.join(cmd)}")
    return r


def build(vvp, defines=()):
    cmd = ["iverilog", "-g2001", "-I", "rtl", "-Wall", "-o", vvp] + [f"-D{d}" for d in defines] + SRC
    r = sh(cmd)
    if r.stderr.strip():
        print(r.stderr)


def sim(vvp, mode, seed, tests, tag, knobs=None):
    args = ["vvp", vvp, f"+MODE={mode}", f"+SEED={seed}", f"+TESTS={tests}",
            f"+TESTS_CSV={tag}_tests.csv", f"+BINS_CSV={tag}_bins.csv"]
    if knobs:
        args.append(f"+KNOBS={knobs}")
    out = sh(args).stdout
    m = re.search(r"RESULT .*errors=(\d+)", out)
    if not m:
        raise SystemExit(f"no RESULT line for {tag}:\n{out}")
    return int(m.group(1)), out


def run_many(jobs):
    """jobs: list of kwargs for sim(); returns total scoreboard errors"""
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 2) as ex:
        results = list(ex.map(lambda kw: sim(**kw), jobs))
    return sum(e for e, _ in results)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", nargs="+",
                    default=["build", "train", "model", "eval", "compare", "mutants"])
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--eval-seeds", type=int, default=30)
    ap.add_argument("--eval-tests", type=int, default=600)
    ap.add_argument("--train-seeds", type=int, default=10)
    ap.add_argument("--train-tests", type=int, default=300)
    a = ap.parse_args()
    if a.quick:
        a.eval_seeds, a.eval_tests, a.train_seeds, a.train_tests = 6, 300, 4, 200

    for d in (BUILD, RES, f"{RES}/train", f"{RES}/eval"):
        os.makedirs(d, exist_ok=True)
    vvp = f"{BUILD}/sim.vvp"
    train_seeds = list(range(1001, 1001 + a.train_seeds))
    eval_seeds = list(range(1, 1 + a.eval_seeds))

    if "build" in a.steps:
        print("[build] iverilog -g2001 (pure Verilog-2001)")
        build(vvp)

    if "train" in a.steps:
        print(f"[train] {a.train_seeds} baseline + {a.train_seeds} explore runs x {a.train_tests} tests")
        jobs = []
        for s in train_seeds:
            jobs.append(dict(vvp=vvp, mode="BASELINE", seed=s, tests=a.train_tests,
                             tag=f"{RES}/train/baseline_s{s}"))
            jobs.append(dict(vvp=vvp, mode="EXPLORE", seed=s + 1000, tests=a.train_tests,
                             tag=f"{RES}/train/explore_s{s + 1000}"))
        errs = run_many(jobs)
        print(f"        scoreboard errors on the clean design: {errs}")
        if errs:
            raise SystemExit("clean RTL must produce 0 scoreboard errors")

    if "model" in a.steps:
        print("[model] training decision tree")
        sh([sys.executable, "scripts/train_coverage_model.py"])
        print(open(f"{RES}/model_report.txt").read())

    if "eval" in a.steps:
        print(f"[eval] {a.eval_seeds} held-out seeds x {a.eval_tests} tests, BASELINE vs GUIDED")
        jobs = []
        for s in eval_seeds:
            jobs.append(dict(vvp=vvp, mode="BASELINE", seed=s, tests=a.eval_tests,
                             tag=f"{RES}/eval/baseline_s{s}"))
            jobs.append(dict(vvp=vvp, mode="GUIDED", seed=s, tests=a.eval_tests,
                             tag=f"{RES}/eval/guided_s{s}", knobs=f"{RES}/knobs.txt"))
        errs = run_many(jobs)
        print(f"        scoreboard errors on the clean design: {errs}")
        if errs:
            raise SystemExit("clean RTL must produce 0 scoreboard errors")

    if "compare" in a.steps:
        print("[compare]")
        sh([sys.executable, "scripts/compare_coverage.py"])
        print(open(f"{RES}/summary.md").read())

    if "mutants" in a.steps:
        print("[mutants] injecting RTL bugs; the checker must flag every one")
        rows = []
        for b in MUTANTS:
            mv = f"{BUILD}/mut_{b}.vvp"
            build(mv, [f"BUG_{b}"])
            e = [sim(mv, "BASELINE", s, 50, f"{BUILD}/mut_tmp")[0] for s in (1, 2, 3)]
            rows.append((b, e))
            print(f"  BUG_{b:12s} scoreboard errors per seed (1,2,3): {e}  ->  "
                  f"{'CAUGHT' if all(x > 0 for x in e) else 'MISSED'}")
            os.remove(mv)
        for f in (f"{BUILD}/mut_tmp_tests.csv", f"{BUILD}/mut_tmp_bins.csv"):
            if os.path.exists(f):
                os.remove(f)
        with open(f"{RES}/mutation_report.md", "w") as f:
            f.write("| injected bug | errors (seeds 1/2/3, 50 tests each) | result |\n|---|---|---|\n")
            for b, e in rows:
                f.write(f"| BUG_{b} | {e} | {'caught' if all(x > 0 for x in e) else 'MISSED'} |\n")


if __name__ == "__main__":
    main()
