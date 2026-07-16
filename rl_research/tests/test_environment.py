import numpy as np
from csi1000_rl.environment import CSI1000TimingEnv
from csi1000_rl.features import FEATURE_COLUMNS
from test_features import frame
from csi1000_rl.features import add_features

def data():
    d=add_features(frame(120));d.loc[:,FEATURE_COLUMNS]=0.;return d

def test_continuous_action_cost_and_dates():
    env=CSI1000TimingEnv(data(),transaction_cost_bps=10,drawdown_penalty=0);env.reset(seed=1);_,_,_,_,info=env.step(np.array([.5],dtype=np.float32));assert abs(info["cost"]-.0005)<1e-12;assert info["signal_date"]<info["execution_date"]<info["exit_date"]

def test_dqn_positions():
    env=CSI1000TimingEnv(data(),action_mode="discrete");env.reset();*_,info=env.step(3);assert info["position"]==.75