param(
    [string]$DailyDir = "C:\ftshare_data\daily_intraday_summary\20260716_100619",
    [string]$MarketDir = "C:\ftshare_data\market_state_research\20260716_20260716_101206",
    [string]$FundamentalDir = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $OutputPath) {
    $OutputPath = Join-Path $DailyDir "integrated_research_dashboard.html"
}

function Read-JsonFile([string]$Path) {
    if (Test-Path $Path) {
        return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $null
}

function To-Number($Value) {
    if ($null -eq $Value -or $Value -eq "") { return $null }
    $n = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $n
    }
    return $null
}

function Pick-Rows($Rows, [string]$SortField, [int]$Count = 20, [switch]$Descending) {
    $sorted = $Rows | Sort-Object @{ Expression = { To-Number $_.$SortField }; Descending = [bool]$Descending }
    return @($sorted | Select-Object -First $Count)
}

function Trim-SignalRows($Rows) {
    return @($Rows | ForEach-Object {
        [pscustomobject]@{
            symbol = $_.symbol
            name = $_.component_name
            sector = $_.sw_level1_name
            close = To-Number $_.close
            change_rate = To-Number $_.change_rate
            return_5m = To-Number $_.return_5m
            turnover_delta_5m = To-Number $_.turnover_delta_5m
            resonance_score_5m = To-Number $_.resonance_score_5m
            risk_score_5m = To-Number $_.risk_score_5m
            weighted_change_contribution = To-Number $_.weighted_change_contribution
            composite_score = To-Number $_.composite_score
            prediction_label = $_.prediction_label
            reason = $_.reason
        }
    })
}

$daily = Read-JsonFile (Join-Path $DailyDir "daily_analysis.json")
$summary = Read-JsonFile (Join-Path $DailyDir "summary.json")
$quality = Read-JsonFile (Join-Path $DailyDir "data_quality.json")
$marketSummary = Read-JsonFile (Join-Path $MarketDir "research_summary.json")
$marketQuality = Read-JsonFile (Join-Path $MarketDir "data_quality.json")

$signals = Import-Csv -Path (Join-Path $DailyDir "latest_signals.csv") -Encoding UTF8
$sectors = Import-Csv -Path (Join-Path $DailyDir "sector_rotation.csv") -Encoding UTF8
$indexMinutePath = Join-Path $MarketDir "index_minute.csv"
if (-not (Test-Path $indexMinutePath)) { $indexMinutePath = Join-Path $DailyDir "index_minutes_ftshare.csv" }
$minutes = Import-Csv -Path $indexMinutePath -Encoding UTF8

$sectorRows = @($sectors | ForEach-Object {
    [pscustomobject]@{
        name = $_.sw_level1_name
        count = To-Number $_.component_count
        avg_change_rate = To-Number $_.avg_change_rate
        turnover_delta_sum = To-Number $_.turnover_delta_sum
        avg_interval_return = To-Number $_.avg_interval_return
        weighted_contribution_sum = To-Number $_.weighted_contribution_sum
        strong_count = To-Number $_.strong_count
        risk_count = To-Number $_.risk_count
        sector_score = To-Number $_.sector_score
    }
})

$minuteRows = @($minutes | ForEach-Object {
    [pscustomobject]@{
        time = if ($_.bar_end) { $_.bar_end } elseif ($_.minute_time) { $_.minute_time } elseif ($_.time) { $_.time } elseif ($_.ts_millis) { $_.ts_millis } else { $_.trade_time }
        open = To-Number $_.open
        high = To-Number $_.high
        low = To-Number $_.low
        close = To-Number $_.close
        volume = To-Number $_.volume
        turnover = To-Number $_.turnover
    }
})

function Count-Where($Rows, [scriptblock]$Block) {
    return @($Rows | Where-Object $Block).Count
}

