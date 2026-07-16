param(
    [int]$Iterations = 2,
    [int]$IntervalSeconds = 20,
    [string]$OutRoot = "C:\ftshare_data\csi1000_intraday",
    [string]$IndexCode = "000852",
    [int]$SampleMinutes = 5,
    [int]$MinMatchedComponents = 980,
    [double]$MinFieldCoverage = 0.95,
    [double]$MinChangedSymbolRatio = 0.05,
    [switch]$SessionOnly
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
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "--" }
    $Number = Convert-ToDoubleOrNull $Value
    if ($null -eq $Number) { return [Net.WebUtility]::HtmlEncode([string]$Value) }
    switch ($Kind) {
        "percent" { return ("{0:P2}" -f $Number) }
        "money" { return ("{0:N0}" -f $Number) }
        default { return ("{0:N6}" -f $Number) }
    }
}

function Get-MarketStatus {
    param([datetime]$At = (Get-Date))
    if ($At.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) { return "NON_TRADING_DAY" }
    $Minutes = $At.Hour * 60 + $At.Minute
    if ($Minutes -lt 570) { return "PREOPEN" }
    if ($Minutes -le 690) { return "TRADING" }
    if ($Minutes -lt 780) { return "LUNCH" }
    if ($Minutes -le 900) { return "TRADING" }
    return "CLOSED"
}

function Get-SessionId {
    param([datetime]$At)
    $Minutes = $At.Hour * 60 + $At.Minute
    if ($Minutes -ge 570 -and $Minutes -le 690) { return "AM" }
    if ($Minutes -ge 780 -and $Minutes -le 900) { return "PM" }
    return "NONE"
}

function Wait-ForTradingSession {
    while ($true) {
        $Status = Get-MarketStatus (Get-Date)
        if ($Status -eq "TRADING") { return $true }
        if ($Status -in @("CLOSED", "NON_TRADING_DAY")) { return $false }
        Start-Sleep -Seconds 15
    }
}

function Get-FieldCoverage {
    param([object[]]$Rows, [string[]]$Fields)
    if ($Rows.Count -eq 0) { return 0.0 }
    $Expected = $Rows.Count * $Fields.Count
    $Present = 0
    foreach ($Row in $Rows) {
        foreach ($Field in $Fields) {
            if ($null -ne (Convert-ToDoubleOrNull $Row.$Field)) { $Present++ }
        }
    }
    return $Present / [double]$Expected
}

