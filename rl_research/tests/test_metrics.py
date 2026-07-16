from csi1000_rl.metrics import performance_metrics

def test_metrics_are_recomputable():
    m=performance_metrics([.01,-.02,.03],[0,.5,1],[0,.001,.001]);assert set(["total_return","max_drawdown","sharpe","turnover","transaction_cost"]).issubset(m);assert m["transaction_cost"]==.002