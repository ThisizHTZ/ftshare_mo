param(
    [Parameter(Mandatory=$true)][string[]]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputCsv,
    [string]$DefaultSymbol = "000852.XSHG"
)
$ErrorActionPreference = "Stop"
function Number-OrNull($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { [double]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
$rows = foreach ($path in $InputPath) {
    if ($path.EndsWith('.csv',[StringComparison]::OrdinalIgnoreCase)) { Import-Csv -LiteralPath $path -Encoding UTF8; continue }
    $payload=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($payload.ohlcs){@($payload.ohlcs)}elseif($payload.items){@($payload.items)}elseif($payload.data){@($payload.data)}else{@($payload)}
}
$normalized=@($rows|ForEach-Object{
    $ts=if($_.ts_millis){[int64]$_.ts_millis}elseif($_.close_ts_ms -as [int64]){[int64]$_.close_ts_ms}else{$null}
    if($null -eq $ts){return}
    [pscustomobject]@{symbol=if($_.symbol){[string]$_.symbol}else{$DefaultSymbol};ts_millis=$ts;minute_time=[DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss');open=Number-OrNull $_.open;high=Number-OrNull $_.high;low=Number-OrNull $_.low;close=Number-OrNull $_.close;volume=Number-OrNull $_.volume;turnover=Number-OrNull $_.turnover;source='FTShare';frequency='1min'}
}|Sort-Object symbol,ts_millis -Unique)
$invalid=@($normalized|Where-Object{$null -eq $_.open -or $null -eq $_.high -or $null -eq $_.low -or $null -eq $_.close -or $_.open -le 0 -or $_.high -lt [Math]::Max($_.open,$_.close) -or $_.low -gt [Math]::Min($_.open,$_.close) -or ($null -ne $_.volume -and $_.volume -lt 0) -or ($null -ne $_.turnover -and $_.turnover -lt 0)})
if($invalid.Count){throw "Candlestick quality gate failed: $($invalid.Count) invalid rows."}
$normalized|Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
[pscustomobject]@{rows=$normalized.Count;invalid_rows=$invalid.Count;output=$OutputCsv}|ConvertTo-Json