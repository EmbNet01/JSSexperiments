#!/usr/bin/env Rscript

parse_args <- function() {
  cli <- commandArgs(trailingOnly = TRUE)
  out <- list(dataset = "exathlon1", method = "all", project_root = getwd(),
              results_dir = file.path(getwd(), "results"), lags = 5)
  i <- 1
  while (i <= length(cli)) {
    key <- gsub("-", "_", sub("^--", "", cli[i]))
    out[[key]] <- cli[i + 1]
    i <- i + 2
  }
  out
}

args <- parse_args()
setwd(args$project_root)

required_packages <- c("forecast", "glmnet", "HDeconometrics", "matrixStats")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_packages) > 0) stop("Missing R packages: ", paste(missing_packages, collapse = ", "))

library(forecast)
library(glmnet)
library(HDeconometrics)
library(matrixStats)

features_by_dataset <- list(
  exathlon1 = c("X1_jvm_pools_PS.Eden.Space_max_value", "X1_jvm_pools_PS.Survivor.Space_committed_value", "X2_jvm_heap_committed_value", "driver_BlockManager_memory_memUsed_MB_value", "driver_BlockManager_memory_remainingMem_MB_value", "node5_NET_ib0.write.KB.s", "node6_CPU031_User.", "node6_NETPACKET_em1.write.s", "node6_NET_ib0.write.KB.s", "node7_NET_ib0.read.KB.s"),
  exathlon2 = c("X1_jvm_pools_PS.Eden.Space_max_value", "X1_jvm_pools_PS.Survivor.Space_committed_value", "X2_jvm_heap_committed_value", "driver_BlockManager_memory_memUsed_MB_value", "driver_BlockManager_memory_remainingMem_MB_value", "driver_DAGScheduler_stage_waitingStages_value", "node5_NET_ib0.write.KB.s", "node6_CPU031_User.", "node6_NETPACKET_em1.write.s", "node6_NET_ib0.write.KB.s", "node7_NET_ib0.read.KB.s"),
  exathlon3 = c("X2_jvm_heap_committed_value", "X2_jvm_heap_usage_value", "X2_jvm_pools_PS.Eden.Space_committed_value", "X2_jvm_pools_PS.Old.Gen_usage_value", "driver_BlockManager_memory_memUsed_MB_value", "node5_CPU023_User.", "node5_NETPACKET_em1.read.s", "node5_NET_ib0.read.KB.s", "node5_NET_ib0.write.KB.s", "node6_NET_ib0.read.KB.s", "node7_NET_ib0.write.KB.s", "node8_CPU009_User.", "node8_CPU015_User.", "node8_NETPACKET_em1.write.s"),
  materna = c("CPU.usage..MHZ.", "Memory.usage..KB.", "Disk.write.throughput..KB.s.", "Network.received.throughput..KB.s.", "Network.transmitted.throughput..KB.s."),
  pod_metrics = c("adservice-cpu", "cartservice-cpu", "checkoutservice-cpu", "currencyservice-cpu", "emailservice-cpu", "frontend-cpu", "paymentservice-cpu", "productcatalogservice-cpu", "recommendationservice-cpu", "redis-cart-cpu", "shippingservice-cpu", "adservice-mem", "cartservice-mem", "checkoutservice-mem", "currencyservice-mem", "emailservice-mem", "frontend-mem", "paymentservice-mem", "productcatalogservice-mem", "recommendationservice-mem", "redis-cart-mem", "shippingservice-mem")
)

load_table1_dataset <- function(dataset) {
  dataset <- tolower(dataset)
  if (dataset == "kubernetes") dataset <- "pod_metrics"
  if (startsWith(dataset, "exathlon")) {
    data_number <- sub("exathlon", "", dataset)
    df <- read.csv(file.path("datasets", paste0("Exathlon_Data", data_number, ".csv")),
                   header = TRUE, check.names = FALSE)
    if (names(df)[1] == "" || names(df)[1] == "X") df <- df[, -1, drop = FALSE]
    features <- features_by_dataset[[dataset]]
    return(list(dataset = dataset, DF = df[, features, drop = FALSE], features = features, pod = FALSE))
  }
  if (dataset == "materna") {
    df <- read.csv("datasets/Materna.csv", header = TRUE, check.names = FALSE)
    if (names(df)[1] == "" || names(df)[1] == "X") df <- df[, -1, drop = FALSE]
    features <- features_by_dataset$materna
    return(list(dataset = dataset, DF = df[, features, drop = FALSE], features = features, pod = FALSE))
  }
  if (dataset == "pod_metrics") {
    train <- read.csv("datasets/pod_metrics_train.csv", header = TRUE, check.names = FALSE)[, -1, drop = FALSE]
    test <- read.csv("datasets/pod_metrics_test.csv", header = TRUE, check.names = FALSE)[, -1, drop = FALSE]
    features <- features_by_dataset$pod_metrics
    return(list(dataset = dataset, DF = rbind(train, test), DF_training = train,
                DF_test = test, features = features, pod = TRUE))
  }
  stop("Unsupported dataset: ", dataset)
}

