<#
.SYNOPSIS
    Submits a single paper market order using the full risk-gated workflow.

.DESCRIPTION
    Demonstrates the recommended order submission pattern:
      1. Initialize config and risk limits
      2. Generate an idempotent client order ID
      3. Check for duplicates
      4. Check risk limits (position size, daily loss, kill switch)
      5. Submit the order
      6. Register the order for future duplicate detection
      7. Print the returned order details

    This is the template you should copy for any automated strategy.
    Do NOT call Submit-AlpacaOrder directly without going through the
    risk checks first.

.PARAMETER Symbol
    The ticker to buy. Defaults to 'AAPL'.

.PARAMETER Qty
    Number of shares. Defaults to 1.

.PARAMETER Side
    'buy' or 'sell'. Defaults to 'buy'.

.EXAMPLE
    .\examples\Submit-PaperOrder.ps1
    .\examples\Submit-PaperOrder.ps1 -Symbol SPY -Qty 2 -Side buy
    .\examples\Submit-PaperOrder.ps1 -Symbol AAPL -Qty 5 -Side sell

.NOTES
    This submits a real paper order. It uses fake money but the order
    will appear in your Alpaca paper account.
#>

#Requires -Version 5.1

param(
    [string]$Symbol = 'AAPL',

    [ValidateRange(1, 100)]
    [int]$Qty = 1,

    [ValidateSet('buy', 'sell')]
    [string]$Side = 'buy'
)

$repoRoot = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1')              -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')                  -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Trading.Orders\Alpaca.Trading.Orders.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.MarketData.Historical\Alpaca.MarketData.Historical.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Risk\Alpaca.Risk.psd1')                  -Force

# Step 1: Initialize config (paper mode, reads .env)
Initialize-AlpacaConfig

# Step 2: Set risk limits for this session
Initialize-AlpacaRisk -MaxPositionValue 5000 -MaxShares 50 -MaxDailyLoss 500

# Step 3: Get a current price for the notional check
Write-Host "Getting latest trade price for $Symbol..."
try {
    $lastTrade      = Get-AlpacaLatestTrade -Symbol $Symbol
    $estimatedPrice = [double]$lastTrade.p
    Write-Host ("  Last trade: `${0:N2}" -f $estimatedPrice)
} catch {
    Write-Warning "Could not fetch last price for $Symbol. Skipping notional check."
    $estimatedPrice = 0
}

# Step 4: Generate idempotent client order ID
$coid = New-AlpacaClientOrderId -Strategy 'example' -Symbol $Symbol -Side $Side
Write-Host "  Client order ID: $coid"

# Step 5: Duplicate check
if (Test-AlpacaDuplicateOrder -ClientOrderId $coid) {
    Write-Warning "Duplicate order detected for $coid - this was already submitted this minute. Exiting."
    exit 0
}

# Step 6: Risk validation - throws if any limit is breached
try {
    $null = Test-AlpacaOrderRisk -Symbol $Symbol -Side $Side -Qty $Qty -EstimatedPrice $estimatedPrice
} catch {
    Write-Error "Risk check failed: $_"
    exit 1
}

# Step 7: Submit the order
Write-Host "Submitting paper order: $Side $Symbol x$Qty (market, day)..."
try {
    $order = Submit-AlpacaOrder -Symbol $Symbol -Qty $Qty -Side $Side -ClientOrderId $coid

    # Step 8: Record submission for duplicate prevention
    Register-AlpacaOrderSent -ClientOrderId $coid

    Write-Host ""
    Write-Host "Order submitted successfully:" -ForegroundColor Green
    Write-Host ("  Order ID       : {0}" -f $order.id)
    Write-Host ("  Client Order ID: {0}" -f $order.client_order_id)
    Write-Host ("  Symbol         : {0}" -f $order.symbol)
    Write-Host ("  Side           : {0}" -f $order.side)
    Write-Host ("  Qty            : {0}" -f $order.qty)
    Write-Host ("  Type           : {0}" -f $order.type)
    Write-Host ("  Status         : {0}" -f $order.status)
    Write-Host ("  Submitted At   : {0}" -f $order.submitted_at)
    Write-Host ""

} catch {
    Write-Error "Order submission failed: $_"
    exit 1
}
