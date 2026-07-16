from __future__ import annotations
import html,json
from pathlib import Path
import matplotlib.pyplot as plt

def write_report(results,trajectories,output_dir:Path,data_hash,config_hash):
    output_dir.mkdir(parents=True,exist_ok=True);chart=output_dir/"equity_curves.png";plt.figure(figsize=(11,5))
    for name,frame in trajectories.items(): plt.plot(frame["signal_date"],frame["equity"],label=name)
    plt.title("Out-of-sample equity curves");plt.xlabel("Signal date");plt.ylabel("Equity");plt.legend();plt.grid(alpha=.2);plt.tight_layout();plt.savefig(chart,dpi=150);plt.close()
    keys=["total_return","annual_return","max_drawdown","sharpe","sortino","turnover","transaction_cost"];rows=[]
    for name,result in results.items():
        if name == "ablations": continue
        m=result.get("test",result);rows.append("<tr><td>"+html.escape(name)+"</td>"+"".join(f"<td>{m.get(k,0):.4f}</td>" for k in keys)+"</tr>")
    page=f'''<!doctype html><html><meta charset="utf-8"><title>CSI 1000 RL Research</title><style>body{{font-family:Arial,"Microsoft YaHei";max-width:1100px;margin:auto;padding:28px;color:#1c2734}}table{{border-collapse:collapse;width:100%}}th,td{{padding:9px;border-bottom:1px solid #ddd;text-align:right}}th:first-child,td:first-child{{text-align:left}}img{{max-width:100%}}.tag{{padding:8px;background:#eef5f1;border-left:4px solid #287a55}}</style><h1>中证1000强化学习择时研究</h1><p class="tag">状态：真实运行完成。研究指数风险暴露，不构成投资建议。</p><p>Data SHA256: {data_hash}<br>Config SHA256: {config_hash}</p><table><tr><th>模型</th><th>总收益</th><th>年化</th><th>最大回撤</th><th>夏普</th><th>Sortino</th><th>换手</th><th>成本</th></tr>{''.join(rows)}</table><h2>样本外净值</h2><img src="equity_curves.png"><p>PPO/A2C使用连续仓位，DQN使用五档仓位，横向比较并非完全同构。</p></html>'''
    (output_dir/"report_zh.html").write_text(page,encoding="utf-8");(output_dir/"report_en.html").write_text(page.replace("中证1000强化学习择时研究","CSI 1000 Reinforcement-Learning Timing Research").replace("状态：真实运行完成。研究指数风险暴露，不构成投资建议。","Status: completed with a real run. Index exposure research only; not investment advice."),encoding="utf-8");(output_dir/"results.json").write_text(json.dumps(results,indent=2),encoding="utf-8")