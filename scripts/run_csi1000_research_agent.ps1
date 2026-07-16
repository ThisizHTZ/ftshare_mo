param(
    [string]$TradeDate = (Get-Date -Format "yyyy-MM-dd"),
    [string]$OutRoot = "C:\ftshare_data\daily_intraday_summary",
    [string]$MarketRoot = "C:\ftshare_data\market_state_research",
    [string]$ArchiveRoot = "C:\ftshare_data\research_archive",
    [string]$DailyDir = "",
    [string]$MarketDir = "",
    [string]$FundamentalDir = "",
    [switch]$Collect,
    [int]$Iterations = 50,
    [int]$IntervalSeconds = 300,
    [int]$SampleMinutes = 5,
    [int]$MaxSymbols = 120,
    [int]$MaxNewsQueries = 60,
    [switch]$SkipExplainNetwork
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$MonitorScript = Join-Path $ScriptRoot "ftshare_csi1000_intraday_monitor.ps1"
$ExplainScript = Join-Path $ScriptRoot "build_fundamental_nlp_explain_report.ps1"
$DashboardScript = Join-Path $ScriptRoot "build_integrated_morning_report.ps1"

function Read-JsonFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $null
}

function To-Number($Value) {
    if ($null -eq $Value -or $Value -eq "") { return $null }
    $n = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    return $null
}

function Format-Pct($Value) {
    $n = To-Number $Value
    if ($null -eq $n) { return "--" }
    return ("{0:N2}%" -f ($n * 100))
}

function Format-Bn($Value) {
    $n = To-Number $Value
    if ($null -eq $n) { return "--" }
    return ("{0:N2}亿" -f ($n / 100000000))
}

function Get-LatestDirWithFile([string]$Root, [string]$FileName) {
    if (-not (Test-Path -LiteralPath $Root)) { return "" }
    $dir = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $FileName) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($dir) { return $dir.FullName }
    return ""
}

