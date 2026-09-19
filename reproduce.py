#!/usr/bin/env python
import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
RESULTS_DIR = ROOT / "results"
CLUSTER_RSCRIPT = Path("/srv/hpc/home/g.squillace/miniforge3/envs/tonini-forecast/bin/Rscript")
DEFAULT_RSCRIPT = str(CLUSTER_RSCRIPT) if CLUSTER_RSCRIPT.exists() else "Rscript"
PROJECT_ROOT = ROOT

SETTINGS = (
    "fixed-split",
    "rolling-observed-regressors",
    "rolling-predicted-regressors",
)
FIXED_R_METHODS = {"lasso", "armar-lasso"}
FIXED_PY_METHODS = {
    "tide", "transformer", "dlinear", "nhits", "random-forest"
}
ROLLING_METHODS = {
    "rolling-observed-regressors": {"armar-lasso", "lasso", "arma"},
    "rolling-predicted-regressors": {"armar-lasso", "lasso"},
}
DATASETS = (
    "exathlon1", "exathlon2", "exathlon3", "materna", "pod_metrics", "kubernetes"
)


def execute(cmd, dry_run=False):
    print("+ " + " ".join(str(x) for x in cmd))
    if not dry_run:
        subprocess.run(cmd, check=True)


def run_fixed_r(args, method):
    execute([
        args.rscript,
        str(ROOT / "r" / "table1_lasso_metrics.R"),
        "--dataset", args.dataset,
        "--method", method,
        "--project-root", str(args.project_root),
        "--results-dir", str(args.results_dir),
        "--lags", str(args.lags),
    ], args.dry_run)


def run_fixed_python(args, method):
    execute([
        sys.executable,
        str(ROOT / "python" / "table1_ml_metrics.py"),
        "--dataset", args.dataset,
        "--method", method,
        "--project-root", str(args.project_root),
        "--results-dir", str(args.results_dir),
        "--lags", str(args.lags),
        "--epochs", str(args.epochs),
    ], args.dry_run)


def run_fixed(args, method):
    if not args.dataset:
        raise SystemExit("--dataset is required for the fixed-split setting.")
    if method in FIXED_R_METHODS:
        run_fixed_r(args, method)
    elif method in FIXED_PY_METHODS:
        run_fixed_python(args, method)
    else:
        valid = sorted(FIXED_R_METHODS | FIXED_PY_METHODS)
        raise SystemExit(
            f"Method {method!r} is not available for fixed-split. "
            f"Choose: {', '.join(valid)}"
        )


def run_rolling(args, method, horizons):
    valid = ROLLING_METHODS[args.setting]
    if method != "all" and method not in valid:
        raise SystemExit(
            f"Method {method!r} is not available for {args.setting}. "
            f"Choose: {', '.join(sorted(valid))}"
        )
    execute([
        args.rscript,
        str(ROOT / "r" / "rolling_metrics.R"),
        "--setting", args.setting,
        "--method", method,
        "--project-root", str(args.project_root),
        "--source-results-dir", str(args.source_results_dir),
        "--results-dir", str(args.results_dir),
        "--horizons", horizons,
    ], args.dry_run)


def run_one(args):
    method = args.method.lower()
    if args.setting == "fixed-split":
        run_fixed(args, method)
        return
    if args.horizon is None:
        raise SystemExit(f"--horizon is required for the {args.setting} setting.")
    run_rolling(args, method, str(args.horizon))


def run_all(args):
    if args.setting == "fixed-split":
        for dataset in args.datasets:
            one_args = argparse.Namespace(**vars(args))
            one_args.dataset = dataset
            run_fixed_r(one_args, "all")
            run_fixed_python(one_args, "all")
        return
    run_rolling(args, "all", args.horizons)


def add_shared_experiment_options(parser):
    parser.add_argument("--setting", required=True, choices=SETTINGS)
    parser.add_argument("--lags", type=int, default=5)
    parser.add_argument("--epochs", type=int, default=100)


def main():
    parser = argparse.ArgumentParser(description="Run Tonini forecasting experiments.")
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--results-dir", type=Path, default=RESULTS_DIR)
    parser.add_argument("--source-results-dir", type=Path, default=PROJECT_ROOT / "results")
    parser.add_argument(
        "--rscript",
        default=DEFAULT_RSCRIPT,
    )
    parser.add_argument("--dry-run", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    one = sub.add_parser("run", help="Run one method in one experimental setting.")
    add_shared_experiment_options(one)
    one.add_argument("--method", required=True)
    one.add_argument("--dataset", choices=DATASETS)
    one.add_argument("--horizon", type=int, choices=range(1, 5))
    one.set_defaults(func=run_one)

    all_parser = sub.add_parser(
        "run-all", help="Run every method for one experimental setting."
    )
    add_shared_experiment_options(all_parser)
    all_parser.add_argument(
        "--datasets",
        nargs="+",
        default=["exathlon1", "exathlon2", "exathlon3", "materna", "pod_metrics"],
        choices=DATASETS,
    )
    all_parser.add_argument("--horizons", default="1,2,3,4")
    all_parser.set_defaults(func=run_all)

    args = parser.parse_args()
    args.results_dir.mkdir(parents=True, exist_ok=True)
    args.func(args)


if __name__ == "__main__":
    main()
