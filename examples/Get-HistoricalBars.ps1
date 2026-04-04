<#
.SYNOPSIS
    Pulls historical daily bars for a symbol and prints a summary.

.DESCRIPTION
    Demonstrates Get-AlpacaBars with a date range and outputs the bars
    in a table. Useful for verifying your market data access and as a
    template for backtesting data pulls.

    The IEX feed (default, free) returns last-traded prices from IEX exchange
    only. SIP feed (paid) returns consolidated tape data. For learning and
    paper trading, IEX is sufficient.

.PARAMETER Symbol
    Ticker symbol. Defaults to 'SPY'.

.PARAMETER Days
    Number of calendar days of history to fetch. Defaults to 30.
    Note: only trading days have bars, so 30 calendar days yields ~21 bars.

.PARAMETER Timeframe
    Bar period. Defaults to '1Day'.
    Options: 1Min, 5Min, 15Min, 30Min, 1Hour, 2Hour, 4Hour, 1Day, 1Week, 1Month

.EXAMPLE
    cd "C:\path\to\Trading"
    .\examples\Get-HistoricalBars.ps1
    .\examples\Get-HistoricalBars.ps1 -Symbol AAPL -Days 60 -Timeframe 1Day
    .\examples\Get-HistoricalBars.ps1 -Symbol SPY -Days 5 -Timeframe 1Hour
#>

#Requires -Version 5.1

param(
    [string]$Symbol    = 'SPY',
    [int]$Days         = 30,
    [ValidateSet('1Min','5Min','15Min','30Min','1Hour','2Hour','4Hour','1Day','1Week','1Month')]
    [string]$Timeframe = '1Day'
)

$repoRoot = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1')                          -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')                              -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.MarketData.Historical\Alpaca.MarketData.Historical.psd1') -Force

Initialize-AlpacaConfig

$startDate = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd')
$endDate   = (Get-Date).ToString('yyyy-MM-dd')

Write-Host ""
Write-Host "Fetching $Timeframe bars for $Symbol" -ForegroundColor Cyan
Write-Host "  Range: $startDate to $endDate"
Write-Host "  Feed : $((Get-AlpacaConfig).DefaultFeed)"
Write-Host ""

$bars = Get-AlpacaBars -Symbol $Symbol -Timeframe $Timeframe -Start $startDate -End $endDate

if (-not $bars -or $bars.Count -eq 0) {
    Write-Warning "No bars returned. Check symbol name and date range."
    exit 0
}

# Display last 20 bars in a table (or all if fewer)
$display = $bars | Select-Object -Last 20

$display | ForEach-Object {
    [PSCustomObject]@{
        Date   = $_.t.Substring(0, 10)
        Open   = '{0:N2}' -f [double]$_.o
        High   = '{0:N2}' -f [double]$_.h
        Low    = '{0:N2}' -f [double]$_.l
        Close  = '{0:N2}' -f [double]$_.c
        Volume = '{0:N0}' -f [double]$_.v
        VWAP   = '{0:N2}' -f [double]$_.vw
    }
} | Format-Table -AutoSize

Write-Host "Total bars returned: $($bars.Count)"

# Quick stats on the close price series
if ($bars.Count -gt 1) {
    $closes  = $bars | ForEach-Object { [double]$_.c }
    $first   = $closes[0]
    $last    = $closes[-1]
    $change  = (($last - $first) / $first) * 100
    $highest = ($bars | ForEach-Object { [double]$_.h } | Measure-Object -Maximum).Maximum
    $lowest  = ($bars | ForEach-Object { [double]$_.l } | Measure-Object -Minimum).Minimum

    Write-Host ""
    Write-Host ("  Period return : {0:+0.00;-0.00}%" -f $change)
    Write-Host ("  Period high   : `${0:N2}" -f $highest)
    Write-Host ("  Period low    : `${0:N2}" -f $lowest)
    Write-Host ""
}
