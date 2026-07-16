from __future__ import annotations
import hashlib, json, time, urllib.parse, urllib.request
from dataclasses import dataclass, asdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
import pandas as pd

PRICE_COLUMNS = ["open_hfq", "high_hfq", "low_hfq", "close_hfq"]

@dataclass(frozen=True)
class ValidationResult:
    is_valid: bool
    errors: list[str]
    warnings: list[str]
    stats: dict[str, Any]


def request_json(url: str, params: dict[str, Any], timeout: int = 45, retries: int = 5) -> Any:
    request = urllib.request.Request(
        url + "?" + urllib.parse.urlencode(params),
        headers={"X-Client-Name": "ft-claw", "User-Agent": "ftshare-csi1000-rl/0.1"},
    )
    last_error = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            last_error = exc
            time.sleep(min(2 ** attempt, 16))
    raise RuntimeError(f"FTShare request failed after {retries} attempts") from last_error


def year_chunks(start: date, end: date) -> list[tuple[date, date]]:
    chunks, cursor = [], start
    while cursor <= end:
        chunk_end = min(date(cursor.year, 12, 31), end)
        chunks.append((cursor, chunk_end))
        cursor = chunk_end + timedelta(days=1)
    return chunks


def extract_rows(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("ohlcs", "data", "items"):
            if isinstance(payload.get(key), list):
                return payload[key]
    raise ValueError("Unexpected FTShare OHLC response shape")


def normalize_ohlcs(rows: list[dict[str, Any]], downloaded_at: str) -> pd.DataFrame:
    records = []
    for row in rows:
        timestamp = row.get("open_ts_ms") or row.get("open_time")
        if timestamp is None:
            raise ValueError("OHLC row is missing open timestamp")
        records.append({
            "trade_date": pd.to_datetime(timestamp).date().isoformat(),
            "open_hfq": row.get("open"), "high_hfq": row.get("high"),
            "low_hfq": row.get("low"), "close_hfq": row.get("close"),
            "volume": row.get("volume"), "turnover": row.get("turnover"),
            "adjust_type": "Backward", "source": "FTShare", "download_time": downloaded_at,
        })
    frame = pd.DataFrame(records)
    for column in PRICE_COLUMNS + ["volume", "turnover"]:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    frame["trade_date"] = pd.to_datetime(frame["trade_date"])
    return frame.sort_values("trade_date").drop_duplicates("trade_date", keep="last").reset_index(drop=True)


def dataframe_hash(frame: pd.DataFrame) -> str:
    return hashlib.sha256(frame.to_csv(index=False, date_format="%Y-%m-%d").encode()).hexdigest()


def validate_daily_data(frame: pd.DataFrame) -> ValidationResult:
    errors, warnings = [], []
    required = {"trade_date", *PRICE_COLUMNS, "volume", "turnover", "adjust_type", "source"}
    missing = sorted(required.difference(frame.columns))
    if missing:
        return ValidationResult(False, ["missing_columns:" + ",".join(missing)], [], {"rows": len(frame)})
    if frame["trade_date"].duplicated().any(): errors.append("duplicate_trade_dates")
    if not frame["trade_date"].is_monotonic_increasing: errors.append("trade_dates_not_increasing")
    if frame[PRICE_COLUMNS].isna().any().any(): errors.append("missing_prices")
    if (frame[PRICE_COLUMNS] <= 0).any().any(): errors.append("non_positive_prices")
    if (frame["high_hfq"] < frame[["open_hfq", "close_hfq"]].max(axis=1)).any(): errors.append("invalid_high")
    if (frame["low_hfq"] > frame[["open_hfq", "close_hfq"]].min(axis=1)).any(): errors.append("invalid_low")
    if (frame[["volume", "turnover"]].fillna(-1) < 0).any().any(): errors.append("negative_volume_or_turnover")
    if not frame["adjust_type"].eq("Backward").all(): errors.append("adjust_type_not_backward")
    extreme = int((frame["close_hfq"].pct_change().abs() > 0.15).sum())
    if extreme: warnings.append(f"extreme_daily_returns:{extreme}")
    long_gaps = int((frame["trade_date"].diff().dt.days > 10).sum())
    if long_gaps: warnings.append(f"long_calendar_gaps:{long_gaps}")
    stats = {"rows": int(len(frame)), "start_date": frame["trade_date"].min().date().isoformat() if len(frame) else None,
             "end_date": frame["trade_date"].max().date().isoformat() if len(frame) else None,
             "extreme_return_count": extreme, "sha256": dataframe_hash(frame)}
    return ValidationResult(not errors, errors, warnings, stats)


def download_index_history(config: dict[str, Any], project_root: Path) -> pd.DataFrame:
    from .config import resolve_path
    end = date.today()
    try: start = end.replace(year=end.year - int(config["project"]["years"]))
    except ValueError: start = end.replace(month=2, day=28, year=end.year - int(config["project"]["years"]))
    raw_dir = resolve_path(project_root, config["data"]["raw_dir"])
    raw_dir.mkdir(parents=True, exist_ok=True)
    downloaded_at, frames = datetime.now(timezone.utc).isoformat(), []
    for chunk_start, chunk_end in year_chunks(start, end):
        params = {"symbol": config["project"]["symbol"], "since": chunk_start.strftime("%Y%m%d"),
                  "until": chunk_end.strftime("%Y%m%d"), "interval": "Day", "adjust": "Backward"}
        payload = request_json(config["data"]["endpoint"], params, int(config["data"]["timeout_seconds"]), int(config["data"]["retries"]))
        (raw_dir / f"{chunk_start:%Y%m%d}_{chunk_end:%Y%m%d}.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        frames.append(normalize_ohlcs(extract_rows(payload), downloaded_at))
    return pd.concat(frames, ignore_index=True).sort_values("trade_date").drop_duplicates("trade_date").reset_index(drop=True)


def save_validated_data(frame: pd.DataFrame, config: dict[str, Any], project_root: Path) -> ValidationResult:
    from .config import resolve_path
    result = validate_daily_data(frame)
    quality = resolve_path(project_root, config["data"]["quality_path"])
    quality.parent.mkdir(parents=True, exist_ok=True)
    quality.write_text(json.dumps({**asdict(result), **result.stats}, indent=2), encoding="utf-8")
    if not result.is_valid: raise ValueError(f"Data quality gate failed: {result.errors}")
    output = resolve_path(project_root, config["data"]["processed_path"])
    output.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(output, index=False, date_format="%Y-%m-%d")
    return result