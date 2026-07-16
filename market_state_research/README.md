# 中证1000分钟量价、市场状态与行业扩散研究

本模块只使用 FTShare 数据，研究中证1000指数分钟量价、市场宽度、权重与等权背离、行业扩散和资金流。输出是可检验的市场状态假设，不是个股推荐。

## 分钟数据基座

历史分钟数据以 `ft_stock_candlesticks` 为主，多个指数使用 `ft_stock_candlesticks_batch`。参数契约：

- `symbol`: 如 `000852.XSHG`
- `interval_unit=minute`
- `interval_value=1`
- `since_ts_millis` / `until_ts_millis`: 北京时间对应的毫秒时间戳
- `limit`: 单次返回上限
- 返回字段：`open/high/low/close/volume/turnover/ts_millis`

单次起止跨度不得超过3天。`new_candlestick_request_plan.ps1` 自动切段；函数结果保存为JSON后，由 `normalize_candlesticks.ps1` 合并、按 `symbol+ts_millis` 去重、排序并执行OHLCV质量门禁。不要把新函数参数直接拼到旧 REST 路径；它是 FTShare MCP 函数契约。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\new_candlestick_request_plan.ps1 `
  -Symbols 000852.XSHG `
  -Since '2026-01-01 00:00:00' `
  -Until '2026-07-15 23:59:59' `
  -OutputPath .\candlestick_request_plan.json

powershell -ExecutionPolicy Bypass -File .\scripts\normalize_candlesticks.ps1 `
  -InputPath .\raw\chunk_*.json `
  -OutputCsv .\data\csi1000_1min.csv
```

## 运行主研究

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_market_state_study.ps1 `
  -TradeDate 20260715 `
  -SnapshotRunDir C:\ftshare_data\daily_intraday_summary\20260715_170202 `
  -IndexMinuteCsv .\data\csi1000_1min.csv
```

不传 `IndexMinuteCsv` 时仍可使用旧 `history/prices` 做近期兼容验证，但质量报告会明确标记为回退来源。正式历史研究应使用 `ft_stock_candlesticks` 的OHLCV。

主要产物：`index_minute.csv`、`index_15m_features.csv`、`component_capital_flows_15m.csv`、`sector_diffusion.csv`、`research_summary.json`、`data_quality.json` 和 `report.html`。

## 主课题假设

1. 指数15分钟收益、实现波动率和成交额冲击能否识别风险开启、震荡与风险收缩状态。
2. 等权收益与指数权重收益背离是否预示市场扩散或集中化的后续变化。
3. 行业扩散与资金流方向一致时，状态延续概率是否更高。
4. 成交放大但价格不延续时，是否代表短周期过热或反转风险。

至少积累60个交易日后，再做滚动训练、样本外验证、交易成本敏感性和统计显著性检验。首日发现见 `FIRST_FINDINGS_20260715.md`。