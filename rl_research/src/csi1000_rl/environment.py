from __future__ import annotations
from typing import Literal
import gymnasium as gym
import numpy as np
import pandas as pd
from gymnasium import spaces
from .features import FEATURE_COLUMNS

class CSI1000TimingEnv(gym.Env):
    metadata = {"render_modes": []}
    def __init__(self, data: pd.DataFrame, action_mode: Literal["continuous", "discrete"] = "continuous",
                 feature_columns=None, transaction_cost_bps=10.0, drawdown_penalty=0.05,
                 turnover_penalty=0.0, initial_equity=1.0, dqn_positions=None):
        super().__init__()
        self.data = data.reset_index(drop=True).copy(); self.features = feature_columns or FEATURE_COLUMNS
        if len(self.data) < 2: raise ValueError("Environment requires at least two observations")
        self.action_mode = action_mode; self.cost_rate = transaction_cost_bps / 10000.0
        self.drawdown_penalty = drawdown_penalty; self.turnover_penalty = turnover_penalty; self.initial_equity = initial_equity
        self.positions = np.asarray(dqn_positions or [0, .25, .5, .75, 1], dtype=np.float32)
        self.action_space = spaces.Box(0, 1, (1,), np.float32) if action_mode == "continuous" else spaces.Discrete(len(self.positions))
        self.observation_space = spaces.Box(-np.inf, np.inf, (len(self.features) + 1,), np.float32)
    def _observation(self):
        values = self.data.loc[self.index, self.features].to_numpy(np.float32)
        return np.concatenate([values, np.asarray([self.position], np.float32)])
    def _position(self, action):
        return float(np.clip(np.asarray(action).reshape(-1)[0], 0, 1)) if self.action_mode == "continuous" else float(self.positions[int(action)])
    def reset(self, seed=None, options=None):
        super().reset(seed=seed); self.index=0; self.position=0.; self.equity=self.initial_equity; self.peak=self.initial_equity; self.total_cost=0.
        return self._observation(), {"equity": self.equity, "position": self.position}
    def step(self, action):
        target = self._position(action); turnover = abs(target-self.position); cost = turnover*self.cost_rate
        market_return = float(self.data.loc[self.index, "next_open_return"]); gross = target*market_return
        prior_equity=self.equity; self.equity *= max(1e-12, 1+gross-cost); self.peak=max(self.peak,self.equity)
        drawdown=max(0.,1-self.equity/self.peak); reward=(self.equity/prior_equity-1)-self.drawdown_penalty*drawdown-self.turnover_penalty*turnover
        self.total_cost += cost; self.position=target
        row=self.data.loc[self.index]; info={"signal_date":str(pd.Timestamp(row.trade_date).date()),"execution_date":str(pd.Timestamp(row.execution_date).date()),
          "exit_date":str(pd.Timestamp(row.exit_date).date()),"position":target,"turnover":turnover,"cost":cost,"market_return":market_return,
          "gross_return":gross,"net_return":self.equity/prior_equity-1,"equity":self.equity,"drawdown":drawdown}
        self.index += 1; terminated=self.index >= len(self.data); truncated=False
        observation=np.zeros(self.observation_space.shape,np.float32) if terminated else self._observation()
        return observation, float(reward), terminated, truncated, info