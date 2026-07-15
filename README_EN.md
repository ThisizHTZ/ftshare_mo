# FTShare CSI 1000 Intraday Monitor and Interactive Knowledge Graph

This project is an intraday research and monitoring toolkit for the constituents of the CSI 1000 Index. It uses FTShare market-data endpoints to collect market snapshots, calculate short-horizon signals, rank stocks, analyze Shenwan Level-1 sector rotation, and generate standalone interactive HTML dashboards and a scatter-style knowledge graph.

The current system is designed for intraday speed monitoring, sudden turnover expansion detection, constituent ranking, short-term momentum analysis, abnormal-move screening, and approximate constituent contribution analysis.

> All outputs are research signals and observation lists, not investment advice. The current source is polled snapshot data, not tick-by-tick trades, order events, order-book queues, or Level-2 market data.

## What the system does

A complete monitoring run performs the following steps:

1. Fetches CSI 1000 constituents and index weights. The default index code is `000852`.
2. Retrieves paginated real-time snapshots for the full stock market.
3. Matches the market snapshot to the 1,000 index constituents.
4. Retrieves Shenwan Level-1 industries and historical membership records to map each stock to an industry.
5. Collects multiple snapshots at a configurable interval.
6. From the second snapshot onward, compares each stock with its previous snapshot and calculates short-horizon price and activity signals.
7. Produces six Top-20 rankings, daily breadth statistics, sector-rotation metrics, and signal watchlists.
8. Writes CSV, JSON, and standalone HTML outputs.
9. Builds an interactive knowledge graph from the latest stock signals and sector aggregates.

## Data frequency

The monitor runs two iterations with a 20-second wait by default:

```powershell
param(
    [int]$Iterations = 2,
    [int]$IntervalSeconds = 20,
    [string]$OutRoot = "C:\ftshare_data\csi1000_intraday",
    [string]$IndexCode = "000852"
)
```

`IntervalSeconds` is the waiting time between polling rounds. The effective snapshot interval also includes API pagination and local processing time, so it is not guaranteed to equal the configured value exactly. The first snapshot establishes the baseline. At least two snapshots are required before fields such as `interval_return` and `turnover_delta` can be calculated.

This design is suitable for monitoring horizons from tens of seconds to several minutes. It is not intended for millisecond trading, tick replay, or order-book microstructure research.

## Core metrics

Let `close_t` be the current snapshot price and `close_prev` the previous snapshot price.

| Field | Definition | Interpretation |
| --- | --- | --- |
| `change_rate` | Daily return supplied by the API | Intraday strength relative to the previous close |
| `interval_return` | `(close_t - close_prev) / close_prev` | Return between adjacent snapshots; the basis of the speed ranking |
| `volume_delta` | `volume_t - volume_prev` | New traded volume between snapshots |
| `turnover_delta` | `turnover_t - turnover_prev` | New traded value between snapshots |
| `amplitude` | Daily amplitude supplied by the API | Relative daily price range |
| `weighted_change_contribution` | `weight * change_rate` | Approximate weighted contribution to index performance |
| `resonance_score` | `interval_return * log(1 + max(turnover_delta, 0))` | Price-volume resonance when a positive short-term move is accompanied by turnover expansion |
| `risk_score` | `max(-interval_return, 0) * log(1 + max(turnover_delta, 0))` | Downside risk when a short-term decline is accompanied by turnover expansion |

The monitor also calculates cross-sectional standardized scores within the current CSI 1000 universe:

- `momentum_z`: Z-score of `interval_return`.
- `turnover_z`: Z-score of `turnover_delta`.
- `strength_z`: Z-score of `change_rate`.
- `risk_z`: Z-score of `risk_score`.
- `composite_score = momentum_z + turnover_z + strength_z - risk_z`.

These scores are relative to the current snapshot cross-section. They are useful for ranking stocks at one point in time but should not be compared mechanically across dates without further normalization.

## Six intraday rankings

`dashboard.html` generates six Top-20 tables by default:

| Ranking | Sort rule | Main purpose |
| --- | --- | --- |
| Price Speed | `interval_return` descending | Finds the fastest risers during the latest snapshot interval |
| Turnover Increase | `turnover_delta` descending | Finds stocks with the largest newly traded value |
| Price-Volume Resonance | `resonance_score` descending | Finds positive short-term moves supported by turnover expansion |
| Daily Strength | `change_rate` descending | Ranks constituents by cumulative daily performance |
| Weighted Contribution | `weighted_change_contribution` descending | Approximates the strongest positive contributors to the index |
| Risk Warning | `risk_score` descending | Finds short-term declines accompanied by turnover expansion |

## Daily analysis, sector rotation, and labels

Daily analysis summarizes advancing, declining, and unchanged constituents; average and median returns; total turnover; signal-label counts; and the largest positive and negative weighted contributors.

Sector rotation is aggregated by Shenwan Level-1 industry. Each row includes constituent count, average daily return, total turnover increase, average interval return, average resonance score, total weighted contribution, and signal counts. The sector ranking is defined as:

```text
sector_score = z(sector average daily return)
             + z(sector total turnover increase)
             + z(sector average interval return)
```

The current stock-label rules are:

- `Risk Warning`: `risk_z >= 1` and the interval return is negative.
- `Strong Watch`: `composite_score >= 1`, daily return is positive, and turnover increase is non-negative.
- `Volume Anomaly`: `turnover_z >= 1` and the resonance score is positive.
- `Neutral`: none of the above thresholds are reached.

The labels describe relative conditions in the current cross-section. They are not deterministic forecasts of future returns.

## Interactive knowledge graph

