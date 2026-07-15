param(
    [int]$Iterations = 2,
    [int]$IntervalSeconds = 20,
    [string]$OutRoot = "C:\ftshare_data\csi1000_intraday",
    [string]$IndexCode = "000852"
)

$ErrorActionPreference = "Stop"

$IndexWeightUrl = "https://market.ft.tech/gateway/api/v1/market/data/index/index_weight"
$RealtimeUrl = "https://market.ft.tech/gateway/api/v1/market/data/stock-list/filter"
$SwOverviewUrl = "https://market.ft.tech/gateway/api/v1/market/data/sw-industry/overview"
$SwConstituentUrl = "https://market.ft.tech/gateway/api/v1/market/data/sw-industry/constituent-history"
$PageSize = 200
$WeightPageSize = 100
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $OutRoot $Stamp

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Invoke-JsonGet {
    param([string]$Url, [hashtable]$Params)
    $Query = ($Params.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
    }) -join "&"
    $FullUrl = "$Url`?$Query"
    $LastError = $null
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            $Response = Invoke-WebRequest -Uri $FullUrl -UseBasicParsing -Headers @{ "User-Agent" = "ftshare-csi1000-intraday-monitor/1.1" } -TimeoutSec 30
            $Text = [Text.Encoding]::UTF8.GetString($Response.RawContentStream.ToArray())
            return $Text | ConvertFrom-Json
        } catch {
            $LastError = $_
            Start-Sleep -Milliseconds (500 * $Attempt)
        }
    }
    throw $LastError
}

function Convert-ToDoubleOrNull {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Format-DashboardValue {
    param($Value, [string]$Kind = "number")
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "" }
    $Number = Convert-ToDoubleOrNull $Value
    if ($null -eq $Number) { return [Net.WebUtility]::HtmlEncode([string]$Value) }
    switch ($Kind) {
        "percent" { return ("{0:P2}" -f $Number) }
        "money" { return ("{0:N0}" -f $Number) }
        default { return ("{0:N6}" -f $Number) }
    }
}

function Get-ZScoreMap {
    param([object[]]$Rows, [string]$Field)
    $Values = @($Rows | ForEach-Object { Convert-ToDoubleOrNull $_.$Field } | Where-Object { $null -ne $_ })
    if ($Values.Count -eq 0) { return @{} }
    $Mean = ($Values | Measure-Object -Average).Average
    $Variance = 0.0
    foreach ($Value in $Values) { $Variance += [Math]::Pow($Value - $Mean, 2) }
    $Std = [Math]::Sqrt($Variance / [Math]::Max($Values.Count, 1))
    if ($Std -eq 0) { $Std = 1.0 }
    $Map = @{}
    foreach ($Row in $Rows) {
        $Value = Convert-ToDoubleOrNull $Row.$Field
        $Map[[string]$Row.symbol] = if ($null -eq $Value) { 0.0 } else { ($Value - $Mean) / $Std }
    }
    return $Map
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $Sorted = @($Values | Sort-Object)
    $Mid = [int]($Sorted.Count / 2)
    if ($Sorted.Count % 2 -eq 1) { return $Sorted[$Mid] }
    return ($Sorted[$Mid - 1] + $Sorted[$Mid]) / 2
}

function Get-IndexWeights {
    $First = Invoke-JsonGet -Url $IndexWeightUrl -Params @{ index_code = $IndexCode; page = 1; page_size = $WeightPageSize }
    $TotalPages = [Math]::Ceiling([double]$First.total / $WeightPageSize)
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Item in @($First.index_weights)) { $Rows.Add($Item) }
    for ($Page = 2; $Page -le $TotalPages; $Page++) {
        $Payload = Invoke-JsonGet -Url $IndexWeightUrl -Params @{ index_code = $IndexCode; page = $Page; page_size = $WeightPageSize }
        foreach ($Item in @($Payload.index_weights)) { $Rows.Add($Item) }
        Start-Sleep -Milliseconds 80
    }
    return $Rows
}

