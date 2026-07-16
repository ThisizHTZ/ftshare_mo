import numpy as np
import pandas as pd
from csi1000_rl.features import add_features,temporal_split,scale_splits,FEATURE_COLUMNS

def frame(n=800):
    d=pd.bdate_range("2023-01-02",periods=n);x=np.arange(n);o=100+x*.02;return pd.DataFrame({"trade_date":d,"open_hfq":o,"high_hfq":o*1.01,"low_hfq":o*.99,"close_hfq":o*(1+.002*np.sin(x/7)),"volume":1e8+x*1000,"turnover":1e9+x*10000,"adjust_type":"Backward","source":"FTShare"})

def test_next_open_execution_is_lagged():
    raw=frame();featured=add_features(raw);row=featured.iloc[0];i=raw.index[raw.trade_date.eq(row.trade_date)][0];expected=raw.open_hfq.iloc[i+2]/raw.open_hfq.iloc[i+1]-1;assert abs(row.next_open_return-expected)<1e-12;assert row.execution_date==raw.trade_date.iloc[i+1]

def test_scaler_fits_train_only():
    split=temporal_split(add_features(frame()));scaled,scaler=scale_splits(split);assert len(scaler.mean_)==len(FEATURE_COLUMNS);assert scaled.train.trade_date.max()<scaled.validation.trade_date.min();assert scaled.validation.trade_date.max()<scaled.test.trade_date.min()