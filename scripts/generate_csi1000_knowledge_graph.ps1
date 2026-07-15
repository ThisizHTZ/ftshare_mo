param(
    [string]$RunDir = "",
    [int]$DefaultTopPerIndustry = 8
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RunDir)) {
    $RunDir = Get-ChildItem -Path "C:\ftshare_data\csi1000_intraday" -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$SignalsPath = Join-Path $RunDir "latest_signals.csv"
$SectorsPath = Join-Path $RunDir "sector_rotation.csv"
$OutputPath = Join-Path $RunDir "knowledge_graph.html"

if (-not (Test-Path $SignalsPath)) {
    throw "Missing latest_signals.csv in $RunDir"
}
if (-not (Test-Path $SectorsPath)) {
    throw "Missing sector_rotation.csv in $RunDir"
}

$Signals = Import-Csv -Path $SignalsPath
$Sectors = Import-Csv -Path $SectorsPath

function Convert-ToDoubleOrZero {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 0.0
    }
    try {
        return [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return 0.0
    }
}

function Encode-JsonLiteral {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 8 -Compress)
}

$SectorRows = foreach ($Sector in $Sectors) {
    [pscustomobject]@{
        id = "sector:" + [string]$Sector.sw_level1_name
        name = [string]$Sector.sw_level1_name
        component_count = [int](Convert-ToDoubleOrZero $Sector.component_count)
        avg_change_rate = Convert-ToDoubleOrZero $Sector.avg_change_rate
        turnover_delta_sum = Convert-ToDoubleOrZero $Sector.turnover_delta_sum
        avg_interval_return = Convert-ToDoubleOrZero $Sector.avg_interval_return
        weighted_contribution_sum = Convert-ToDoubleOrZero $Sector.weighted_contribution_sum
        strong_count = [int](Convert-ToDoubleOrZero $Sector.strong_count)
        risk_count = [int](Convert-ToDoubleOrZero $Sector.risk_count)
        sector_score = Convert-ToDoubleOrZero $Sector.sector_score
    }
}

$StockRows = foreach ($Signal in $Signals) {
    $label = [string]$Signal.prediction_label
    if ([string]::IsNullOrWhiteSpace($label)) { $label = "中性" }
    $sector = [string]$Signal.sw_level1_name
    if ([string]::IsNullOrWhiteSpace($sector)) { $sector = "未映射" }
    [pscustomobject]@{
        id = "stock:" + [string]$Signal.symbol
        symbol = [string]$Signal.symbol
        name = [string]$Signal.component_name
        sector = $sector
        label = $label
        close = Convert-ToDoubleOrZero $Signal.close
        weight = Convert-ToDoubleOrZero $Signal.weight
        change_rate = Convert-ToDoubleOrZero $Signal.change_rate
        interval_return = Convert-ToDoubleOrZero $Signal.interval_return
        turnover_delta = Convert-ToDoubleOrZero $Signal.turnover_delta
        weighted_change_contribution = Convert-ToDoubleOrZero $Signal.weighted_change_contribution
        resonance_score = Convert-ToDoubleOrZero $Signal.resonance_score
        risk_score = Convert-ToDoubleOrZero $Signal.risk_score
        composite_score = Convert-ToDoubleOrZero $Signal.composite_score
        reason = [string]$Signal.reason
    }
}

$Payload = [pscustomobject]@{
    run_dir = $RunDir
    generated_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    default_top_per_industry = $DefaultTopPerIndustry
    sectors = @($SectorRows)
    stocks = @($StockRows)
}

$Json = Encode-JsonLiteral $Payload

