from __future__ import annotations
import numpy as np
import pandas as pd

def performance_metrics(returns, positions=None, costs=None, periods=252):
    r=pd.Series(returns,dtype=float).fillna(0); equity=(1+r).cumprod(); years=max(len(r)/periods,1/periods)
    total=float(equity.iloc[-1]-1) if len(equity) else 0.; annual=float((1+total)**(1/years)-1) if total>-1 else -1
    vol=float(r.std(ddof=0)*np.sqrt(periods)); downside=float(r[r<0].std(ddof=0)*np.sqrt(periods)) if (r<0).any() else 0.
    dd=equity/equity.cummax()-1; max_dd=float(dd.min()) if len(dd) else 0.; sharpe=float(r.mean()/r.std(ddof=0)*np.sqrt(periods)) if r.std(ddof=0)>0 else 0.
    sortino=float(r.mean()/r[r<0].std(ddof=0)*np.sqrt(periods)) if downside>0 else 0.
    p=pd.Series(positions,dtype=float) if positions is not None else pd.Series(dtype=float)
    return {"total_return":total,"annual_return":annual,"max_drawdown":max_dd,"sharpe":sharpe,"sortino":sortino,
      "calmar":annual/abs(max_dd) if max_dd<0 else 0.,"annual_volatility":vol,"win_rate":float((r>0).mean()),
      "turnover":float(p.diff().abs().sum()) if len(p) else 0.,"transaction_cost":float(pd.Series(costs,dtype=float).sum()) if costs is not None else 0.,
      "average_exposure":float(p.mean()) if len(p) else 0.}