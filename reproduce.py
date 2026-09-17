#!/usr/bin/env python
import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = ROOT.parent
RESULTS_DIR = ROOT / "results"

R_METHODS = {"lasso", "armar-lasso", "armar", "all"}
PY_METHODS = {"tide", "transformer", "dlinear", "nhits", "random-forest", "rf", "naive", "all"}


def run(cmd, dry_run=False):
    print("+ " + " ".join(str(x) for x in cmd))
    if dry_run:
        return
    subprocess.run(cmd, check=True)


def run_table1_r(args, method):
    run([
        args.rscript,
        str(ROOT / "r" / "table1_lasso_metrics.R"),
        "--dataset", args.dataset,
        "--method", method,
        "--project-root", str(args.project_root),
        "--results-dir", str(args.results_dir),
        "--lags", str(args.lags),
    ], args.dry_run)


def run_table1_py(args, method):
    run([
        sys.executable,
        str(ROOT / "python" / "table1_ml_metrics.py"),
        "--dataset", args.dataset,
        "--method", method,
        "--project-root", str(args.project_root),
        "--results-dir", str(args.results_dir),
        "--lags", str(args.lags),
        "--epochs", str(args.epochs),
    ], args.dry_run)


def table1(args):
    method = args.method.lower()
    if method == "all":
        run_table1_r(args, "all")
        run_table1_py(args, "all")
    elif method in R_METHODS:
        run_table1_r(args, method)
    elif method in PY_METHODS:
        run_table1_py(args, method)
    else:
        raise SystemExit(f"Unknown method {args.method!r}")


def table_all(args):
    for dataset in args.datasets:
        one_args = argparse.Namespace(**vars(args))
        one_args.dataset = dataset
        one_args.method = "all"
        table1(one_args)


def rolling(args):
    run([
        args.rscript,
        str(ROOT / "r" / "rolling_metrics.R"),
        "--setting", args.setting,
        "--project-root", str(args.project_root),
        "--source-results-dir", str(args.source_results_dir),
        "--results-dir", str(args.results_dir),
        "--horizons", args.horizons,
    ], args.dry_run)


def main():
    parser = argparse.ArgumentParser(description="Reproduce Tonini forecasting tables.")
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--results-dir", type=Path, default=RESULTS_DIR)
    parser.add_argument("--source-results-dir", type=Path, default=PROJECT_ROOT / "results")
    parser.add_argument("--rscript", default="/srv/hpc/home/g.squillace/miniforge3/envs/tonini-forecast/bin/Rscript")
    parser.add_argument("--dry-run", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    t1 = sub.add_parser("table1", help="Run one Table 1 method on one dataset.")
    t1.add_argument("--dataset", required=True, choices=["exathlon1", "exathlon2", "exathlon3", "materna", "pod_metrics", "kubernetes"])
    t1.add_argument("--method", required=True, help="lasso, armar-lasso, tide, transformer, dlinear, nhits, random-forest, naive, or all")
    t1.add_argument("--lags", type=int, default=5)
    t1.add_argument("--epochs", type=int, default=100)
    t1.set_defaults(func=table1)

    tall = sub.add_parser("table1-all", help="Run all Table 1 methods on all selected datasets.")
    tall.add_argument("--datasets", nargs="+", default=["exathlon1", "exathlon2", "exathlon3", "materna", "pod_metrics"])
    tall.add_argument("--lags", type=int, default=5)
    tall.add_argument("--epochs", type=int, default=100)
    tall.set_defaults(func=table_all)

    roll = sub.add_parser("rolling-metrics", help="Compute Table 2 or Table 3 metrics from saved rolling forecasts.")
    roll.add_argument("--setting", required=True, choices=["table2", "table3"])
    roll.add_argument("--horizons", default="1,2,3,4")
    roll.set_defaults(func=rolling)

    args = parser.parse_args()
    args.results_dir.mkdir(parents=True, exist_ok=True)
    args.func(args)


if __name__ == "__main__":
    main()