selected_count <- function(fit) {
  sum(as.numeric(coef(fit))[-1] != 0, na.rm = TRUE)
}

metrics_from_predictions <- function(dataset, method, features, y_true, y_pred, train_for_mase, avg_selected) {
  err <- y_true - y_pred
  rmse <- sqrt(colMeans(err^2, na.rm = TRUE))
  mae <- colMeans(abs(err), na.rm = TRUE)
  scale <- colMeans(abs(diff(train_for_mase)), na.rm = TRUE)
  mase <- mae / scale
  mase[scale == 0] <- NA_real_
  out <- data.frame(Setting = "fixed-split", Dataset = dataset, Method = method,
                    Variable = features, RMSE = as.numeric(rmse),
                    MAE = as.numeric(mae), MASE = as.numeric(mase),
                    stringsAsFactors = FALSE)
  out[nrow(out) + 1, ] <- list("fixed-split", dataset, method, "MEAN",
                               mean(rmse, na.rm = TRUE), mean(mae, na.rm = TRUE),
                               mean(mase, na.rm = TRUE))
  out
}

fit_nonpod_legacy <- function(obj, use_armar) {
  DF <- obj$DF
  TrainPerc <- 0.7
  TestPerc <- 0.3
  pred <- matrix(NA_real_, nrow = nrow(DF) * TestPerc, ncol = ncol(DF))
  y_true <- pred
  train_for_mase <- NULL
  selected <- numeric(ncol(DF))

  if (use_armar) {
    u_list <- vector("list", ncol(DF))
    for (j in seq_len(ncol(DF))) {
      u_list[[j]] <- auto.arima(DF[, j], max.p = 5, max.d = 0, max.q = 5, ic = "bic")$residuals
    }
    u_hat <- matrix(unlist(u_list), ncol = ncol(DF), byrow = FALSE)
    colnames(u_hat) <- colnames(DF)
  }

  for (j in seq_len(ncol(DF))) {
    exog <- if (use_armar) u_hat[5:(nrow(DF) - 1), -j, drop = FALSE] else DF[5:(nrow(DF) - 1), -j, drop = FALSE]
    dati <- cbind(DF[6:nrow(DF), j], exog,
                  DF[5:(nrow(DF) - 1), j], DF[4:(nrow(DF) - 2), j],
                  DF[3:(nrow(DF) - 3), j], DF[2:(nrow(DF) - 4), j],
                  DF[1:(nrow(DF) - 5), j])
    colnames(dati)[c(1, (ncol(dati) - 4):ncol(dati))] <- c("y_t", "y_t1", "y_t2", "y_t3", "y_t4", "y_t5")
    dati_training <- dati[1:(round(nrow(dati) * TrainPerc) - 1), ]
    train_means <- colMeans(dati_training)
    train_sds <- apply(dati_training, 2, sd)
    dati_test <- cbind(scale(dati[-seq_len(nrow(dati_training)), ],
                             center = train_means, scale = train_sds))
    fit <- ic.glmnet(scale(as.matrix(dati_training[, -1])),
                     scale(as.matrix(dati_training[, 1])),
                     alpha = 1, crit = "bic")
    pred[, j] <- as.numeric(predict(fit, dati_test[, -1], s = fit$lambda, type = "response"))
    selected[j] <- selected_count(fit)
    y_true[, j] <- as.numeric(scale(tail(DF[, j], length(pred[, j])),
                                    center = mean(DF[seq_len(nrow(dati_training)), j]),
                                    scale = sd(DF[seq_len(nrow(dati_training)), j])))
    one_train <- as.numeric(scale(DF[seq_len(nrow(dati_training)), j],
                                  center = mean(DF[seq_len(nrow(dati_training)), j]),
                                  scale = sd(DF[seq_len(nrow(dati_training)), j])))
    train_for_mase <- cbind(train_for_mase, one_train)
  }
  colnames(pred) <- obj$features
  colnames(y_true) <- obj$features
  colnames(train_for_mase) <- obj$features
  list(pred = pred, y_true = y_true, train_for_mase = train_for_mase,
       avg_selected = mean(selected, na.rm = TRUE))
}