`knowledge_graph.html` organizes the data as `CSI 1000 Index -> Shenwan Level-1 Industry -> Constituent Stock`. The current example uses a dispersed scatter layout: stock nodes are distributed around their industries, while momentum and trading activity influence their positions.

Available interactions include:

- Search by symbol or company name.
- Filter by Shenwan Level-1 industry.
- Filter by Strong Watch, Volume Anomaly, Risk Warning, or Neutral label.
- Change the number of displayed stocks per industry.
- Zoom with the mouse wheel and pan by dragging.
- Click industry or stock nodes to inspect metrics, rankings, and relationships.

The graph is an exploratory view of membership and signal relationships. Edges do not imply causality.

## Repository structure

```text
ftshare_mo/
├── README.md
├── README_EN.md
├── scripts/
│   ├── ftshare_csi1000_intraday_monitor.ps1
│   ├── generate_csi1000_knowledge_graph.ps1
│   ├── ftshare_fetch_realtime_quotes.ps1
│   ├── ftshare_fetch_realtime_quotes.py
│   └── ftshare_fetch_history_plus_realtime.ps1
├── reports/
│   ├── csi1000_intraday_monitor_report.html
│   └── csi1000_intraday_monitor_report.tex
└── runs/20260709_155132/
    ├── dashboard.html
    ├── knowledge_graph.html
    ├── csi1000_components.csv
    ├── csi1000_snapshots.csv
    ├── snapshot_001.csv
    ├── snapshot_002.csv
    ├── latest_signals.csv
    ├── signals_002.csv
    ├── sector_rotation.csv
    ├── prediction_watchlist.csv
    ├── daily_analysis.json
    └── summary.json
```

## Main scripts

### Run the CSI 1000 intraday monitor

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ftshare_csi1000_intraday_monitor.ps1 `
  -Iterations 10 `
  -IntervalSeconds 30 `
  -OutRoot "C:\ftshare_data\csi1000_intraday" `
  -IndexCode "000852"
```

Each run creates a timestamped output directory. Run it during A-share trading hours and use a polling interval appropriate for the capacity and terms of the source API.

### Generate the knowledge graph

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate_csi1000_knowledge_graph.ps1 `
  -RunDir "C:\ftshare_data\csi1000_intraday\20260709_155132" `
  -DefaultTopPerIndustry 8
```

The target directory must contain `latest_signals.csv` and `sector_rotation.csv`. The script writes `knowledge_graph.html` to the same directory.

### Fetch full-market real-time snapshots

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ftshare_fetch_realtime_quotes.ps1
```

A Python standard-library implementation is also included:

```powershell
python .\scripts\ftshare_fetch_realtime_quotes.py
```

The scripts export full-market, STAR Market, ChiNext, Beijing Stock Exchange, Shanghai, Shenzhen, and main-board files.

### Combine historical daily bars with today's snapshot

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ftshare_fetch_history_plus_realtime.ps1 `
  -Symbols "000001.SZ","600519.SH" `
  -StartDate "2026-07-01" `
  -EndDate "2026-07-09" `
  -RealtimeCsv "C:\ftshare_data\realtime_quotes\<run_id>\all.csv"
```

This helper retrieves daily historical bars and combines them with the selected real-time snapshot. The historical section is daily-frequency data; it does not provide historical minute bars or historical ticks.

## Output files

| File | Description |
| --- | --- |
| `csi1000_components.csv` | CSI 1000 constituents, index weights, and industry mapping |
| `snapshot_NNN.csv` | Constituent snapshot from polling round N |
| `csi1000_snapshots.csv` | Combined snapshots from all rounds |
| `signals_NNN.csv` | Signals calculated from adjacent snapshots |
| `latest_signals.csv` | Latest signals, standardized scores, labels, and reasons |
| `daily_analysis.json` | Market breadth, turnover, and contribution summary |
| `sector_rotation.csv` | Shenwan Level-1 aggregates and rotation scores |
| `prediction_watchlist.csv` | Strong, volume-anomaly, and risk observation lists |
| `dashboard.html` | Main dashboard with rankings and extended analysis |
| `knowledge_graph.html` | Standalone interactive scatter knowledge graph |
| `summary.json` | Run paths and per-iteration matching summary |

## Included example

`runs/20260709_155132/` contains a short two-snapshot test. Both snapshots matched all 1,000 CSI 1000 constituents, and the second snapshot produced 1,000 short-horizon signal rows. The industry mapping uses the most recent Shenwan Level-1 membership data available to that run.

After downloading the repository, open these files directly in a browser:

- `runs/20260709_155132/dashboard.html`
- `runs/20260709_155132/knowledge_graph.html`

## Known limitations

- Real-time fields are cumulative market snapshots; short-horizon metrics are derived from adjacent-snapshot differences.
- Pagination and processing make the effective interval slightly longer than `IntervalSeconds`.
- Blank fields may represent suspended stocks, no new trades, unavailable API values, non-applicable fields, or failed industry mappings.
- Index constituents and weights change over time; results depend on what the API returns at run time.
- `weighted_change_contribution` is an approximation and does not reproduce the index provider's official point-contribution methodology.
- Rotation scores and labels depend on the current cross-section and require multi-day backtesting and calibration before systematic use.
- Included data represents one historical run, not the current market state.

## Possible next steps

Natural extensions include longer continuous collection, a minute-bar history store, trading calendars, corporate-action adjustment, signal backtesting, cached industry mappings, outlier treatment, a time-series database, real-time alerts, WebSocket or higher-frequency sources, and knowledge-graph links to historical events and company fundamentals.

