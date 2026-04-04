<#
.SYNOPSIS
    Tests Alpaca paper trading connectivity and prints account status.

.DESCRIPTION
    Imports the core modules, initializes config from your .env file,
    calls the Alpaca paper API, and prints a formatted account summary.

    Run this first to confirm your API keys work and the paper account
    is reachable before trying anything that submits orders.

.EXAMPLE
    cd "C:\path\to\Trading"
    .\examples\Get-AccountStatus.ps1

.NOTES
    Prerequisites:
      - ALPACA_API_KEY and ALPACA_SECRET_KEY in .env or as env vars
      - PowerShell 5.1 or later
#>

#Requires -Version 5.1

# Load modules relative to the repo root (this script lives in /examples)
$repoRoot = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1')    -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')        -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Trading.Account\Alpaca.Trading.Account.psd1') -Force

# Initialize config - reads from .env in the repo root
Initialize-AlpacaConfig -Verbose

# Print full formatted summary
Show-AlpacaAccountSummary

# Also print the market clock
$clock = Get-AlpacaClock
$status = if ($clock.is_open) { 'OPEN' } else { 'CLOSED' }
Write-Host "Market is currently: $status" -ForegroundColor (if ($clock.is_open) { 'Green' } else { 'Yellow' })
Write-Host ("  Next open  : {0}" -f $clock.next_open)
Write-Host ("  Next close : {0}" -f $clock.next_close)
Write-Host ""
