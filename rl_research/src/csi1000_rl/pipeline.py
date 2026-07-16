from __future__ import annotations
import argparse,json
from pathlib import Path
import joblib
import pandas as pd
from .baselines import baseline_positions,trajectory_from_positions
from .config import config_hash,load_config,resolve_path
from .data import download_index_history,save_validated_data,validate_daily_data
from .features import FEATURE_COLUMNS,add_features,scale_splits,temporal_split
from .metrics import performance_metrics

def download(config,root):
    frame=download_index_history(config,root);quality=save_validated_data(frame,config,root);print(json.dumps({"status":"downloaded",**quality.stats},indent=2))

def run(config,root):
    path=resolve_path(root,config["data"]["processed_path"]);frame=pd.read_csv(path,parse_dates=["trade_date"]);quality=validate_daily_data(frame)
    if not quality.is_valid: raise ValueError(f"Data quality gate failed: {quality.errors}")
    featured=add_features(frame);split=temporal_split(featured,config["split"]["validation_months"],config["split"]["test_months"]);scaled,scaler=scale_splits(split)
    output=resolve_path(root,config["report"]["output_dir"]);output.mkdir(parents=True,exist_ok=True);joblib.dump(scaler,output/"feature_scaler.joblib")
    manifest={"train_end":str(split.train_end.date()),"validation_end":str(split.validation_end.date()),"feature_columns":FEATURE_COLUMNS,"data_sha256":quality.stats["sha256"],"config_sha256":config_hash(config)};(output/"run_manifest.json").write_text(json.dumps(manifest,indent=2),encoding="utf-8")
    results,trajectories={},{}
    from .train import train_algorithm
    for algorithm in config["training"]["algorithms"]:
        results[algorithm]=train_algorithm(algorithm,scaled.train,scaled.validation,scaled.test,config,output);trajectories[algorithm]=pd.read_csv(output/algorithm.lower()/"test_trajectory.csv")
    for name,positions in baseline_positions(split.test).items():
        trajectory=trajectory_from_positions(split.test,positions,config["environment"]["transaction_cost_bps"]);trajectories[name]=trajectory;results[name]=performance_metrics(trajectory.net_return,trajectory.position,trajectory.cost);trajectory.to_csv(output/f"baseline_{name}.csv",index=False)
    if config["training"].get("run_ablations"):
        from .ablations import run_ablations
        results["ablations"]={"status":"completed","experiments":run_ablations(scaled,config,output)}
    from .report import write_report
    write_report(results,trajectories,output,quality.stats["sha256"],config_hash(config))

def main():
    parser=argparse.ArgumentParser();parser.add_argument("command",choices=["download","train","all"]);parser.add_argument("--config",default="config/default.yaml");args=parser.parse_args();root=Path(__file__).resolve().parents[2];config=load_config(root/args.config)
    if args.command in ("download","all"): download(config,root)
    if args.command in ("train","all"): run(config,root)
if __name__=="__main__": main()