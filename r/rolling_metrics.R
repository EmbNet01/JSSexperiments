#!/usr/bin/env Rscript

parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  out <- list(setting = "rolling-predicted-regressors", method = "all", project_root = getwd(),
              source_results_dir = file.path(getwd(), "results"),
              results_dir = file.path(getwd(), "results"),
              horizons = "1,2,3,4")
  i <- 1
  while (i <= length(args)) {
    key <- gsub("-", "_", sub("^--", "", args[i]))
    out[[key]] <- args[i + 1]
    i <- i + 2
  }
  out$horizons <- as.integer(strsplit(out$horizons, ",")[[1]])
  out
}

args <- parse_args()
setwd(args$project_root)

w_size <- 200
first_drop <- 761
train <- read.csv("datasets/pod_metrics_train.csv", check.names = FALSE)
test <- read.csv("datasets/pod_metrics_test.csv", check.names = FALSE)
dati <- rbind(train, test)[, -1, drop = FALSE]
dati <- dati[-seq_len(first_drop), , drop = FALSE]

safe_num <- function(x) as.numeric(as.character(x))
get_errors <- function(forecasts, pattern) {
  cols <- grep(pattern, colnames(forecasts), value = TRUE)
  if (length(cols) == 0) stop("No columns found for pattern: ", pattern)
  out <- sapply(cols, function(col) safe_num(forecasts[, col]))
  colnames(out) <- cols
  out
}
mase_denominator <- function(n_windows, h = 1) {
  den <- matrix(NA_real_, nrow = n_windows, ncol = ncol(dati))
  for (i in seq_len(n_windows)) {
    end <- w_size + i - h
    x_in <- as.matrix(dati[i:end, , drop = FALSE])
    den[i, ] <- apply(x_in, 2, function(z) mean(abs(diff(z)), na.rm = TRUE))
  }
  den[den == 0] <- NA_real_
  den
}
metric_row <- function(setting, h, method, errors, mase_den, avg_selected = NA_real_) {
  rmse_by_variable <- sqrt(colMeans(errors^2, na.rm = TRUE))
  data.frame(
    Setting = setting,
    Horizon = paste0("h=", h),
    Method = method,
    RMSE = mean(rmse_by_variable, na.rm = TRUE),
    MAE = mean(abs(errors), na.rm = TRUE),
    MASE = mean(abs(errors) / mase_den, na.rm = TRUE),
    AVG_SELECTED_VARIABLES = avg_selected,
    stringsAsFactors = FALSE
  )
}

rows <- list()
setting <- tolower(args$setting)

for (h in args$horizons) {
  if (setting == "rolling-observed-regressors") {
    rds_path <- file.path(args$source_results_dir, paste0("rolling_observed_forecasts_h", h, ".rds"))
    if (!file.exists(rds_path)) stop("Forecast generation did not create ", rds_path)
    forecasts <- readRDS(rds_path)
    n_windows <- nrow(forecasts)
    mase_den <- mase_denominator(n_windows, h)
    specs <- list(
      list("ARMAr-LASSO", "^X[0-9]+ ARMAr_lasso er$", "ARMAr_lasso positives"),
      list("LASSO", "^X[0-9]+ lasso er$", "lasso positives"),
      list("ARMA", "^X[0-9]+ ARIMA er$", NA)
    )
  } else if (setting == "rolling-predicted-regressors") {
    rds_path <- file.path(args$source_results_dir, "rolling_predicted_forecasts.rds")
    if (!file.exists(rds_path)) stop("Forecast generation did not create ", rds_path)
    forecasts <- readRDS(rds_path)
    n_windows <- nrow(forecasts)
    mase_den <- mase_denominator(n_windows, 1)
    specs <- list(
      list("ARMAr-LASSO", paste0("^X[0-9]+ ARMAr_lasso h", h, " er$"), NA),
      list("LASSO", paste0("^X[0-9]+ lasso h", h, " er$"), NA)
    )
  } else {
    stop("Unsupported setting: ", args$setting)
  }

  requested_method <- tolower(args$method)
  if (requested_method != "all") {
    method_keys <- vapply(specs, function(spec) tolower(spec[[1]]), character(1))
    keep <- method_keys == requested_method
    if (!any(keep)) {
      stop("Method ", args$method, " is not available for setting ", args$setting)
    }
    specs <- specs[keep]
  }

  for (spec in specs) {
    avg_selected <- NA_real_
    if (!is.na(spec[[3]]) && spec[[3]] %in% colnames(forecasts)) {
      avg_selected <- mean(safe_num(forecasts[, spec[[3]]]), na.rm = TRUE)
    }
    rows[[length(rows) + 1]] <- metric_row(setting, h, spec[[1]], get_errors(forecasts, spec[[2]]), mase_den, avg_selected)
  }
}

out <- do.call(rbind, rows)
dir.create(args$results_dir, recursive = TRUE, showWarnings = FALSE)
method_slug <- if (tolower(args$method) == "all") "all_methods" else gsub("-", "_", tolower(args$method))
out_path <- file.path(args$results_dir, paste0(gsub("-", "_", setting), "_", method_slug, "_metrics.csv"))
write.csv(out, out_path, row.names = FALSE)
print(out, row.names = FALSE)
cat("Wrote", out_path, "\n")
