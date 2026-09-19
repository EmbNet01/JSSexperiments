#!/usr/bin/env python
import argparse
from pathlib import Path

import numpy as np
import pandas as pd
from dataset_config import load_dataset
from sklearn.ensemble import RandomForestRegressor
from sklearn.preprocessing import StandardScaler


METHODS = {
    "tide": "TiDE",
    "transformer": "Transformer",
    "dlinear": "DLinear",
    "nhits": "NHITS",
    "random-forest": "Random Forest",
    "rf": "Random Forest",
}
ALL_METHODS = ["tide", "transformer", "dlinear", "nhits", "random-forest"]


def metrics_frame(method_name, features, y_true, y_pred, train_values):
    err = y_true - y_pred
    rmse = np.sqrt(np.nanmean(err ** 2, axis=0))
    mae = np.nanmean(np.abs(err), axis=0)
    scale = np.nanmean(np.abs(np.diff(train_values, axis=0)), axis=0)
    mase = np.divide(mae, scale, out=np.full_like(mae, np.nan), where=scale != 0)

    out = pd.DataFrame(
        {
            "Setting": "fixed-split",
            "Dataset": "",
            "Method": method_name,
            "Variable": features,
            "RMSE": rmse,
            "MAE": mae,
            "MASE": mase,
            "AVG_SELECTED_VARIABLES": np.nan,
        }
    )
    mean = out[["RMSE", "MAE", "MASE"]].mean(numeric_only=True)
    out.loc[len(out)] = ["fixed-split", "", method_name, "MEAN", *mean.tolist(), np.nan]
    return out


def random_forest_predict(values_all, n_train, n_test, lags):
    train_values = values_all[:n_train]
    x_train, y_train = [], []
    for t in range(lags, n_train):
        x_train.append(train_values[t - lags:t].flatten())
        y_train.append(train_values[t])

    model = RandomForestRegressor(
        n_estimators=500,
        max_features=max(1, int(np.sqrt(len(x_train[0])))),
        max_depth=20,
        min_samples_split=4,
        min_samples_leaf=2,
        random_state=42,
        n_jobs=-1,
    )
    model.fit(np.asarray(x_train), np.asarray(y_train))

    preds = []
    for t in range(n_test):
        current_end = n_train + t
        window = values_all[current_end - lags:current_end]
        preds.append(model.predict(window.flatten().reshape(1, -1))[0])
    return np.vstack(preds)


def darts_predict(method, values_all, n_train, n_test, lags, epochs, features):
    import torch
    from darts import TimeSeries
    from darts.models import DLinearModel, NHiTSModel, TiDEModel, TransformerModel

    times = pd.date_range("2024-01-01 00:00:00", periods=len(values_all), freq="5min")
    df = pd.DataFrame(values_all, columns=features)
    df["timestamp"] = times
    series_all = TimeSeries.from_dataframe(df, time_col="timestamp", value_cols=features, freq="5min")
    if not torch.cuda.is_available():
        raise RuntimeError("The fixed-split Darts runs expect a CUDA GPU, matching main.py.")
    trainer_kwargs = {"accelerator": "cuda"}
    model_map = {
        "tide": TiDEModel,
        "transformer": TransformerModel,
        "dlinear": DLinearModel,
        "nhits": NHiTSModel,
    }
    model = model_map[method](
        input_chunk_length=lags,
        output_chunk_length=1,
        random_state=42,
        pl_trainer_kwargs=trainer_kwargs,
    )
    model.fit(series_all[:n_train])

    preds = []
    for t in range(n_test):
        current_end = n_train + t
        window = series_all[current_end - lags:current_end]
        preds.append(model.predict(n=1, series=window, verbose=False).values()[0])
    return np.vstack(preds)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--method", default="all", choices=["all", *METHODS.keys()])
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--results-dir", type=Path, default=Path(__file__).resolve().parents[1] / "results")
    parser.add_argument("--lags", type=int, default=5)
    parser.add_argument("--epochs", type=int, default=100)
    args = parser.parse_args()

    df_train, df_test, features = load_dataset(args.dataset, args.project_root)
    scaler = StandardScaler()
    scaler.fit(df_train[features])
    train_values = scaler.transform(df_train[features])
    test_values = scaler.transform(df_test[features])
    values_all = np.vstack([train_values, test_values])
    n_train, n_test = len(train_values), len(test_values)
    y_true = values_all[n_train:n_train + n_test]

    methods = ALL_METHODS if args.method == "all" else [args.method]
    rows = []
    for method in methods:
        method_name = METHODS[method]
        print(f"Running {method_name} on {args.dataset}")
        if method in {"random-forest", "rf"}:
            y_pred = random_forest_predict(values_all, n_train, n_test, args.lags)
        else:
            y_pred = darts_predict(method, values_all, n_train, n_test, args.lags, args.epochs, features)
        frame = metrics_frame(method_name, features, y_true, y_pred, train_values)
        frame["Dataset"] = args.dataset
        rows.append(frame)

    out = pd.concat(rows, ignore_index=True)
    args.results_dir.mkdir(parents=True, exist_ok=True)
    method_slug = "ml_methods" if args.method == "all" else args.method.replace("-", "_")
    out_path = args.results_dir / f"fixed_split_{args.dataset}_{method_slug}_metrics.csv"
    out.to_csv(out_path, index=False)
    print(out[out["Variable"] == "MEAN"].to_string(index=False))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