function Test-SnapshotQuality {
    param([object[]]$CurrentRows, [object[]]$PreviousRows, [datetime]$SnapshotAt)
    $Status = Get-MarketStatus $SnapshotAt
    $CloseCoverage = Get-FieldCoverage $CurrentRows @("close")
    $VolumeCoverage = Get-FieldCoverage $CurrentRows @("volume")
    $TurnoverCoverage = Get-FieldCoverage $CurrentRows @("turnover")
    $Coverage = ($CloseCoverage + $VolumeCoverage + $TurnoverCoverage) / 3.0
    $CoverageDetail = [pscustomobject]@{ close=$CloseCoverage; volume=$VolumeCoverage; turnover=$TurnoverCoverage; overall=$Coverage }
    $Comparable = 0; $Changed = 0; $Regressed = 0
    if ($PreviousRows.Count -gt 0) {
        $PreviousBySymbol = @{}
        foreach ($Row in $PreviousRows) { $PreviousBySymbol[[string]$Row.symbol] = $Row }
        foreach ($Row in $CurrentRows) {
            $Previous = $PreviousBySymbol[[string]$Row.symbol]
            if ($null -eq $Previous) { continue }
            $CurrentClose = Convert-ToDoubleOrNull $Row.close; $PreviousClose = Convert-ToDoubleOrNull $Previous.close
            $CurrentVolume = Convert-ToDoubleOrNull $Row.volume; $PreviousVolume = Convert-ToDoubleOrNull $Previous.volume
            $CurrentTurnover = Convert-ToDoubleOrNull $Row.turnover; $PreviousTurnover = Convert-ToDoubleOrNull $Previous.turnover
            if ($null -in @($CurrentClose,$PreviousClose,$CurrentVolume,$PreviousVolume,$CurrentTurnover,$PreviousTurnover)) { continue }
            $Comparable++
            if ($CurrentClose -ne $PreviousClose -or $CurrentVolume -ne $PreviousVolume -or $CurrentTurnover -ne $PreviousTurnover) { $Changed++ }
            if ($CurrentVolume -lt $PreviousVolume -or $CurrentTurnover -lt $PreviousTurnover) { $Regressed++ }
        }
    }
    $ChangedRatio = if ($Comparable -gt 0) { $Changed / [double]$Comparable } else { 0.0 }
    $RegressionRatio = if ($Comparable -gt 0) { $Regressed / [double]$Comparable } else { 0.0 }
    $Reasons = New-Object System.Collections.Generic.List[string]
    if ($Status -ne "TRADING") { $Reasons.Add("outside_continuous_trading") }
    if ($CurrentRows.Count -lt $MinMatchedComponents) { $Reasons.Add("matched_components_below_threshold") }
    if ($Coverage -lt $MinFieldCoverage) { $Reasons.Add("field_coverage_below_threshold") }
    if ($PreviousRows.Count -eq 0) { $Reasons.Add("baseline_only") }
    elseif ($ChangedRatio -lt $MinChangedSymbolRatio) { $Reasons.Add("changed_symbol_ratio_below_threshold") }
    if ($RegressionRatio -gt 0.01) { $Reasons.Add("cumulative_fields_regressed") }
    $CanBeBaseline = $Status -eq "TRADING" -and $CurrentRows.Count -ge $MinMatchedComponents -and $Coverage -ge $MinFieldCoverage -and $RegressionRatio -le 0.01
    $StaleSeconds = if ($Status -eq "CLOSED") { [Math]::Max(0, ($SnapshotAt - $SnapshotAt.Date.AddHours(15)).TotalSeconds) } else { 0 }
    return [pscustomobject]@{ market_status=$Status; is_valid_snapshot=($Reasons.Count -eq 0); can_be_baseline=$CanBeBaseline; matched_components=$CurrentRows.Count; field_coverage=$CoverageDetail; changed_symbol_ratio=$ChangedRatio; regression_ratio=$RegressionRatio; stale_seconds=$StaleSeconds; invalid_reasons=@($Reasons); snapshot_time=$SnapshotAt.ToString("yyyy-MM-dd HH:mm:ss.fff"); last_valid_signal_time=$null }
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

function Get-HorizonPreviousEntry {
    param([object[]]$History, [datetime]$CurrentAt, [int]$Minutes)
    $Target = $CurrentAt.AddMinutes(-$Minutes)
    $CurrentSession = Get-SessionId $CurrentAt
    $Candidates = @($History | Where-Object {
        $_.quality.can_be_baseline -and (Get-SessionId $_.at) -eq $CurrentSession -and $_.at -lt $CurrentAt
    })
    if ($Candidates.Count -eq 0) { return $null }
    $Selected = $Candidates | Sort-Object @{ Expression = { [Math]::Abs(($_.at - $Target).TotalSeconds) } } | Select-Object -First 1
    if ([Math]::Abs(($Selected.at - $Target).TotalSeconds) -gt ($SampleMinutes * 60 + 30)) { return $null }
    return $Selected
}

function New-MultiHorizonSignalRows {
    param([object[]]$CurrentRows, [object[]]$History, [datetime]$CurrentAt, [object]$Quality)
    $Horizons = @(5,15,30)
    $Maps = @{}
    foreach ($Horizon in $Horizons) {
        $Previous = Get-HorizonPreviousEntry -History $History -CurrentAt $CurrentAt -Minutes $Horizon
        $Map = @{}
        if ($Quality.is_valid_snapshot -and $null -ne $Previous) {
            foreach ($Signal in @(New-SignalRows -CurrentRows $CurrentRows -PreviousRows $Previous.rows -SnapshotTime $Quality.snapshot_time)) {
                $Map[[string]$Signal.symbol] = $Signal
            }
        }
        $Maps[$Horizon] = $Map
    }
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Current in $CurrentRows) {
        $Symbol = [string]$Current.symbol
        $Row = [pscustomobject]@{
            snapshot_time=$Quality.snapshot_time; symbol=$Symbol; component_name=$Current.component_name; weight=$Current.weight
            sw_level1_code=$Current.sw_level1_code; sw_level1_name=$Current.sw_level1_name; close=$Current.close; change_rate=$Current.change_rate
            interval_return=$null; volume_delta=$null; turnover=$Current.turnover; turnover_delta=$null
            weighted_change_contribution=(Convert-ToDoubleOrNull $Current.weighted_change_contribution)
            resonance_score=$null; risk_score=$null; amplitude=$Current.amplitude; ts_nanos=$Current.ts_nanos
            signal_valid=$false; signal_horizon="5m"
        }
        foreach ($Horizon in $Horizons) {
            $Signal = $Maps[$Horizon][$Symbol]
            $Suffix = "${Horizon}m"
            $Row | Add-Member -NotePropertyName "return_$Suffix" -NotePropertyValue $(if($Signal){$Signal.interval_return}else{$null})
            $Row | Add-Member -NotePropertyName "volume_delta_$Suffix" -NotePropertyValue $(if($Signal){$Signal.volume_delta}else{$null})
            $Row | Add-Member -NotePropertyName "turnover_delta_$Suffix" -NotePropertyValue $(if($Signal){$Signal.turnover_delta}else{$null})
            $Row | Add-Member -NotePropertyName "resonance_score_$Suffix" -NotePropertyValue $(if($Signal){$Signal.resonance_score}else{$null})
            $Row | Add-Member -NotePropertyName "risk_score_$Suffix" -NotePropertyValue $(if($Signal){$Signal.risk_score}else{$null})
        }
        $Five = $Maps[5][$Symbol]
        if ($Five) {
            $Row.interval_return=$Five.interval_return; $Row.volume_delta=$Five.volume_delta; $Row.turnover_delta=$Five.turnover_delta
            $Row.resonance_score=$Five.resonance_score; $Row.risk_score=$Five.risk_score; $Row.signal_valid=$true
        }
        $Rows.Add($Row)
    }
    return $Rows
}