function Get-RealtimeAll {
    $First = Invoke-JsonGet -Url $RealtimeUrl -Params @{ page = 1; page_size = $PageSize }
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Item in @($First.items)) { $Rows.Add($Item) }
    for ($Page = 2; $Page -le [int]$First.total_pages; $Page++) {
        $Payload = Invoke-JsonGet -Url $RealtimeUrl -Params @{ page = $Page; page_size = $PageSize }
        foreach ($Item in @($Payload.items)) { $Rows.Add($Item) }
        Start-Sleep -Milliseconds 40
    }
    return $Rows
}

function Get-SwOverviewDate {
    for ($Offset = 0; $Offset -lt 15; $Offset++) {
        $Date = (Get-Date).AddDays(-$Offset).ToString("yyyyMMdd")
        try {
            $Payload = Invoke-JsonGet -Url $SwOverviewUrl -Params @{ date = $Date; level = 1; page = 1; page_size = 100 }
            if ($Payload.data.records -and @($Payload.data.records).Count -gt 0) { return @{ date = $Date; records = @($Payload.data.records) } }
        } catch { }
    }
    return $null
}

function Get-SwIndustryMap {
    $Result = @{ Available = $false; Date = $null; Map = @{}; Industries = @(); Error = $null }
    try {
        $Overview = Get-SwOverviewDate
        if ($null -eq $Overview) { $Result.Error = "未找到可用申万一级行业总览数据"; return $Result }
        $Result.Date = $Overview.date
        $Result.Industries = $Overview.records
        $Today = Get-Date -Format "yyyy-MM-dd"
        foreach ($Industry in $Overview.records) {
            $Code = [string]$Industry.industryCode
            if ([string]::IsNullOrWhiteSpace($Code)) { continue }
            try {
                $Payload = Invoke-JsonGet -Url $SwConstituentUrl -Params @{ industry_code = $Code }
                foreach ($Item in @($Payload.data.items)) {
                    $OutDate = [string]$Item.outDate
                    if (-not [string]::IsNullOrWhiteSpace($OutDate) -and $OutDate -lt $Today) { continue }
                    $StockCode = [string]$Item.stockCode
                    if (-not $Result.Map.ContainsKey($StockCode)) {
                        $Result.Map[$StockCode] = [pscustomobject]@{
                            sw_level1_code = $Item.swLevel1Code
                            sw_level1_name = $Item.swLevel1Name
                            sw_level2_code = $Item.swLevel2Code
                            sw_level2_name = $Item.swLevel2Name
                            sw_level3_code = $Item.swLevel3Code
                            sw_level3_name = $Item.swLevel3Name
                        }
                    }
                }
                Start-Sleep -Milliseconds 80
            } catch { }
        }
        $Result.Available = $Result.Map.Count -gt 0
        if (-not $Result.Available) { $Result.Error = "申万行业成分映射为空" }
        return $Result
    } catch {
        $Result.Error = $_.Exception.Message
        return $Result
    }
}

function New-SnapshotRows {
    param([object[]]$RealtimeRows, [object[]]$Components, [hashtable]$IndustryMap, [string]$SnapshotTime)
    $QuoteByCode = @{}
    foreach ($Quote in $RealtimeRows) { if ($Quote.symbol_id) { $QuoteByCode[[string]$Quote.symbol_id] = $Quote } }
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Component in $Components) {
        $Code = [string]$Component.component_code
        if (-not $QuoteByCode.ContainsKey($Code)) { continue }
        $Quote = $QuoteByCode[$Code]
        $Weight = Convert-ToDoubleOrNull $Component.weight
        $ChangeRate = Convert-ToDoubleOrNull $Quote.change_rate
        $Contribution = if ($null -ne $Weight -and $null -ne $ChangeRate) { $Weight * $ChangeRate } else { $null }
        $Industry = if ($IndustryMap.ContainsKey($Code)) { $IndustryMap[$Code] } else { $null }
        $Rows.Add([pscustomobject]@{
            snapshot_time = $SnapshotTime; index_code = $Component.index_code; index_weight_date = $Component.date
            component_code = $Code; component_name = $Component.component_name; weight = $Component.weight; symbol = $Quote.symbol; board = $Quote.board
            sw_level1_code = if ($Industry) { $Industry.sw_level1_code } else { "" }
            sw_level1_name = if ($Industry) { $Industry.sw_level1_name } else { "未映射" }
            sw_level2_code = if ($Industry) { $Industry.sw_level2_code } else { "" }
            sw_level2_name = if ($Industry) { $Industry.sw_level2_name } else { "" }
            open = $Quote.open; high = $Quote.high; low = $Quote.low; close = $Quote.close; prev_close = $Quote.prev_close; change = $Quote.change
            change_rate = $Quote.change_rate; volume = $Quote.volume; turnover = $Quote.turnover; amplitude = $Quote.amplitude
            change_rate_day5 = $Quote.change_rate_day5; change_rate_day10 = $Quote.change_rate_day10; change_rate_day20 = $Quote.change_rate_day20
            change_rate_day60 = $Quote.change_rate_day60; change_rate_ytd = $Quote.change_rate_ytd; ts_nanos = $Quote.ts_nanos
            weighted_change_contribution = $Contribution
        })
    }
    return $Rows
}