function Trim-ExplainRows($Rows, [int]$Count = 80) {
    return @($Rows | Sort-Object @{ Expression = { To-Number $_.explain_score }; Descending = $true } | Select-Object -First $Count | ForEach-Object {
        [pscustomobject]@{
            symbol = $_.symbol
            name = $_.component_name
            sector = $_.sw_level1_name
            change_rate = To-Number $_.change_rate
            return_5m = To-Number $_.return_5m
            resonance_score_5m = To-Number $_.resonance_score_5m
            risk_score_5m = To-Number $_.risk_score_5m
            fundamental_quality_flag = $_.fundamental_quality_flag
            valuation_bucket = $_.valuation_bucket
            event_tags = $_.event_tags
            matched_topics = $_.matched_topics
            sentiment_rule = $_.sentiment_rule
            attention_bucket = $_.attention_bucket
            explain_score = To-Number $_.explain_score
            explain_label = $_.explain_label
            explain_confidence = $_.explain_confidence
        }
    })
}
if (-not $FundamentalDir) {
    $latestFundamental = Get-ChildItem -Path "C:\ftshare_data\fundamental_nlp" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "fundamental_nlp_summary.json") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestFundamental) { $FundamentalDir = $latestFundamental.FullName }
}
$fundamentalSummary = $null
$explainRows = @()
$explainSectorRows = @()
$explainPayload = $null
if ($FundamentalDir -and (Test-Path (Join-Path $FundamentalDir "fundamental_nlp_summary.json"))) {
    $fundamentalSummary = Read-JsonFile (Join-Path $FundamentalDir "fundamental_nlp_summary.json")
    $datasetPath = Join-Path $FundamentalDir "intraday_explain_dataset.csv"
    if (Test-Path $datasetPath) {
        $explainDataset = Import-Csv -Path $datasetPath -Encoding UTF8
        $explainRows = Trim-ExplainRows $explainDataset 80
        $explainSectorRows = @($explainDataset | Group-Object sw_level1_name | ForEach-Object {
            $scores = @($_.Group | ForEach-Object { To-Number $_.explain_score } | Where-Object { $null -ne $_ })
            [pscustomobject]@{
                sector = $_.Name
                count = $_.Count
                avg_explain = if ($scores.Count) { ($scores | Measure-Object -Average).Average } else { $null }
                fundamental_count = Count-Where $_.Group { $_.fundamental_quality_flag -eq "稳健" }
                news_count = Count-Where $_.Group { $_.news_catalyst_score -gt 0 }
                attention_count = Count-Where $_.Group { $_.attention_bucket -eq "高" }
                risk_count = Count-Where $_.Group { $_.explain_label -match "风险解释" }
            }
        } | Sort-Object avg_explain -Descending)
        $explainPayload = [pscustomobject]@{
            summary = $fundamentalSummary
            rows = $explainRows
            sectors = $explainSectorRows
            report = Join-Path $FundamentalDir "fundamental_nlp_report.html"
        }
    }
}
$payload = [pscustomobject]@{
    generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    daily = $daily
    summary = $summary
    quality = $quality
    market_summary = $marketSummary
    market_quality = $marketQuality
    fundamental_explain = $explainPayload
    sectors = @($sectorRows | Sort-Object sector_score -Descending)
    index_minutes = $minuteRows
    rankings = [pscustomobject]@{
        speed = Trim-SignalRows (Pick-Rows $signals "return_5m" 20 -Descending)
        turnover = Trim-SignalRows (Pick-Rows $signals "turnover_delta_5m" 20 -Descending)
        resonance = Trim-SignalRows (Pick-Rows $signals "resonance_score_5m" 20 -Descending)
        strength = Trim-SignalRows (Pick-Rows $signals "change_rate" 20 -Descending)
        contribution = Trim-SignalRows (Pick-Rows $signals "weighted_change_contribution" 20 -Descending)
        risk = Trim-SignalRows (Pick-Rows $signals "risk_score_5m" 20 -Descending)
        composite = Trim-SignalRows (Pick-Rows $signals "composite_score" 20 -Descending)
    }
    source_files = [pscustomobject]@{
        six_rank_dashboard = Join-Path $DailyDir "dashboard.html"
        narrative_report = Join-Path $DailyDir "morning_complete_report.html"
        market_state_report = Join-Path $MarketDir "report.html"
        data_manifest = Join-Path $DailyDir "report_manifest.json"
        fundamental_nlp_report = if ($FundamentalDir) { Join-Path $FundamentalDir "fundamental_nlp_report.html" } else { "" }
    }
}

$json = $payload | ConvertTo-Json -Depth 8 -Compress
$safeJson = $json.Replace("</script", "<\/script")

