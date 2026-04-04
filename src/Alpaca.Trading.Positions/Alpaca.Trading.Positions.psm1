#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca position query and close functions.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


function Get-AlpacaPosition {
    <#
    .SYNOPSIS
        Returns the open position for a single symbol.

    .PARAMETER Symbol
        The ticker symbol. Example: 'AAPL', 'BTC/USD'.

    .EXAMPLE
        $pos = Get-AlpacaPosition -Symbol 'AAPL'
        if ($pos) { Write-Host "P&L: $($pos.unrealized_pl)" }

    .OUTPUTS
        PSCustomObject, or $null if no open position exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol
    )

    $cfg           = Get-AlpacaConfig
    $encodedSymbol = [Uri]::EscapeDataString($Symbol.ToUpperInvariant())
    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path "/v2/positions/$encodedSymbol" -AllowNotFound
}


function Get-AlpacaPositions {
    <#
    .SYNOPSIS
        Returns all open positions in the paper account.

    .EXAMPLE
        $positions = Get-AlpacaPositions
        $positions | Format-Table symbol, qty, unrealized_pl

    .OUTPUTS
        Array of PSCustomObject. Empty array if flat.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-AlpacaConfig
    $result = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/positions'

    # Alpaca returns an empty array when flat; normalize to consistent type
    if ($null -eq $result) { return @() }
    return $result
}


function Close-AlpacaPosition {
    <#
    .SYNOPSIS
        Liquidates an open position for a given symbol.

    .DESCRIPTION
        Sends DELETE to /v2/positions/{symbol} which submits a market order
        to flatten the position. The resulting order will appear on the
        trade_updates stream. This function returns the liquidation order object.

    .PARAMETER Symbol
        Symbol to close. Example: 'AAPL'.

    .PARAMETER Qty
        Optional: close only this many shares instead of the full position.
        Mutually exclusive with Percentage.

    .PARAMETER Percentage
        Optional: close this percentage of the position (0-100).
        Mutually exclusive with Qty.

    .EXAMPLE
        Close-AlpacaPosition -Symbol 'AAPL'

    .EXAMPLE
        Close-AlpacaPosition -Symbol 'AAPL' -Qty 5

    .EXAMPLE
        Close-AlpacaPosition -Symbol 'SPY' -Percentage 50

    .OUTPUTS
        PSCustomObject (the liquidation order), or $null if no position existed.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Full')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [Parameter(ParameterSetName = 'ByQty')]
        [ValidateRange(0.00001, 1000000)]
        [double]$Qty,

        [Parameter(ParameterSetName = 'ByPct')]
        [ValidateRange(1, 100)]
        [double]$Percentage
    )

    Assert-PaperMode

    $cfg           = Get-AlpacaConfig
    $encodedSymbol = [Uri]::EscapeDataString($Symbol.ToUpperInvariant())
    $query         = @{}

    if ($PSCmdlet.ParameterSetName -eq 'ByQty') {
        $query['qty'] = [string]$Qty
    } elseif ($PSCmdlet.ParameterSetName -eq 'ByPct') {
        $query['percentage'] = [string]$Percentage
    }

    $describe = "Close position: $Symbol"
    if ($query.Count -gt 0) { $describe += " ($($query | Out-String -NoNewline))" }

    if ($PSCmdlet.ShouldProcess($describe, 'Close paper position')) {
        $result = Invoke-AlpacaRequest -Method DELETE `
            -BaseUrl    $cfg.TradingBaseUrl `
            -Path       "/v2/positions/$encodedSymbol" `
            -QueryParams $query `
            -AllowNotFound

        if ($null -eq $result) {
            Write-Verbose "No open position found for $Symbol - nothing to close."
        } else {
            Write-Verbose "Close order submitted for $Symbol: order=$($result.id)"
        }

        return $result
    }
}


function Close-AllAlpacaPositions {
    <#
    .SYNOPSIS
        Liquidates all open positions at market.

    .DESCRIPTION
        Sends DELETE to /v2/positions to close every open position.
        Cancels open orders first if -CancelOrders is specified (recommended).
        Use this as part of end-of-day cleanup or a kill-switch sequence.

    .PARAMETER CancelOrders
        If set, cancels all open orders before closing positions.
        Recommended to avoid double fills on pending orders.

    .EXAMPLE
        Close-AllAlpacaPositions -CancelOrders

    .OUTPUTS
        Array of close order results.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$CancelOrders
    )

    Assert-PaperMode

    if ($PSCmdlet.ShouldProcess('all open positions', 'Close paper positions')) {
        $cfg = Get-AlpacaConfig

        if ($CancelOrders) {
            Write-Verbose "Canceling all open orders first..."
            try {
                Invoke-AlpacaRequest -Method DELETE -BaseUrl $cfg.TradingBaseUrl -Path '/v2/orders' | Out-Null
            } catch {
                Write-Warning "Cancel-all orders failed (may be no open orders): $_"
            }
        }

        $query  = @{ cancel_orders = 'false' }   # we already canceled above if needed
        $result = Invoke-AlpacaRequest -Method DELETE -BaseUrl $cfg.TradingBaseUrl -Path '/v2/positions' -QueryParams $query

        Write-Verbose "Close-all positions submitted. Results: $($result.Count) positions."
        return $result
    }
}


Export-ModuleMember -Function @(
    'Get-AlpacaPosition',
    'Get-AlpacaPositions',
    'Close-AlpacaPosition',
    'Close-AllAlpacaPositions'
)
