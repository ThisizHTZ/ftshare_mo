from __future__ import annotations
import json,random
from pathlib import Path
import numpy as np
import pandas as pd
from stable_baselines3 import A2C,DQN,PPO
from .environment import CSI1000TimingEnv
from .metrics import performance_metrics
ALGORITHMS={"PPO":PPO,"A2C":A2C,"DQN":DQN}

def make_env(data,algorithm,config,cost_bps=None,drawdown_penalty=None,feature_columns=None):
    e=config["environment"]
    return CSI1000TimingEnv(data,"discrete" if algorithm=="DQN" else "continuous",feature_columns=feature_columns,transaction_cost_bps=e["transaction_cost_bps"] if cost_bps is None else cost_bps,drawdown_penalty=e["drawdown_penalty"] if drawdown_penalty is None else drawdown_penalty,turnover_penalty=e["turnover_penalty"],initial_equity=e["initial_equity"],dqn_positions=config["training"]["dqn_positions"])

def evaluate_model(model,env):
    obs,_=env.reset();rows=[];done=False
    while not done:
        action,_=model.predict(obs,deterministic=True);obs,_,terminated,truncated,info=env.step(action);rows.append(info);done=terminated or truncated
    frame=pd.DataFrame(rows);return frame,performance_metrics(frame.net_return,frame.position,frame.cost)

def train_algorithm(algorithm,train_data,validation_data,test_data,config,output_dir:Path,experiment_name=None,feature_columns=None,drawdown_penalty=None):
    target=output_dir/(experiment_name or algorithm.lower());target.mkdir(parents=True,exist_ok=True);candidates=[]
    for seed in config["training"]["seeds"]:
        random.seed(seed);np.random.seed(seed);env=make_env(train_data,algorithm,config,drawdown_penalty=drawdown_penalty,feature_columns=feature_columns);model=ALGORITHMS[algorithm]("MlpPolicy",env,seed=seed,verbose=0);model.learn(total_timesteps=int(config["training"]["total_timesteps"]));vf,vm=evaluate_model(model,make_env(validation_data,algorithm,config,drawdown_penalty=drawdown_penalty,feature_columns=feature_columns));model.save(target/f"seed_{seed}");vf.to_csv(target/f"validation_seed_{seed}.csv",index=False);candidates.append((vm["sharpe"],seed,model,vm))
    _,best_seed,best_model,val_metrics=max(candidates,key=lambda x:x[0]);tf,tm=evaluate_model(best_model,make_env(test_data,algorithm,config,drawdown_penalty=drawdown_penalty,feature_columns=feature_columns));tf.to_csv(target/"test_trajectory.csv",index=False);sensitivity={}
    for bps in config["training"]["sensitivity_cost_bps"]: sensitivity[str(bps)]=evaluate_model(best_model,make_env(test_data,algorithm,config,cost_bps=bps,drawdown_penalty=drawdown_penalty,feature_columns=feature_columns))[1]
    result={"status":"completed","algorithm":algorithm,"best_seed":best_seed,"validation":val_metrics,"test":tm,"cost_sensitivity":sensitivity};(target/"metrics.json").write_text(json.dumps(result,indent=2),encoding="utf-8");return result