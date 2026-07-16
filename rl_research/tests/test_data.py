import pandas as pd
from csi1000_rl.data import normalize_ohlcs,validate_daily_data

def rows():
    return [{"open":"10","high":"11","low":"9","close":"10.5","volume":100,"turnover":"1000","open_ts_ms":"2026-01-02T09:30:00"},{"open":"10.5","high":"12","low":"10","close":"11","volume":120,"turnover":"1300","open_ts_ms":"2026-01-05T09:30:00"}]

def test_backward_contract_and_quality():
    frame=normalize_ohlcs(rows(),"now");result=validate_daily_data(frame);assert result.is_valid;assert frame.adjust_type.eq("Backward").all()

def test_invalid_ohlc_is_rejected():
    frame=normalize_ohlcs(rows(),"now");frame.loc[0,"high_hfq"]=8;assert "invalid_high" in validate_daily_data(frame).errors