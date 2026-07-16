# CSI 1000 Recent-Market Reinforcement-Learning Timing Research

This subproject studies whether reinforcement learning improves daily CSI 1000 index exposure control over the most recent three years. It does not select stocks, provide investment advice, or publish performance before a real run.

## Colab workflow

Open `notebooks/csi1000_rl_colab.ipynb` in Google Colab and run all cells. It installs dependencies, downloads only FTShare `000852.XSHG` Backward-adjusted daily bars, enforces the data-quality gate, trains PPO/A2C/DQN, evaluates isolated out-of-sample results, and creates `csi1000_rl_results.zip`.

## Protocol

- First two years train, next six months validate, final six months test.
- State is formed after day t closes; the action executes at the next open and earns the following open-to-open return.
- PPO/A2C use continuous [0,1] exposure; DQN uses 0/25/50/75/100% exposure.
- Default one-way cost is 10 bps, with 0/5/10/20 bps sensitivity.
- Validation selects the seed; test data never tunes the model.

## Commands

```bash
pip install -r requirements.txt
pip install -e .
python -m csi1000_rl.pipeline all
pytest -q
```

All real data, models, and generated results are ignored by Git. A completed report can only be produced by a successful real Colab run and includes data/config SHA256 identifiers. See `README.md` for the full Chinese guide.