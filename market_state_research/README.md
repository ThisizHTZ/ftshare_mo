# 中证1000盘中市场状态、行业扩散与风险暴露研究

本模块只使用 FTShare 官方接口，研究中证1000的分钟量价、市场宽度、权重与等权背离、行业扩散和资金流。研究输出是统计状态与待检验假设，不是个股推荐。

## 第一阶段

- 拉取中证1000指数1分钟数据并检查每个交易日完整性。
- 复用当日中证1000成分、权重、收盘快照和申万行业映射。
- 计算收盘市场宽度、等权与权重收益背离、行业扩散与集中度。
- 生成数据质量文件和独立 HTML 研究报告。
- 缺失的历史盘中成分宽度保持为空，不使用收盘数据反推。

## 运行

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_market_state_study.ps1 `
  -TradeDate 20260715 `
  -SnapshotRunDir C:\ftshare_data\daily_intraday_summary\20260715_170202
```

输出默认写入 `C:\ftshare_data\market_state_research\<trade_date>_<run_id>\`。


主要产物：

- `index_minute.csv`：指数1分钟价格、均价、成交量和成交额。
- `index_15m_features.csv`：15分钟收益、实现波动率、成交量与成交额。
- `component_capital_flows_15m.csv`：四个锚点的中证1000成分股资金流。
- `sector_diffusion.csv`：行业平均收益、方向和权重贡献。
- `research_summary.json`：宽度、等权/权重背离、行业扩散与状态标签。
- `data_quality.json`：分钟完整性、成分覆盖率和不可恢复的数据缺口。
- `report.html`：独立研究看板。

首期单日发现见 [`FIRST_FINDINGS_20260715.md`](FIRST_FINDINGS_20260715.md)。单日结果只用于形成待检验假设；至少积累60个交易日后才进行条件收益、显著性和样本外检验。