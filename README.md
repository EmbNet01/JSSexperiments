# Reproducibility

This folder reproduces the forecasting experiments through a single Python
interface:

```bash
python reproduce.py run --setting SETTING --method METHOD [options]
```


## Installation

Create a Python environment and install the dependencies:

```bash
cd reproducibility
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

Install the required R packages:

```r
install.packages(c("forecast", "glmnet", "matrixStats", "remotes"),
                 repos = "https://cloud.r-project.org")
remotes::install_github("gabrielrvsc/HDeconometrics")
```

The deep-learning methods use Darts/PyTorch and require a CUDA GPU to reproduce
the paper environment. LASSO, ARMAr-LASSO, ARMA, and Random Forest do not
require a GPU.

If `Rscript` is not on `PATH`, provide it before the `run` command:

```bash
python reproduce.py --rscript /path/to/Rscript run \
  --setting fixed-split --dataset exathlon1 --method lasso
```

## Experimental Settings

### `fixed-split`

The model is fitted on a fixed training set and evaluated on a separate test
set. This is the experiment reported in Table 1 of the paper.

Required options:

```text
--dataset DATASET
--method METHOD
```

Available datasets:

```text
exathlon1
exathlon2
exathlon3
materna
pod_metrics
kubernetes
```


Available methods:

```text
armar-lasso
lasso
tide
transformer
dlinear
nhits
random-forest
naive
```

Example:

```bash
python reproduce.py run \
  --setting fixed-split \
  --dataset exathlon1 \
  --method armar-lasso
```

The terminal prints only the requested method's `MEAN` row. The CSV also
contains the metrics for each variable.

### `rolling-observed-regressors`

A window of 200 observations moves through the Kubernetes data. At each shift,
the predictors available from the observed series are used. This is the
experiment reported in Table 2 of the paper.

Available methods:

```text
armar-lasso
lasso
arma
```

One horizon from 1 to 4 must be specified:

```bash
python reproduce.py run \
  --setting rolling-observed-regressors \
  --method armar-lasso \
  --horizon 2
```


### `rolling-predicted-regressors`

The rolling multi-step forecast reuses predicted regressors, allowing forecast
errors to propagate across the horizon. This is the experiment reported in
Table 3 of the paper.

Available methods:

```text
armar-lasso
lasso
```

Example:

```bash
python reproduce.py run \
  --setting rolling-predicted-regressors \
  --method lasso \
  --horizon 3
```


For both rolling settings, a single `run` command prints and saves exactly one
row: the selected method at the selected horizon.

## Metrics And Outputs

Every result reports:

```text
RMSE, MAE, MASE
```


## Run Complete Experiments

Run all fixed-split methods on all datasets:

```bash
python reproduce.py run-all --setting fixed-split
```

Limit the datasets when needed:

```bash
python reproduce.py run-all --setting fixed-split \
  --datasets exathlon1 materna pod_metrics
```

Compute all methods and horizons for the rolling setting with observed
regressors:

```bash
python reproduce.py run-all --setting rolling-observed-regressors
```

Compute all methods and horizons for the rolling setting with predicted
regressors:

```bash
python reproduce.py run-all --setting rolling-predicted-regressors
```

A subset of rolling horizons can be selected with, for example,
`--horizons 2,3,4`.


## Dry Run

Use `--dry-run` before `run` or `run-all` to inspect the backend command
without executing an experiment:

```bash
python reproduce.py --dry-run run \
  --setting rolling-predicted-regressors \
  --method armar-lasso \
  --horizon 4
```

## Folder Layout

```text
reproducibility/
  reproduce.py
  requirements.txt
  run_reproducibility.slurm
  python/
    dataset_config.py
    table1_ml_metrics.py
  r/
    table1_lasso_metrics.R
    rolling_metrics.R
  results/
    *.csv
```

The original datasets must be available in `../datasets/`. Saved rolling
forecast objects must be available in `../results/`.
