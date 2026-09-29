# Reproducibility

This folder reproduces the forecasting experiments through a single Python
interface:

```bash
python reproduce.py run --setting SETTING --method METHOD [options]
```


## Installation

Create a Python environment and install the dependencies:

```bash
cd JSSexperiments
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

Install the required R packages:

```r
install.packages(c("forecast", "foreach", "glmnet", "matrixStats", "remotes"),
                 repos = "https://cloud.r-project.org")
remotes::install_github("gabrielrvsc/HDeconometrics")
```

The `darts[torch]` requirement installs Darts with the backend required by
TiDE, Transformer, DLinear, and NHITS. These methods require a CUDA GPU to
reproduce the paper environment. LASSO, ARMAr-LASSO, ARMA, and Random Forest
do not require a GPU.

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

The command first runs the rolling-window estimation only for the requested
method and writes the generated forecasts to
`results/rolling_observed_armar_lasso_forecasts_h2.rds`. It then computes and
prints the requested method's metrics. No precomputed forecast file is
required.


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

The command first regenerates the requested method's recursive multi-step
forecasts in `results/rolling_predicted_lasso_forecasts.rds` and then computes
the requested horizon's metrics. No precomputed forecast file is required.


For both rolling settings, a single `run` command estimates only the selected
method and prints and saves exactly one result row at the selected horizon.
Rolling estimation is still more expensive than the fixed-split experiment:
the selected model is fitted again for every window and every target variable.
Every rolling command regenerates its forecasts from scratch before computing
the requested metrics.

## Metrics And Outputs

Every result reports:

```text
RMSE, MAE, MASE
```

The `rolling-observed-regressors` setting also reports
`AVG_SELECTED_VARIABLES`, computed as the average number of selected
cross-series regressors across rolling windows. This value is `NA` for ARMA,
which is univariate and performs no variable selection. Following the paper,
the `rolling-predicted-regressors` output does not include this column.


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
JSSexperiments/
  reproduce.py
  requirements.txt
  run_reproducibility.slurm
  python/
    dataset_config.py
    table1_ml_metrics.py
  r/
    table1_lasso_metrics.R
    rolling_forecasts.R
    rolling_metrics.R
  results/
    *.csv
```

All datasets must be available in `./datasets/`, next to `reproduce.py`.
Rolling forecast objects are generated by the pipeline itself and stored in
`./results/`; they are outputs, not required inputs.