$Html = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>中证1000信号知识图谱</title>
  <style>
    :root {
      --bg: #f5f7fb;
      --panel: #ffffff;
      --border: #dbe3ef;
      --text: #172033;
      --muted: #64748b;
      --blue: #2563eb;
      --green: #16a34a;
      --orange: #f97316;
      --red: #dc2626;
      --slate: #475569;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
    }
    .app {
      height: 100vh;
      display: grid;
      grid-template-columns: 320px 1fr 360px;
      grid-template-rows: auto 1fr;
    }
    header {
      grid-column: 1 / -1;
      padding: 16px 20px;
      border-bottom: 1px solid var(--border);
      background: var(--panel);
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 16px;
    }
    h1 { margin: 0; font-size: 22px; }
    .subtitle { color: var(--muted); font-size: 13px; }
    aside, .details {
      background: var(--panel);
      border-right: 1px solid var(--border);
      padding: 16px;
      overflow: auto;
    }
    .details { border-right: 0; border-left: 1px solid var(--border); }
    .stage {
      position: relative;
      overflow: hidden;
      background:
        radial-gradient(circle at 30% 30%, rgba(37,99,235,.08), transparent 28%),
        radial-gradient(circle at 70% 70%, rgba(22,163,74,.07), transparent 30%),
        #f8fafc;
    }
    #graph {
      width: 100%;
      height: 100%;
      cursor: grab;
    }
    #graph:active { cursor: grabbing; }
    .group { margin-bottom: 18px; }
    .group h2 {
      font-size: 14px;
      margin: 0 0 8px;
      color: #334155;
    }
    label { display: block; margin: 7px 0; color: #334155; font-size: 13px; }
    input[type="text"], input[type="number"], select {
      width: 100%;
      padding: 8px 10px;
      border: 1px solid var(--border);
      border-radius: 6px;
      font-size: 13px;
    }
    input[type="range"] { width: 100%; }
    button {
      border: 1px solid var(--border);
      background: #fff;
      border-radius: 6px;
      padding: 7px 10px;
      cursor: pointer;
      font-size: 13px;
    }
    button:hover { border-color: var(--blue); color: var(--blue); }
    .button-row { display: flex; gap: 8px; flex-wrap: wrap; }
    .legend {
      display: grid;
      grid-template-columns: 16px 1fr;
      gap: 6px 8px;
      align-items: center;
      font-size: 13px;
      color: #334155;
    }
    .dot { width: 12px; height: 12px; border-radius: 50%; }
    .stats {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
    }
    .stat {
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px;
      background: #fbfdff;
    }
    .stat b { display: block; font-size: 18px; }
    .stat span { color: var(--muted); font-size: 12px; }
    .node-index { fill: #111827; }
    .node-sector { fill: #2563eb; }
    .node-stock-neutral { fill: #64748b; }
    .node-stock-strong { fill: #16a34a; }
    .node-stock-volume { fill: #f97316; }
    .node-stock-risk { fill: #dc2626; }
    .node-label { pointer-events: none; font-size: 11px; fill: #0f172a; paint-order: stroke; stroke: white; stroke-width: 3px; stroke-linejoin: round; }
    .edge { stroke: #94a3b8; stroke-opacity: .45; }
    .edge-contrib-pos { stroke: #dc2626; stroke-opacity: .55; }
    .edge-contrib-neg { stroke: #2563eb; stroke-opacity: .55; }
    .selected { stroke: #111827; stroke-width: 3px; }
    .tooltip {
      position: absolute;
      pointer-events: none;
      background: rgba(15,23,42,.92);
      color: white;
      padding: 8px 10px;
      border-radius: 6px;
      font-size: 12px;
      display: none;
      max-width: 280px;
    }
    .details h2 { margin-top: 0; font-size: 18px; }
    .kv {
      display: grid;
      grid-template-columns: 120px 1fr;
      gap: 6px 10px;
      font-size: 13px;
      margin-top: 12px;
    }
    .kv div:nth-child(odd) { color: var(--muted); }
    .list {
      margin-top: 14px;
      border-top: 1px solid var(--border);
      padding-top: 12px;
      font-size: 13px;
    }
    .list-item {
      display: flex;
      justify-content: space-between;
      gap: 10px;
      padding: 5px 0;
      border-bottom: 1px dashed #e2e8f0;
    }
    .badge {
      display: inline-block;
      padding: 2px 7px;
      border-radius: 999px;
      color: white;
      font-size: 12px;
    }
    .badge-strong { background: var(--green); }
    .badge-volume { background: var(--orange); }
    .badge-risk { background: var(--red); }
    .badge-neutral { background: var(--slate); }
  </style>
</head>
<body>
<div class="app">
  <header>
    <div>
      <h1>中证1000信号知识图谱</h1>
      <div class="subtitle">指数 → 申万一级行业 → 成分股 → 信号标签。用于解释板块轮动、异动聚集和贡献来源。</div>
    </div>
    <div class="subtitle" id="runMeta"></div>
  </header>

  <aside>
    <div class="group">
      <h2>搜索</h2>
      <input id="searchBox" type="text" placeholder="输入代码、股票名、行业名">
    </div>
    <div class="group">
      <h2>每个行业展示股票数：<span id="topNLabel"></span></h2>
      <input id="topN" type="range" min="3" max="30" value="8">
    </div>
    <div class="group">
      <h2>信号过滤</h2>
      <label><input type="checkbox" class="labelFilter" value="强势观察" checked> 强势观察</label>
      <label><input type="checkbox" class="labelFilter" value="放量异动" checked> 放量异动</label>
      <label><input type="checkbox" class="labelFilter" value="风险预警" checked> 风险预警</label>
      <label><input type="checkbox" class="labelFilter" value="中性"> 中性</label>
    </div>
    <div class="group">
      <h2>行业过滤</h2>
      <select id="sectorFilter"><option value="">全部行业</option></select>
    </div>
    <div class="group">
      <h2>视图</h2>
      <div class="button-row">
        <button id="zoomIn">放大</button>
        <button id="zoomOut">缩小</button>
        <button id="resetView">重置</button>
      </div>
    </div>
    <div class="group">
      <h2>图例</h2>
      <div class="legend">
        <span class="dot" style="background:#111827"></span><span>中证1000指数</span>
        <span class="dot" style="background:#2563eb"></span><span>申万一级行业</span>
        <span class="dot" style="background:#16a34a"></span><span>强势观察</span>
        <span class="dot" style="background:#f97316"></span><span>放量异动</span>
        <span class="dot" style="background:#dc2626"></span><span>风险预警</span>
        <span class="dot" style="background:#64748b"></span><span>中性</span>
      </div>
    </div>
  </aside>

  <section class="stage">
    <svg id="graph"></svg>
    <div id="tooltip" class="tooltip"></div>
  </section>

  <section class="details">
    <h2>图谱摘要</h2>
    <div class="stats" id="stats"></div>
    <div id="detailPanel" class="list">点击节点查看详情。</div>
  </section>
</div>

<script>
const rawData = $Json;
const state = {
  topN: rawData.default_top_per_industry || 8,
  labels: new Set(["强势观察", "放量异动", "风险预警"]),
  sector: "",
  search: "",
  scale: 1,
  tx: 0,
  ty: 0,
  selectedId: null
};

const svg = document.getElementById("graph");
const tooltip = document.getElementById("tooltip");
const topNInput = document.getElementById("topN");
const topNLabel = document.getElementById("topNLabel");
const sectorFilter = document.getElementById("sectorFilter");
const searchBox = document.getElementById("searchBox");

document.getElementById("runMeta").textContent = `生成时间：${rawData.generated_at} ｜ ${rawData.run_dir}`;
topNInput.value = state.topN;
topNLabel.textContent = state.topN;

rawData.sectors
  .map(s => s.name)
  .filter(Boolean)
  .sort((a, b) => a.localeCompare(b, "zh-CN"))
  .forEach(name => {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    sectorFilter.appendChild(opt);
  });

function fmtPct(v) {
  const n = Number(v || 0);
  return (n * 100).toFixed(2) + "%";
}
function fmtNum(v, d = 2) {
  const n = Number(v || 0);
  return n.toLocaleString("zh-CN", { maximumFractionDigits: d });
}
function badge(label) {
  const cls = label === "强势观察" ? "badge-strong" : label === "放量异动" ? "badge-volume" : label === "风险预警" ? "badge-risk" : "badge-neutral";
  return `<span class="badge ${cls}">${label}</span>`;
}
function stockColorClass(label) {
  if (label === "强势观察") return "node-stock-strong";
  if (label === "放量异动") return "node-stock-volume";
  if (label === "风险预警") return "node-stock-risk";
  return "node-stock-neutral";
}
function scoreStock(s) {
  return Math.abs(Number(s.composite_score || 0)) +
    Math.abs(Number(s.resonance_score || 0)) +
    Math.abs(Number(s.risk_score || 0)) +
    Math.abs(Number(s.weighted_change_contribution || 0)) * 10;
}
function filteredStocks() {
  const q = state.search.trim().toLowerCase();
  const grouped = new Map();
  rawData.stocks.forEach(s => {
    if (!state.labels.has(s.label)) return;
    if (state.sector && s.sector !== state.sector) return;
    if (q && !(`${s.symbol} ${s.name} ${s.sector}`.toLowerCase().includes(q))) return;
    if (!grouped.has(s.sector)) grouped.set(s.sector, []);
    grouped.get(s.sector).push(s);
  });
  const picked = [];
  grouped.forEach(list => {
    list.sort((a, b) => scoreStock(b) - scoreStock(a));
    picked.push(...list.slice(0, state.topN));
  });
  return picked;
}
function buildGraph() {
  const stocks = filteredStocks();
  const sectorNames = [...new Set(stocks.map(s => s.sector))];
  const sectors = rawData.sectors.filter(s => sectorNames.includes(s.name));
  const nodes = [{ id: "index:000852", type: "index", name: "中证1000" }];
  const edges = [];
  sectors.forEach(sec => {
    nodes.push({ ...sec, type: "sector" });
    edges.push({ source: "index:000852", target: sec.id, type: "sector", weight: Math.max(1, Math.abs(sec.sector_score || 0)) });
  });
  stocks.forEach(st => {
    nodes.push({ ...st, type: "stock" });
    edges.push({
      source: "sector:" + st.sector,
      target: st.id,
      type: Number(st.weighted_change_contribution || 0) >= 0 ? "contrib-pos" : "contrib-neg",
      weight: Math.max(1, Math.abs(Number(st.weighted_change_contribution || 0)) * 80)
    });
  });
  return { nodes, edges, stocks, sectors };
}
function layout(graph, width, height) {
  const cx = width / 2, cy = height / 2;
  const sectorRadius = Math.min(width, height) * 0.27;
  const stockRadius = Math.min(width, height) * 0.14;
  const sectors = graph.nodes.filter(n => n.type === "sector");
  const bySector = new Map();
  graph.nodes.filter(n => n.type === "stock").forEach(s => {
    if (!bySector.has(s.sector)) bySector.set(s.sector, []);
    bySector.get(s.sector).push(s);
  });
  graph.nodes.forEach(n => {
    if (n.type === "index") { n.x = cx; n.y = cy; }
  });
  sectors.forEach((sec, i) => {
    const a = -Math.PI / 2 + i * Math.PI * 2 / Math.max(sectors.length, 1);
    sec.x = cx + Math.cos(a) * sectorRadius;
    sec.y = cy + Math.sin(a) * sectorRadius;
    const stocks = bySector.get(sec.name) || [];
    stocks.forEach((st, j) => {
      const spread = Math.PI * 0.52;
      const start = a - spread / 2;
      const aa = stocks.length === 1 ? a : start + j * spread / (stocks.length - 1);
      st.x = sec.x + Math.cos(aa) * stockRadius;
      st.y = sec.y + Math.sin(aa) * stockRadius;
    });
  });
}
function render() {
  const graph = buildGraph();
  const rect = svg.getBoundingClientRect();
  const width = rect.width || 900;
  const height = rect.height || 700;
  layout(graph, width, height);
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.innerHTML = "";
  const g = document.createElementNS("http://www.w3.org/2000/svg", "g");
  g.setAttribute("transform", `translate(${state.tx},${state.ty}) scale(${state.scale})`);
  svg.appendChild(g);
  const nodeById = new Map(graph.nodes.map(n => [n.id, n]));
  graph.edges.forEach(e => {
    const s = nodeById.get(e.source), t = nodeById.get(e.target);
    if (!s || !t) return;
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    line.setAttribute("x1", s.x); line.setAttribute("y1", s.y);
    line.setAttribute("x2", t.x); line.setAttribute("y2", t.y);
    line.setAttribute("class", "edge " + (e.type === "contrib-pos" ? "edge-contrib-pos" : e.type === "contrib-neg" ? "edge-contrib-neg" : ""));
    line.setAttribute("stroke-width", Math.min(5, 0.8 + e.weight));
    g.appendChild(line);
  });
  graph.nodes.forEach(n => {
    const group = document.createElementNS("http://www.w3.org/2000/svg", "g");
    group.style.cursor = "pointer";
    const c = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    const r = n.type === "index" ? 28 : n.type === "sector" ? 17 : 8 + Math.min(8, Math.abs(Number(n.composite_score || 0)));
    c.setAttribute("cx", n.x); c.setAttribute("cy", n.y); c.setAttribute("r", r);
    c.setAttribute("class", n.type === "index" ? "node-index" : n.type === "sector" ? "node-sector" : stockColorClass(n.label));
    if (state.selectedId === n.id) c.classList.add("selected");
    group.appendChild(c);
    const text = document.createElementNS("http://www.w3.org/2000/svg", "text");
    text.setAttribute("x", n.x + r + 4);
    text.setAttribute("y", n.y + 4);
    text.setAttribute("class", "node-label");
    text.textContent = n.type === "stock" ? `${n.symbol} ${n.name}` : n.name;
    group.appendChild(text);
    group.addEventListener("click", () => {
      state.selectedId = n.id;
      showDetails(n, graph);
      render();
    });
    group.addEventListener("mousemove", ev => showTooltip(ev, n));
    group.addEventListener("mouseleave", () => tooltip.style.display = "none");
    g.appendChild(group);
  });
  renderStats(graph);
}
function showTooltip(ev, n) {
  tooltip.style.display = "block";
  tooltip.style.left = ev.offsetX + 14 + "px";
  tooltip.style.top = ev.offsetY + 14 + "px";
  if (n.type === "stock") {
    tooltip.innerHTML = `<b>${n.symbol} ${n.name}</b><br>${badge(n.label)}<br>行业：${n.sector}<br>涨跌幅：${fmtPct(n.change_rate)}<br>综合分：${fmtNum(n.composite_score)}`;
  } else if (n.type === "sector") {
    tooltip.innerHTML = `<b>${n.name}</b><br>成分数：${n.component_count}<br>平均涨跌幅：${fmtPct(n.avg_change_rate)}<br>轮动分：${fmtNum(n.sector_score)}`;
  } else {
    tooltip.innerHTML = "<b>中证1000</b><br>点击行业或股票查看详情";
  }
}
function showDetails(n, graph) {
  const panel = document.getElementById("detailPanel");
  if (n.type === "stock") {
    panel.innerHTML = `<h2>${n.symbol} ${n.name}</h2>${badge(n.label)}
      <div class="kv">
        <div>行业</div><div>${n.sector}</div>
        <div>最新价</div><div>${fmtNum(n.close)}</div>
        <div>当日涨跌幅</div><div>${fmtPct(n.change_rate)}</div>
        <div>短周期收益</div><div>${fmtPct(n.interval_return)}</div>
        <div>成交额增量</div><div>${fmtNum(n.turnover_delta, 0)}</div>
        <div>权重</div><div>${fmtNum(n.weight, 4)}</div>
        <div>权重贡献</div><div>${fmtNum(n.weighted_change_contribution, 6)}</div>
        <div>量价共振分</div><div>${fmtNum(n.resonance_score, 6)}</div>
        <div>风险分</div><div>${fmtNum(n.risk_score, 6)}</div>
        <div>综合分</div><div>${fmtNum(n.composite_score, 6)}</div>
        <div>原因</div><div>${n.reason || ""}</div>
      </div>`;
  } else if (n.type === "sector") {
    const stocks = rawData.stocks.filter(s => s.sector === n.name).sort((a,b) => Number(b.composite_score || 0) - Number(a.composite_score || 0)).slice(0, 12);
    panel.innerHTML = `<h2>${n.name}</h2>
      <div class="kv">
        <div>成分数</div><div>${n.component_count}</div>
        <div>平均涨跌幅</div><div>${fmtPct(n.avg_change_rate)}</div>
        <div>成交额增量</div><div>${fmtNum(n.turnover_delta_sum, 0)}</div>
        <div>行业动量</div><div>${fmtPct(n.avg_interval_return)}</div>
        <div>贡献合计</div><div>${fmtNum(n.weighted_contribution_sum, 6)}</div>
        <div>轮动分</div><div>${fmtNum(n.sector_score, 6)}</div>
      </div>
      <div class="list"><b>行业内综合分靠前</b>${stocks.map(s => `<div class="list-item"><span>${s.symbol} ${s.name}</span><span>${fmtNum(s.composite_score)}</span></div>`).join("")}</div>`;
  } else {
    panel.innerHTML = "<h2>中证1000</h2><p>中心节点连接全部申万一级行业。边的粗细表示行业轮动分或股票权重贡献强度。</p>";
  }
}
function renderStats(graph) {
  const counts = rawData.stocks.reduce((m, s) => (m[s.label] = (m[s.label] || 0) + 1, m), {});
  document.getElementById("stats").innerHTML = `
    <div class="stat"><b>${rawData.sectors.length}</b><span>申万一级行业</span></div>
    <div class="stat"><b>${rawData.stocks.length}</b><span>中证1000成分股</span></div>
    <div class="stat"><b>${counts["强势观察"] || 0}</b><span>强势观察</span></div>
    <div class="stat"><b>${counts["放量异动"] || 0}</b><span>放量异动</span></div>
    <div class="stat"><b>${counts["风险预警"] || 0}</b><span>风险预警</span></div>
    <div class="stat"><b>${graph.nodes.length}</b><span>当前显示节点</span></div>`;
}

topNInput.addEventListener("input", () => { state.topN = Number(topNInput.value); topNLabel.textContent = state.topN; render(); });
searchBox.addEventListener("input", () => { state.search = searchBox.value; render(); });
sectorFilter.addEventListener("change", () => { state.sector = sectorFilter.value; render(); });
document.querySelectorAll(".labelFilter").forEach(cb => cb.addEventListener("change", () => {
  state.labels = new Set([...document.querySelectorAll(".labelFilter")].filter(x => x.checked).map(x => x.value));
  render();
}));
document.getElementById("zoomIn").onclick = () => { state.scale *= 1.18; render(); };
document.getElementById("zoomOut").onclick = () => { state.scale /= 1.18; render(); };
document.getElementById("resetView").onclick = () => { state.scale = 1; state.tx = 0; state.ty = 0; render(); };

let dragging = false, last = null;
svg.addEventListener("mousedown", ev => { dragging = true; last = [ev.clientX, ev.clientY]; });
window.addEventListener("mouseup", () => dragging = false);
window.addEventListener("mousemove", ev => {
  if (!dragging) return;
  state.tx += ev.clientX - last[0];
  state.ty += ev.clientY - last[1];
  last = [ev.clientX, ev.clientY];
  render();
});
svg.addEventListener("wheel", ev => {
  ev.preventDefault();
  state.scale *= ev.deltaY < 0 ? 1.08 : 0.92;
  render();
}, { passive: false });
window.addEventListener("resize", render);
render();
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutputPath, $Html, (New-Object System.Text.UTF8Encoding($false)))
[pscustomobject]@{
    run_dir = $RunDir
    output = $OutputPath
    sectors = @($SectorRows).Count
    stocks = @($StockRows).Count
} | ConvertTo-Json -Depth 4