fit_pod_legacy <- function(obj, use_armar) {
  DF <- obj$DF
  DF_training <- obj$DF_training
  DF_test <- obj$DF_test
  pred <- matrix(NA_real_, nrow = nrow(DF_test) - 5, ncol = ncol(DF))
  selected <- numeric(ncol(DF))

  if (use_armar) {
    u_list <- vector("list", ncol(DF))
    for (j in seq_len(ncol(DF))) {
      u_list[[j]] <- auto.arima(DF[, j], max.p = 5, max.d = 0, max.q = 5, ic = "bic")$residuals
    }
    u_hat <- matrix(unlist(u_list), ncol = ncol(DF), byrow = FALSE)
    u_hat_in <- u_hat[seq_len(nrow(DF_training)), , drop = FALSE]
    u_hat_out <- (u_hat[-seq_len(nrow(DF_training)), , drop = FALSE] -
                    colMeans(u_hat[seq_len(nrow(DF_training)), , drop = FALSE])) /
      colSds(u_hat[seq_len(nrow(DF_training)), , drop = FALSE])
    u_hat <- rbind(scale(u_hat_in), u_hat_out)
    colnames(u_hat) <- colnames(DF)
  }

  for (j in seq_len(ncol(DF))) {
    exog <- if (use_armar) u_hat[5:(nrow(DF) - 1), -j, drop = FALSE] else DF[5:(nrow(DF) - 1), -j, drop = FALSE]
    dati <- cbind(DF[6:nrow(DF), j], exog,
                  DF[5:(nrow(DF) - 1), j], DF[4:(nrow(DF) - 2), j],
                  DF[3:(nrow(DF) - 3), j], DF[2:(nrow(DF) - 4), j],
                  DF[1:(nrow(DF) - 5), j])
    colnames(dati)[c(1, (ncol(DF) + 1):(ncol(DF) + 5))] <- c("y_t", "y_t1", "y_t2", "y_t3", "y_t4", "y_t5")
    dati_training <- dati[seq_len(nrow(DF_training)), ]
    dati_test <- dati[-seq_len(nrow(dati_training)), ]
    fit <- ic.glmnet(as.matrix(dati_training[, -1]), as.matrix(dati_training[, 1]),
                     alpha = 1, crit = "bic")
    pred[, j] <- as.numeric(predict(fit, dati_test[, -1], s = fit$lambda, type = "response"))
    selected[j] <- selected_count(fit)
  }
  y_true <- as.matrix(DF_test[-seq_len(5), , drop = FALSE])
  colnames(pred) <- obj$features
  colnames(y_true) <- obj$features
  list(pred = pred, y_true = y_true, train_for_mase = as.matrix(DF_training),
       avg_selected = mean(selected, na.rm = TRUE))
}

obj <- load_table1_dataset(args$dataset)
methods <- if (args$method == "all") c("lasso", "armar-lasso") else strsplit(args$method, ",")[[1]]
rows <- list()

if ("lasso" %in% methods) {
  fit <- if (obj$pod) fit_pod_legacy(obj, FALSE) else fit_nonpod_legacy(obj, FALSE)
  rows[[length(rows) + 1]] <- metrics_from_predictions(obj$dataset, "LASSO", obj$features,
                                                       fit$y_true, fit$pred, fit$train_for_mase,
                                                       fit$avg_selected)
}
if ("armar-lasso" %in% methods || "armar" %in% methods) {
  fit <- if (obj$pod) fit_pod_legacy(obj, TRUE) else fit_nonpod_legacy(obj, TRUE)
  rows[[length(rows) + 1]] <- metrics_from_predictions(obj$dataset, "ARMAr-LASSO", obj$features,
                                                       fit$y_true, fit$pred, fit$train_for_mase,
                                                       fit$avg_selected)
}
if (length(rows) == 0) stop("No LASSO-family method selected.")

out <- do.call(rbind, rows)
dir.create(args$results_dir, recursive = TRUE, showWarnings = FALSE)
method_slug <- if (args$method == "all") "lasso_family" else gsub("-", "_", args$method)
out_path <- file.path(args$results_dir, paste0("fixed_split_", obj$dataset, "_", method_slug, "_metrics.csv"))
write.csv(out, out_path, row.names = FALSE)
print(out[out$Variable == "MEAN", ], row.names = FALSE)
cat("Wrote", out_path, "\n")