function New-SignalRows {
    param([object[]]$CurrentRows, [object[]]$PreviousRows, [string]$SnapshotTime)
    $PrevBySymbol = @{}
    foreach ($Row in $PreviousRows) { $PrevBySymbol[[string]$Row.symbol] = $Row }
    $Signals = New-Object System.Collections.Generic.List[object]
    foreach ($Row in $CurrentRows) {
        $Prev = $PrevBySymbol[[string]$Row.symbol]
        if ($null -eq $Prev) { continue }
        $Close = Convert-ToDoubleOrNull $Row.close; $PrevClose = Convert-ToDoubleOrNull $Prev.close
        $Volume = Convert-ToDoubleOrNull $Row.volume; $PrevVolume = Convert-ToDoubleOrNull $Prev.volume
        $Turnover = Convert-ToDoubleOrNull $Row.turnover; $PrevTurnover = Convert-ToDoubleOrNull $Prev.turnover
        $IntervalReturn = if ($null -ne $Close -and $null -ne $PrevClose -and $PrevClose -ne 0) { ($Close - $PrevClose) / $PrevClose } else { $null }
        $VolumeDelta = if ($null -ne $Volume -and $null -ne $PrevVolume) { $Volume - $PrevVolume } else { $null }
        $TurnoverDelta = if ($null -ne $Turnover -and $null -ne $PrevTurnover) { $Turnover - $PrevTurnover } else { $null }
        $PositiveTurnoverDelta = if ($null -ne $TurnoverDelta -and $TurnoverDelta -gt 0) { $TurnoverDelta } else { 0.0 }
        $ResonanceScore = if ($null -ne $IntervalReturn) { $IntervalReturn * [Math]::Log(1 + $PositiveTurnoverDelta) } else { $null }
        $RiskScore = if ($null -ne $IntervalReturn) { [Math]::Max(-$IntervalReturn, 0) * [Math]::Log(1 + $PositiveTurnoverDelta) } else { $null }
        $Signals.Add([pscustomobject]@{
            snapshot_time = $SnapshotTime; symbol = $Row.symbol; component_name = $Row.component_name; weight = $Row.weight
            sw_level1_code = $Row.sw_level1_code; sw_level1_name = $Row.sw_level1_name
            close = $Row.close; change_rate = $Row.change_rate; interval_return = $IntervalReturn; volume_delta = $VolumeDelta; turnover = $Row.turnover
            turnover_delta = $TurnoverDelta; weighted_change_contribution = (Convert-ToDoubleOrNull $Row.weighted_change_contribution)
            resonance_score = $ResonanceScore; risk_score = $RiskScore; amplitude = $Row.amplitude; ts_nanos = $Row.ts_nanos
        })
    }
    return $Signals
}

