from __future__ import annotations
import numpy as np
import pandas as pd

def baseline_positions(data):
    close=data["close_hfq"]
    return {"buy_hold":np.ones(len(data)),"cash":np.zeros(len(data)),"fixed_50":np.full(len(data),.5),"ma20_timing":(close>close.rolling(20,min_periods=1).mean()).astype(float).to_numpy(),"momentum20_timing":(close.pct_change(20).fillna(0)>0).astype(float).to_numpy()}

def trajectory_from_positions(data,positions,transaction_cost_bps=10):
    positions=np.asarray(positions,float);turnover=np.abs(np.diff(np.r_[0.,positions]));costs=turnover*transaction_cost_bps/10000;returns=positions*data["next_open_return"].to_numpy()-costs;equity=np.cumprod(1+returns)
    return pd.DataFrame({"signal_date":data.trade_date,"position":positions,"market_return":data.next_open_return,"turnover":turnover,"cost":costs,"net_return":returns,"equity":equity})