# Reproducibility

This folder contains the scripts needed to reproduce the forecasting experiments
reported in Tables 1, 2, and 3.

The main entry point is:

```bash
python reproduce.py ...
```

Python is the user-facing interface. R is used internally for ARMAr-LASSO,
LASSO, ARMA, and the rolling-window metric post-processing.

## Folder Layout

```text
reproducibility/
  reproduce.py                 # main command-line interface
  requirements.txt             # minimal Python requirements
  run_reproducibility.slurm     # SLURM wrapper for HPC execution
  python/
    dataset_config.py           # dataset paths and selected variables
    table1_ml_metrics.py        # Darts and Random Forest backend
  r/
    table1_lasso_metrics.R      # LASSO and ARMAr-LASSO backend
    rolling_metrics.R           # Table 2 and Table 3 metric computation
  results/
    *.csv                       # generated outputs
```

The scripts assume that the original datasets are available in:

```text
../datasets/
```

and that the rolling-window forecast objects used for Tables 2 and 3 are
available in:

```text
../results/
```

## Installation

### Python

Create and activate a Python environment, then install the minimal requirements:

```bash
cd reproducibility
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

The deep-learning methods use Darts/PyTorch. To reproduce the paper setting,
these methods are expected to run with a CUDA GPU. LASSO, ARMAr-LASSO, ARMA, and
Random Forest do not require a GPU.

### R

Install the required R packages:

```r
install.packages(c("forecast", "glmnet", "matrixStats", "remotes"),
                 repos = "https://cloud.r-project.org")
remotes::install_github("gabrielrvsc/HDeconometrics")
```

If `Rscript` is not available as `Rscript` on your machine, pass its path with
`--rscript`, for example:

```bash
python reproduce.py --rscript /path/to/Rscript table1 --dataset exathlon1 --method lasso
```

## Metrics

Each output reports:

```text
RMSE, MAE, MASE
```

For all tables, `RMSE` is computed variable by variable and then averaged across
variables. This is the convention used in the paper tables.

For LASSO-family methods, the output also reports:

```text
AVG_SELECTED_VARIABLES
```

This is the average number of selected regressors. It is reported for Table 1
and Table 2. It is `NA` for ARMA because ARMA is univariate and does not perform
variable selection.

## Available Datasets

```text
exathlon1
exathlon2
exathlon3
materna
pod_metrics
kubernetes
```

`kubernetes` is an alias for `pod_metrics`.

## Available Methods

For Table 1:

```text
lasso
armar-lasso
tide
transformer
dlinear
nhits
random-forest
naive
all
```

`lasso` and `armar-lasso` use the legacy R code path from the original
experiments. The Darts and Random Forest methods use the Python backend.

## Run Locally

All commands below can be run directly on a local machine without SLURM.

### Single Dataset And Method

Run ARMAr-LASSO on Exathlon Data 1:

```bash
cd reproducibility
python reproduce.py table1 --dataset exathlon1 --method armar-lasso
```

Run LASSO on Kubernetes:

```bash
cd reproducibility
python reproduce.py table1 --dataset pod_metrics --method lasso
```

Run DLinear on Materna:

```bash
cd reproducibility
python reproduce.py table1 --dataset materna --method dlinear
```

Run all Table 1 methods on one dataset:

```bash
cd reproducibility
python reproduce.py table1 --dataset exathlon1 --method all
```

Outputs:

```text
results/table1_<dataset>_lasso_metrics.csv
results/table1_<dataset>_ml_metrics.csv
```

Each file contains one row per variable plus a final `MEAN` row. The `MEAN` row
is the row used in the paper tables.

### Full Table 1

Run all Table 1 methods on all datasets:

```bash
cd reproducibility
python reproduce.py table1-all
```

This generates:

```text
results/table1_exathlon1_lasso_metrics.csv
results/table1_exathlon1_ml_metrics.csv
results/table1_exathlon2_lasso_metrics.csv
results/table1_exathlon2_ml_metrics.csv
results/table1_exathlon3_lasso_metrics.csv
results/table1_exathlon3_ml_metrics.csv
results/table1_materna_lasso_metrics.csv
results/table1_materna_ml_metrics.csv
results/table1_pod_metrics_lasso_metrics.csv
results/table1_pod_metrics_ml_metrics.csv
```

### Table 2

Table 2 is the rolling-window direct forecasting setting on Kubernetes with
window size 200 and horizons `h = 1, 2, 3, 4`.

It expects these forecast files to already exist in `../results/`:

```text
rolling_pod_original_style_forecasts_h1.rds
rolling_pod_original_style_forecasts_h2.rds
rolling_pod_original_style_forecasts_h3.rds
rolling_pod_original_style_forecasts_h4.rds
```

Compute Table 2 metrics:

```bash
cd reproducibility
python reproduce.py rolling-metrics --setting table2
```

Output:

```text
results/table2_rolling_metrics.csv
```

### Table 3

Table 3 is the rolling-window setting with predicted regressors on Kubernetes.

It expects this forecast file to already exist in `../results/`:

```text
rollingLASSO_forecasts.rds
```

Compute Table 3 metrics:

```bash
cd reproducibility
python reproduce.py rolling-metrics --setting table3
```

Output:

```text
results/table3_rolling_metrics.csv
```

### Only Some Horizons

For Tables 2 and 3, a subset of horizons can be selected:

```bash
cd reproducibility
python reproduce.py rolling-metrics --setting table2 --horizons 1,2
python reproduce.py rolling-metrics --setting table3 --horizons 2,3,4
```

## Run On SLURM

The provided SLURM wrapper runs the same Python interface on the cluster.

Submit one method/dataset:

```bash
cd /srv/hpc/home/g.squillace/Tonini/reproducibility
sbatch --export=ALL,CMD="table1 --dataset exathlon1 --method armar-lasso" run_reproducibility.slurm
```

Submit all Table 1 experiments:

```bash
cd /srv/hpc/home/g.squillace/Tonini/reproducibility
sbatch --export=ALL,CMD="table1-all" run_reproducibility.slurm
```

Submit Table 2 metric computation:

```bash
cd /srv/hpc/home/g.squillace/Tonini/reproducibility
sbatch --export=ALL,CMD="rolling-metrics --setting table2" run_reproducibility.slurm
```

Submit Table 3 metric computation:

```bash
cd /srv/hpc/home/g.squillace/Tonini/reproducibility
sbatch --export=ALL,CMD="rolling-metrics --setting table3" run_reproducibility.slurm
```

SLURM logs are written to:

```text
slurm_repro_<jobid>.out
slurm_repro_<jobid>.err
```

## Cluster Environment Used In The Experiments

On the original HPC system, the working environment is:

```bash
/srv/hpc/home/g.squillace/miniforge3/envs/tonini-forecast/bin/python
/srv/hpc/home/g.squillace/miniforge3/envs/tonini-forecast/bin/Rscript
```

The SLURM wrapper uses the GPU partition and requests one GPU:

```text
#SBATCH -p gpu_l40s
#SBATCH --gres=gpu:1
```

## Dry Run

To print the backend command without executing it:

```bash
cd reproducibility
python reproduce.py --dry-run table1 --dataset exathlon1 --method armar-lasso
python reproduce.py --dry-run rolling-metrics --setting table2
```