function Add-SignalScores {
    param([object[]]$Signals)
    $MomentumZ = Get-ZScoreMap $Signals "interval_return"
    $TurnoverZ = Get-ZScoreMap $Signals "turnover_delta"
    $StrengthZ = Get-ZScoreMap $Signals "change_rate"
    $RiskZ = Get-ZScoreMap $Signals "risk_score"
    foreach ($Signal in $Signals) {
        $Symbol = [string]$Signal.symbol
        $Composite = $MomentumZ[$Symbol] + $TurnoverZ[$Symbol] + $StrengthZ[$Symbol] - $RiskZ[$Symbol]
        $Label = "中性"; $Reason = "信号未达到强势、放量或风险阈值"
        $ChangeRate = Convert-ToDoubleOrNull $Signal.change_rate
        $TurnoverDelta = Convert-ToDoubleOrNull $Signal.turnover_delta
        $IntervalReturn = Convert-ToDoubleOrNull $Signal.interval_return
        if ($RiskZ[$Symbol] -ge 1 -and $IntervalReturn -lt 0) { $Label = "风险预警"; $Reason = "短周期下跌且成交额放大" }
        elseif ($Composite -ge 1 -and $ChangeRate -gt 0 -and $TurnoverDelta -ge 0) { $Label = "强势观察"; $Reason = "综合动量、资金和当日强度较高" }
        elseif ($TurnoverZ[$Symbol] -ge 1 -and (Convert-ToDoubleOrNull $Signal.resonance_score) -gt 0) { $Label = "放量异动"; $Reason = "成交额增量显著且价格方向偏强" }
        $Signal | Add-Member -NotePropertyName momentum_z -NotePropertyValue $MomentumZ[$Symbol] -Force
        $Signal | Add-Member -NotePropertyName turnover_z -NotePropertyValue $TurnoverZ[$Symbol] -Force
        $Signal | Add-Member -NotePropertyName strength_z -NotePropertyValue $StrengthZ[$Symbol] -Force
        $Signal | Add-Member -NotePropertyName risk_z -NotePropertyValue $RiskZ[$Symbol] -Force
        $Signal | Add-Member -NotePropertyName composite_score -NotePropertyValue $Composite -Force
        $Signal | Add-Member -NotePropertyName prediction_label -NotePropertyValue $Label -Force
        $Signal | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force
    }
    return $Signals
}

