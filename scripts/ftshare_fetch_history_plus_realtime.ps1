param(
    [string[]]$Symbols = @("000001.SZ", "600519.SH"),
    [string]$StartDate = "2026-07-01",
    [string]$EndDate = (Get-Date -Format "yyyy-MM-dd"),
    [string]$RealtimeCsv = "C:\ftshare_data\realtime_quotes\20260709_115423\all.csv",
    [string]$OutRoot = "C:\ftshare_data\history_plus_realtime"
)

$ErrorActionPreference = "Stop"

$KlineUrl = "https://market.ft.tech/gateway/api/v1/market/data/stock-candlesticks"
$PageWindowDays = 3
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $OutRoot $Stamp

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Convert-DateToUnixMillis {
    param([datetime]$Date)

    $Offset = [DateTimeOffset]::new($Date)
    return $Offset.ToUnixTimeMilliseconds()
}

function Convert-MillisToLocalDate {
    param([Int64]$Millis)

    return [DateTimeOffset]::FromUnixTimeMilliseconds($Millis).LocalDateTime.ToString("yyyy-MM-dd")
}

function Invoke-Kline {
    param(
        [string]$Symbol,
        [Int64]$SinceMs,
        [Int64]$UntilMs
    )

    $Body = @{
        symbol = $Symbol
        interval_unit = "Day"
        interval_value = 1
        since_ts_millis = $SinceMs
        until_ts_millis = $UntilMs
        limit = 20
    } | ConvertTo-Json -Compress

    $Response = Invoke-WebRequest `
        -Uri $KlineUrl `
        -Method POST `
        -UseBasicParsing `
        -ContentType "application/json" `
        -Headers @{ "User-Agent" = "ftshare-history-plus-realtime/1.0" } `
        -Body $Body `
        -TimeoutSec 20

    return $Response.Content | ConvertFrom-Json
}

function Get-HistoryRows {
    param(
        [string]$Symbol,
        [datetime]$Start,
        [datetime]$End
    )

    $Rows = New-Object System.Collections.Generic.List[object]
    $Cursor = $Start
    $EndExclusive = $End.Date.AddDays(1)

    while ($Cursor -lt $EndExclusive) {
        $WindowEnd = $Cursor.AddDays($PageWindowDays)
        if ($WindowEnd -gt $EndExclusive) {
            $WindowEnd = $EndExclusive
        }

        $Payload = Invoke-Kline `
            -Symbol $Symbol `
            -SinceMs (Convert-DateToUnixMillis $Cursor) `
            -UntilMs (Convert-DateToUnixMillis $WindowEnd)

        foreach ($Item in @($Payload)) {
            if ($null -eq $Item.ts_millis) {
                continue
            }

            $Rows.Add([pscustomobject]@{
                symbol = $Symbol
                trade_date = Convert-MillisToLocalDate ([Int64]$Item.ts_millis)
                source = "history_day"
                open = $Item.open
                high = $Item.high
                low = $Item.low
                close = $Item.close
                prev_close = $null
                change = $null
                change_rate = $null
                volume = $Item.volume
                turnover = $Item.turnover
                ts_millis = $Item.ts_millis
                ts_nanos = $null
            })
        }

        $Cursor = $WindowEnd
        Start-Sleep -Milliseconds 120
    }

    return $Rows
}

$Start = [datetime]::Parse($StartDate)
$End = [datetime]::Parse($EndDate)
$RealtimeRows = @()
if (Test-Path $RealtimeCsv) {
    $RealtimeRows = Import-Csv -Path $RealtimeCsv
}

$Summary = @()
foreach ($Symbol in $Symbols) {
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($HistoryRow in @(Get-HistoryRows -Symbol $Symbol -Start $Start -End $End)) {
        $Rows.Add($HistoryRow)
    }

    $Realtime = $RealtimeRows | Where-Object { $_.symbol -eq $Symbol } | Select-Object -First 1
    if ($Realtime) {
        $Rows.Add([pscustomobject]@{
            symbol = $Symbol
            trade_date = (Get-Date).ToString("yyyy-MM-dd")
            source = "realtime_today"
            open = $Realtime.open
            high = $Realtime.high
            low = $Realtime.low
            close = $Realtime.close
            prev_close = $Realtime.prev_close
            change = $Realtime.change
            change_rate = $Realtime.change_rate
            volume = $Realtime.volume
            turnover = $Realtime.turnover
            ts_millis = $null
            ts_nanos = $Realtime.ts_nanos
        })
    }

    $Deduped = $Rows |
        Sort-Object symbol, trade_date, source -Unique |
        Sort-Object trade_date, source

    $CsvPath = Join-Path $RunDir "$Symbol.csv"
    $JsonPath = Join-Path $RunDir "$Symbol.json"

    $Deduped | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    $Deduped | ConvertTo-Json -Depth 6 | Set-Content -Path $JsonPath -Encoding UTF8

    $Summary += [pscustomobject]@{
        symbol = $Symbol
        rows = @($Deduped).Count
        csv = $CsvPath
        json = $JsonPath
    }
}

$SummaryPath = Join-Path $RunDir "summary.json"
$Summary | ConvertTo-Json -Depth 4 | Set-Content -Path $SummaryPath -Encoding UTF8

[pscustomobject]@{
    output_dir = $RunDir
    summary = $Summary
} | ConvertTo-Json -Depth 5

