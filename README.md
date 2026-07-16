# FTShare 中证1000盘中监控与交互式知识图谱

本项目基于 FTShare 市场数据接口，构建了一套面向中证1000成分股的盘中行情采集、短周期信号计算、排行榜监控、申万一级行业轮动分析和交互式知识图谱工具。

项目当前关注的是盘中研究与监控：定时获取全市场实时快照，筛选中证1000成分股，比较相邻快照变化，生成可直接在浏览器打开的 HTML 看板与散点知识图谱。它适合用于盘中涨速观察、成交额突然放大监控、内部强弱排名、短周期动量分析、异动股筛选以及成分股贡献度粗估。

> 本项目输出的是研究信号和观察清单，不构成投资建议。当前数据属于快照轮询数据，不是逐笔成交、逐笔委托、盘口队列或 Level-2 数据。

## 当前系统在做什么

一次完整运行包含以下流程：

1. 从指数权重接口获取中证1000（默认指数代码 `000852`）成分股及权重。
2. 从实时行情列表接口分页获取全市场股票快照。
3. 按股票代码匹配出1000只指数成分股。
4. 获取申万一级行业及历史成分关系，为股票补充行业映射。
5. 按设定间隔连续采集快照。
6. 从第二轮开始比较当前快照与上一快照，计算短周期收益、成交量增量、成交额增量和衍生分数。
7. 生成六大排行榜、每日市场广度分析、行业轮动分析和信号观察清单。
8. 将结果写入 CSV、JSON 和独立 HTML 文件。
9. 使用信号与行业数据生成可搜索、筛选、缩放、拖拽和点击查看详情的交互式知识图谱。

## 数据频率与含义

监控脚本默认运行两轮，每轮间隔20秒：

```powershell
param(
    [int]$Iterations = 2,
    [int]$IntervalSeconds = 20,
    [string]$OutRoot = "C:\ftshare_data\csi1000_intraday",
    [string]$IndexCode = "000852"
)
```

`IntervalSeconds` 是两轮请求之间的等待时间。实际快照间隔还包含全市场分页请求和数据处理耗时，因此并不保证严格等于设定值。第一轮只建立比较基线，不产生区间信号；至少需要两轮快照才能计算 `interval_return`、`turnover_delta` 等字段。

这种频率适合几十秒到数分钟尺度的盘中监控和统计，不适合毫秒级交易、逐笔回放或盘口微观结构研究。

## 核心指标

设当前快照价格为 `close_t`，上一快照价格为 `close_prev`：

| 字段 | 定义 | 含义 |
| --- | --- | --- |
| `change_rate` | 接口返回的当日涨跌幅 | 当前价格相对昨收的日内强弱 |
| `interval_return` | `(close_t - close_prev) / close_prev` | 相邻快照之间的短周期收益，即盘中涨速的基础 |
| `volume_delta` | `volume_t - volume_prev` | 相邻快照之间新增成交量 |
| `turnover_delta` | `turnover_t - turnover_prev` | 相邻快照之间新增成交额 |
| `amplitude` | 接口返回的当日振幅 | 当日价格波动范围的相对指标 |
| `weighted_change_contribution` | `weight * change_rate` | 个股对指数当日涨跌的粗略权重贡献，不是严格指数点位归因 |
| `resonance_score` | `interval_return * log(1 + max(turnover_delta, 0))` | 短周期上涨与成交额放大的量价共振程度 |
| `risk_score` | `max(-interval_return, 0) * log(1 + max(turnover_delta, 0))` | 短周期下跌同时成交额放大的风险程度 |

系统还会在当轮1000只股票的横截面上计算标准分：

- `momentum_z`：`interval_return` 的横截面 Z-score。
- `turnover_z`：`turnover_delta` 的横截面 Z-score。
- `strength_z`：`change_rate` 的横截面 Z-score。
- `risk_z`：`risk_score` 的横截面 Z-score。
- `composite_score = momentum_z + turnover_z + strength_z - risk_z`。

Z-score 是相对当轮中证1000内部均值和标准差的标准化结果，因此用于横向比较，不应直接跨日期机械比较。

## 六大盘中排行榜

`dashboard.html` 默认生成六个 Top 20 榜单：

| 榜单 | 排序规则 | 主要用途 |
| --- | --- | --- |
| 涨速榜 | `interval_return` 降序 | 寻找最近一个快照区间内上涨最快的股票 |
| 成交额增量榜 | `turnover_delta` 降序 | 监控短时间内新增成交额最大的股票 |
| 量价共振榜 | `resonance_score` 降序 | 筛选上涨与放量同时出现的股票 |
| 当日强势榜 | `change_rate` 降序 | 查看当日累计表现最强的成分股 |
| 权重贡献榜 | `weighted_change_contribution` 降序 | 粗估对中证1000表现贡献较大的股票 |
| 风险预警榜 | `risk_score` 降序 | 寻找短周期下跌且成交额放大的股票 |

## 每日分析、板块轮动与观察标签

每日分析汇总中证1000内部上涨、下跌和平盘家数，平均与中位涨跌幅，成交额合计，强势观察、放量异动和风险预警数量，以及正负贡献较大的股票。

板块轮动按申万一级行业聚合，输出行业成分数、平均涨跌幅、成交额增量合计、平均短周期收益、平均量价共振分、权重贡献合计和行业内信号数量。行业排序分数为：

```text
sector_score = z(行业平均涨跌幅)
             + z(行业成交额增量合计)
             + z(行业平均短周期收益)
```

个股观察标签的当前规则如下：

