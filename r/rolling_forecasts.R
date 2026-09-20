#!/usr/bin/env Rscript

library(forecast)
library(foreach)
library(HDeconometrics)
library(glmnet)

confusionMatrix <- function(data, reference, positive = "1") {
  list(table = table(
    factor(data, levels = c("0", "1")),
    factor(reference, levels = c("0", "1"))
  ))
}

parse_args <- function() {
  cli <- commandArgs(trailingOnly = TRUE)
  out <- list(setting = "rolling-observed-regressors", horizon = "1",
              project_root = getwd(), results_dir = file.path(getwd(), "results"))
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
requested_horizon <- as.integer(args$horizon)
if (is.na(requested_horizon) || requested_horizon < 1 || requested_horizon > 4) {
  stop("--horizon must be an integer from 1 to 4")
}
if (!setting %in% c("rolling-observed-regressors", "rolling-predicted-regressors")) {
  stop("Unsupported setting: ", args$setting)
}

setwd(args$project_root)
h <- if (setting == "rolling-predicted-regressors") 1L else requested_horizon
cat("Generating", setting, "forecasts for requested horizon", requested_horizon, "\n")

Kubernetes_train<- read.table("datasets/pod_metrics_train.csv", sep=",", header=TRUE, fill=TRUE)

Kubernetes_test<- read.table("datasets/pod_metrics_test.csv", sep=",", header=TRUE, fill=TRUE)

means<- data.frame(value = colMeans(Kubernetes_train[, -1]))
means<-as.vector(means[,1])

standevs<- data.frame(value = apply(Kubernetes_train[, -1], 2, sd))
standevs<-as.vector(standevs[,1])


Kubernetes_train <- Kubernetes_train[,-1]
Kubernetes_test <- Kubernetes_test[,-1]


Kubernetes <- rbind(Kubernetes_train,Kubernetes_test)


dati = Kubernetes[-c(1:761),]

l=1

w_size = 200 #nrow(Kubernetes_train) 
n_windows = nrow(dati) - w_size

set.seed(86)
forecasts = foreach(i=1:n_windows, .combine = rbind) %do%{
  # = Select data for the window (in and out-of-sample) = #
  
  X = dati[i:(w_size + i), ]     # = change to X[1:(w_size + i - 1), ] for expanding window
  
  X_h2 = dati[(w_size + i + 1), ]
  X_h3 = dati[(w_size + i + 2), ]
  X_h4 = dati[(w_size + i + 3), ]
  
  X1 = embed(as.matrix(X), l) #X[-c(1:3),1], 
  X_in = X1[1:(nrow(X1)-h),]
  colnames(X_in)<-colnames(dati)
  X_out = X1[nrow(X1),]#(X1[nrow(X1),] - colMeans(X_in)) / colSds(X_in)
  
  X_in_scale = scale(X_in)
  
  
  ### ARIMA
  
  ARIMA_pred=NULL
  for (i in 1:ncol(X_in)){ 
    ARIMA_pred[[i]] = predict(auto.arima(X_in[,i], max.p=5, max.d=0, max.q=5, ic="bic"),
                              h)$pred[h]
  }
  
  
  ### LASSO
  
  lasso <- matrix(, ncol(X_in), (ncol(X_in)*1+5))
  for (i in 1:ncol(X_in)) {
    lasso[i,] <- coef(ic.glmnet(as.matrix(cbind(X_in_scale[5:(nrow(X_in)-1),-i],
                                                X_in_scale[5:(nrow(X_in)-1),i],
                                                X_in_scale[4:(nrow(X_in)-2),i],
                                                X_in_scale[3:(nrow(X_in)-3),i],
                                                X_in_scale[2:(nrow(X_in)-4),i],
                                                X_in_scale[1:(nrow(X_in)-5),i])), 
                                as.matrix(X_in[6:nrow(X_in),i]), alpha=1, crit="bic"))
  }
  
  
  lasso_pred <- NULL
  for (i in 1:ncol(X_in)) {
    lasso_pred[i] <- lasso[i,][1] + lasso[i,][-1]%*%c(X_in_scale[(nrow(X_in)),-i],
                                                      X_in_scale[(nrow(X_in)),i],
                                                      X_in_scale[(nrow(X_in)-1),i],
                                                      X_in_scale[(nrow(X_in)-2),i],
                                                      X_in_scale[(nrow(X_in)-3),i],
                                                      X_in_scale[(nrow(X_in)-4),i])
  }
  
  
  
  
  lasso_pred_h1 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    Xx_out <- c(X_in[(nrow(X_in)),colnames(X_in[,-i])[which(lasso[i,2:22]!=0)]],
                X_in[(nrow(X_in)),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    lasso_pred_h1[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out)  
    
    
    
    
  }
  
  
  lasso_pred_h2 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    Xx_out_h2 <- c(lasso_pred_h1[which(lasso[i,2:22]!=0)], lasso_pred_h1[i])
    
    lasso_pred_h2[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out_h2)  
    
  }
  
  
  lasso_pred_h3 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    Xx_out_h3 <- c(lasso_pred_h2[which(lasso[i,2:22]!=0)], lasso_pred_h2[i])
    
    lasso_pred_h3[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out_h3)  
    
  }
  
  
  lasso_pred_h4 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    Xx_out_h4 <- c(lasso_pred_h3[which(lasso[i,2:22]!=0)], lasso_pred_h3[i])
    
    lasso_pred_h4[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out_h4)  
    
  }
  
  
  
  
  
  ### ARMAr-LASSO
  
  u.hat=NULL
  for (i in 1:ncol(X1)){ 
    u.hat[[i]] = auto.arima(X1[,i], max.p=5, max.d=0, max.q=5, ic="bic")$residuals
  }
  
  u.hat <- matrix(unlist(u.hat), ncol = ncol(X1), byrow = FALSE)
  u.hat <- cbind(embed(as.matrix(u.hat),l))
  u.hat<-as.matrix(u.hat) # dim=dati-lag di ar
  
  u.hat_in = u.hat[1:(nrow(u.hat)-h),]

  colnames(u.hat_in)<-colnames(dati)
  
  u.hat_in_scale = scale(u.hat_in)
  
  ARMAr_lasso <- matrix(, ncol(u.hat_in), (ncol(u.hat_in)*1+5))
  for (i in 1:ncol(u.hat_in)) {
    ARMAr_lasso[i,] <- coef(ic.glmnet(as.matrix(cbind(u.hat_in_scale[5:(nrow(X_in)-1),-i],
                                                      X_in_scale[5:(nrow(X_in)-1),i],
                                                      X_in_scale[4:(nrow(X_in)-2),i],
                                                      X_in_scale[3:(nrow(X_in)-3),i],
                                                      X_in_scale[2:(nrow(X_in)-4),i],
                                                      X_in_scale[1:(nrow(X_in)-5),i])), 
                                      as.matrix(X_in[6:nrow(X_in),i]), alpha=1, crit="bic"))
  }
  
  
  ARMAr_lasso_pred <- NULL
  for (i in 1:ncol(X_in)) {
    ARMAr_lasso_pred[i] <- ARMAr_lasso[i,][1] + ARMAr_lasso[i,][-1]%*%c(u.hat_in_scale[(nrow(X_in)),-i],
                                                                        X_in_scale[(nrow(X_in)),i],
                                                                        X_in_scale[(nrow(X_in)-1),i],
                                                                        X_in_scale[(nrow(X_in)-2),i],
                                                                        X_in_scale[(nrow(X_in)-3),i],
                                                                        X_in_scale[(nrow(X_in)-4),i])
  }
  
  
  
  
  ARMAr_lasso_pred_h1 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(ARMAr_lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    Xx_out <- c(X_in[(nrow(X_in)),colnames(X_in[,-i])[which(ARMAr_lasso[i,2:22]!=0)]],
                X_in[(nrow(X_in)),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    ARMAr_lasso_pred_h1[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out)  
    
    
    
    
  }
  
  
  ARMAr_lasso_pred_h2 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(ARMAr_lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    Xx_out_h2 <- c(ARMAr_lasso_pred_h1[which(ARMAr_lasso[i,2:22]!=0)], ARMAr_lasso_pred_h1[i])
    
    ARMAr_lasso_pred_h2[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out_h2)  
    
  }
  
  
  ARMAr_lasso_pred_h3 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(ARMAr_lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    Xx_out_h3 <- c(ARMAr_lasso_pred_h2[which(ARMAr_lasso[i,2:22]!=0)], ARMAr_lasso_pred_h2[i])
    
    ARMAr_lasso_pred_h3[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out_h3)  
    
  }
  
  
  ARMAr_lasso_pred_h4 <- NULL
  for (i in 1:ncol(X_in)) {
    
    y <- X_in[2:nrow(X_in),i]
    Xx <- cbind(X_in[1:(nrow(X_in)-1),colnames(X_in[,-i])[which(ARMAr_lasso[i,2:22]!=0)]],
                X_in[1:(nrow(X_in)-1),i])
    
    colnames(Xx)[ncol(Xx)] <- "y_1"
    OLS_X <- coef(lm(X_in[2:nrow(X_in),i] ~ Xx))
    
    Xx_out_h4 <- c(ARMAr_lasso_pred_h3[which(ARMAr_lasso[i,2:22]!=0)], ARMAr_lasso_pred_h3[i])
    
    ARMAr_lasso_pred_h4[i] <- OLS_X[1] + OLS_X[-1]%*%c(Xx_out_h4)  
    
  }
  

  
  ARIMA_er = X_out - unlist(ARIMA_pred)
  lasso_er = X_out - lasso_pred
  ARMAr_lasso_er = X_out - ARMAr_lasso_pred
  
  lasso_h1_er = X_out - unlist(lasso_pred_h1)
  lasso_h2_er = as.vector(unlist(X_h2)) - unlist(lasso_pred_h2)
  lasso_h3_er = as.vector(unlist(X_h3)) - unlist(lasso_pred_h3)
  lasso_h4_er = as.vector(unlist(X_h4)) - unlist(lasso_pred_h4)
  
  ARMAr_lasso_h1_er = X_out - unlist(ARMAr_lasso_pred_h1)
  ARMAr_lasso_h2_er = as.vector(unlist(X_h2)) - unlist(ARMAr_lasso_pred_h2)
  ARMAr_lasso_h3_er = as.vector(unlist(X_h3)) - unlist(ARMAr_lasso_pred_h3)
  ARMAr_lasso_h4_er = as.vector(unlist(X_h4)) - unlist(ARMAr_lasso_pred_h4)
  
  
  
  if (sum(as.numeric(lasso[,2:22]!=0))==0 || sum(as.numeric(ARMAr_lasso[,2:22]!=0))==0) {
    ConfMat <- matrix(c(0,0,0,0),2,2)
  } else {
    ConfMat <- confusionMatrix(as.factor(as.numeric(lasso[,2:22]!=0)),
                               as.factor(as.numeric(ARMAr_lasso[,2:22]!=0)), positive="1")$table
  }
  
  
  return(c("X1 ARIMA er"=unname(ARIMA_er[1]),
           "X2 ARIMA er"=unname(ARIMA_er[2]),
           "X3 ARIMA er"=unname(ARIMA_er[3]),
           "X4 ARIMA er"=unname(ARIMA_er[4]),
           "X5 ARIMA er"=unname(ARIMA_er[5]),
           "X6 ARIMA er"=unname(ARIMA_er[6]),
           "X7 ARIMA er"=unname(ARIMA_er[7]),
           "X8 ARIMA er"=unname(ARIMA_er[8]),
           "X9 ARIMA er"=unname(ARIMA_er[9]),
           "X10 ARIMA er"=unname(ARIMA_er[10]),
           "X11 ARIMA er"=unname(ARIMA_er[11]),
           "X12 ARIMA er"=unname(ARIMA_er[12]),
           "X13 ARIMA er"=unname(ARIMA_er[13]),
           "X14 ARIMA er"=unname(ARIMA_er[14]),
           "X15 ARIMA er"=unname(ARIMA_er[15]),
           "X16 ARIMA er"=unname(ARIMA_er[16]),
           "X17 ARIMA er"=unname(ARIMA_er[17]),
           "X18 ARIMA er"=unname(ARIMA_er[18]),
           "X19 ARIMA er"=unname(ARIMA_er[19]),
           "X20 ARIMA er"=unname(ARIMA_er[20]),
           "X21 ARIMA er"=unname(ARIMA_er[21]),
           "X22 ARIMA er"=unname(ARIMA_er[22]),
           
           
           "X1 lasso er"=unname(lasso_er[1]),
           "X2 lasso er"=unname(lasso_er[2]),
           "X3 lasso er"=unname(lasso_er[3]),
           "X4 lasso er"=unname(lasso_er[4]),
           "X5 lasso er"=unname(lasso_er[5]),
           "X6 lasso er"=unname(lasso_er[6]),
           "X7 lasso er"=unname(lasso_er[7]),
           "X8 lasso er"=unname(lasso_er[8]),
           "X9 lasso er"=unname(lasso_er[9]),
           "X10 lasso er"=unname(lasso_er[10]),
           "X11 lasso er"=unname(lasso_er[11]),
           "X12 lasso er"=unname(lasso_er[12]),
           "X13 lasso er"=unname(lasso_er[13]),
           "X14 lasso er"=unname(lasso_er[14]),
           "X15 lasso er"=unname(lasso_er[15]),
           "X16 lasso er"=unname(lasso_er[16]),
           "X17 lasso er"=unname(lasso_er[17]),
           "X18 lasso er"=unname(lasso_er[18]),
           "X19 lasso er"=unname(lasso_er[19]),
           "X20 lasso er"=unname(lasso_er[20]),
           "X21 lasso er"=unname(lasso_er[21]),
           "X22 lasso er"=unname(lasso_er[22]),
           
           "X1 ARMAr_lasso er"=unname(ARMAr_lasso_er[1]),
           "X2 ARMAr_lasso er"=unname(ARMAr_lasso_er[2]),
           "X3 ARMAr_lasso er"=unname(ARMAr_lasso_er[3]),
           "X4 ARMAr_lasso er"=unname(ARMAr_lasso_er[4]),
           "X5 ARMAr_lasso er"=unname(ARMAr_lasso_er[5]),
           "X6 ARMAr_lasso er"=unname(ARMAr_lasso_er[6]),
           "X7 ARMAr_lasso er"=unname(ARMAr_lasso_er[7]),
           "X8 ARMAr_lasso er"=unname(ARMAr_lasso_er[8]),
           "X9 ARMAr_lasso er"=unname(ARMAr_lasso_er[9]),
           "X10 ARMAr_lasso er"=unname(ARMAr_lasso_er[10]),
           "X11 ARMAr_lasso er"=unname(ARMAr_lasso_er[11]),
           "X12 ARMAr_lasso er"=unname(ARMAr_lasso_er[12]),
           "X13 ARMAr_lasso er"=unname(ARMAr_lasso_er[13]),
           "X14 ARMAr_lasso er"=unname(ARMAr_lasso_er[14]),
           "X15 ARMAr_lasso er"=unname(ARMAr_lasso_er[15]),
           "X16 ARMAr_lasso er"=unname(ARMAr_lasso_er[16]),
           "X17 ARMAr_lasso er"=unname(ARMAr_lasso_er[17]),
           "X18 ARMAr_lasso er"=unname(ARMAr_lasso_er[18]),
           "X19 ARMAr_lasso er"=unname(ARMAr_lasso_er[19]),
           "X20 ARMAr_lasso er"=unname(ARMAr_lasso_er[20]),
           "X21 ARMAr_lasso er"=unname(ARMAr_lasso_er[21]),
           "X22 ARMAr_lasso er"=unname(ARMAr_lasso_er[22]),
           
           
           "lasso positives"=unname(sum(lasso[,2:22]!=0)),
           "ARMAr_lasso positives"=unname(sum(ARMAr_lasso[,2:22]!=0)),
           
           "Common 0"=unname(ConfMat[1,1]),
           "Common 1"=unname(ConfMat[2,2]),
           
           
           "X1 lasso h1 er"=unname(lasso_h1_er[1]),
           "X2 lasso h1 er"=unname(lasso_h1_er[2]),
           "X3 lasso h1 er"=unname(lasso_h1_er[3]),
           "X4 lasso h1 er"=unname(lasso_h1_er[4]),
           "X5 lasso h1 er"=unname(lasso_h1_er[5]),
           "X6 lasso h1 er"=unname(lasso_h1_er[6]),
           "X7 lasso h1 er"=unname(lasso_h1_er[7]),
           "X8 lasso h1 er"=unname(lasso_h1_er[8]),
           "X9 lasso h1 er"=unname(lasso_h1_er[9]),
           "X10 lasso h1 er"=unname(lasso_h1_er[10]),
           "X11 lasso h1 er"=unname(lasso_h1_er[11]),
           "X12 lasso h1 er"=unname(lasso_h1_er[12]),
           "X13 lasso h1 er"=unname(lasso_h1_er[13]),
           "X14 lasso h1 er"=unname(lasso_h1_er[14]),
           "X15 lasso h1 er"=unname(lasso_h1_er[15]),
           "X16 lasso h1 er"=unname(lasso_h1_er[16]),
           "X17 lasso h1 er"=unname(lasso_h1_er[17]),
           "X18 lasso h1 er"=unname(lasso_h1_er[18]),
           "X19 lasso h1 er"=unname(lasso_h1_er[19]),
           "X20 lasso h1 er"=unname(lasso_h1_er[20]),
           "X21 lasso h1 er"=unname(lasso_h1_er[21]),
           "X22 lasso h1 er"=unname(lasso_h1_er[22]),
           
           "X1 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[1]),
           "X2 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[2]),
           "X3 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[3]),
           "X4 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[4]),
           "X5 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[5]),
           "X6 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[6]),
           "X7 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[7]),
           "X8 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[8]),
           "X9 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[9]),
           "X10 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[10]),
           "X11 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[11]),
           "X12 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[12]),
           "X13 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[13]),
           "X14 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[14]),
           "X15 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[15]),
           "X16 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[16]),
           "X17 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[17]),
           "X18 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[18]),
           "X19 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[19]),
           "X20 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[20]),
           "X21 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[21]),
           "X22 ARMAr_lasso h1 er"=unname(ARMAr_lasso_h1_er[22]),
           
           
           "X1 lasso h2 er"=unname(lasso_h2_er[1]),
           "X2 lasso h2 er"=unname(lasso_h2_er[2]),
           "X3 lasso h2 er"=unname(lasso_h2_er[3]),
           "X4 lasso h2 er"=unname(lasso_h2_er[4]),
           "X5 lasso h2 er"=unname(lasso_h2_er[5]),
           "X6 lasso h2 er"=unname(lasso_h2_er[6]),
           "X7 lasso h2 er"=unname(lasso_h2_er[7]),
           "X8 lasso h2 er"=unname(lasso_h2_er[8]),
           "X9 lasso h2 er"=unname(lasso_h2_er[9]),
           "X10 lasso h2 er"=unname(lasso_h2_er[10]),
           "X11 lasso h2 er"=unname(lasso_h2_er[11]),
           "X12 lasso h2 er"=unname(lasso_h2_er[12]),
           "X13 lasso h2 er"=unname(lasso_h2_er[13]),
           "X14 lasso h2 er"=unname(lasso_h2_er[14]),
           "X15 lasso h2 er"=unname(lasso_h2_er[15]),
           "X16 lasso h2 er"=unname(lasso_h2_er[16]),
           "X17 lasso h2 er"=unname(lasso_h2_er[17]),
           "X18 lasso h2 er"=unname(lasso_h2_er[18]),
           "X19 lasso h2 er"=unname(lasso_h2_er[19]),
           "X20 lasso h2 er"=unname(lasso_h2_er[20]),
           "X21 lasso h2 er"=unname(lasso_h2_er[21]),
           "X22 lasso h2 er"=unname(lasso_h2_er[22]),
           
           "X1 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[1]),
           "X2 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[2]),
           "X3 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[3]),
           "X4 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[4]),
           "X5 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[5]),
           "X6 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[6]),
           "X7 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[7]),
           "X8 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[8]),
           "X9 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[9]),
           "X10 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[10]),
           "X11 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[11]),
           "X12 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[12]),
           "X13 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[13]),
           "X14 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[14]),
           "X15 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[15]),
           "X16 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[16]),
           "X17 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[17]),
           "X18 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[18]),
           "X19 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[19]),
           "X20 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[20]),
           "X21 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[21]),
           "X22 ARMAr_lasso h2 er"=unname(ARMAr_lasso_h2_er[22]),
           
           
           "X1 lasso h3 er"=unname(lasso_h3_er[1]),
           "X2 lasso h3 er"=unname(lasso_h3_er[2]),
           "X3 lasso h3 er"=unname(lasso_h3_er[3]),
           "X4 lasso h3 er"=unname(lasso_h3_er[4]),
           "X5 lasso h3 er"=unname(lasso_h3_er[5]),
           "X6 lasso h3 er"=unname(lasso_h3_er[6]),
           "X7 lasso h3 er"=unname(lasso_h3_er[7]),
           "X8 lasso h3 er"=unname(lasso_h3_er[8]),
           "X9 lasso h3 er"=unname(lasso_h3_er[9]),
           "X10 lasso h3 er"=unname(lasso_h3_er[10]),
           "X11 lasso h3 er"=unname(lasso_h3_er[11]),
           "X12 lasso h3 er"=unname(lasso_h3_er[12]),
           "X13 lasso h3 er"=unname(lasso_h3_er[13]),
           "X14 lasso h3 er"=unname(lasso_h3_er[14]),
           "X15 lasso h3 er"=unname(lasso_h3_er[15]),
           "X16 lasso h3 er"=unname(lasso_h3_er[16]),
           "X17 lasso h3 er"=unname(lasso_h3_er[17]),
           "X18 lasso h3 er"=unname(lasso_h3_er[18]),
           "X19 lasso h3 er"=unname(lasso_h3_er[19]),
           "X20 lasso h3 er"=unname(lasso_h3_er[20]),
           "X21 lasso h3 er"=unname(lasso_h3_er[21]),
           "X22 lasso h3 er"=unname(lasso_h3_er[22]),
           
           "X1 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[1]),
           "X2 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[2]),
           "X3 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[3]),
           "X4 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[4]),
           "X5 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[5]),
           "X6 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[6]),
           "X7 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[7]),
           "X8 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[8]),
           "X9 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[9]),
           "X10 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[10]),
           "X11 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[11]),
           "X12 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[12]),
           "X13 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[13]),
           "X14 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[14]),
           "X15 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[15]),
           "X16 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[16]),
           "X17 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[17]),
           "X18 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[18]),
           "X19 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[19]),
           "X20 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[20]),
           "X21 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[21]),
           "X22 ARMAr_lasso h3 er"=unname(ARMAr_lasso_h3_er[22]),
           
           
           "X1 lasso h4 er"=unname(lasso_h4_er[1]),
           "X2 lasso h4 er"=unname(lasso_h4_er[2]),
           "X3 lasso h4 er"=unname(lasso_h4_er[3]),
           "X4 lasso h4 er"=unname(lasso_h4_er[4]),
           "X5 lasso h4 er"=unname(lasso_h4_er[5]),
           "X6 lasso h4 er"=unname(lasso_h4_er[6]),
           "X7 lasso h4 er"=unname(lasso_h4_er[7]),
           "X8 lasso h4 er"=unname(lasso_h4_er[8]),
           "X9 lasso h4 er"=unname(lasso_h4_er[9]),
           "X10 lasso h4 er"=unname(lasso_h4_er[10]),
           "X11 lasso h4 er"=unname(lasso_h4_er[11]),
           "X12 lasso h4 er"=unname(lasso_h4_er[12]),
           "X13 lasso h4 er"=unname(lasso_h4_er[13]),
           "X14 lasso h4 er"=unname(lasso_h4_er[14]),
           "X15 lasso h4 er"=unname(lasso_h4_er[15]),
           "X16 lasso h4 er"=unname(lasso_h4_er[16]),
           "X17 lasso h4 er"=unname(lasso_h4_er[17]),
           "X18 lasso h4 er"=unname(lasso_h4_er[18]),
           "X19 lasso h4 er"=unname(lasso_h4_er[19]),
           "X20 lasso h4 er"=unname(lasso_h4_er[20]),
           "X21 lasso h4 er"=unname(lasso_h4_er[21]),
           "X22 lasso h4 er"=unname(lasso_h4_er[22]),
           
           "X1 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[1]),
           "X2 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[2]),
           "X3 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[3]),
           "X4 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[4]),
           "X5 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[5]),
           "X6 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[6]),
           "X7 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[7]),
           "X8 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[8]),
           "X9 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[9]),
           "X10 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[10]),
           "X11 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[11]),
           "X12 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[12]),
           "X13 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[13]),
           "X14 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[14]),
           "X15 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[15]),
           "X16 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[16]),
           "X17 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[17]),
           "X18 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[18]),
           "X19 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[19]),
           "X20 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[20]),
           "X21 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[21]),
           "X22 ARMAr_lasso h4 er"=unname(ARMAr_lasso_h4_er[22]),
           
           
           "X1 lasso"=list(lasso[1,2:22]),
           "X2 lasso"=list(lasso[2,2:22]),
           "X3 lasso"=list(lasso[3,2:22]),
           "X4 lasso"=list(lasso[4,2:22]),
           "X5 lasso"=list(lasso[5,2:22]),
           "X6 lasso"=list(lasso[6,2:22]),
           "X7 lasso"=list(lasso[7,2:22]),
           "X8 lasso"=list(lasso[8,2:22]),
           "X9 lasso"=list(lasso[9,2:22]),
           "X10 lasso"=list(lasso[10,2:22]),
           "X11 lasso"=list(lasso[11,2:22]),
           "X12 lasso"=list(lasso[12,2:22]),
           "X13 lasso"=list(lasso[13,2:22]),
           "X14 lasso"=list(lasso[14,2:22]),
           "X15 lasso"=list(lasso[15,2:22]),
           "X16 lasso"=list(lasso[16,2:22]),
           "X17 lasso"=list(lasso[17,2:22]),
           "X18 lasso"=list(lasso[18,2:22]),
           "X19 lasso"=list(lasso[19,2:22]),
           "X20 lasso"=list(lasso[20,2:22]),
           "X21 lasso"=list(lasso[21,2:22]),
           "X22 lasso"=list(lasso[22,2:22]),
           
           "X1 ARMAr_lasso"=list(ARMAr_lasso[1,2:22]),
           "X2 ARMAr_lasso"=list(ARMAr_lasso[2,2:22]),
           "X3 ARMAr_lasso"=list(ARMAr_lasso[3,2:22]),
           "X4 ARMAr_lasso"=list(ARMAr_lasso[4,2:22]),
           "X5 ARMAr_lasso"=list(ARMAr_lasso[5,2:22]),
           "X6 ARMAr_lasso"=list(ARMAr_lasso[6,2:22]),
           "X7 ARMAr_lasso"=list(ARMAr_lasso[7,2:22]),
           "X8 ARMAr_lasso"=list(ARMAr_lasso[8,2:22]),
           "X9 ARMAr_lasso"=list(ARMAr_lasso[9,2:22]),
           "X10 ARMAr_lasso"=list(ARMAr_lasso[10,2:22]),
           "X11 ARMAr_lasso"=list(ARMAr_lasso[11,2:22]),
           "X12 ARMAr_lasso"=list(ARMAr_lasso[12,2:22]),
           "X13 ARMAr_lasso"=list(ARMAr_lasso[13,2:22]),
           "X14 ARMAr_lasso"=list(ARMAr_lasso[14,2:22]),
           "X15 ARMAr_lasso"=list(ARMAr_lasso[15,2:22]),
           "X16 ARMAr_lasso"=list(ARMAr_lasso[16,2:22]),
           "X17 ARMAr_lasso"=list(ARMAr_lasso[17,2:22]),
           "X18 ARMAr_lasso"=list(ARMAr_lasso[18,2:22]),
           "X19 ARMAr_lasso"=list(ARMAr_lasso[19,2:22]),
           "X20 ARMAr_lasso"=list(ARMAr_lasso[20,2:22]),
           "X21 ARMAr_lasso"=list(ARMAr_lasso[21,2:22]),
           "X22 ARMAr_lasso"=list(ARMAr_lasso[22,2:22])
           
           
           
  ))
  
}

dir.create(args$results_dir, recursive = TRUE, showWarnings = FALSE)
if (setting == "rolling-observed-regressors") {
  forecasts_path <- file.path(args$results_dir, paste0("rolling_observed_forecasts_h", requested_horizon, ".rds"))
} else {
  forecasts_path <- file.path(args$results_dir, "rolling_predicted_forecasts.rds")
}

saveRDS(forecasts, forecasts_path)
cat("Wrote", forecasts_path, "\n")