function New-DailyAnalysis {
    param([object[]]$Signals)
    $ChangeRates = @($Signals | ForEach-Object { Convert-ToDoubleOrNull $_.change_rate } | Where-Object { $null -ne $_ })
    $TotalTurnover = ($Signals | ForEach-Object { Convert-ToDoubleOrNull $_.turnover } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum
    $TopContributors = @($Signals | Sort-Object @{ Expression = "weighted_change_contribution"; Descending = $true } | Select-Object -First 10 symbol,component_name,sw_level1_name,weighted_change_contribution,change_rate)
    $BottomContributors = @($Signals | Sort-Object @{ Expression = "weighted_change_contribution"; Descending = $false } | Select-Object -First 10 symbol,component_name,sw_level1_name,weighted_change_contribution,change_rate)
    return [pscustomobject]@{
        up_count = @($Signals | Where-Object { (Convert-ToDoubleOrNull $_.change_rate) -gt 0 }).Count
        down_count = @($Signals | Where-Object { (Convert-ToDoubleOrNull $_.change_rate) -lt 0 }).Count
        flat_count = @($Signals | Where-Object { (Convert-ToDoubleOrNull $_.change_rate) -eq 0 }).Count
        avg_change_rate = if ($ChangeRates.Count) { ($ChangeRates | Measure-Object -Average).Average } else { $null }
        median_change_rate = Get-Median $ChangeRates
        total_turnover = $TotalTurnover
        strong_observe_count = @($Signals | Where-Object prediction_label -eq "强势观察").Count
        volume_abnormal_count = @($Signals | Where-Object prediction_label -eq "放量异动").Count
        risk_warning_count = @($Signals | Where-Object prediction_label -eq "风险预警").Count
        top_contributors = $TopContributors
        bottom_contributors = $BottomContributors
    }
}

function New-SectorRotation {
    param([object[]]$Signals)
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Group in ($Signals | Group-Object sw_level1_name)) {
        $Items = @($Group.Group)
        $Rows.Add([pscustomobject]@{
            sw_level1_name = if ([string]::IsNullOrWhiteSpace($Group.Name)) { "未映射" } else { $Group.Name }
            component_count = $Items.Count
            avg_change_rate = (@($Items | ForEach-Object { Convert-ToDoubleOrNull $_.change_rate } | Where-Object { $null -ne $_ }) | Measure-Object -Average).Average
            turnover_delta_sum = (@($Items | ForEach-Object { Convert-ToDoubleOrNull $_.turnover_delta } | Where-Object { $null -ne $_ }) | Measure-Object -Sum).Sum
            avg_interval_return = (@($Items | ForEach-Object { Convert-ToDoubleOrNull $_.interval_return } | Where-Object { $null -ne $_ }) | Measure-Object -Average).Average
            avg_resonance_score = (@($Items | ForEach-Object { Convert-ToDoubleOrNull $_.resonance_score } | Where-Object { $null -ne $_ }) | Measure-Object -Average).Average
            weighted_contribution_sum = (@($Items | ForEach-Object { Convert-ToDoubleOrNull $_.weighted_change_contribution } | Where-Object { $null -ne $_ }) | Measure-Object -Sum).Sum
            strong_count = @($Items | Where-Object prediction_label -eq "强势观察").Count
            risk_count = @($Items | Where-Object prediction_label -eq "风险预警").Count
        })
    }
    $A = Get-ZScoreMap $Rows "avg_change_rate"; $B = Get-ZScoreMap $Rows "turnover_delta_sum"; $C = Get-ZScoreMap $Rows "avg_interval_return"
    foreach ($Row in $Rows) {
        $Key = [string]$Row.symbol
        if ([string]::IsNullOrWhiteSpace($Key)) { $Key = [string]$Row.sw_level1_name }
    }
    foreach ($Row in $Rows) {
        $Name = [string]$Row.sw_level1_name
        $Score = 0.0
        $AvgZ = if ($Rows.Count -gt 1) { (($Rows.avg_change_rate | Where-Object { $null -ne $_ } | Measure-Object -Average).Average) } else { 0 }
        $Row | Add-Member -NotePropertyName sector_score -NotePropertyValue 0.0 -Force
    }
    $Fields = @("avg_change_rate", "turnover_delta_sum", "avg_interval_return")
    foreach ($Field in $Fields) {
        $Values = @($Rows | ForEach-Object { Convert-ToDoubleOrNull $_.$Field } | Where-Object { $null -ne $_ })
        if ($Values.Count -eq 0) { continue }
        $Mean = ($Values | Measure-Object -Average).Average
        $Var = 0.0; foreach ($V in $Values) { $Var += [Math]::Pow($V - $Mean, 2) }
        $Std = [Math]::Sqrt($Var / [Math]::Max($Values.Count, 1)); if ($Std -eq 0) { $Std = 1.0 }
        foreach ($Row in $Rows) {
            $V = Convert-ToDoubleOrNull $Row.$Field
            $Z = if ($null -eq $V) { 0.0 } else { ($V - $Mean) / $Std }
            $Row.sector_score += $Z
        }
    }
    return @($Rows | Sort-Object @{ Expression = "sector_score"; Descending = $true })
}

function New-PredictionWatchlist {
    param([object[]]$Signals)
    return @(
        $Signals | Sort-Object @{ Expression = "composite_score"; Descending = $true } | Where-Object { $_.prediction_label -eq "强势观察" } | Select-Object -First 20
        $Signals | Sort-Object @{ Expression = "resonance_score"; Descending = $true } | Where-Object { $_.prediction_label -eq "放量异动" } | Select-Object -First 20
        $Signals | Sort-Object @{ Expression = "risk_score"; Descending = $true } | Where-Object { $_.prediction_label -eq "风险预警" } | Select-Object -First 20
    )
}