function Invoke-AndCapture([string]$File, [string[]]$ArgsList) {
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $File @ArgsList
    $text = ($output | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function Pick-Top($Rows, [string]$Field, [int]$Count = 5, [switch]$Ascending) {
    $rows2 = @($Rows | Where-Object { $null -ne (To-Number $_.$Field) })
    if ($Ascending) {
        return @($rows2 | Sort-Object { To-Number $_.$Field } | Select-Object -First $Count)
    }
    return @($rows2 | Sort-Object { To-Number $_.$Field } -Descending | Select-Object -First $Count)
}

function New-ResearchSummary {
    param(
        [string]$DailyDir,
        [string]$MarketDir,
        [string]$FundamentalDir,
        [string]$DashboardPath,
        [string]$ArchiveDir
    )

    $quality = Read-JsonFile (Join-Path $DailyDir "data_quality.json")
    $daily = Read-JsonFile (Join-Path $DailyDir "daily_analysis.json")
    $fund = Read-JsonFile (Join-Path $FundamentalDir "fundamental_nlp_summary.json")
    $signalsPath = Join-Path $DailyDir "latest_signals.csv"
    $sectorsPath = Join-Path $DailyDir "sector_rotation.csv"
    $signals = @(Import-Csv -LiteralPath $signalsPath)
    $sectors = @(Import-Csv -LiteralPath $sectorsPath)

    $validSignals = @($signals | Where-Object { $_.signal_valid -eq "True" -or $_.signal_valid -eq $true })
    $strong = @($signals | Where-Object { $_.prediction_label -match "高综合分|强势|量价共振" })
    $risk = @($signals | Where-Object { $_.prediction_label -match "风险" })
    $positive5 = @($signals | Where-Object { (To-Number $_.return_5m) -gt 0 })
    $negative5 = @($signals | Where-Object { (To-Number $_.return_5m) -lt 0 })

    $topSectors = @(Pick-Top $sectors "sector_score" 5)
    $weakSectors = @(Pick-Top $sectors "sector_score" 5 -Ascending)
    $topResonance = @(Pick-Top $signals "resonance_score_5m" 8)
    $topRisk = @(Pick-Top $signals "risk_score_5m" 8)
    $topComposite = @(Pick-Top $signals "composite_score" 8)

    $marketTone = "中性震荡"
    $avgChange = To-Number $daily.avg_change_rate
    $breadth = 0.0
    if (($daily.up_count + $daily.down_count) -gt 0) { $breadth = ($daily.up_count - $daily.down_count) / ($daily.up_count + $daily.down_count) }
    if ($avgChange -gt 0.005 -and $breadth -gt 0.15) { $marketTone = "偏强扩散" }
    elseif ($avgChange -lt -0.005 -and $breadth -lt -0.15) { $marketTone = "偏弱收缩" }
    elseif ($avgChange -gt 0 -and $breadth -gt 0) { $marketTone = "震荡偏强" }
    elseif ($avgChange -lt 0 -and $breadth -lt 0) { $marketTone = "震荡偏弱" }

    $qualityLabel = if ($quality.is_valid_snapshot) { "可用于短周期研究" } else { "降级，仅用于静态观察" }
    $newsText = if ($fund -and (To-Number $fund.news_coverage) -gt 0) { "新闻语义搜索已有部分覆盖，可进入文本催化观察。" } else { "新闻覆盖不足，文本催化结论应降级。" }
    $eventText = if ($fund -and (To-Number $fund.event_catalyst_count) -gt 0) { "事件催化存在命中样本。" } else { "重大合同/解禁等事件命中较少，事件解释目前偏稀疏。" }

    $sectorLines = ($topSectors | ForEach-Object { "- $($_.sw_level1_name)：行业分 $([math]::Round((To-Number $_.sector_score),2))，平均涨跌 $(Format-Pct $_.avg_change_rate)，成交额增量 $(Format-Bn $_.turnover_delta_sum)" }) -join "`n"
    $weakLines = ($weakSectors | ForEach-Object { "- $($_.sw_level1_name)：行业分 $([math]::Round((To-Number $_.sector_score),2))，平均涨跌 $(Format-Pct $_.avg_change_rate)" }) -join "`n"
    $resLines = ($topResonance | ForEach-Object { "- $($_.component_name) $($_.symbol)：5分钟 $(Format-Pct $_.return_5m)，成交额增量 $(Format-Bn $_.turnover_delta_5m)，共振分 $([math]::Round((To-Number $_.resonance_score_5m),3))" }) -join "`n"
    $riskLines = ($topRisk | ForEach-Object { "- $($_.component_name) $($_.symbol)：5分钟 $(Format-Pct $_.return_5m)，风险分 $([math]::Round((To-Number $_.risk_score_5m),3))" }) -join "`n"

    $summary = [pscustomobject]@{
        generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        trade_date = $TradeDate
        daily_dir = $DailyDir
        market_dir = $MarketDir
        fundamental_dir = $FundamentalDir
        dashboard_html = $DashboardPath
        archive_dir = $ArchiveDir
        snapshot_time = $quality.snapshot_time
        last_valid_signal_time = $quality.last_valid_signal_time
        data_quality_label = $qualityLabel
        market_tone = $marketTone
        matched_components = $quality.matched_components
        field_coverage = $quality.field_coverage.overall
        changed_symbol_ratio = $quality.changed_symbol_ratio
        up_count = $daily.up_count
        down_count = $daily.down_count
        flat_count = $daily.flat_count
        avg_change_rate = $daily.avg_change_rate
        total_turnover = $daily.total_turnover
        valid_signal_count = $validSignals.Count
        positive_5m_count = $positive5.Count
        negative_5m_count = $negative5.Count
        strong_signal_count = $strong.Count
        risk_signal_count = $risk.Count
        fundamental_coverage = if($fund){$fund.fundamental_coverage}else{$null}
        news_coverage = if($fund){$fund.news_coverage}else{$null}
        attention_coverage = if($fund){$fund.attention_coverage}else{$null}
        event_catalyst_count = if($fund){$fund.event_catalyst_count}else{$null}
        notes = @("研究解释，不构成投资建议", $newsText, $eventText)
    }

    $md = @"
# 中证1000端到端 AI 研究摘要

生成时间：$($summary.generated_at)  
交易日：$TradeDate  
最新快照：$($summary.snapshot_time)  
最后有效信号：$($summary.last_valid_signal_time)  
数据状态：$qualityLabel

## 1. 市场状态

本轮中证1000内部状态判断为：**$marketTone**。

- 上涨 / 下跌 / 平盘：$($daily.up_count) / $($daily.down_count) / $($daily.flat_count)
- 平均涨跌幅：$(Format-Pct $daily.avg_change_rate)
- 成交额合计：$(Format-Bn $daily.total_turnover)
- 有效变化比例：$(Format-Pct $quality.changed_symbol_ratio)
- 字段覆盖率：$(Format-Pct $quality.field_coverage.overall)

## 2. 板块轮动

强势行业前列：

$sectorLines

弱势行业前列：

$weakLines

## 3. 量价异动样本

量价共振样本前列：

$resLines

负向放量/风险样本前列：

$riskLines

## 4. 解释层覆盖

- 基本面覆盖：$(if($fund){Format-Pct $fund.fundamental_coverage}else{"--"})
- 新闻覆盖：$(if($fund){Format-Pct $fund.news_coverage}else{"--"})
- 关注度覆盖：$(if($fund){Format-Pct $fund.attention_coverage}else{"--"})
- 事件催化命中数：$(if($fund){$fund.event_catalyst_count}else{"--"})

$newsText  
$eventText

## 5. AI 研究判断

当前 Agent 的判断不是买卖建议，而是研究假设生成：

1. 若强势行业同时出现成交额增量和正向短周期收益，后续应检验其是否有 15/30 分钟延续性。
2. 若个股出现高量价共振但缺少基本面/事件/关注度解释，应优先标记为“纯交易性异动”，后续用分层收益检验是否只是短期噪声。
3. 若风险分靠前且所属行业扩散偏弱，应检验其对后续回撤或尾部损失的解释力。
4. 新闻覆盖不足时，文本催化结论降级，不把空白解释为没有事件。

## 6. 输出入口

- 完整交互网页：$DashboardPath
- 解释层目录：$FundamentalDir
- 归档目录：$ArchiveDir
"@

    $htmlBody = ($md -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') -replace "`r?`n", "<br>`n"
    $html = "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><title>中证1000 AI 研究摘要</title><style>body{margin:0;background:#eef2f6;color:#172033;font-family:'Microsoft YaHei UI','Microsoft YaHei',Arial,sans-serif;line-height:1.75}main{max-width:960px;margin:0 auto;padding:28px}article{background:#fff;border:1px solid #edf1f6;border-radius:8px;padding:24px;box-shadow:0 16px 38px rgba(21,31,47,.08)}code{background:#f3f6fa;padding:2px 5px;border-radius:4px}</style></head><body><main><article>$htmlBody</article></main></body></html>"

    $summaryJsonPath = Join-Path $DailyDir "ai_research_summary.json"
    $summaryMdPath = Join-Path $DailyDir "ai_research_summary.md"
    $summaryHtmlPath = Join-Path $DailyDir "ai_research_summary.html"
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8
    Set-Content -LiteralPath $summaryMdPath -Value $md -Encoding UTF8
    Set-Content -LiteralPath $summaryHtmlPath -Value $html -Encoding UTF8

    return [pscustomobject]@{
        json = $summaryJsonPath
        markdown = $summaryMdPath
        html = $summaryHtmlPath
        summary = $summary
    }
}

function Save-ResearchArchive {
    param(
        [string]$DailyDir,
        [string]$FundamentalDir,
        [string]$DashboardPath,
        [object]$AiSummary
    )

    $dateKey = $TradeDate -replace "-", ""
    $runId = Split-Path -Leaf $DailyDir
    $archiveDir = Join-Path (Join-Path $ArchiveRoot $dateKey) $runId
    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

    $files = @(
        "data_quality.json",
        "snapshot_manifest.csv",
        "snapshot_manifest.json",
        "daily_analysis.json",
        "sector_rotation.csv",
        "prediction_watchlist.csv",
        "latest_signals.csv",
        "latest_snapshot.csv",
        "dashboard.html",
        "integrated_research_dashboard.html",
        "ai_research_summary.json",
        "ai_research_summary.md",
        "ai_research_summary.html"
    )
    foreach ($name in $files) {
        $src = Join-Path $DailyDir $name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $archiveDir $name) -Force }
    }

    if ($FundamentalDir -and (Test-Path -LiteralPath $FundamentalDir)) {
        $fundArchive = Join-Path $archiveDir "fundamental_nlp"
        New-Item -ItemType Directory -Force -Path $fundArchive | Out-Null
        foreach ($name in @("fundamental_nlp_summary.json","fundamental_nlp_report.html","intraday_explain_dataset.csv","csi1000_fundamental_features.csv","csi1000_event_features.csv","csi1000_news_features.csv","csi1000_attention_features.csv")) {
            $src = Join-Path $FundamentalDir $name
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $fundArchive $name) -Force }
        }
    }

    $manifest = [pscustomobject]@{
        archived_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        trade_date = $TradeDate
        daily_dir = $DailyDir
        fundamental_dir = $FundamentalDir
        dashboard_html = $DashboardPath
        ai_summary_json = $AiSummary.json
        ai_summary_markdown = $AiSummary.markdown
        ai_summary_html = $AiSummary.html
        archive_dir = $archiveDir
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $archiveDir "research_archive_manifest.json") -Encoding UTF8
    return $archiveDir
}