function Add-MultiHorizonScores {
    param([object[]]$Signals)
    foreach ($Horizon in @(5,15,30)) {
        $Suffix = "${Horizon}m"
        $Temporary = @($Signals | ForEach-Object {
            [pscustomobject]@{
                symbol=$_.symbol; component_name=$_.component_name; weight=$_.weight; sw_level1_code=$_.sw_level1_code; sw_level1_name=$_.sw_level1_name
                close=$_.close; change_rate=$_.change_rate; interval_return=$_.$("return_$Suffix"); volume_delta=$_.$("volume_delta_$Suffix")
                turnover=$_.turnover; turnover_delta=$_.$("turnover_delta_$Suffix"); weighted_change_contribution=$_.weighted_change_contribution
                resonance_score=$_.$("resonance_score_$Suffix"); risk_score=$_.$("risk_score_$Suffix"); amplitude=$_.amplitude; ts_nanos=$_.ts_nanos
            }
        })
        $Scored = @(Add-SignalScores $Temporary)
        $BySymbol = @{}; foreach ($Item in $Scored) { $BySymbol[[string]$Item.symbol]=$Item }
        foreach ($Signal in $Signals) {
            $Item = $BySymbol[[string]$Signal.symbol]
            foreach ($Field in @("momentum_z","turnover_z","strength_z","risk_z","composite_score","prediction_label","reason")) {
                $Value = if ($Item) { $Item.$Field } else { $null }
                $Signal | Add-Member -NotePropertyName "${Field}_$Suffix" -NotePropertyValue $Value -Force
            }
        }
    }
    foreach ($Signal in $Signals) {
        foreach ($Field in @("momentum_z","turnover_z","strength_z","risk_z","composite_score","prediction_label","reason")) {
            $Signal | Add-Member -NotePropertyName $Field -NotePropertyValue $Signal.$("${Field}_5m") -Force
        }
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
        $ChangeRate = Convert-ToDoubleOrNull $Signal.change_rate
        $TurnoverDelta = Convert-ToDoubleOrNull $Signal.turnover_delta
        $IntervalReturn = Convert-ToDoubleOrNull $Signal.interval_return
        $Composite = $null
        $Label = "信号不可用"; $Reason = "短周期窗口缺少有效快照或未通过质量门禁"
        if ($null -ne $IntervalReturn -and $null -ne $TurnoverDelta) {
            $Composite = $MomentumZ[$Symbol] + $TurnoverZ[$Symbol] + $StrengthZ[$Symbol] - $RiskZ[$Symbol]
            $Label = "中性"; $Reason = "信号未达到强势、放量或风险阈值"
            if ($RiskZ[$Symbol] -ge 1 -and $IntervalReturn -lt 0 -and $TurnoverDelta -gt 0) { $Label = "负向放量样本"; $Reason = "有效窗口内短周期下跌且成交额放大" }
            elseif ($Composite -ge 1 -and $ChangeRate -gt 0 -and $IntervalReturn -gt 0 -and $TurnoverDelta -gt 0 -and $TurnoverZ[$Symbol] -ge 0) { $Label = "高综合分样本"; $Reason = "有效窗口内价格动量、成交额和当日强度共振" }
            elseif ($TurnoverZ[$Symbol] -ge 1 -and (Convert-ToDoubleOrNull $Signal.resonance_score) -gt 0) { $Label = "量价共振样本"; $Reason = "有效窗口内成交额增量显著且价格方向偏强" }
        }
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
        strong_observe_count = @($Signals | Where-Object prediction_label -eq "高综合分样本").Count
        volume_abnormal_count = @($Signals | Where-Object prediction_label -eq "量价共振样本").Count
        risk_warning_count = @($Signals | Where-Object prediction_label -eq "负向放量样本").Count
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
            strong_count = @($Items | Where-Object prediction_label -eq "高综合分样本").Count
            risk_count = @($Items | Where-Object prediction_label -eq "负向放量样本").Count
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
    param([object[]]$Signals, [string]$Horizon = "5m")
    $Composite = "composite_score_$Horizon"; $Resonance = "resonance_score_$Horizon"; $Risk = "risk_score_$Horizon"; $Label = "prediction_label_$Horizon"
    return @(
        $Signals | Where-Object { $_.$Label -eq "高综合分样本" } | Sort-Object @{ Expression = $Composite; Descending = $true } | Select-Object -First 20
        $Signals | Where-Object { $_.$Label -eq "量价共振样本" } | Sort-Object @{ Expression = $Resonance; Descending = $true } | Select-Object -First 20
        $Signals | Where-Object { $_.$Label -eq "负向放量样本" } | Sort-Object @{ Expression = $Risk; Descending = $true } | Select-Object -First 20
    )
}

function Get-LastValidArtifact {
    param([string]$Root, [string]$ExcludeRunDir, [datetime]$TradeDate)
    $Dirs = @(Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $ExcludeRunDir } | Sort-Object Name -Descending)
    foreach ($Dir in $Dirs) {
        $QPath = Join-Path $Dir.FullName "data_quality.json"; $SPath = Join-Path $Dir.FullName "latest_signals.csv"
        if (-not (Test-Path $QPath) -or -not (Test-Path $SPath)) { continue }
        try {
            $Q = Get-Content -Raw -Encoding UTF8 $QPath | ConvertFrom-Json
            if (-not $Q.last_valid_signal_time) { continue }
            $At = [datetime]::Parse([string]$Q.last_valid_signal_time)
            if ($At.Date -ne $TradeDate.Date) { continue }
            return [pscustomobject]@{ signals=@(Import-Csv -Path $SPath -Encoding UTF8); time=$At; source=$Dir.FullName }
        } catch { continue }
    }
    return $null
}

