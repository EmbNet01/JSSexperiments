#!/usr/bin/env Rscript

library(forecast)
library(foreach)
library(HDeconometrics)
library(glmnet)

parse_args <- function() {
  cli <- commandArgs(trailingOnly = TRUE)
  out <- list(
    setting = "rolling-observed-regressors",
    method = "all",
    horizon = "1",
    project_root = getwd(),
    results_dir = file.path(getwd(), "results")
  )
  i <- 1
  while (i <= length(cli)) {
    key <- gsub("-", "_", sub("^--", "", cli[i]))
    out[[key]] <- cli[i + 1]
    i <- i + 2
  }
  out
}

args <- parse_args()
setting <- tolower(args$setting)
method <- tolower(args$method)
requested_horizon <- as.integer(args$horizon)

if (is.na(requested_horizon) || requested_horizon < 1 || requested_horizon > 4) {
  stop("--horizon must be an integer from 1 to 4")
}
if (!setting %in% c("rolling-observed-regressors", "rolling-predicted-regressors")) {
  stop("Unsupported setting: ", args$setting)
}

available_methods <- if (setting == "rolling-observed-regressors") {
  c("arma", "lasso", "armar-lasso")
} else {
  c("lasso", "armar-lasso")
}
if (method != "all" && !method %in% available_methods) {
  stop("Method ", args$method, " is not available for setting ", args$setting)
}
methods <- if (method == "all") available_methods else method

setwd(args$project_root)
h <- if (setting == "rolling-predicted-regressors") 1L else requested_horizon

train <- read.table(
  "datasets/pod_metrics_train.csv",
  sep = ",", header = TRUE, fill = TRUE
)
test <- read.table(
  "datasets/pod_metrics_test.csv",
  sep = ",", header = TRUE, fill = TRUE
)
train <- train[, -1, drop = FALSE]
test <- test[, -1, drop = FALSE]
dati <- rbind(train, test)
dati <- dati[-seq_len(761), , drop = FALSE]

lag_order <- 1
window_size <- 200
n_windows <- nrow(dati) - window_size
n_variables <- ncol(dati)

fit_coefficients <- function(X_in, X_in_scale, exogenous_scale) {
  coefficients <- matrix(NA_real_, n_variables, n_variables + 5)
  for (target in seq_len(n_variables)) {
    design <- cbind(
      exogenous_scale[5:(nrow(X_in) - 1), -target],
      X_in_scale[5:(nrow(X_in) - 1), target],
      X_in_scale[4:(nrow(X_in) - 2), target],
      X_in_scale[3:(nrow(X_in) - 3), target],
      X_in_scale[2:(nrow(X_in) - 4), target],
      X_in_scale[1:(nrow(X_in) - 5), target]
    )
    coefficients[target, ] <- coef(ic.glmnet(
      as.matrix(design),
      as.matrix(X_in[6:nrow(X_in), target]),
      alpha = 1,
      crit = "bic"
    ))
  }
  coefficients
}

direct_predictions <- function(coefficients, X_in_scale, exogenous_scale) {
  predictions <- numeric(n_variables)
  for (target in seq_len(n_variables)) {
    predictors <- c(
      exogenous_scale[nrow(X_in_scale), -target],
      X_in_scale[nrow(X_in_scale), target],
      X_in_scale[nrow(X_in_scale) - 1, target],
      X_in_scale[nrow(X_in_scale) - 2, target],
      X_in_scale[nrow(X_in_scale) - 3, target],
      X_in_scale[nrow(X_in_scale) - 4, target]
    )
    predictions[target] <- coefficients[target, 1] +
      coefficients[target, -1] %*% predictors
  }
  predictions
}

recursive_predictions <- function(coefficients, X_in) {
  predictions <- matrix(NA_real_, nrow = 4, ncol = n_variables)
  selected_by_target <- vector("list", n_variables)
  ols_by_target <- vector("list", n_variables)

  # Complete horizon 1 for every variable before recursively using predictions.
  for (target in seq_len(n_variables)) {
    selected <- which(coefficients[target, 2:n_variables] != 0)
    selected_by_target[[target]] <- selected
    selected_names <- colnames(X_in[, -target, drop = FALSE])[selected]
    regressors <- cbind(
      X_in[1:(nrow(X_in) - 1), selected_names, drop = FALSE],
      X_in[1:(nrow(X_in) - 1), target]
    )
    colnames(regressors)[ncol(regressors)] <- "y_1"
    ols_coefficients <- coef(lm(X_in[2:nrow(X_in), target] ~ regressors))
    ols_by_target[[target]] <- ols_coefficients

    first_inputs <- c(
      X_in[nrow(X_in), selected_names, drop = FALSE],
      X_in[nrow(X_in), target]
    )
    predictions[1, target] <- ols_coefficients[1] +
      ols_coefficients[-1] %*% first_inputs
  }

  for (step in 2:4) {
    for (target in seq_len(n_variables)) {
      selected <- selected_by_target[[target]]
      ols_coefficients <- ols_by_target[[target]]
      previous <- predictions[step - 1, ]
      recursive_inputs <- c(previous[selected], previous[target])
      predictions[step, target] <- ols_coefficients[1] +
        ols_coefficients[-1] %*% recursive_inputs
    }
  }
  predictions
}

