from __future__ import annotations
import json
from pathlib import Path
from .features import BASE_FEATURES, FEATURE_COLUMNS, TECHNICAL_FEATURES, TURNOVER_FEATURES
from .train import train_algorithm

def run_ablations(scaled, config, output_dir: Path):
    specs={"no_turnover_features":[c for c in FEATURE_COLUMNS if c not in TURNOVER_FEATURES],"no_technical_features":[c for c in FEATURE_COLUMNS if c not in TECHNICAL_FEATURES],"no_drawdown_penalty":FEATURE_COLUMNS}
    original_seeds=config["training"]["seeds"];original_steps=config["training"]["total_timesteps"];config["training"]["seeds"]=[original_seeds[0]];config["training"]["total_timesteps"]=max(20000,original_steps//2);results={}
    try:
        for name,columns in specs.items():
            results[name]=train_algorithm("PPO",scaled.train,scaled.validation,scaled.test,config,output_dir,"ablation_"+name,columns,0.0 if name=="no_drawdown_penalty" else None)
    finally:
        config["training"]["seeds"]=original_seeds;config["training"]["total_timesteps"]=original_steps
    (output_dir/"ablation_results.json").write_text(json.dumps(results,indent=2),encoding="utf-8");return results