if ($Collect) {
    if (-not (Test-Path -LiteralPath $MonitorScript)) { throw "Monitor script not found: $MonitorScript" }
    $monitorArgs = @(
        "-Iterations", [string]$Iterations,
        "-IntervalSeconds", [string]$IntervalSeconds,
        "-SampleMinutes", [string]$SampleMinutes,
        "-MinMatchedComponents", "980",
        "-MinFieldCoverage", "0.95",
        "-MinChangedSymbolRatio", "0.05",
        "-SessionOnly",
        "-OutRoot", $OutRoot
    )
    $monitorResult = Invoke-AndCapture $MonitorScript $monitorArgs
    if ($monitorResult -and $monitorResult.output_dir) { $DailyDir = $monitorResult.output_dir }
}

if (-not $DailyDir) { $DailyDir = Get-LatestDirWithFile $OutRoot "latest_signals.csv" }
if (-not $DailyDir) { throw "No daily run directory found under $OutRoot" }

if (-not $MarketDir) { $MarketDir = Get-LatestDirWithFile $MarketRoot "report.html" }
if (-not $MarketDir) { $MarketDir = "C:\ftshare_data\market_state_research\20260716_20260716_101206" }

if (-not $FundamentalDir) {
    if (-not (Test-Path -LiteralPath $ExplainScript)) { throw "Explain script not found: $ExplainScript" }
    $explainArgs = @("-DailyDir", $DailyDir, "-MarketDir", $MarketDir, "-TradeDate", $TradeDate, "-MaxSymbols", [string]$MaxSymbols, "-MaxNewsQueries", [string]$MaxNewsQueries)
    if ($SkipExplainNetwork) { $explainArgs += "-SkipNetwork" }
    $explainResult = Invoke-AndCapture $ExplainScript $explainArgs
    if ($explainResult -and $explainResult.output_dir) { $FundamentalDir = $explainResult.output_dir }
}