named_errors <- function(errors, label) {
  setNames(
    as.numeric(errors),
    paste0("X", seq_len(n_variables), " ", label)
  )
}

cat(
  "Generating", setting, "forecasts for", method,
  "at requested horizon", requested_horizon, "\n"
)

set.seed(86)
forecasts <- foreach(window = seq_len(n_windows), .combine = rbind) %do% {
  X <- dati[window:(window_size + window), , drop = FALSE]
  future_values <- list(
    as.numeric(X[nrow(X), ]),
    as.numeric(dati[window_size + window + 1, ]),
    as.numeric(dati[window_size + window + 2, ]),
    as.numeric(dati[window_size + window + 3, ])
  )

  X1 <- embed(as.matrix(X), lag_order)
  X_in <- X1[1:(nrow(X1) - h), , drop = FALSE]
  colnames(X_in) <- colnames(dati)
  X_out <- X1[nrow(X1), ]
  X_in_scale <- scale(X_in)
  result <- numeric()

  if ("arma" %in% methods) {
    arma_predictions <- numeric(n_variables)
    for (target in seq_len(n_variables)) {
      arma_predictions[target] <- predict(
        auto.arima(
          X_in[, target],
          max.p = 5, max.d = 0, max.q = 5, ic = "bic"
        ),
        h
      )$pred[h]
    }
    result <- c(result, named_errors(X_out - arma_predictions, "ARIMA er"))
  }

  if ("lasso" %in% methods) {
    lasso <- fit_coefficients(X_in, X_in_scale, X_in_scale)
    lasso_direct <- direct_predictions(lasso, X_in_scale, X_in_scale)
    result <- c(result, named_errors(X_out - lasso_direct, "lasso er"))

    if (setting == "rolling-predicted-regressors") {
      lasso_recursive <- recursive_predictions(lasso, X_in)
      for (step in 1:4) {
        errors <- future_values[[step]] - lasso_recursive[step, ]
        result <- c(result, named_errors(errors, paste0("lasso h", step, " er")))
      }
    }
    result <- c(
      result,
      "lasso positives" = sum(lasso[, 2:n_variables] != 0)
    )
  }

  if ("armar-lasso" %in% methods) {
    residuals <- vector("list", n_variables)
    for (target in seq_len(n_variables)) {
      residuals[[target]] <- auto.arima(
        X1[, target],
        max.p = 5, max.d = 0, max.q = 5, ic = "bic"
      )$residuals
    }
    residuals <- matrix(
      unlist(residuals),
      ncol = n_variables,
      byrow = FALSE
    )
    residuals <- as.matrix(embed(residuals, lag_order))
    residuals_in <- residuals[1:(nrow(residuals) - h), , drop = FALSE]
    colnames(residuals_in) <- colnames(dati)
    residuals_scale <- scale(residuals_in)

    armar_lasso <- fit_coefficients(X_in, X_in_scale, residuals_scale)
    armar_direct <- direct_predictions(
      armar_lasso,
      X_in_scale,
      residuals_scale
    )
    result <- c(
      result,
      named_errors(X_out - armar_direct, "ARMAr_lasso er")
    )

    if (setting == "rolling-predicted-regressors") {
      armar_recursive <- recursive_predictions(armar_lasso, X_in)
      for (step in 1:4) {
        errors <- future_values[[step]] - armar_recursive[step, ]
        result <- c(
          result,
          named_errors(errors, paste0("ARMAr_lasso h", step, " er"))
        )
      }
    }
    result <- c(
      result,
      "ARMAr_lasso positives" = sum(armar_lasso[, 2:n_variables] != 0)
    )
  }

  result
}

dir.create(args$results_dir, recursive = TRUE, showWarnings = FALSE)
method_slug <- gsub("-", "_", method)
if (setting == "rolling-observed-regressors") {
  filename <- paste0(
    "rolling_observed_", method_slug,
    "_forecasts_h", requested_horizon, ".rds"
  )
} else {
  filename <- paste0("rolling_predicted_", method_slug, "_forecasts.rds")
}
forecasts_path <- file.path(args$results_dir, filename)
saveRDS(forecasts, forecasts_path)
cat("Wrote", forecasts_path, "\n")
