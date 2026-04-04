#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca account and market clock functions.

.DESCRIPTION
    Read-only functions for inspecting the paper account state and market schedule.
    No orders, no positions, no state changes.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


function Get-AlpacaAccount {
    <#
    .SYNOPSIS
        Returns the current paper account details.

    .DESCRIPTION
        Fetches cash, buying power, portfolio value, equity, daily P&L, pattern
        day trader status, and account restrictions from the Alpaca paper API.

    .EXAMPLE
        $acct = Get-AlpacaAccount
        Write-Host "Cash: $($acct.cash)  Buying power: $($acct.buying_power)"

    .OUTPUTS
        PSCustomObject (Alpaca account object)
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-AlpacaConfig
    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/account'
}


function Get-AlpacaClock {
    <#
    .SYNOPSIS
        Returns the current market clock status.

    .DESCRIPTION
        Returns whether the US equity market is currently open, the current
        server timestamp, the next open time, and the next close time.

        Crypto markets are always open so this clock only reflects US equity
        hours for stocks and ETFs.

    .EXAMPLE
        $clock = Get-AlpacaClock
        if ($clock.is_open) {
            Write-Host "Market is open. Closes at: $($clock.next_close)"
        }

    .OUTPUTS
        PSCustomObject with: timestamp, is_open, next_open, next_close
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-AlpacaConfig
    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/clock'
}


function Get-AlpacaCalendar {
    <#
    .SYNOPSIS
        Returns the market trading calendar for a date range.

    .DESCRIPTION
        Returns a list of trading days with their open and close times.
        Useful for checking whether a backfill date range includes market holidays.

    .PARAMETER Start
        Start date in YYYY-MM-DD format. Defaults to today.

    .PARAMETER End
        End date in YYYY-MM-DD format. Defaults to 7 days from today.

    .EXAMPLE
        Get-AlpacaCalendar -Start '2025-01-01' -End '2025-01-31'

    .OUTPUTS
        Array of PSCustomObject with: date, open, close
    #>
    [CmdletBinding()]
    param(
        [string]$Start = (Get-Date -Format 'yyyy-MM-dd'),
        [string]$End   = (Get-Date (Get-Date).AddDays(7) -Format 'yyyy-MM-dd')
    )

    $cfg = Get-AlpacaConfig
    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/calendar' -QueryParams @{
        start = $Start
        end   = $End
    }
}


function Show-AlpacaAccountSummary {
    <#
    .SYNOPSIS
        Prints a formatted paper account summary to the console.

    .DESCRIPTION
        Convenience wrapper around Get-AlpacaAccount that formats the key fields
        into a readable table. Does not return a pipeline object.

    .EXAMPLE
        Show-AlpacaAccountSummary
    #>
    [CmdletBinding()]
    param()

    $acct = Get-AlpacaAccount

    $equity     = [double]$acct.equity
    $lastEquity = [double]$acct.last_equity
    $pnl        = $equity - $lastEquity
    $pnlLabel   = if ($pnl -ge 0) { "[UP]  " } else { "[DOWN]" }

    Write-Host ""
    Write-Host "PAPER ACCOUNT  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC" -ForegroundColor White
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Write-Host ("  Status         : {0}"     -f $acct.status)
    Write-Host ("  Portfolio Value: `${0,14:N2}" -f [double]$acct.portfolio_value)
    Write-Host ("  Cash           : `${0,14:N2}" -f [double]$acct.cash)
    Write-Host ("  Buying Power   : `${0,14:N2}" -f [double]$acct.buying_power)
    Write-Host ("  Equity         : `${0,14:N2}" -f $equity)
    Write-Host ("  Today P&L  {0}: `${1,13:+#,##0.00;-#,##0.00}" -f $pnlLabel, $pnl)
    Write-Host ("  Day Trades     : {0} / 3 (PDT rule)" -f $acct.daytrade_count)
    Write-Host ("  PDT Protected  : {0}"     -f $acct.pattern_day_trader)
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Write-Host ""
}


Export-ModuleMember -Function @(
    'Get-AlpacaAccount',
    'Get-AlpacaClock',
    'Get-AlpacaCalendar',
    'Show-AlpacaAccountSummary'
)
