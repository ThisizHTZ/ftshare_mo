from __future__ import annotations
from dataclasses import dataclass
import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler

TURNOVER_FEATURES = ["volume_change", "turnover_change"]
TECHNICAL_FEATURES = ["ma_gap_5", "ma_gap_10", "ma_gap_20", "rsi_14", "macd", "macd_signal"]
BASE_FEATURES = ["return_1", "return_5", "return_10", "return_20", "volatility_5", "volatility_10", "volatility_20",
                 "open_close_return", "amplitude", "upper_shadow", "lower_shadow"]
FEATURE_COLUMNS = BASE_FEATURES + TURNOVER_FEATURES + TECHNICAL_FEATURES

@dataclass
class DatasetSplit:
    train: pd.DataFrame
    validation: pd.DataFrame
    test: pd.DataFrame
    train_end: pd.Timestamp
    validation_end: pd.Timestamp


def add_features(frame: pd.DataFrame) -> pd.DataFrame:
    data = frame.copy().sort_values("trade_date").reset_index(drop=True)
    close, open_, high, low = data["close_hfq"], data["open_hfq"], data["high_hfq"], data["low_hfq"]
    for window in (1, 5, 10, 20): data[f"return_{window}"] = close.pct_change(window)
    daily = close.pct_change()
    for window in (5, 10, 20): data[f"volatility_{window}"] = daily.rolling(window).std()
    data["open_close_return"] = close / open_ - 1
    data["amplitude"] = (high - low) / open_
    body_high, body_low = pd.concat([open_, close], axis=1).max(axis=1), pd.concat([open_, close], axis=1).min(axis=1)
    data["upper_shadow"] = (high - body_high) / open_
    data["lower_shadow"] = (body_low - low) / open_
    data["volume_change"] = np.log1p(data["volume"]).diff()
    data["turnover_change"] = np.log1p(data["turnover"]).diff()
    for window in (5, 10, 20): data[f"ma_gap_{window}"] = close / close.rolling(window).mean() - 1
    delta = close.diff(); gain = delta.clip(lower=0).rolling(14).mean(); loss = -delta.clip(upper=0).rolling(14).mean()
    data["rsi_14"] = 100 - 100 / (1 + gain / loss.replace(0, np.nan))
    ema12, ema26 = close.ewm(span=12, adjust=False).mean(), close.ewm(span=26, adjust=False).mean()
    data["macd"] = ema12 - ema26; data["macd_signal"] = data["macd"].ewm(span=9, adjust=False).mean()
    data["next_open_return"] = open_.shift(-2) / open_.shift(-1) - 1
    data["execution_date"] = data["trade_date"].shift(-1)
    data["exit_date"] = data["trade_date"].shift(-2)
    return data.replace([np.inf, -np.inf], np.nan).dropna(subset=FEATURE_COLUMNS + ["next_open_return"]).reset_index(drop=True)


def temporal_split(data: pd.DataFrame, validation_months: int = 6, test_months: int = 6) -> DatasetSplit:
    latest = data["trade_date"].max()
    validation_end = latest - pd.DateOffset(months=test_months)
    train_end = validation_end - pd.DateOffset(months=validation_months)
    train = data[data.trade_date < train_end].copy()
    validation = data[(data.trade_date >= train_end) & (data.trade_date < validation_end)].copy()
    test = data[data.trade_date >= validation_end].copy()
    if min(len(train), len(validation), len(test)) < 40: raise ValueError("Each temporal split must contain at least 40 observations")
    return DatasetSplit(train, validation, test, train_end, validation_end)


def scale_splits(split: DatasetSplit, feature_columns: list[str] | None = None):
    columns = feature_columns or FEATURE_COLUMNS
    scaler = StandardScaler().fit(split.train[columns])
    def transform(frame):
        result = frame.copy(); result.loc[:, columns] = scaler.transform(result[columns]); return result
    return DatasetSplit(transform(split.train), transform(split.validation), transform(split.test), split.train_end, split.validation_end), scaler