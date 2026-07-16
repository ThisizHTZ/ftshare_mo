param(
    [Parameter(Mandatory=$true)][string]$TradeDate,
    [Parameter(Mandatory=$true)][string]$SnapshotRunDir,
    [string]$OutRoot = "C:\ftshare_data\market_state_research",
    [switch]$IncludeCapitalFlows
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Config = Get-Content -Raw -Encoding UTF8 (Join-Path $ProjectRoot "config.json") | ConvertFrom-Json
$Date = [datetime]::ParseExact($TradeDate, "yyyyMMdd", $null)
$DateIso = $Date.ToString("yyyy-MM-dd")
$RunDir = Join-Path $OutRoot ($TradeDate + "_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Invoke-FtShareJson {
    param([string]$Url)
    $LastError = $null
    for ($Attempt=1; $Attempt -le 5; $Attempt++) {
        try {
            return Invoke-RestMethod -Uri $Url -Headers @{"X-Client-Name"="ft-claw";"User-Agent"="ftshare-market-state-research/0.1"} -TimeoutSec 60
        } catch {
            $LastError = $_
            Start-Sleep -Seconds ([Math]::Min(16, [Math]::Pow(2, $Attempt-1)))
        }
    }
    throw $LastError
}

function Convert-EpochMsToChinaTime {
    param([int64]$Milliseconds)
    return [DateTimeOffset]::FromUnixTimeMilliseconds($Milliseconds).ToOffset([TimeSpan]::FromHours(8)).DateTime
}

function Convert-ToNumberOrNull {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Normalize-Symbol {
    param([string]$Symbol)
    $Normalized = $Symbol.Replace(".XSHG", ".SH").Replace(".XSHE", ".SZ")
    if ($Normalized.Contains(".")) { return $Normalized }
    if ($Normalized.StartsWith("6")) { return "$Normalized.SH" }
    if ($Normalized.StartsWith("8") -or $Normalized.StartsWith("9")) { return "$Normalized.BJ" }
    return "$Normalized.SZ"
}

$MinuteUrl = "https://market.ft.tech/gateway/api/v1/market/data/daec/history/prices?symbol=$($Config.index_symbol)&days=$($Config.minute_days)"
$MinuteResponse = Invoke-FtShareJson $MinuteUrl
$MinuteRows = @($MinuteResponse | ForEach-Object {
    $At = Convert-EpochMsToChinaTime ([int64]$_.ts_ms)
    if ($At.ToString("yyyy-MM-dd") -eq $DateIso) {
        [pscustomobject]@{
            trade_date=$DateIso; minute_time=$At.ToString("yyyy-MM-dd HH:mm:ss")
            price=Convert-ToNumberOrNull $_.price; avg_price=Convert-ToNumberOrNull $_.avg_price
            volume=Convert-ToNumberOrNull $_.volume; turnover=Convert-ToNumberOrNull $_.turnover
            source="FTShare"; frequency="1min"
        }
    }
} | Where-Object { $null -ne $_ } | Sort-Object minute_time)
$MinutePath = Join-Path $RunDir "index_minute.csv"
$MinuteRows | Export-Csv $MinutePath -NoTypeInformation -Encoding UTF8

$FeatureRows = @()
$MinuteGroups = @($MinuteRows | Group-Object {
    $At = [datetime]::Parse($_.minute_time)
    $SessionStart = if ($At.Hour -lt 12) { $At.Date.AddHours(9).AddMinutes(30) } else { $At.Date.AddHours(13) }
    $Session = if ($At.Hour -lt 12) { "AM" } else { "PM" }
    $Bucket = [Math]::Floor(($At-$SessionStart).TotalMinutes/15)
    "$Session-$Bucket"
})
foreach ($MinuteGroup in $MinuteGroups) {
    $Window = @($MinuteGroup.Group | Sort-Object minute_time)
    if ($Window.Count -eq 0) { continue }
    $FirstPrice = Convert-ToNumberOrNull $Window[0].price
    $LastPrice = Convert-ToNumberOrNull $Window[-1].price
    $Returns = @()
    for ($i=1; $i -lt $Window.Count; $i++) {
        $Previous = Convert-ToNumberOrNull $Window[$i-1].price; $Current = Convert-ToNumberOrNull $Window[$i].price
        if ($Previous -and $Current) { $Returns += (($Current/$Previous)-1.0) }
    }
    $RealizedVariance = 0.0; foreach ($Return in $Returns) { $RealizedVariance += $Return*$Return }
    $FeatureRows += [pscustomobject]@{
        window_end=$Window[-1].minute_time; observations=$Window.Count
        return_15m=if($FirstPrice){$LastPrice/$FirstPrice-1.0}else{$null}
        realized_volatility_15m=[Math]::Sqrt($RealizedVariance)
        volume_15m=($Window | Measure-Object volume -Sum).Sum
        turnover_15m=($Window | Measure-Object turnover -Sum).Sum
        close=$LastPrice
    }
}
$FeaturePath = Join-Path $RunDir "index_15m_features.csv"
$FeatureRows | Export-Csv $FeaturePath -NoTypeInformation -Encoding UTF8

$Components = @(Import-Csv (Join-Path $SnapshotRunDir "csi1000_components.csv") -Encoding UTF8)
$SnapshotFile = Get-ChildItem $SnapshotRunDir -Filter "snapshot_*.csv" | Sort-Object Name | Select-Object -Last 1
if (-not $SnapshotFile) { throw "No snapshot_NNN.csv found in $SnapshotRunDir" }
$Snapshot = @(Import-Csv $SnapshotFile.FullName -Encoding UTF8)
$SectorRows = @(Import-Csv (Join-Path $SnapshotRunDir "sector_rotation.csv") -Encoding UTF8)

$ValidChanges = @($Snapshot | ForEach-Object { Convert-ToNumberOrNull $_.change_rate } | Where-Object { $null -ne $_ })
$Up = @($ValidChanges | Where-Object { $_ -gt 0 }).Count
$Down = @($ValidChanges | Where-Object { $_ -lt 0 }).Count
$Flat = @($ValidChanges | Where-Object { $_ -eq 0 }).Count
$EqualWeightReturn = if ($ValidChanges.Count) { ($ValidChanges | Measure-Object -Average).Average } else { $null }
$WeightedContributionSum = ($Snapshot | ForEach-Object { Convert-ToNumberOrNull $_.weighted_change_contribution } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum
$WeightSum = ($Snapshot | ForEach-Object { Convert-ToNumberOrNull $_.weight } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum
$WeightedReturn = if ($WeightSum) { $WeightedContributionSum/$WeightSum } else { $null }
$Breadth = if ($ValidChanges.Count) { ($Up-$Down)/[double]$ValidChanges.Count } else { $null }
$Divergence = if ($null -ne $EqualWeightReturn -and $null -ne $WeightedReturn) { $WeightedReturn-$EqualWeightReturn } else { $null }

$SectorAnalysis = @($SectorRows | ForEach-Object {
    $Average = Convert-ToNumberOrNull $_.avg_change_rate
    [pscustomobject]@{
        industry=$_.sw_level1_name; component_count=[int]$_.component_count; avg_change_rate=$Average
        direction=if($Average -gt 0){"up"}elseif($Average -lt 0){"down"}else{"flat"}
        weighted_contribution=Convert-ToNumberOrNull $_.weighted_contribution_sum
    }
})
$SectorAnalysis | Export-Csv (Join-Path $RunDir "sector_diffusion.csv") -NoTypeInformation -Encoding UTF8
$PositiveSectors = @($SectorAnalysis | Where-Object { $_.avg_change_rate -gt 0 }).Count
$SectorDiffusion = if ($SectorAnalysis.Count) { $PositiveSectors/[double]$SectorAnalysis.Count } else { $null }

$CapitalFlowRows = @()
if ($IncludeCapitalFlows) {
    $ComponentSymbols = @{}; foreach ($Component in $Components) { $ComponentSymbols[(Normalize-Symbol ([string]$Component.component_code))] = $true }
    foreach ($Time in $Config.capital_flow_times) {
        for ($Page=1; ; $Page++) {
            $Url = "https://market.ft.tech/gateway/api/v1/market/data/stock-capital-flows?date=$TradeDate&time=$Time&page=$Page&page_size=200"
            $Response = Invoke-FtShareJson $Url
            foreach ($Item in @($Response.items)) {
                if ($ComponentSymbols.ContainsKey([string]$Item.symbol)) {
                    $CapitalFlowRows += [pscustomobject]@{
                        trade_date=$DateIso; slice_time=$Time; symbol=$Item.symbol; symbol_name=$Item.symbol_name
                        net_inflow_extra_large=Convert-ToNumberOrNull $Item.net_inflow_extra_large
                        net_inflow_large=Convert-ToNumberOrNull $Item.net_inflow_large
                        net_inflow_main=Convert-ToNumberOrNull $Item.net_inflow_main
                        net_inflow_medium=Convert-ToNumberOrNull $Item.net_inflow_medium
                        net_inflow_small=Convert-ToNumberOrNull $Item.net_inflow_small
                        ts_nanos=$Item.ts_nanos
                    }
                }
            }
            if ($Page -ge [int]$Response.total_pages) { break }
        }
    }
    $CapitalFlowRows | Export-Csv (Join-Path $RunDir "component_capital_flows_15m.csv") -NoTypeInformation -Encoding UTF8
}

$MinuteComplete = $MinuteRows.Count -eq [int]$Config.expected_full_day_minutes
$CapitalCoverage = @{}
foreach ($Time in $Config.capital_flow_times) { $CapitalCoverage[$Time] = @($CapitalFlowRows | Where-Object { $_.slice_time -eq $Time }).Count }
$Quality = [ordered]@{
    trade_date=$DateIso; source="FTShare"; index_symbol=$Config.index_symbol
    minute_rows=$MinuteRows.Count; expected_minute_rows=[int]$Config.expected_full_day_minutes
    minute_complete=$MinuteComplete; component_snapshot_rows=$Snapshot.Count
    component_snapshot_complete=($Snapshot.Count -ge [int]$Config.minimum_component_matches)
    capital_flows_requested=[bool]$IncludeCapitalFlows; capital_flow_component_coverage=$CapitalCoverage
    intraday_component_breadth_available=$false
    limitations=@("Historical intraday component snapshots were not collected on this date; intraday breadth cannot be reconstructed from the close snapshot.")
}
$Quality | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $RunDir "data_quality.json") -Encoding UTF8

$State = if ($Breadth -gt 0.15 -and $SectorDiffusion -gt 0.60 -and $WeightedReturn -gt 0) { "broad_risk_on" }
    elseif ($Breadth -gt 0 -and $WeightedReturn -lt 0) { "positive_breadth_weight_drag" }
    elseif ($Breadth -lt -0.15 -and $SectorDiffusion -lt 0.40) { "broad_risk_off" }
    elseif ([Math]::Abs($Breadth) -lt 0.10) { "mixed_range" } else { "partial_diffusion" }

$Summary = [ordered]@{
    trade_date=$DateIso; state=$State; up_count=$Up; down_count=$Down; flat_count=$Flat
    breadth=$Breadth; equal_weight_return=$EqualWeightReturn; weighted_return_approx=$WeightedReturn
    weighted_equal_divergence=$Divergence; positive_sector_count=$PositiveSectors
    sector_count=$SectorAnalysis.Count; sector_diffusion=$SectorDiffusion
    minute_rows=$MinuteRows.Count; capital_flow_rows=$CapitalFlowRows.Count
}
$Summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $RunDir "research_summary.json") -Encoding UTF8

$TopSectors = @($SectorAnalysis | Sort-Object avg_change_rate -Descending | Select-Object -First 8)
$BottomSectors = @($SectorAnalysis | Sort-Object avg_change_rate | Select-Object -First 8)
$SectorJson = $SectorAnalysis | ConvertTo-Json -Compress
$FeatureJson = $FeatureRows | ConvertTo-Json -Compress
$Html = @"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>中证1000市场状态研究</title><style>
body{margin:0;background:#f4f6f8;color:#17212f;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1280px;margin:auto;padding:26px}h1{margin:0 0 6px}.meta,.note{color:#607084}.status{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin:18px 0}.metric,.panel{background:#fff;border:1px solid #dbe2ea;border-radius:7px}.metric{padding:13px}.metric span{display:block;font-size:12px;color:#6a788b}.metric b{font-size:20px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}.panel{padding:15px}.panel canvas{width:100%;height:260px}.warning{padding:13px;background:#fff6d8;border-left:4px solid #d4a72c;margin:14px 0}table{width:100%;border-collapse:collapse}th,td{padding:7px;border-bottom:1px solid #edf0f4;text-align:right}th:first-child,td:first-child{text-align:left}@media(max-width:800px){.grid{grid-template-columns:1fr}}
</style></head><body><main><h1>中证1000盘中市场状态研究</h1><div class="meta">$DateIso · FTShare · 研究状态而非个股推荐</div>
<div class="status"><div class="metric"><span>状态分类</span><b>$State</b></div><div class="metric"><span>市场宽度</span><b>$([Math]::Round(100*$Breadth,1))%</b></div><div class="metric"><span>行业扩散</span><b>$([Math]::Round(100*$SectorDiffusion,1))%</b></div><div class="metric"><span>等权收益</span><b>$([Math]::Round(100*$EqualWeightReturn,2))%</b></div><div class="metric"><span>权重近似收益</span><b>$([Math]::Round(100*$WeightedReturn,2))%</b></div><div class="metric"><span>指数分钟完整度</span><b>$($MinuteRows.Count)/$($Config.expected_full_day_minutes)</b></div></div>
<div class="warning">7月15日没有保存连续的成分股盘中快照，因此只能研究收盘宽度和行业结构；不能从收盘数据反推盘中扩散路径。</div>
<div class="grid"><section class="panel"><h2>指数15分钟量价路径</h2><canvas id="minute"></canvas></section><section class="panel"><h2>行业收益分布</h2><canvas id="sector"></canvas></section></div>
<div class="grid"><section class="panel"><h2>较强行业</h2><table><tr><th>行业</th><th>成分</th><th>平均涨跌</th></tr>$(@($TopSectors|ForEach-Object{"<tr><td>$($_.industry)</td><td>$($_.component_count)</td><td>$([Math]::Round(100*$_.avg_change_rate,2))%</td></tr>"})-join'')</table></section><section class="panel"><h2>较弱行业</h2><table><tr><th>行业</th><th>成分</th><th>平均涨跌</th></tr>$(@($BottomSectors|ForEach-Object{"<tr><td>$($_.industry)</td><td>$($_.component_count)</td><td>$([Math]::Round(100*$_.avg_change_rate,2))%</td></tr>"})-join'')</table></section></div>
<p class="note">状态规则是第一版描述性基线，尚未经过长期样本外检验。分钟量价、行业扩散、宽度背离和资金流将在后续交易日持续积累后进入统计模型。</p></main><script>
const features=$FeatureJson,sectors=$SectorJson;function chart(id,values,color){const c=document.getElementById(id),x=c.getContext('2d');c.width=c.clientWidth*2;c.height=520;const w=c.width,h=c.height,p=45,min=Math.min(...values),max=Math.max(...values),span=max-min||1;x.clearRect(0,0,w,h);x.strokeStyle='#cbd5df';x.beginPath();x.moveTo(p,h/2);x.lineTo(w-p,h/2);x.stroke();x.strokeStyle=color;x.lineWidth=3;x.beginPath();values.forEach((v,i)=>{const px=p+i*(w-2*p)/Math.max(1,values.length-1),py=h-p-(v-min)/span*(h-2*p);i?x.lineTo(px,py):x.moveTo(px,py)});x.stroke()}chart('minute',features.map(x=>Number(x.close)),'#2367a8');chart('sector',sectors.sort((a,b)=>Number(a.avg_change_rate)-Number(b.avg_change_rate)).map(x=>Number(x.avg_change_rate)),'#2b7a55');
</script></body></html>
"@
[IO.File]::WriteAllText((Join-Path $RunDir "report.html"), $Html, (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{ output_dir=$RunDir; report=(Join-Path $RunDir "report.html"); summary=(Join-Path $RunDir "research_summary.json"); quality=(Join-Path $RunDir "data_quality.json") } | ConvertTo-Json