- `风险预警`：`risk_z >= 1` 且短周期收益为负。
- `强势观察`：`composite_score >= 1`、当日涨跌幅为正且成交额增量非负。
- `放量异动`：`turnover_z >= 1` 且量价共振分为正。
- `中性`：未达到以上阈值。

这些标签表达的是当前快照横截面中的相对状态，不是确定性的未来涨跌预测。

## 交互式知识图谱

`knowledge_graph.html` 将数据组织为“中证1000指数 → 申万一级行业 → 成分股”的关系网络。当前示例采用散点式展开，使股票节点围绕所属行业分散分布，并结合动量和成交热度呈现位置差异。

支持的交互包括：

- 按股票代码或名称搜索。
- 按申万一级行业筛选。
- 按强势观察、放量异动、风险预警或中性标签筛选。
- 调整每个行业展示的股票数量。
- 鼠标滚轮缩放、拖拽平移。
- 点击行业或股票节点查看指标、排名与关联信息。

图谱用于探索“行业归属、个股状态和信号关系”，节点之间的连接不表示因果关系。

## 仓库结构

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

## 主要脚本

### 中证1000盘中监控

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ftshare_csi1000_intraday_monitor.ps1 `
  -Iterations 10 `
  -IntervalSeconds 30 `
  -OutRoot "C:\ftshare_data\csi1000_intraday" `
  -IndexCode "000852"
```

运行结束后会在输出根目录下创建带时间戳的新目录。建议在A股交易时段运行，并根据接口承载能力设置合理间隔。

### 生成知识图谱

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\generate_csi1000_knowledge_graph.ps1 `
  -RunDir "C:\ftshare_data\csi1000_intraday\20260709_155132" `
  -DefaultTopPerIndustry 8
```

脚本要求目标目录中存在 `latest_signals.csv` 和 `sector_rotation.csv`，生成结果为同目录下的 `knowledge_graph.html`。

### 获取全市场实时快照

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ftshare_fetch_realtime_quotes.ps1
```

也可以使用标准库实现的 Python 版本：

```powershell
python .\scripts\ftshare_fetch_realtime_quotes.py
```

脚本分别输出全市场、科创板、创业板、北交所、沪市、深市和主板行情文件。

### 合并历史日线与当日实时快照

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ftshare_fetch_history_plus_realtime.ps1 `
  -Symbols "000001.SZ","600519.SH" `
  -StartDate "2026-07-01" `
  -EndDate "2026-07-09" `
  -RealtimeCsv "C:\ftshare_data\realtime_quotes\<run_id>\all.csv"
```

该脚本获取日线历史数据，并与指定实时快照文件中的当日数据组合。历史部分是日频数据，不能代替历史分钟线或历史逐笔数据。

## 输出文件说明

| 文件 | 内容 |
| --- | --- |
| `csi1000_components.csv` | 中证1000成分股、指数权重及行业映射 |
| `snapshot_NNN.csv` | 第 N 轮成分股实时快照 |
| `csi1000_snapshots.csv` | 所有轮次快照的合并文件 |
| `signals_NNN.csv` | 相邻快照计算得到的当轮信号 |
| `latest_signals.csv` | 最新一轮信号及标准分、标签和原因 |
| `daily_analysis.json` | 市场广度、成交额和贡献股摘要 |
| `sector_rotation.csv` | 申万一级行业聚合与轮动分数 |
| `prediction_watchlist.csv` | 强势、放量和风险观察清单 |
| `dashboard.html` | 六大排行榜及扩展分析主看板 |
| `knowledge_graph.html` | 独立、可交互的散点知识图谱 |
| `summary.json` | 运行参数、文件路径和各轮匹配情况 |

## 示例运行

仓库中的 `runs/20260709_155132/` 是一次两轮短测试结果：两轮均匹配1000只中证1000成分股，第二轮生成1000行短周期信号。示例行业映射使用最近可用的申万一级行业数据。

直接下载仓库后，用浏览器打开以下文件即可查看：

- `runs/20260709_155132/dashboard.html`
- `runs/20260709_155132/knowledge_graph.html`

## 已知限制

- 实时接口返回的是累计行情快照，短周期指标来自相邻快照差分。
- 请求分页耗时会使实际间隔略长于 `IntervalSeconds`。
- 空白字段可能来自停牌、未成交、接口缺失值、字段不适用或行业映射失败。
- 指数成分和权重会调整，运行时结果取决于接口当时返回的数据。
- `weighted_change_contribution` 是简化估算，没有复刻指数公司的精确点位计算方法。
- 轮动分数和观察标签依赖当轮横截面，阈值需要通过更多交易日进行回测和校准。
- 示例数据只代表一次历史运行，不能代表当前市场状态。

## 后续方向

适合继续扩展的方向包括：更长时间连续采样、分钟级历史落库、交易日历、复权处理、信号回测、行业映射缓存、异常值处理、时序数据库、实时告警、WebSocket或更高频数据源，以及把知识图谱与历史事件和公司基本面关系结合。


## 强化学习择时研究

新增 [`rl_research/`](rl_research/) 子项目：仅使用 FTShare `000852.XSHG` 后复权日线，在 Google Colab 比较 PPO、A2C、DQN 的中证1000指数风险暴露控制。状态在收盘后形成、动作在下一交易日开盘执行，最后六个月为隔离样本外测试。仓库不包含虚构收益；正式模型、轨迹和报告必须由真实 Colab 运行生成。

- [中文研究说明](rl_research/README.md)
- [English guide](rl_research/README_EN.md)
- [Colab Notebook](rl_research/notebooks/csi1000_rl_colab.ipynb)