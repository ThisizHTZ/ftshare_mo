param(
    [Parameter(Mandatory=$true)][string[]]$Symbols,
    [Parameter(Mandatory=$true)][datetime]$Since,
    [Parameter(Mandatory=$true)][datetime]$Until,
    [string]$OutputPath = ".\candlestick_request_plan.json",
    [int]$Limit = 2000
)
$ErrorActionPreference = "Stop"
if ($Until -lt $Since) { throw "Until must be on or after Since." }
$offset = [TimeSpan]::FromHours(8)
$requests = @()
foreach ($symbol in $Symbols) {
    $cursor = $Since
    while ($cursor -le $Until) {
        $chunkEnd = $cursor.AddDays(3).AddMilliseconds(-1)
        if ($chunkEnd -gt $Until) { $chunkEnd = $Until }
        $requests += [ordered]@{
            function = if ($Symbols.Count -gt 1) { "ft_stock_candlesticks_batch" } else { "ft_stock_candlesticks" }
            symbol = $symbol; interval_unit = "minute"; interval_value = 1
            since_ts_millis = [DateTimeOffset]::new($cursor, $offset).ToUnixTimeMilliseconds()
            until_ts_millis = [DateTimeOffset]::new($chunkEnd, $offset).ToUnixTimeMilliseconds()
            limit = $Limit
        }
        $cursor = $chunkEnd.AddMilliseconds(1)
    }
}
$plan = [ordered]@{schema_version="1.0";source="FTShare";rule="Each since/until span is <= 3 days; concatenate, deduplicate by symbol+ts_millis, then sort.";requests=$requests}
$resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
[IO.File]::WriteAllText($resolvedOutput,($plan|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$plan | ConvertTo-Json -Depth 6