function New-DashboardTable {
    param([string]$Title, [object[]]$Rows, [string]$ScoreField, [string]$ScoreLabel, [string]$ScoreKind = "number")
    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.AppendLine("<section class=""board""><h2>$([Net.WebUtility]::HtmlEncode($Title))</h2><table>")
    [void]$Builder.AppendLine("<thead><tr><th>#</th><th>代码</th><th>名称</th><th>最新价</th><th>当日涨跌幅</th><th>短周期收益</th><th>成交额增量</th><th>权重</th><th>$([Net.WebUtility]::HtmlEncode($ScoreLabel))</th></tr></thead><tbody>")
    $Rank = 1
    foreach ($Row in $Rows) {
        [void]$Builder.AppendLine("<tr><td>$Rank</td><td>$([Net.WebUtility]::HtmlEncode([string]$Row.symbol))</td><td>$([Net.WebUtility]::HtmlEncode([string]$Row.component_name))</td><td>$(Format-DashboardValue $Row.close)</td><td>$(Format-DashboardValue $Row.change_rate percent)</td><td>$(Format-DashboardValue $Row.interval_return percent)</td><td>$(Format-DashboardValue $Row.turnover_delta money)</td><td>$(Format-DashboardValue $Row.weight)</td><td>$(Format-DashboardValue $Row.$ScoreField $ScoreKind)</td></tr>")
        $Rank++
    }
    [void]$Builder.AppendLine("</tbody></table></section>")
    return $Builder.ToString()
}

function New-SimpleTableHtml {
    param([string]$Title, [object[]]$Rows, [string[]]$Fields, [hashtable]$Labels)
    $B = New-Object System.Text.StringBuilder
    [void]$B.AppendLine("<section class=""board wide""><h2>$([Net.WebUtility]::HtmlEncode($Title))</h2><table><thead><tr>")
    foreach ($F in $Fields) { [void]$B.AppendLine("<th>$([Net.WebUtility]::HtmlEncode($Labels[$F]))</th>") }
    [void]$B.AppendLine("</tr></thead><tbody>")
    foreach ($R in $Rows) {
        [void]$B.AppendLine("<tr>")
        foreach ($F in $Fields) { [void]$B.AppendLine("<td>$([Net.WebUtility]::HtmlEncode([string]$R.$F))</td>") }
        [void]$B.AppendLine("</tr>")
    }
    [void]$B.AppendLine("</tbody></table></section>")
    return $B.ToString()
}

