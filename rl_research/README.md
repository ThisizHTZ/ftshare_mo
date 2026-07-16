# 中证1000近期市场强化学习择时研究

## 定位

本子项目研究强化学习能否在最近三年的中证1000指数上改善风险暴露控制。它不选择个股，不构成投资建议，也不在未真实运行时展示收益。

## 一键运行

1. 在 Google Colab 打开 `notebooks/csi1000_rl_colab.ipynb`。
2. 依次执行全部单元格。Notebook会安装依赖、仅从FTShare下载 `000852.XSHG` 后复权日线、运行质量门禁、训练PPO/A2C/DQN并生成结果包。
3. 完成结果位于 `artifacts/results/`，并打包为 `csi1000_rl_results.zip`。

## 研究协议

- 最近3年数据：前2年训练，随后6个月验证，最后6个月样本外测试。
- 状态在交易日收盘后形成，动作在下一交易日开盘执行，收益为下一开盘到再下一开盘。
- PPO/A2C输出0到1连续仓位；DQN输出0/25/50/75/100%五档仓位。
- 默认单边成本10bp，另检验0/5/10/20bp。
- 验证集选择随机种子，测试集不参与调参。

## 命令

```bash
pip install -r requirements.txt
pip install -e .
python -m csi1000_rl.pipeline download
python -m csi1000_rl.pipeline train
# 或一次完成
python -m csi1000_rl.pipeline all
pytest -q
```

## 数据与结果诚信

`adjust_type` 必须全部为 `Backward`，否则训练停止。原始响应、大型数据、模型和真实结果不提交Git；仓库默认只有 `NOT_RUN.md`。正式报告必须由Colab真实运行后生成，并包含数据与配置SHA256。

## 目录

- `config/default.yaml`：唯一默认实验配置。
- `src/csi1000_rl/`：下载、质量、特征、环境、训练和报告代码。
- `notebooks/`：Colab一键入口。
- `tests/`：轻量可复现测试。
- `sample_data/`：仅用于测试的合成数据，不代表市场表现。
- `artifacts/`：运行时数据、模型与报告目录。

## 限制

指数本身不可直接交易；成本是假设值；日频样本较少；不同算法动作空间不完全相同；强化学习结果可能对随机种子和市场阶段敏感。任何结论都必须以隔离样本外结果和基准比较为依据。