if (-not $FundamentalDir) { throw "Fundamental explanation directory is empty" }

if (-not (Test-Path -LiteralPath $DashboardScript)) { throw "Dashboard script not found: $DashboardScript" }
$dashboardResult = Invoke-AndCapture $DashboardScript @("-DailyDir", $DailyDir, "-MarketDir", $MarketDir, "-FundamentalDir", $FundamentalDir)
$dashboardPath = if ($dashboardResult) { [string]$dashboardResult } else { Join-Path $DailyDir "integrated_research_dashboard.html" }
if (-not (Test-Path -LiteralPath $dashboardPath)) { $dashboardPath = Join-Path $DailyDir "integrated_research_dashboard.html" }

$archivePreviewDir = Join-Path (Join-Path $ArchiveRoot ($TradeDate -replace "-", "")) (Split-Path -Leaf $DailyDir)
$aiSummary = New-ResearchSummary -DailyDir $DailyDir -MarketDir $MarketDir -FundamentalDir $FundamentalDir -DashboardPath $dashboardPath -ArchiveDir $archivePreviewDir
$archiveDir = Save-ResearchArchive -DailyDir $DailyDir -FundamentalDir $FundamentalDir -DashboardPath $dashboardPath -AiSummary $aiSummary

$result = [pscustomobject]@{
    status = "complete"
    trade_date = $TradeDate
    daily_dir = $DailyDir
    market_dir = $MarketDir
    fundamental_dir = $FundamentalDir
    dashboard_html = $dashboardPath
    ai_summary_json = $aiSummary.json
    ai_summary_markdown = $aiSummary.markdown
    ai_summary_html = $aiSummary.html
    archive_dir = $archiveDir
}
$result | ConvertTo-Json -Depth 6

