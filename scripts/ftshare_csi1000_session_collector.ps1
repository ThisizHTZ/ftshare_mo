param(
    [string]$OutRoot = "C:\ftshare_data\daily_intraday_summary",
    [int]$IntervalSeconds = 300
)

$ErrorActionPreference = "Stop"
$Monitor = Join-Path $PSScriptRoot "ftshare_csi1000_intraday_monitor.ps1"
if (-not (Test-Path $Monitor)) { throw "Monitor script not found: $Monitor" }

# 50 samples cover 09:30-11:30 and 13:00-15:00 at five-minute cadence.
& $Monitor `
    -Iterations 50 `
    -IntervalSeconds $IntervalSeconds `
    -SampleMinutes 5 `
    -MinMatchedComponents 980 `
    -MinFieldCoverage 0.95 `
    -MinChangedSymbolRatio 0.05 `
    -SessionOnly `
    -OutRoot $OutRoot