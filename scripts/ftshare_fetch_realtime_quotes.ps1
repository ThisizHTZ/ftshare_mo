$ErrorActionPreference = "Stop"

$BaseUrl = "https://market.ft.tech/gateway/api/v1/market/data/stock-list/filter"
$PageSize = 200
$OutRoot = "C:\ftshare_data\realtime_quotes"
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $OutRoot $Stamp

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$Targets = @(
    @{ Name = "all"; Board = $null },
    @{ Name = "star"; Board = "star" },
    @{ Name = "chi_next"; Board = "chi_next" },
    @{ Name = "bjse"; Board = "bjse" },
    @{ Name = "xshg"; Board = "xshg" },
    @{ Name = "xshe"; Board = "xshe" },
    @{ Name = "main"; Board = "main" }
)

function Invoke-FtshareJson {
    param(
        [hashtable]$Params
    )

    $Query = ($Params.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
    }) -join "&"

    $Url = "$BaseUrl`?$Query"
    $Response = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers @{
        "User-Agent" = "ftshare-realtime-fetch/1.0"
    } -TimeoutSec 20

    return $Response.Content | ConvertFrom-Json
}

function Get-NormalizedPage {
    param($Payload)

    if ($Payload.items -ne $null) {
        return @{
            Items = @($Payload.items)
            TotalPages = [int]$Payload.total_pages
            TotalItems = [int]$Payload.total_items
        }
    }

    if ($Payload.data -ne $null -and $Payload.data.records -ne $null) {
        return @{
            Items = @($Payload.data.records)
            TotalPages = [int]$Payload.data.pages
            TotalItems = [int]$Payload.data.total
        }
    }

    throw "Unexpected response shape"
}

$Summary = @()

foreach ($Target in $Targets) {
    $Rows = New-Object System.Collections.Generic.List[object]
    $Params = @{
        page = 1
        page_size = $PageSize
    }

    if ($Target.Board) {
        $Params.board = $Target.Board
    }

    $FirstPage = Get-NormalizedPage (Invoke-FtshareJson -Params $Params)
    foreach ($Item in $FirstPage.Items) {
        $Rows.Add($Item)
    }

    for ($Page = 2; $Page -le $FirstPage.TotalPages; $Page++) {
        $Params.page = $Page
        $PageData = Get-NormalizedPage (Invoke-FtshareJson -Params $Params)
        foreach ($Item in $PageData.Items) {
            $Rows.Add($Item)
        }
        Start-Sleep -Milliseconds 80
    }

    $CsvPath = Join-Path $RunDir "$($Target.Name).csv"
    $JsonPath = Join-Path $RunDir "$($Target.Name).json"

    $Rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    $Rows | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonPath -Encoding UTF8

    $Summary += [pscustomobject]@{
        target = $Target.Name
        rows = $Rows.Count
        reported_total_items = $FirstPage.TotalItems
        pages = $FirstPage.TotalPages
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
