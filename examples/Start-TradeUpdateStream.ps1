<#
.SYNOPSIS
    Starts the Alpaca paper trade_updates WebSocket stream and logs every event.

.DESCRIPTION
    Connects to the Alpaca paper trading WebSocket, authenticates, subscribes to
    trade_updates, and prints every order lifecycle event as it arrives.

    This is the primary method for tracking order state. Run this alongside any
    order-submitting script to see fills, partial fills, and cancellations in
    real time.

    Events you will see:
      new           - Order accepted by Alpaca, not yet matched
      pending_new   - Order received by us, not yet confirmed by exchange
      fill          - Order fully filled
      partial_fill  - Order partially filled
      canceled      - Order canceled
      expired       - Day order expired at close
      replaced      - Order was replace (amended)

    Press Ctrl+C to disconnect cleanly.

.EXAMPLE
    cd "C:\path\to\Trading"
    .\examples\Start-TradeUpdateStream.ps1

.NOTES
    Logs all events to Journal/trade_updates.log as well as the console.
    Reconnects automatically on disconnect (up to 10 times with backoff).
#>

#Requires -Version 5.1

$repoRoot = Split-Path $PSScriptRoot -Parent
$logFile  = Join-Path $repoRoot 'Journal\trade_updates.log'

Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1')                       -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')                           -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Streams.TradeUpdates\Alpaca.Streams.TradeUpdates.psd1') -Force

Initialize-AlpacaConfig

Write-Host ""
Write-Host "Starting trade_updates stream..." -ForegroundColor Cyan
Write-Host "  Log file : $logFile"
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

# The -OnEvent scriptblock receives a normalized event object.
# This example prints the key fields in a human-readable format.
Start-AlpacaTradeUpdateStream -LogFile $logFile -OnEvent {
    param($event)

    $color = switch ($event.EventType) {
        'fill'         { 'Green' }
        'partial_fill' { 'Yellow' }
        'canceled'     { 'Red' }
        'expired'      { 'DarkYellow' }
        default        { 'White' }
    }

    Write-Host ("-" * 60) -ForegroundColor DarkGray
    Write-Host ("  Event    : {0}"   -f $event.EventType.ToUpper()) -ForegroundColor $color
    Write-Host ("  Symbol   : {0}"   -f $event.Symbol)
    Write-Host ("  Side     : {0}"   -f $event.Side)
    Write-Host ("  Qty      : {0} (filled {1})" -f $event.Qty, $event.FilledQty)
    Write-Host ("  Avg Fill : {0}"   -f (if ($event.FilledAvgPx -gt 0) { "`$$($event.FilledAvgPx:N2)" } else { 'n/a' }))
    Write-Host ("  Status   : {0}"   -f $event.Status)
    Write-Host ("  Order ID : {0}"   -f $event.OrderId)
    if ($event.ClientOrderId) {
        Write-Host ("  COID     : {0}" -f $event.ClientOrderId)
    }
    Write-Host ("  At       : {0}"   -f $event.EventAt)
}