$html = @'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>2026-07-16 上午中证1000盘中研究台</title>
<style>
:root{--bg:#eef2f6;--panel:#fff;--panel2:#f8fafc;--text:#172033;--muted:#697586;--line:#d8e0ea;--line2:#edf1f6;--accent:#1d5f8f;--accent2:#0f766e;--up:#b42318;--down:#087443;--warn:#b54708;--shadow:0 16px 38px rgba(21,31,47,.08)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:"Microsoft YaHei UI","Microsoft YaHei",Arial,sans-serif;font-size:14px;letter-spacing:0}
body:before{content:"";position:fixed;inset:0 0 auto 0;height:220px;background:linear-gradient(180deg,#dbe7f1 0%,rgba(219,231,241,0) 100%);pointer-events:none;z-index:-1}
header{padding:20px 28px 14px;border-bottom:1px solid rgba(216,224,234,.86);background:rgba(255,255,255,.92);position:sticky;top:0;z-index:5;backdrop-filter:blur(14px)}
.titlebar{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;max-width:1440px;margin:0 auto}.brand{min-width:0}
h1{margin:0 0 8px;font-size:22px;font-weight:700;letter-spacing:0}.sub{color:var(--muted);line-height:1.7}
.status-strip{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end}.status-chip{border:1px solid var(--line);background:var(--panel2);border-radius:999px;padding:6px 10px;color:var(--muted);font-size:12px;white-space:nowrap}.status-chip strong{color:var(--text);font-weight:700}
.tabs{display:flex;gap:6px;flex-wrap:wrap;margin:15px auto 0;max-width:1440px;padding:5px;background:#e8edf3;border:1px solid #dbe3ed;border-radius:8px}.tabs button{border:0;background:transparent;color:#435064;padding:8px 11px;border-radius:6px;cursor:pointer;font-weight:600;line-height:1}.tabs button:hover{background:rgba(255,255,255,.72)}.tabs button.active{background:#fff;color:var(--accent);box-shadow:0 1px 3px rgba(21,31,47,.09)}
main{padding:22px 28px 38px;max-width:1440px;margin:0 auto}.view{display:none}.view.active{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px;margin-bottom:18px}.card{background:var(--panel);border:1px solid var(--line2);border-radius:8px;padding:15px 16px;box-shadow:var(--shadow)}.label{color:var(--muted);font-size:12px}.value{font-size:24px;font-weight:750;margin-top:7px;line-height:1.1}.note{color:var(--muted);line-height:1.7}
.split{display:grid;grid-template-columns:minmax(0,1.12fr) minmax(340px,.88fr);gap:16px}.wide{overflow:auto;border-radius:8px}svg{width:100%;height:auto;display:block}.chartbox{background:var(--panel);border:1px solid var(--line2);border-radius:8px;padding:15px 16px;margin-bottom:16px;box-shadow:var(--shadow)}
table{width:100%;border-collapse:separate;border-spacing:0;background:var(--panel);border:1px solid var(--line2);border-radius:8px;overflow:hidden;box-shadow:var(--shadow)}th,td{border-bottom:1px solid var(--line2);padding:9px 10px;text-align:right;white-space:nowrap}tbody tr:hover{background:#f8fafc}tbody tr:last-child td{border-bottom:0}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2),th:nth-child(3),td:nth-child(3){text-align:left}th{font-weight:700;color:#536176;background:#f5f7fa;position:sticky;top:0}.pos{color:var(--up);font-weight:650}.neg{color:var(--down);font-weight:650}.pill{display:inline-flex;align-items:center;border:1px solid var(--line);border-radius:999px;padding:3px 9px;color:var(--muted);font-size:12px;background:#fff}.section-title{display:flex;align-items:end;justify-content:space-between;gap:12px;margin:18px 0 10px}h2{font-size:17px;margin:0;font-weight:750}select{padding:8px 32px 8px 10px;border:1px solid var(--line);border-radius:8px;background:#fff;color:var(--text);font-weight:600}.bar-row{display:grid;grid-template-columns:98px 1fr 82px;gap:9px;align-items:center;margin:8px 0}.bar-track{height:10px;background:#edf2f7;border-radius:999px;overflow:hidden}.bar-fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2));border-radius:999px}.small{font-size:12px;color:var(--muted)}.warn{color:var(--warn)}
@media(max-width:900px){header,main{padding-left:14px;padding-right:14px}.titlebar{display:block}.status-strip{justify-content:flex-start;margin-top:10px}.split{grid-template-columns:1fr}th,td{padding:8px 7px}.hide-sm{display:none}.tabs{overflow-x:auto;flex-wrap:nowrap}.tabs button{white-space:nowrap}}
</style>
</head>
<body>
<header>
  <div class="titlebar">
    <div class="brand">
      <h1>2026-07-16 上午中证1000盘中研究台</h1>
      <div class="sub" id="headline"></div>
    </div>
    <div class="status-strip" id="statusStrip"></div>
  </div>
  <div class="tabs" role="tablist" aria-label="报告模块">
    <button type="button" class="active" data-view="overview">总览</button>
    <button type="button" data-view="market">指数分钟</button>
    <button type="button" data-view="sector">板块轮动</button>
    <button type="button" data-view="rankings">六大榜单</button>
    <button type="button" data-view="research">研究解释</button>
    <button type="button" data-view="explain-overview">解释总览</button>
    <button type="button" data-view="event-nlp">事件NLP</button>
    <button type="button" data-view="cross-research">交叉研究</button>
    <button type="button" data-view="quality">数据可信度</button>
  </div>
</header>
<main>
  <section id="overview" class="view active"></section>
  <section id="market" class="view"></section>
  <section id="sector" class="view"></section>
  <section id="rankings" class="view"></section>
  <section id="research" class="view"></section>
  <section id="explain-overview" class="view"></section>
  <section id="event-nlp" class="view"></section>
  <section id="cross-research" class="view"></section>
  <section id="quality" class="view"></section>
</main>
<script id="dashboard-data" type="application/json">__DATA_JSON__</script>
<script>
const DATA = JSON.parse(document.getElementById('dashboard-data').textContent);
const fmtPct=v=>v==null?'--':(v*100).toFixed(2)+'%';
const fmtNum=v=>v==null?'--':Number(v).toLocaleString('zh-CN',{maximumFractionDigits:2});
const fmtBn=v=>v==null?'--':(v/1e8).toLocaleString('zh-CN',{maximumFractionDigits:2})+'亿';
const cls=v=>v>0?'pos':v<0?'neg':'';
const coverage=q=>q?.field_coverage?.overall ?? q?.field_coverage ?? null;
function esc(s){return String(s??'--').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));}
function stat(label,value,note){return `<div class="card"><div class="label">${label}</div><div class="value">${value}</div><div class="note">${note||''}</div></div>`}
function rows(items, scoreField){
  return items.map((r,i)=>`<tr><td>${i+1}</td><td>${esc(r.name)}</td><td>${esc(r.symbol)}</td><td>${esc(r.sector)}</td><td>${fmtNum(r.close)}</td><td class="${cls(r.change_rate)}">${fmtPct(r.change_rate)}</td><td class="${cls(r.return_5m)}">${fmtPct(r.return_5m)}</td><td>${fmtBn(r.turnover_delta_5m)}</td><td class="${cls(r[scoreField])}">${fmtNum(r[scoreField])}</td></tr>`).join('');
}
function table(title, items, scoreField, scoreName){
  return `<div class="section-title"><h2>${title}</h2><span class="pill">Top ${items.length}</span></div><div class="wide"><table><thead><tr><th>#</th><th>名称</th><th>代码</th><th>行业</th><th>现价</th><th>当日</th><th>相邻快照</th><th>成交额增量</th><th>${scoreName}</th></tr></thead><tbody>${rows(items,scoreField)}</tbody></table></div>`;
}
function lineChart(points){
  const w=880,h=280,p=42; const vals=points.map(d=>d.close).filter(v=>v!=null); if(!vals.length)return '<div class="card">指数分钟线暂无数据</div>';
  const min=Math.min(...vals), max=Math.max(...vals), span=max-min||1;
  const path=points.map((d,i)=>{const x=p+i*(w-2*p)/Math.max(points.length-1,1); const y=h-p-(d.close-min)/span*(h-2*p); return (i?'L':'M')+x.toFixed(1)+','+y.toFixed(1)}).join(' ');
  const last=points[points.length-1], first=points[0];
  return `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="中证1000指数上午分钟线"><line x1="${p}" y1="${h-p}" x2="${w-p}" y2="${h-p}" stroke="#d9dee7"/><line x1="${p}" y1="${p}" x2="${p}" y2="${h-p}" stroke="#d9dee7"/><path d="${path}" fill="none" stroke="#2563eb" stroke-width="2"/><text x="${p}" y="24" fill="#667085">开端 ${fmtNum(first.close)}</text><text x="${w-p-150}" y="24" fill="#667085">最新 ${fmtNum(last.close)}</text><text x="${p}" y="${h-10}" fill="#667085">${esc(first.time)}</text><text x="${w-p-170}" y="${h-10}" fill="#667085">${esc(last.time)}</text></svg>`;
}
function sectorBars(items){
  const top=items.slice(0,16); const max=Math.max(...top.map(d=>Math.abs(d.sector_score)||0),1);
  return top.map(d=>`<div class="bar-row"><div>${esc(d.name)}</div><div class="bar-track"><div class="bar-fill" style="width:${Math.max(2,Math.abs(d.sector_score)/max*100)}%"></div></div><div class="${cls(d.avg_change_rate)}">${fmtPct(d.avg_change_rate)}</div></div>`).join('');
}
function renderOverview(){
  const d=DATA.daily, m=DATA.market_summary, q=DATA.quality;
  document.getElementById('headline').innerHTML=`生成时间 ${esc(DATA.generated_at)} · 最新快照 ${esc(q?.snapshot_time||'--')} · 本页为研究观察，不是选股建议`;
  const explain=DATA.fundamental_explain?.summary;
  document.getElementById('statusStrip').innerHTML=`<span class="status-chip">市场 <strong>${esc(m?.state||'--')}</strong></span><span class="status-chip">字段覆盖 <strong>${fmtPct(coverage(q))}</strong></span><span class="status-chip">有效变化 <strong>${fmtPct(q.changed_symbol_ratio)}</strong></span><span class="status-chip">解释层 <strong>${explain?fmtPct(explain.fundamental_coverage):'--'}</strong></span>`;
  document.getElementById('overview').innerHTML=`<div class="grid">
    ${stat('上涨 / 下跌 / 平盘',`${d.up_count} / ${d.down_count} / ${d.flat_count}`,'中证1000成分股内部宽度')}
    ${stat('平均涨跌幅',fmtPct(d.avg_change_rate),'等权口径')}
    ${stat('近似权重贡献',fmtPct(m.weighted_return_approx),'用当前权重粗估')}
    ${stat('成交额合计',fmtBn(d.total_turnover),'成分股累计成交额')}
    ${stat('有效变化比例',fmtPct(q.changed_symbol_ratio),'质量门禁用于避免全零伪信号')}
    ${stat('板块扩散',`${m.positive_sector_count}/${m.sector_count}`,fmtPct(m.sector_diffusion))}
  </div><div class="split"><div class="chartbox"><h2>指数上午路径</h2>${lineChart(DATA.index_minutes)}</div><div class="chartbox"><h2>强势板块前列</h2>${sectorBars(DATA.sectors)}</div></div>
  <div class="grid">${stat('高综合分样本',d.strong_observe_count,'仅作研究标签')}${stat('放量异动样本',d.volume_abnormal_count,'成交额放大与短周期收益组合')}${stat('负向放量样本',d.risk_warning_count,'下跌与成交活跃度组合')}</div>`;
}
function renderMarket(){
  document.getElementById('market').innerHTML=`<div class="chartbox"><h2>中证1000指数分钟线</h2>${lineChart(DATA.index_minutes)}</div><div class="card note">上午主升段集中在 09:45-09:59，10:00 后继续偏强但斜率放缓。当前分钟数据截至约 10:12，因此这是上午进行中报告，不是 11:30 完整上午收盘版。</div>`;
}
function renderSector(){
  const rows=DATA.sectors.map((d,i)=>`<tr><td>${i+1}</td><td>${esc(d.name)}</td><td>${fmtNum(d.count)}</td><td class="${cls(d.avg_change_rate)}">${fmtPct(d.avg_change_rate)}</td><td>${fmtBn(d.turnover_delta_sum)}</td><td class="${cls(d.avg_interval_return)}">${fmtPct(d.avg_interval_return)}</td><td>${fmtNum(d.strong_count)}</td><td>${fmtNum(d.risk_count)}</td><td>${fmtNum(d.sector_score)}</td></tr>`).join('');
  document.getElementById('sector').innerHTML=`<div class="chartbox"><h2>板块轮动强度</h2>${sectorBars(DATA.sectors)}</div><div class="wide"><table><thead><tr><th>#</th><th>申万一级</th><th>成分数</th><th>平均涨跌</th><th>成交额增量</th><th>短周期收益</th><th>强势</th><th>风险</th><th>行业分</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}
function renderRankings(){
  const map={speed:['涨速榜','return_5m','相邻快照收益'],turnover:['成交额增量榜','turnover_delta_5m','成交额增量'],resonance:['量价共振榜','resonance_score_5m','共振分'],strength:['当日强势榜','change_rate','当日涨跌'],contribution:['权重贡献榜','weighted_change_contribution','贡献度'],risk:['风险预警榜','risk_score_5m','风险分']};
  const controls=`<div class="section-title"><h2>六大榜单</h2><select id="rankSelect">${Object.keys(map).map(k=>`<option value="${k}">${map[k][0]}</option>`).join('')}</select></div><div id="rankBox"></div>`;
  document.getElementById('rankings').innerHTML=controls;
  const draw=()=>{const k=document.getElementById('rankSelect').value; document.getElementById('rankBox').innerHTML=table(map[k][0],DATA.rankings[k],map[k][1],map[k][2]);};
  document.getElementById('rankSelect').addEventListener('change',draw); draw();
}
function renderResearch(){
  const top=DATA.rankings.composite.slice(0,10).map((r,i)=>`<tr><td>${i+1}</td><td>${esc(r.name)}</td><td>${esc(r.sector)}</td><td>${fmtNum(r.composite_score)}</td><td>${esc(r.prediction_label)}</td><td>${esc(r.reason)}</td></tr>`).join('');
  document.getElementById('research').innerHTML=`<div class="grid">${stat('研究问题','上午盘中结构','宽度、轮动、量价变化是否一致')}${stat('核心口径','信号观察','不输出确定性买卖判断')}${stat('当前结论','震荡中略强','电子、通信、计算机更强，传统周期偏弱')}</div><div class="card note">本页把“涨速、成交额增量、量价共振、当日强弱、贡献度、风险预警”作为金融工程研究变量。后续更适合做横截面分层收益、Rank IC、板块扩散与指数分钟状态的关系检验，而不是把单次榜单当作个股推荐。</div><div class="section-title"><h2>综合观察样本</h2><span class="pill">Top 10</span></div><div class="wide"><table><thead><tr><th>#</th><th>名称</th><th>行业</th><th>综合分</th><th>标签</th><th>原因</th></tr></thead><tbody>${top}</tbody></table></div>`;
}
function explainMissing(id){document.getElementById(id).innerHTML='<div class="card note">基本面/NLP解释层数据不可用。请先运行 build_fundamental_nlp_explain_report.ps1。</div>'}
function renderExplainOverview(){
  const e=DATA.fundamental_explain; if(!e){explainMissing('explain-overview');return;} const s=e.summary;
  document.getElementById('explain-overview').innerHTML=`<div class="grid">${stat('输入样本',s.input_rows,'保留盘中信号主键')}${stat('异动样本池',s.candidate_count,'事件和新闻定向查询')}${stat('基本面覆盖',fmtPct(s.fundamental_coverage),'最近可得估值日 '+esc(s.valuation_date_used))}${stat('新闻覆盖',fmtPct(s.news_coverage),'最近半个月语义搜索')}${stat('关注度覆盖',fmtPct(s.attention_coverage),'热度榜/千股千评映射')}${stat('基本面支撑',s.fundamental_support_count,'稳健质量标签')}</div><div class="split"><div class="chartbox"><h2>行业解释强度</h2>${sectorExplainBars(e.sectors)}</div><div class="chartbox"><h2>解释来源</h2>${sourceBars(s)}</div></div><div class="card note">该模块只解释盘中异动的可能来源，不输出确定性预测或个股建议。缺失代表接口未返回或未查询，不代表事件不存在。</div>`;
}
function sourceBars(s){const items=[['基本面支撑',s.fundamental_support_count],['事件/新闻催化',s.event_catalyst_count],['关注度驱动',s.attention_driven_count],['风险解释',s.risk_explain_count]];const max=Math.max(1,...items.map(x=>x[1]||0));return items.map(x=>`<div class="bar-row"><div>${esc(x[0])}</div><div class="bar-track"><div class="bar-fill" style="width:${Math.max(2,(x[1]||0)/max*100)}%"></div></div><div>${fmtNum(x[1])}</div></div>`).join('')}
function sectorExplainBars(items){const top=(items||[]).slice(0,16);const max=Math.max(1,...top.map(x=>Math.abs(x.avg_explain||0)));return top.map(d=>`<div class="bar-row"><div>${esc(d.sector)}</div><div class="bar-track"><div class="bar-fill" style="width:${Math.max(2,Math.abs(d.avg_explain||0)/max*100)}%"></div></div><div>${fmtNum(d.avg_explain)}</div></div>`).join('')}
function renderEventNlp(){
  const e=DATA.fundamental_explain; if(!e){explainMissing('event-nlp');return;} const rows=(e.rows||[]).filter(r=>r.matched_topics||r.event_tags||r.sentiment_rule).slice(0,40).map((r,i)=>`<tr><td>${i+1}</td><td>${esc(r.name)}</td><td>${esc(r.sector)}</td><td>${esc(r.matched_topics)}</td><td>${esc(r.sentiment_rule)}</td><td>${esc(r.event_tags)}</td><td>${fmtNum(r.explain_score)}</td></tr>`).join('');
  document.getElementById('event-nlp').innerHTML=`<div class="section-title"><h2>事件与文本标签</h2><span class="pill">规则NLP</span></div><div class="card note">新闻语义搜索仅覆盖当年最近半个月；第一版使用关键词、主题词和事件词生成可复现标签。</div><div class="wide"><table><thead><tr><th>#</th><th>名称</th><th>行业</th><th>主题</th><th>情绪</th><th>事件</th><th>解释分</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}
function renderCrossResearch(){
  const e=DATA.fundamental_explain; if(!e){explainMissing('cross-research');return;} const rows=(e.rows||[]).slice(0,50).map((r,i)=>`<tr><td>${i+1}</td><td>${esc(r.name)}</td><td>${esc(r.sector)}</td><td class="${cls(r.return_5m)}">${fmtPct(r.return_5m)}</td><td>${fmtNum(r.resonance_score_5m)}</td><td>${esc(r.fundamental_quality_flag)}</td><td>${esc(r.attention_bucket)}</td><td>${esc(r.explain_label)}</td><td>${esc(r.explain_confidence)}</td></tr>`).join('');
  document.getElementById('cross-research').innerHTML=`<div class="split"><div class="chartbox"><h2>行业解释强度</h2>${sectorExplainBars(e.sectors)}</div><div class="card note"><b>交叉口径：</b>高基本面质量 × 高量价共振；高新闻催化 × 高成交额增量；高关注度 × 高涨速；解禁/负面标签 × 负向放量。</div></div><div class="wide"><table><thead><tr><th>#</th><th>名称</th><th>行业</th><th>相邻快照</th><th>量价分</th><th>基本面</th><th>关注度</th><th>解释标签</th><th>置信度</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}
function renderQuality(){
  const q=DATA.quality, mq=DATA.market_quality, s=DATA.source_files;
  document.getElementById('quality').innerHTML=`<div class="grid">${stat('匹配成分股',q.matched_components,'门槛不少于 980')}${stat('字段覆盖率',fmtPct(coverage(q)),'门槛不少于 95%')}${stat('有效快照',q.is_valid_snapshot?'是':'否',esc((q.invalid_reasons||[]).join('；')||'通过门禁'))}${stat('分钟行数',DATA.market_summary.minute_rows,'指数分钟路径')}</div><div class="card note"><b>限制：</b>当前成分股相邻有效快照约为 10:06:40 到 10:10:00，实际间隔约 200 秒，因此页面统一写作“相邻快照收益”，不把它伪装成严格 5 分钟。资金流覆盖目前只有 10:00 切片，11:00、14:00、15:00 切片尚未发生。</div><div class="wide"><table><thead><tr><th>原始入口</th><th>路径</th></tr></thead><tbody>${Object.entries(s).map(([k,v])=>`<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('')}</tbody></table></div>`;
}
function boot(){renderOverview();renderMarket();renderSector();renderRankings();renderResearch();renderExplainOverview();renderEventNlp();renderCrossResearch();renderQuality();}
document.querySelectorAll('.tabs button').forEach(btn=>btn.addEventListener('click',()=>{document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));document.querySelectorAll('.view').forEach(v=>v.classList.remove('active'));btn.classList.add('active');document.getElementById(btn.dataset.view).classList.add('active');}));
boot();
</script>
</body>
</html>
'@

$html = $html.Replace("__DATA_JSON__", $safeJson)

Set-Content -Path $OutputPath -Value $html -Encoding UTF8
Write-Host $OutputPath