function Write-DashboardHtml {
    param([object[]]$Signals, [object]$DailyAnalysis, [object[]]$SectorRows, [object[]]$WatchlistRows, [string]$IndustryStatus, [string]$Path, [string]$SnapshotTime, [int]$MatchedComponents, [int]$TopN = 20)
    $Tables = @(
        New-DashboardTable "涨速榜" (@($Signals | Sort-Object @{ Expression = "interval_return"; Descending = $true } | Select-Object -First $TopN)) "interval_return" "短周期收益" "percent"
        New-DashboardTable "成交额增量榜" (@($Signals | Sort-Object @{ Expression = "turnover_delta"; Descending = $true } | Select-Object -First $TopN)) "turnover_delta" "成交额增量" "money"
        New-DashboardTable "量价共振榜" (@($Signals | Sort-Object @{ Expression = "resonance_score"; Descending = $true } | Select-Object -First $TopN)) "resonance_score" "量价共振分"
        New-DashboardTable "当日强势榜" (@($Signals | Sort-Object @{ Expression = "change_rate"; Descending = $true } | Select-Object -First $TopN)) "change_rate" "当日涨跌幅" "percent"
        New-DashboardTable "权重贡献榜" (@($Signals | Sort-Object @{ Expression = "weighted_change_contribution"; Descending = $true } | Select-Object -First $TopN)) "weighted_change_contribution" "权重贡献"
        New-DashboardTable "风险预警榜" (@($Signals | Sort-Object @{ Expression = "risk_score"; Descending = $true } | Select-Object -First $TopN)) "risk_score" "风险分"
    ) -join "`n"
    $SectorTable = New-SimpleTableHtml "板块轮动（申万一级）" (@($SectorRows | Select-Object -First 30)) @("sw_level1_name","component_count","avg_change_rate","turnover_delta_sum","avg_interval_return","weighted_contribution_sum","strong_count","risk_count","sector_score") @{ sw_level1_name="行业"; component_count="成分数"; avg_change_rate="平均涨跌幅"; turnover_delta_sum="成交额增量"; avg_interval_return="行业动量"; weighted_contribution_sum="贡献合计"; strong_count="强势数"; risk_count="风险数"; sector_score="轮动分" }
    $WatchTable = New-SimpleTableHtml "预测/观察清单" $WatchlistRows @("prediction_label","symbol","component_name","sw_level1_name","close","change_rate","interval_return","turnover_delta","composite_score","reason") @{ prediction_label="标签"; symbol="代码"; component_name="名称"; sw_level1_name="行业"; close="最新价"; change_rate="当日涨跌幅"; interval_return="短周期收益"; turnover_delta="成交额增量"; composite_score="综合分"; reason="原因" }
    $GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Html = @"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>中证1000盘中综合看板</title><style>
body{margin:0;background:#f5f7fb;color:#172033;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1440px;margin:0 auto;padding:28px}h1{margin:0 0 10px;font-size:28px}.meta{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:22px;color:#526076}.pill{background:#fff;border:1px solid #e2e8f0;border-radius:999px;padding:6px 12px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(560px,1fr));gap:18px}.board{background:#fff;border:1px solid #e2e8f0;border-radius:8px;overflow:hidden;box-shadow:0 8px 22px rgba(15,23,42,.06)}.wide{grid-column:1/-1}h2{margin:0;padding:14px 16px;font-size:18px;border-bottom:1px solid #e2e8f0;background:#f8fafc}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:7px 9px;border-bottom:1px solid #edf2f7;text-align:right;white-space:nowrap}th:nth-child(2),th:nth-child(3),td:nth-child(2),td:nth-child(3){text-align:left}th{background:#fbfdff;color:#475569;font-weight:700}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:18px}.card{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:14px}.card b{display:block;font-size:22px}.note{margin:20px 0;color:#64748b;font-size:13px}
</style></head><body><main><h1>中证1000盘中综合看板</h1><div class="meta"><span class="pill">生成时间：$GeneratedAt</span><span class="pill">快照时间：$([Net.WebUtility]::HtmlEncode($SnapshotTime))</span><span class="pill">匹配成分股：$MatchedComponents</span><span class="pill">$([Net.WebUtility]::HtmlEncode($IndustryStatus))</span></div>
<div class="grid">$Tables</div>
<h2>每日分析</h2><div class="cards"><div class="card">上涨家数<b>$($DailyAnalysis.up_count)</b></div><div class="card">下跌家数<b>$($DailyAnalysis.down_count)</b></div><div class="card">平均涨跌幅<b>$(Format-DashboardValue $DailyAnalysis.avg_change_rate percent)</b></div><div class="card">中位涨跌幅<b>$(Format-DashboardValue $DailyAnalysis.median_change_rate percent)</b></div><div class="card">成交额合计<b>$(Format-DashboardValue $DailyAnalysis.total_turnover money)</b></div><div class="card">风险预警数<b>$($DailyAnalysis.risk_warning_count)</b></div></div>
<div class="grid">$SectorTable $WatchTable</div><div class="note">预测模块为信号观察，不构成确定性涨跌判断或投资建议。当前数据来自快照轮询，不是逐笔成交或盘口订单簿。</div></main></body></html>
"@
    [System.IO.File]::WriteAllText($Path, $Html, (New-Object System.Text.UTF8Encoding($false)))
}

$Components = @(Get-IndexWeights)
$ComponentsPath = Join-Path $RunDir "csi1000_components.csv"
$Components | Export-Csv -Path $ComponentsPath -NoTypeInformation -Encoding UTF8
$IndustryResult = Get-SwIndustryMap
$IndustryStatus = if ($IndustryResult.Available) { "申万一级行业映射：$($IndustryResult.Date)" } else { "行业数据不可用：$($IndustryResult.Error)" }
$AllSnapshotsPath = Join-Path $RunDir "csi1000_snapshots.csv"
$LatestSignalsPath = Join-Path $RunDir "latest_signals.csv"
$DashboardPath = Join-Path $RunDir "dashboard.html"
$SummaryPath = Join-Path $RunDir "summary.json"
$DailyAnalysisPath = Join-Path $RunDir "daily_analysis.json"
$SectorRotationPath = Join-Path $RunDir "sector_rotation.csv"
$PredictionWatchlistPath = Join-Path $RunDir "prediction_watchlist.csv"
$PreviousRows = @(); $IterationSummary = @()
for ($Iteration = 1; $Iteration -le $Iterations; $Iteration++) {
    $SnapshotTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $RealtimeRows = @(Get-RealtimeAll)
    $SnapshotRows = @(New-SnapshotRows -RealtimeRows $RealtimeRows -Components $Components -IndustryMap $IndustryResult.Map -SnapshotTime $SnapshotTime)
    $SnapshotPath = Join-Path $RunDir ("snapshot_{0:000}.csv" -f $Iteration)
    $SnapshotRows | Export-Csv -Path $SnapshotPath -NoTypeInformation -Encoding UTF8
    if ($Iteration -eq 1) { $SnapshotRows | Export-Csv -Path $AllSnapshotsPath -NoTypeInformation -Encoding UTF8 } else { $SnapshotRows | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $AllSnapshotsPath -Encoding UTF8 }
    $Signals = @()
    if ($PreviousRows.Count -gt 0) {
        $Signals = @(Add-SignalScores (New-SignalRows -CurrentRows $SnapshotRows -PreviousRows $PreviousRows -SnapshotTime $SnapshotTime))
        $SignalPath = Join-Path $RunDir ("signals_{0:000}.csv" -f $Iteration)
        $Signals | Export-Csv -Path $SignalPath -NoTypeInformation -Encoding UTF8
        $Signals | Sort-Object @{ Expression = "turnover_delta"; Descending = $true }, @{ Expression = "interval_return"; Descending = $true } | Select-Object -First 100 | Export-Csv -Path $LatestSignalsPath -NoTypeInformation -Encoding UTF8
        $DailyAnalysis = New-DailyAnalysis $Signals
        $SectorRows = @(New-SectorRotation $Signals)
        $WatchlistRows = @(New-PredictionWatchlist $Signals)
        $DailyAnalysis | ConvertTo-Json -Depth 6 | Set-Content -Path $DailyAnalysisPath -Encoding UTF8
        $SectorRows | Export-Csv -Path $SectorRotationPath -NoTypeInformation -Encoding UTF8
        $WatchlistRows | Export-Csv -Path $PredictionWatchlistPath -NoTypeInformation -Encoding UTF8
        Write-DashboardHtml -Signals $Signals -DailyAnalysis $DailyAnalysis -SectorRows $SectorRows -WatchlistRows $WatchlistRows -IndustryStatus $IndustryStatus -Path $DashboardPath -SnapshotTime $SnapshotTime -MatchedComponents $SnapshotRows.Count -TopN 20
    }
    $IndexApproxReturn = ($SnapshotRows | Where-Object { $_.weighted_change_contribution -ne $null } | Measure-Object -Property weighted_change_contribution -Sum).Sum
    $IterationSummary += [pscustomobject]@{ iteration=$Iteration; snapshot_time=$SnapshotTime; matched_components=$SnapshotRows.Count; signal_rows=@($Signals).Count; approx_weighted_change=$IndexApproxReturn; snapshot_csv=$SnapshotPath }
    $PreviousRows = $SnapshotRows
    if ($Iteration -lt $Iterations) { Start-Sleep -Seconds $IntervalSeconds }
}
$Result = [pscustomobject]@{ output_dir=$RunDir; components_csv=$ComponentsPath; snapshots_csv=$AllSnapshotsPath; latest_signals_csv=$LatestSignalsPath; dashboard_html=$DashboardPath; daily_analysis_json=$DailyAnalysisPath; sector_rotation_csv=$SectorRotationPath; prediction_watchlist_csv=$PredictionWatchlistPath; industry_status=$IndustryStatus; summary=$IterationSummary }
$Result | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding UTF8
$Result | ConvertTo-Json -Depth 6