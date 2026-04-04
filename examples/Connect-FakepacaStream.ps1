<#
.SYNOPSIS
    Connects to the Alpaca FAKEPACA market data stream for smoke testing.

.DESCRIPTION
    FAKEPACA is a synthetic test ticker provided by Alpaca on the IEX feed.
    Subscribing to it delivers a steady stream of fake trade, quote, and bar
    events without requiring a paid subscription or real market hours.

    Use this to:
      - Verify your WebSocket connection and auth are working
      - Test your event callback logic before using real symbols
      - Smoke test after any change to the stream module

    This script runs until you press Ctrl+C.
    Events are printed to the console and logged to Journal/fakepaca_stream.log.

.EXAMPLE
    cd "C:\path\to\Trading"
    .\examples\Connect-FakepacaStream.ps1

.NOTES
    FAKEPACA only works on the IEX feed (the default free feed).
    If your config uses 'sip', this script overrides to 'iex' for the connection.
#>

#Requires -Version 5.1

$repoRoot = Split-Path $PSScriptRoot -Parent
$logFile  = Join-Path $repoRoot 'Journal\fakepaca_stream.log'

Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1')                    -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')                        -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.MarketData.Stream\Alpaca.MarketData.Stream.psd1') -Force

Initialize-AlpacaConfig

# Event counts for the session
$script:EventCounts = @{ trade = 0; quote = 0; bar = 0; other = 0 }
$script:StartTime   = Get-Date

Write-Host ""
Write-Host "Connecting to FAKEPACA stream (IEX feed)..." -ForegroundColor Cyan
Write-Host "  This symbol delivers synthetic test events at no cost."
Write-Host "  Log file : $logFile"
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

Start-AlpacaMarketDataStream `
    -Trades @('FAKEPACA') `
    -Quotes @('FAKEPACA') `
    -Bars   @('FAKEPACA') `
    -Feed   'iex' `
    -LogFile $logFile `
    -OnEvent {
        param($event)

        $runtime = ((Get-Date) - $script:StartTime).ToString('hh\:mm\:ss')

        switch ($event.EventType) {
            'trade' {
                $script:EventCounts['trade']++
                Write-Host ("[{0}] TRADE  FAKEPACA @ `${1:N4}  size={2}" -f $runtime, $event.Price, $event.Size) -ForegroundColor Green
            }
            'quote' {
                $script:EventCounts['quote']++
                Write-Host ("[{0}] QUOTE  bid=`${1:N4} ({2})  ask=`${3:N4} ({4})" -f $runtime, $event.BidPrice, $event.BidSize, $event.AskPrice, $event.AskSize) -ForegroundColor Yellow
            }
            'bar' {
                $script:EventCounts['bar']++
                Write-Host ("[{0}] BAR    O={1:N4} H={2:N4} L={3:N4} C={4:N4} V={5}" -f $runtime, $event.Open, $event.High, $event.Low, $event.Close, $event.Volume) -ForegroundColor Magenta
            }
            default {
                $script:EventCounts['other']++
                Write-Verbose "[{0}] OTHER [{1}] {2}" -f $runtime, $event.EventType, ($event | ConvertTo-Json -Compress)
            }
        }

        # Print running totals every 50 events
        $total = $script:EventCounts.Values | Measure-Object -Sum | Select-Object -ExpandProperty Sum
        if ($total -gt 0 -and ($total % 50) -eq 0) {
            Write-Host ("-" * 60) -ForegroundColor DarkGray
            Write-Host ("  Totals so far: trades={0}  quotes={1}  bars={2}" -f $script:EventCounts['trade'], $script:EventCounts['quote'], $script:EventCounts['bar']) -ForegroundColor Cyan
            Write-Host ("-" * 60) -ForegroundColor DarkGray
        }
    }

Write-Host ""
Write-Host "Stream stopped." -ForegroundColor Cyan
Write-Host ("  Total events received: trades={0}  quotes={1}  bars={2}" -f $script:EventCounts['trade'], $script:EventCounts['quote'], $script:EventCounts['bar'])
Write-Host ""
