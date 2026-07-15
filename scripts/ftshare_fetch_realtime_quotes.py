import csv
import json
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


BASE_URL = "https://market.ft.tech/gateway/api/v1/market/data/stock-list/filter"
PAGE_SIZE = 200
OUT_DIR = Path(r"C:\ftshare_data\realtime_quotes")

TARGETS = [
    ("all", {}),
    ("star", {"board": "star"}),
    ("chi_next", {"board": "chi_next"}),
    ("bjse", {"board": "bjse"}),
    ("xshg", {"board": "xshg"}),
    ("xshe", {"board": "xshe"}),
    ("main", {"board": "main"}),
]


def fetch_json(params):
    url = f"{BASE_URL}?{urlencode(params)}"
    req = Request(url, headers={"User-Agent": "ftshare-realtime-fetch/1.0"})
    with urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def normalize_response(payload):
    if "items" in payload:
        return payload
    data = payload.get("data")
    if isinstance(data, dict):
        if "records" in data:
            return {
                "items": data.get("records") or [],
                "total_pages": data.get("pages") or 1,
                "total_items": data.get("total") or len(data.get("records") or []),
            }
        if "items" in data:
            return data
    raise ValueError(f"Unexpected response shape: {list(payload.keys())}")


def fetch_target(name, extra_params):
    rows = []
    first = normalize_response(
        fetch_json({**extra_params, "page": 1, "page_size": PAGE_SIZE})
    )
    total_pages = int(first.get("total_pages") or first.get("pages") or 1)
    total_items = int(first.get("total_items") or first.get("total") or 0)
    rows.extend(first.get("items") or [])

    for page in range(2, total_pages + 1):
        payload = normalize_response(
            fetch_json({**extra_params, "page": page, "page_size": PAGE_SIZE})
        )
        rows.extend(payload.get("items") or [])
        time.sleep(0.08)

    return {
        "name": name,
        "rows": rows,
        "total_pages": total_pages,
        "total_items": total_items,
    }


def write_csv(path, rows):
    fields = sorted({key for row in rows for key in row.keys()})
    preferred = [
        "symbol",
        "symbol_id",
        "symbol_name",
        "name",
        "board",
        "close",
        "change",
        "change_rate",
        "open",
        "high",
        "low",
        "prev_close",
        "volume",
        "turnover",
        "amplitude",
        "turnover_rate",
        "pe_ttm",
        "ts_nanos",
    ]
    fieldnames = [field for field in preferred if field in fields]
    fieldnames.extend(field for field in fields if field not in fieldnames)

    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main():
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = OUT_DIR / stamp
    run_dir.mkdir(parents=True, exist_ok=True)

    summary = []
    for name, params in TARGETS:
        result = fetch_target(name, params)
        csv_path = run_dir / f"{name}.csv"
        json_path = run_dir / f"{name}.json"

        write_csv(csv_path, result["rows"])
        json_path.write_text(
            json.dumps(result["rows"], ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        summary.append(
            {
                "target": name,
                "rows": len(result["rows"]),
                "reported_total_items": result["total_items"],
                "pages": result["total_pages"],
                "csv": str(csv_path),
                "json": str(json_path),
            }
        )

    summary_path = run_dir / "summary.json"
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps({"output_dir": str(run_dir), "summary": summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