function New-DashboardTable {
    param([string]$Title,[object[]]$Rows,[string]$ReturnField,[string]$TurnoverField,[string]$ScoreField,[string]$ScoreLabel,[string]$ScoreKind="number")
    $B=New-Object Text.StringBuilder
    [void]$B.AppendLine("<section class=`"board`"><h2>$([Net.WebUtility]::HtmlEncode($Title))</h2><div class=`"table-wrap`"><table><thead><tr><th>#</th><th>代码</th><th>名称</th><th>最新价</th><th>当日涨跌幅</th><th>窗口收益</th><th>成交额增量</th><th>权重</th><th>$([Net.WebUtility]::HtmlEncode($ScoreLabel))</th></tr></thead><tbody>")
    if (@($Rows).Count -eq 0) { [void]$B.AppendLine('<tr><td colspan="9" class="empty">无有效数据</td></tr>') }
    $Rank=1
    foreach($Row in $Rows){
        [void]$B.AppendLine("<tr><td>$Rank</td><td>$([Net.WebUtility]::HtmlEncode([string]$Row.symbol))</td><td>$([Net.WebUtility]::HtmlEncode([string]$Row.component_name))</td><td>$(Format-DashboardValue $Row.close)</td><td>$(Format-DashboardValue $Row.change_rate percent)</td><td>$(Format-DashboardValue $Row.$ReturnField percent)</td><td>$(Format-DashboardValue $Row.$TurnoverField money)</td><td>$(Format-DashboardValue $Row.weight)</td><td>$(Format-DashboardValue $Row.$ScoreField $ScoreKind)</td></tr>");$Rank++
    }
    [void]$B.AppendLine('</tbody></table></div></section>'); return $B.ToString()
}

function New-HorizonTables {
    param([object[]]$Signals,[string]$Horizon,[int]$TopN=20)
    $R="return_$Horizon";$T="turnover_delta_$Horizon";$Res="resonance_score_$Horizon";$Risk="risk_score_$Horizon"
    $Valid=@($Signals | Where-Object { $null -ne (Convert-ToDoubleOrNull $_.$R) -and $null -ne (Convert-ToDoubleOrNull $_.$T) })
    if($Valid.Count -eq 0){return '<div class="unavailable">该窗口没有通过质量门禁的有效盘中差分，不生成涨速、成交额增量、量价共振或风险排名。</div>'}
    return @(
      New-DashboardTable "涨速榜" @($Valid|Sort-Object @{Expression=$R;Descending=$true}|Select-Object -First $TopN) $R $T $R "窗口收益" percent
      New-DashboardTable "成交额增量榜" @($Valid|Sort-Object @{Expression=$T;Descending=$true}|Select-Object -First $TopN) $R $T $T "成交额增量" money
      New-DashboardTable "量价共振榜" @($Valid|Where-Object {$null-ne(Convert-ToDoubleOrNull $_.$Res)}|Sort-Object @{Expression=$Res;Descending=$true}|Select-Object -First $TopN) $R $T $Res "量价共振分"
      New-DashboardTable "负向放量样本榜" @($Valid|Where-Object {$null-ne(Convert-ToDoubleOrNull $_.$Risk)}|Sort-Object @{Expression=$Risk;Descending=$true}|Select-Object -First $TopN) $R $T $Risk "风险分"
    ) -join "`n"
}

function New-SimpleTableHtml {
    param([string]$Title,[object[]]$Rows,[string[]]$Fields,[hashtable]$Labels)
    $B=New-Object Text.StringBuilder;[void]$B.AppendLine("<section class=`"board wide`"><h2>$([Net.WebUtility]::HtmlEncode($Title))</h2><div class=`"table-wrap`"><table><thead><tr>")
    foreach($F in $Fields){[void]$B.AppendLine("<th>$([Net.WebUtility]::HtmlEncode($Labels[$F]))</th>")};[void]$B.AppendLine('</tr></thead><tbody>')
    if(@($Rows).Count -eq 0){[void]$B.AppendLine("<tr><td colspan=`"$($Fields.Count)`" class=`"empty`">无有效数据</td></tr>")}
    foreach($Row in $Rows){[void]$B.AppendLine('<tr>');foreach($F in $Fields){$V=$Row.$F;if($null-eq(Convert-ToDoubleOrNull $V)-and[string]::IsNullOrWhiteSpace([string]$V)){$V='--'};[void]$B.AppendLine("<td>$([Net.WebUtility]::HtmlEncode([string]$V))</td>")};[void]$B.AppendLine('</tr>')}
    [void]$B.AppendLine('</tbody></table></div></section>');return $B.ToString()
}

function Write-DashboardHtml {
 param([object[]]$Signals,[object]$DailyAnalysis,[object[]]$SectorRows,[object[]]$WatchlistRows,[string]$IndustryStatus,[object]$Quality,[string]$Path,[string]$SnapshotTime,[int]$TopN=20,[bool]$UsingFallback=$false)
 $StatusMap=@{TRADING='连续竞价';PREOPEN='盘前';LUNCH='午间休市';CLOSED='已收盘';NON_TRADING_DAY='非交易日'};$MarketText=$StatusMap[[string]$Quality.market_status];if(-not$MarketText){$MarketText=[string]$Quality.market_status}
 $SignalState=if($Quality.is_valid_snapshot){'实时有效'}elseif($UsingFallback){'最近有效'}elseif($Quality.market_status-in@('CLOSED','LUNCH')){'降级'}else{'不可用'}
 $ReasonMap=@{outside_continuous_trading='不在连续竞价时段';matched_components_below_threshold='成分匹配不足';field_coverage_below_threshold='字段覆盖不足';baseline_only='仅建立基线';changed_symbol_ratio_below_threshold='市场更新比例不足';cumulative_fields_regressed='累计成交字段大面积倒退'}
 $Reasons=@($Quality.invalid_reasons|ForEach-Object{if($ReasonMap.ContainsKey([string]$_)){$ReasonMap[[string]$_]}else{[string]$_}})-join '；';if(-not$Reasons){$Reasons='全部质量门禁通过'}
 $Tabs=@();foreach($H in @('5m','15m','30m')){$Tabs+="<section id=`"panel-$H`" class=`"window-panel$(if($H-ne'5m'){' hidden'})`"><div class=`"grid`">$(New-HorizonTables $Signals $H $TopN)</div></section>"};$Tabs=$Tabs-join"`n"
 $DailyTables=@(New-DashboardTable '当日强势榜' @($Signals|Where-Object{$null-ne(Convert-ToDoubleOrNull $_.change_rate)}|Sort-Object @{Expression='change_rate';Descending=$true}|Select-Object -First $TopN) 'return_5m' 'turnover_delta_5m' 'change_rate' '当日涨跌幅' percent;New-DashboardTable '权重贡献榜' @($Signals|Where-Object{$null-ne(Convert-ToDoubleOrNull $_.weighted_change_contribution)}|Sort-Object @{Expression='weighted_change_contribution';Descending=$true}|Select-Object -First $TopN) 'return_5m' 'turnover_delta_5m' 'weighted_change_contribution' '权重贡献')-join"`n"
 $SectorTable=New-SimpleTableHtml '板块分析（申万一级）' @($SectorRows|Select-Object -First 30) @('sw_level1_name','component_count','avg_change_rate','turnover_delta_sum','avg_interval_return','weighted_contribution_sum','strong_count','risk_count','sector_score') @{sw_level1_name='行业';component_count='成分数';avg_change_rate='平均涨跌幅';turnover_delta_sum='成交额增量';avg_interval_return='行业动量';weighted_contribution_sum='贡献合计';strong_count='强势数';risk_count='风险数';sector_score='轮动分'}
 $WatchTable=New-SimpleTableHtml '事件样本清单' $WatchlistRows @('prediction_label','symbol','component_name','sw_level1_name','close','change_rate','interval_return','turnover_delta','composite_score','reason') @{prediction_label='标签';symbol='代码';component_name='名称';sw_level1_name='行业';close='最新价';change_rate='当日涨跌幅';interval_return='短周期收益';turnover_delta='成交额增量';composite_score='综合分';reason='原因'}
 $FallbackNote=if($UsingFallback){'<div class="warning">当前展示的是最近有效盘中信号，不是当前实时信号。时间见“最后有效信号”。</div>'}elseif(-not$Quality.is_valid_snapshot){'<div class="warning">当前快照未通过短周期质量门禁。短周期空值显示为 --，不会用 0 代替。</div>'}else{''}
 $GeneratedAt=Get-Date -Format 'yyyy-MM-dd HH:mm:ss';$Coverage=[Math]::Round(100*[double]$Quality.field_coverage.overall,1);$Changed=[Math]::Round(100*[double]$Quality.changed_symbol_ratio,1);$Last=if($Quality.last_valid_signal_time){[string]$Quality.last_valid_signal_time}else{'--'}
 $Html=@"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>中证1000盘中量价行为研究平台</title><style>
body{margin:0;background:#f4f6f9;color:#182230;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1480px;margin:auto;padding:24px}h1{font-size:27px;margin:0 0 14px;letter-spacing:0}.status{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-bottom:12px}.metric,.board{background:#fff;border:1px solid #dce3eb;border-radius:7px}.metric{padding:11px}.metric span{display:block;color:#657386;font-size:12px}.metric b{font-size:17px}.warning,.unavailable{padding:13px 15px;border:1px solid #e4b84f;background:#fff8df;border-radius:7px;margin:12px 0}.unavailable{grid-column:1/-1}.tabs{display:flex;gap:6px;margin:18px 0 10px}.tabs button{border:1px solid #c9d2dd;background:#fff;padding:8px 15px;border-radius:6px;cursor:pointer}.tabs button.active{background:#172b4d;color:#fff}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(580px,1fr));gap:14px}.board{overflow:hidden}.wide{grid-column:1/-1}.board h2{font-size:17px;margin:0;padding:12px 14px;background:#f8fafc;border-bottom:1px solid #e4e9ef}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:7px 8px;border-bottom:1px solid #edf0f4;text-align:right;white-space:nowrap}th:nth-child(2),th:nth-child(3),td:nth-child(2),td:nth-child(3){text-align:left}th{color:#526173;background:#fbfcfd}.empty{text-align:center!important;color:#7a8796}.hidden{display:none}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:12px 0 16px}.card{background:#fff;border:1px solid #dce3eb;border-radius:7px;padding:12px}.card b{display:block;font-size:21px}.section-title{margin:26px 0 10px}.note{color:#667386;font-size:13px;margin:18px 0}@media(max-width:700px){main{padding:12px}.grid{grid-template-columns:1fr}.status{grid-template-columns:1fr 1fr}}
.viz-grid{display:grid;grid-template-columns:repeat(12,1fr);gap:14px;margin:16px 0}.viz-panel{grid-column:span 4;background:#fff;border:1px solid #dce3eb;border-radius:7px;padding:14px;min-height:230px}.viz-panel.wide{grid-column:span 8}.viz-panel h3{font-size:15px;margin:0 0 6px}.viz-panel p{font-size:12px;color:#68768a;margin:0 0 10px}.viz-panel canvas{width:100%;height:180px;display:block}.signal-orbit{height:180px;display:flex;align-items:center;justify-content:center;position:relative}.signal-orbit .core{width:104px;height:104px;border:12px solid #d7dee8;border-top-color:#27845c;border-right-color:#d39b2a;border-radius:50%;display:flex;align-items:center;justify-content:center;text-align:center;font-weight:700}.legend{display:flex;gap:12px;flex-wrap:wrap;font-size:12px;color:#5f6d80}.legend i{display:inline-block;width:9px;height:9px;margin-right:4px}.research-details{margin:9px 0}.research-details>summary{cursor:pointer;background:#fff;border:1px solid #dce3eb;border-radius:7px;padding:11px 14px;font-weight:700}.research-details[open]>summary{border-radius:7px 7px 0 0}.research-details .board{border-top:0;border-radius:0 0 7px 7px}.research-details .board>h2{display:none}@media(max-width:900px){.viz-panel,.viz-panel.wide{grid-column:1/-1}}</style></head><body><main><h1>中证1000盘中量价行为研究平台</h1><div class="status"><div class="metric"><span>交易状态</span><b>$MarketText</b></div><div class="metric"><span>信号状态</span><b>$SignalState</b></div><div class="metric"><span>快照时间</span><b>$([Net.WebUtility]::HtmlEncode($SnapshotTime))</b></div><div class="metric"><span>最后有效信号</span><b>$([Net.WebUtility]::HtmlEncode($Last))</b></div><div class="metric"><span>成分匹配</span><b>$($Quality.matched_components)</b></div><div class="metric"><span>字段覆盖率</span><b>$Coverage%</b></div><div class="metric"><span>有效变化比例</span><b>$Changed%</b></div></div><div class="note">质量判断：$([Net.WebUtility]::HtmlEncode($Reasons))　生成时间：$GeneratedAt　$([Net.WebUtility]::HtmlEncode($IndustryStatus))</div>$FallbackNote
<section class="board wide" style="margin:14px 0"><h2>研究设计</h2><div style="padding:14px 16px;line-height:1.75"><b>核心问题：</b>中证1000内部的短周期价格变化、成交活跃度与行业扩散，是否存在稳定、可解释、可复现的统计关系？<br><b>解释变量：</b>5/15/30分钟收益、成交额增量、量价共振、负向放量、行业强度与扩散度。<br><b>待检验结果：</b>信号后续收益、最大有利变动、最大不利变动、波动率与回撤；当前页面只记录事件样本，不给出买卖建议。<br><b>有效性约束：</b>只有通过交易时段、覆盖率、市场更新比例和累计字段检查的样本，才能进入短周期统计。</div></section>
<section id="visual-research" class="viz-grid"><div class="viz-panel"><h3>市场宽度</h3><p>上涨、下跌和平盘样本的结构，不展示个股名单</p><canvas id="breadthChart" width="420" height="180"></canvas><div class="legend"><span><i style="background:#27845c"></i>上涨</span><span><i style="background:#c44f4f"></i>下跌</span><span><i style="background:#9aa6b5"></i>平盘</span></div></div><div class="viz-panel wide"><h3>行业强弱分布</h3><p>申万一级行业平均涨跌幅，横轴仅表示相对方向与幅度</p><canvas id="sectorChart" width="820" height="180"></canvas></div><div class="viz-panel"><h3>数据可信状态</h3><p>质量门禁决定短周期样本是否进入研究</p><div class="signal-orbit"><div class="core" id="qualityCore">读取中</div></div></div><div class="viz-panel wide"><h3>窗口可用性</h3><p>绿色表示存在有效事件样本，灰色表示当前窗口不可用于统计</p><canvas id="windowChart" width="820" height="180"></canvas></div></section><div class="tabs"><button class="active" data-window="5m">5分钟</button><button data-window="15m">15分钟</button><button data-window="30m">30分钟</button></div>$Tabs
<h2 class="section-title">当日行情</h2><div class="grid">$DailyTables</div><h2 class="section-title">每日分析</h2><div class="cards"><div class="card">上涨家数<b>$($DailyAnalysis.up_count)</b></div><div class="card">下跌家数<b>$($DailyAnalysis.down_count)</b></div><div class="card">平盘家数<b>$($DailyAnalysis.flat_count)</b></div><div class="card">平均涨跌幅<b>$(Format-DashboardValue $DailyAnalysis.avg_change_rate percent)</b></div><div class="card">中位涨跌幅<b>$(Format-DashboardValue $DailyAnalysis.median_change_rate percent)</b></div><div class="card">成交额合计<b>$(Format-DashboardValue $DailyAnalysis.total_turnover money)</b></div></div><div class="grid">$SectorTable $WatchTable</div><div class="note">0 表示接口明确返回且确实无变化；-- 表示缺失或无法计算；被质量门禁拦截的窗口不参与排名。事件标签仅用于统计研究，不构成投资建议。</div></main><script>document.querySelectorAll('[data-window]').forEach(function(b){b.onclick=function(){document.querySelectorAll('[data-window]').forEach(function(x){x.classList.remove('active')});document.querySelectorAll('.window-panel').forEach(function(x){x.classList.add('hidden')});b.classList.add('active');document.getElementById('panel-'+b.dataset.window).classList.remove('hidden')}});</script><script>(function(){function boardByTitle(word){return Array.from(document.querySelectorAll('.board')).find(function(b){var h=b.querySelector('h2');return h&&h.textContent.indexOf(word)>=0})}function drawBreadth(){var cards=Array.from(document.querySelectorAll('.card'));var get=function(k){var c=cards.find(function(x){return x.textContent.indexOf(k)>=0});return c?Number((c.querySelector('b')||{}).textContent)||0:0};var vals=[get('上涨家数'),get('下跌家数'),get('平盘家数')],colors=['#27845c','#c44f4f','#9aa6b5'],c=document.getElementById('breadthChart');if(!c)return;var x=c.getContext('2d'),total=Math.max(1,vals.reduce(function(a,b){return a+b},0)),left=18,y=68,w=c.width-36;x.clearRect(0,0,c.width,c.height);vals.forEach(function(v,i){var bw=w*v/total;x.fillStyle=colors[i];x.fillRect(left,y,bw,38);left+=bw});x.fillStyle='#263445';x.font='600 15px sans-serif';x.fillText('样本总数 '+total,18,35);x.font='12px sans-serif';x.fillStyle='#657386';x.fillText('结构比绝对排名更适合描述整体市场状态',18,135)}function drawSectors(){var b=boardByTitle('板块分析')||boardByTitle('板块轮动');var c=document.getElementById('sectorChart');if(!b||!c)return;var rows=Array.from(b.querySelectorAll('tbody tr')).slice(0,10).map(function(r){var d=r.querySelectorAll('td');return d.length>2?{n:d[0].textContent,v:parseFloat(d[2].textContent)||0}:null}).filter(Boolean);var x=c.getContext('2d'),mid=c.width*.55,max=Math.max(.01,...rows.map(function(r){return Math.abs(r.v)}));x.clearRect(0,0,c.width,c.height);rows.forEach(function(r,i){var y=12+i*16,len=Math.abs(r.v)/max*(c.width*.34);x.fillStyle=r.v>=0?'#27845c':'#c44f4f';x.fillRect(r.v>=0?mid:mid-len,y,len,9);x.fillStyle='#435164';x.font='11px sans-serif';x.textAlign='right';x.fillText(r.n,mid-8,y+9)});x.strokeStyle='#aab4c0';x.beginPath();x.moveTo(mid,4);x.lineTo(mid,176);x.stroke()}function drawWindows(){var c=document.getElementById('windowChart');if(!c)return;var x=c.getContext('2d'),panels=['5m','15m','30m'].map(function(h){var p=document.getElementById('panel-'+h);return p&&!p.textContent.includes('没有通过质量门禁')});x.clearRect(0,0,c.width,c.height);panels.forEach(function(ok,i){var px=70+i*240;x.fillStyle=ok?'#27845c':'#d4dae2';x.fillRect(px,48,160,58);x.fillStyle=ok?'#fff':'#4f5d70';x.font='700 21px sans-serif';x.textAlign='center';x.fillText([5,15,30][i]+' 分钟',px+80,83);x.fillStyle='#647286';x.font='12px sans-serif';x.fillText(ok?'有效样本':'暂不可用',px+80,130)});var q=document.querySelector('.metric:nth-child(2) b');var core=document.getElementById('qualityCore');if(core){core.textContent=q?q.textContent:'不可用';if(q&&q.textContent.indexOf('有效')>=0)core.style.borderTopColor='#27845c';else core.style.borderTopColor='#c44f4f'}}function collapseTables(){document.querySelectorAll('.board').forEach(function(b){if(b.closest('#visual-research')||b.querySelector('h2')&&b.querySelector('h2').textContent==='研究设计'||b.closest('.research-details'))return;var h=b.querySelector('h2');if(!h)return;var d=document.createElement('details');d.className='research-details';var s=document.createElement('summary');s.textContent=h.textContent+' · 查看研究明细';b.parentNode.insertBefore(d,b);d.appendChild(s);d.appendChild(b)})}drawBreadth();drawSectors();drawWindows();collapseTables()})();</script></body></html>
"@
 [IO.File]::WriteAllText($Path,$Html,(New-Object Text.UTF8Encoding($false)))
}

$Components=@(Get-IndexWeights);$ComponentsPath=Join-Path $RunDir 'csi1000_components.csv';$Components|Export-Csv $ComponentsPath -NoTypeInformation -Encoding UTF8
$IndustryResult=Get-SwIndustryMap;$IndustryStatus=if($IndustryResult.Available){"申万一级行业映射：$($IndustryResult.Date)"}else{"行业数据不可用：$($IndustryResult.Error)"}
$AllSnapshotsPath=Join-Path $RunDir 'csi1000_snapshots.csv';$LatestSignalsPath=Join-Path $RunDir 'latest_signals.csv';$DashboardPath=Join-Path $RunDir 'dashboard.html';$SummaryPath=Join-Path $RunDir 'summary.json';$DailyAnalysisPath=Join-Path $RunDir 'daily_analysis.json';$SectorRotationPath=Join-Path $RunDir 'sector_rotation.csv';$PredictionWatchlistPath=Join-Path $RunDir 'prediction_watchlist.csv';$DataQualityPath=Join-Path $RunDir 'data_quality.json';$LatestSnapshotPath=Join-Path $RunDir 'latest_snapshot.csv';$SnapshotManifestPath=Join-Path $RunDir 'snapshot_manifest.csv';$LiveManifestPath=Join-Path $RunDir 'snapshot_manifest.json'
$History=@();$IterationSummary=@();$SnapshotManifestRows=@();$LastValidSignals=@();$LastValidSignalTime=$null;$Fallback=Get-LastValidArtifact $OutRoot $RunDir (Get-Date)
if($Fallback){$LastValidSignals=@($Fallback.signals);$LastValidSignalTime=$Fallback.time}
for($Iteration=1;$Iteration-le$Iterations;$Iteration++){
 if($SessionOnly){if(-not(Wait-ForTradingSession)){break}}
 $RequestStart=Get-Date;$SnapshotTime=$RequestStart.ToString('yyyy-MM-dd HH:mm:ss.fff');$RealtimeRows=@(Get-RealtimeAll);$RequestEnd=Get-Date
 $SnapshotRows=@(New-SnapshotRows $RealtimeRows $Components $IndustryResult.Map $SnapshotTime);$Previous=if($History.Count){$History[-1]}else{$null};$Quality=Test-SnapshotQuality $SnapshotRows $(if($Previous){$Previous.rows}else{@()}) $RequestStart $RequestEnd $(if($Previous){$Previous.at}else{$null})
 $Signals=@(Add-MultiHorizonScores (New-MultiHorizonSignalRows $SnapshotRows $History $RequestStart $Quality))
 if($Quality.is_valid_snapshot -and @($Signals|Where-Object{$null-ne(Convert-ToDoubleOrNull $_.return_5m)}).Count){$LastValidSignals=$Signals;$LastValidSignalTime=$RequestStart}
 $Quality.last_valid_signal_time=if($LastValidSignalTime){$LastValidSignalTime.ToString('yyyy-MM-dd HH:mm:ss')}else{$null}
 $History+=,[pscustomobject]@{at=$RequestStart;rows=$SnapshotRows;quality=$Quality}
 $SnapshotPath=Join-Path $RunDir ("snapshot_{0:000}.csv"-f$Iteration);$SnapshotRows|Export-Csv $SnapshotPath -NoTypeInformation -Encoding UTF8
 $SnapshotRows|Export-Csv $LatestSnapshotPath -NoTypeInformation -Encoding UTF8
 $ManifestRow=[pscustomobject]@{iteration=$Iteration;snapshot_time=$SnapshotTime;request_start=$RequestStart.ToString('yyyy-MM-dd HH:mm:ss.fff');request_end=$RequestEnd.ToString('yyyy-MM-dd HH:mm:ss.fff');market_status=$Quality.market_status;is_valid_snapshot=$Quality.is_valid_snapshot;matched_components=$SnapshotRows.Count;field_coverage=$Quality.field_coverage.overall;changed_symbol_ratio=$Quality.changed_symbol_ratio;regression_ratio=$Quality.regression_ratio;snapshot_csv=$SnapshotPath;signals_csv=(Join-Path $RunDir ("signals_{0:000}.csv"-f$Iteration));quality_json=(Join-Path $RunDir ("quality_{0:000}.json"-f$Iteration))}
 $SnapshotManifestRows+=,$ManifestRow
 $SnapshotManifestRows|Export-Csv $SnapshotManifestPath -NoTypeInformation -Encoding UTF8
 [pscustomobject]@{output_dir=$RunDir;latest_iteration=$Iteration;latest_snapshot_csv=$LatestSnapshotPath;latest_signals_csv=$LatestSignalsPath;latest_quality_json=$DataQualityPath;snapshot_manifest_csv=$SnapshotManifestPath;snapshots=$SnapshotManifestRows}|ConvertTo-Json -Depth 6|Set-Content $LiveManifestPath -Encoding UTF8
 if($Iteration-eq1){$SnapshotRows|Export-Csv $AllSnapshotsPath -NoTypeInformation -Encoding UTF8}else{$SnapshotRows|ConvertTo-Csv -NoTypeInformation|Select-Object -Skip 1|Add-Content $AllSnapshotsPath -Encoding UTF8}
 $Quality|ConvertTo-Json -Depth 6|Set-Content $DataQualityPath -Encoding UTF8;$Quality|ConvertTo-Json -Depth 6|Set-Content (Join-Path $RunDir ("quality_{0:000}.json"-f$Iteration)) -Encoding UTF8
 $DisplaySignals=if($Quality.is_valid_snapshot){$Signals}elseif($LastValidSignals.Count){$LastValidSignals}else{$Signals};$UsingFallback=(-not$Quality.is_valid_snapshot-and$LastValidSignals.Count-gt0)
 $DisplaySignals|Export-Csv $LatestSignalsPath -NoTypeInformation -Encoding UTF8;$Signals|Export-Csv (Join-Path $RunDir ("signals_{0:000}.csv"-f$Iteration)) -NoTypeInformation -Encoding UTF8
 $DailyAnalysis=New-DailyAnalysis $Signals;$SectorRows=@(New-SectorRotation $Signals);$WatchlistRows=if($UsingFallback-or$Quality.is_valid_snapshot){@(New-PredictionWatchlist $DisplaySignals '5m')}else{@()}
 $DailyAnalysis|ConvertTo-Json -Depth 6|Set-Content $DailyAnalysisPath -Encoding UTF8;$SectorRows|Export-Csv $SectorRotationPath -NoTypeInformation -Encoding UTF8;$WatchlistRows|Export-Csv $PredictionWatchlistPath -NoTypeInformation -Encoding UTF8
 Write-DashboardHtml $DisplaySignals $DailyAnalysis $SectorRows $WatchlistRows $IndustryStatus $Quality $DashboardPath $SnapshotTime 20 $UsingFallback
 $IndexApproxReturn=($SnapshotRows|Where-Object{$null-ne$_.weighted_change_contribution}|Measure-Object weighted_change_contribution -Sum).Sum;$IterationSummary+=[pscustomobject]@{iteration=$Iteration;snapshot_time=$SnapshotTime;market_status=$Quality.market_status;is_valid_snapshot=$Quality.is_valid_snapshot;matched_components=$SnapshotRows.Count;field_coverage=$Quality.field_coverage.overall;changed_symbol_ratio=$Quality.changed_symbol_ratio;invalid_reasons=$Quality.invalid_reasons;signal_rows=$Signals.Count;approx_weighted_change=$IndexApproxReturn;snapshot_csv=$SnapshotPath}
 if($Iteration-lt$Iterations){
  if($SessionOnly){
    $Now=Get-Date;$NextMinute=[Math]::Floor($Now.TimeOfDay.TotalMinutes/$SampleMinutes+1)*$SampleMinutes;$Next=$Now.Date.AddMinutes($NextMinute);$SleepSeconds=[Math]::Max(1,[Math]::Ceiling(($Next-$Now).TotalSeconds));Start-Sleep -Seconds $SleepSeconds
  }else{Start-Sleep -Seconds $IntervalSeconds}
 }
}
$Result=[pscustomobject]@{output_dir=$RunDir;components_csv=$ComponentsPath;snapshots_csv=$AllSnapshotsPath;latest_signals_csv=$LatestSignalsPath;data_quality_json=$DataQualityPath;dashboard_html=$DashboardPath;daily_analysis_json=$DailyAnalysisPath;sector_rotation_csv=$SectorRotationPath;prediction_watchlist_csv=$PredictionWatchlistPath;industry_status=$IndustryStatus;summary=$IterationSummary};$Result|ConvertTo-Json -Depth 6|Set-Content $SummaryPath -Encoding UTF8;$Result|ConvertTo-Json -Depth 6


