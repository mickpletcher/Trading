#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca order submission and management.

.DESCRIPTION
    Functions for submitting, querying, and canceling orders against the Alpaca
    paper trading API.

    Submit-AlpacaOrder calls Assert-PaperMode before every submission to ensure
    live endpoints can never be reached. It also accepts a -ClientOrderId parameter
    so the Risk module can inject idempotency keys.

    Order state queries (Get-AlpacaOrder, Get-AlpacaOrders) are secondary to the
    trade_updates WebSocket stream. Use GET as a reconciliation or startup snapshot,
    not as the primary order tracking mechanism.

.NOTES
    Import the Alpaca.Risk module and call Test-AlpacaOrderRisk + New-AlpacaClientOrderId
    before calling Submit-AlpacaOrder in any automated strategy.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


function Submit-AlpacaOrder {
    <#
    .SYNOPSIS
        Submits a paper order to Alpaca.

    .DESCRIPTION
        Validates paper mode, then posts an order to /v2/orders.

        Supports market, limit, stop, and stop_limit order types.
        For simple market orders, only Symbol, Qty/Notional, Side are required.

        ClientOrderId should be supplied by the Risk module (New-AlpacaClientOrderId)
        for idempotency. If omitted, Alpaca will generate one.

        This function does NOT check risk limits itself. Call Test-AlpacaOrderRisk
        from the Alpaca.Risk module before calling Submit-AlpacaOrder in any
        automated flow.

    .PARAMETER Symbol
        The ticker symbol to trade. Example: 'AAPL', 'BTC/USD'.

    .PARAMETER Qty
        Number of shares/units. Use this OR Notional, not both.
        For fractional: provide a decimal value (requires fractionable asset).

    .PARAMETER Notional
        Dollar amount to trade. Use this OR Qty, not both.
        Only supported for market orders with time_in_force = 'day'.

    .PARAMETER Side
        'buy' or 'sell'.

    .PARAMETER OrderType
        Order type. Defaults to 'market'.
        Values: market, limit, stop, stop_limit, trailing_stop.

    .PARAMETER TimeInForce
        Time in force. Defaults to 'day'.
        Values: day, gtc, opg, cls, ioc, fok.

    .PARAMETER LimitPrice
        Required for limit and stop_limit orders.

    .PARAMETER StopPrice
        Required for stop and stop_limit orders.

    .PARAMETER ClientOrderId
        Optional client-generated order ID for idempotency. Max 128 chars.
        Generate with New-AlpacaClientOrderId from Alpaca.Risk.

    .PARAMETER ExtendedHours
        If set, allows trading during pre-market and after-hours sessions.
        Only valid for limit orders with time_in_force = 'day'.

    .EXAMPLE
        Submit-AlpacaOrder -Symbol 'AAPL' -Qty 1 -Side 'buy'

    .EXAMPLE
        $coid = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        Submit-AlpacaOrder -Symbol 'AAPL' -Qty 5 -Side 'buy' -OrderType 'limit' -LimitPrice 182.50 -ClientOrderId $coid

    .OUTPUTS
        PSCustomObject (Alpaca order object)
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByQty')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [Parameter(Mandatory, ParameterSetName = 'ByQty')]
        [ValidateRange(0.00001, 1000000)]
        [double]$Qty,

        [Parameter(Mandatory, ParameterSetName = 'ByNotional')]
        [ValidateRange(1, 10000000)]
        [double]$Notional,

        [Parameter(Mandatory)]
        [ValidateSet('buy', 'sell')]
        [string]$Side,

        [ValidateSet('market', 'limit', 'stop', 'stop_limit', 'trailing_stop')]
        [string]$OrderType = 'market',

        [ValidateSet('day', 'gtc', 'opg', 'cls', 'ioc', 'fok')]
        [string]$TimeInForce = 'day',

        [double]$LimitPrice,
        [double]$StopPrice,

        [ValidateLength(0, 128)]
        [string]$ClientOrderId,

        [switch]$ExtendedHours
    )

    # Hard stop - never submit to a live endpoint
    Assert-PaperMode

    # Build the order body (only include fields that are set)
    $body = [ordered]@{
        symbol        = $Symbol.ToUpperInvariant()
        side          = $Side
        type          = $OrderType
        time_in_force = $TimeInForce
    }

    if ($PSCmdlet.ParameterSetName -eq 'ByQty') {
        # Send as string to preserve fractional precision
        $body['qty'] = [string]$Qty
    } else {
        $body['notional'] = [string]$Notional
    }

    if ($LimitPrice -gt 0)   { $body['limit_price']  = [string]$LimitPrice }
    if ($StopPrice -gt 0)    { $body['stop_price']   = [string]$StopPrice }
    if ($ClientOrderId)      { $body['client_order_id'] = $ClientOrderId }
    if ($ExtendedHours)      { $body['extended_hours'] = $true }

    $describe = "$Side $Symbol"
    if ($PSCmdlet.ParameterSetName -eq 'ByQty') {
        $describe += " x$Qty ($OrderType)"
    } else {
        $describe += " `$$Notional notional ($OrderType)"
    }

    if ($PSCmdlet.ShouldProcess($describe, 'Submit paper order')) {
        $cfg = Get-AlpacaConfig
        $order = Invoke-AlpacaRequest -Method POST -BaseUrl $cfg.TradingBaseUrl -Path '/v2/orders' -Body $body
        Write-Verbose "Order submitted: $($order.id) | status=$($order.status) | client_order_id=$($order.client_order_id)"
        return $order
    }
}


function Get-AlpacaOrder {
    <#
    .SYNOPSIS
        Returns a single order by order ID.

    .PARAMETER OrderId
        The Alpaca order UUID returned when the order was submitted.

    .EXAMPLE
        $order = Get-AlpacaOrder -OrderId 'e6fe2b0a-...'

    .OUTPUTS
        PSCustomObject (Alpaca order object), or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OrderId
    )

    $cfg = Get-AlpacaConfig
    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path "/v2/orders/$OrderId" -AllowNotFound
}


function Get-AlpacaOrders {
    <#
    .SYNOPSIS
        Returns a list of orders filtered by status and/or symbol.

    .DESCRIPTION
        This is a REST snapshot, not a real-time view. For live order state,
        subscribe to the trade_updates stream via Alpaca.Streams.TradeUpdates.
        Use this for startup reconciliation or manual inspection.

    .PARAMETER Status
        Filter by order status. Defaults to 'open'.
        Values: open, closed, all.

    .PARAMETER Symbol
        Optional symbol filter. Only returns orders for this symbol.

    .PARAMETER Limit
        Maximum orders to return. Range 1-500. Defaults to 50.

    .PARAMETER After
        Return orders submitted after this RFC 3339 timestamp.

    .PARAMETER Until
        Return orders submitted before this RFC 3339 timestamp.

    .PARAMETER Direction
        Sort direction: 'asc' or 'desc'. Defaults to 'desc' (newest first).

    .EXAMPLE
        Get-AlpacaOrders

    .EXAMPLE
        Get-AlpacaOrders -Status 'all' -Symbol 'AAPL' -Limit 20

    .OUTPUTS
        Array of PSCustomObject
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('open', 'closed', 'all')]
        [string]$Status = 'open',

        [string]$Symbol,

        [ValidateRange(1, 500)]
        [int]$Limit = 50,

        [string]$After,
        [string]$Until,

        [ValidateSet('asc', 'desc')]
        [string]$Direction = 'desc'
    )

    $cfg   = Get-AlpacaConfig
    $query = @{
        status    = $Status
        limit     = [string]$Limit
        direction = $Direction
    }

    if ($Symbol)  { $query['symbols'] = $Symbol.ToUpperInvariant() }
    if ($After)   { $query['after']   = $After }
    if ($Until)   { $query['until']   = $Until }

    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/orders' -QueryParams $query
}


function Remove-AlpacaOrder {
    <#
    .SYNOPSIS
        Cancels an open order by order ID.

    .DESCRIPTION
        Sends a DELETE to /v2/orders/{id}. The cancellation is not immediate;
        the order goes into a 'pending_cancel' state and a trade_update event
        with event='canceled' will arrive on the stream once confirmed.

    .PARAMETER OrderId
        The Alpaca order UUID to cancel.

    .EXAMPLE
        Remove-AlpacaOrder -OrderId 'e6fe2b0a-...'

    .OUTPUTS
        None. Throws on failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OrderId
    )

    Assert-PaperMode

    if ($PSCmdlet.ShouldProcess($OrderId, 'Cancel paper order')) {
        $cfg = Get-AlpacaConfig
        # DELETE /v2/orders/{id} returns 204 No Content on success
        Invoke-AlpacaRequest -Method DELETE -BaseUrl $cfg.TradingBaseUrl -Path "/v2/orders/$OrderId"
        Write-Verbose "Cancel request submitted for order: $OrderId"
    }
}


function Remove-AllAlpacaOrders {
    <#
    .SYNOPSIS
        Cancels all open orders.

    .DESCRIPTION
        Sends DELETE to /v2/orders to cancel every open order in the account.
        Use this as part of a kill-switch or end-of-day cleanup routine.

    .EXAMPLE
        Remove-AllAlpacaOrders

    .OUTPUTS
        Array of cancellation results (one per order).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Assert-PaperMode

    if ($PSCmdlet.ShouldProcess('all open orders', 'Cancel paper orders')) {
        $cfg = Get-AlpacaConfig
        $result = Invoke-AlpacaRequest -Method DELETE -BaseUrl $cfg.TradingBaseUrl -Path '/v2/orders'
        Write-Verbose "Cancel-all submitted. Results: $($result.Count) orders."
        return $result
    }
}


Export-ModuleMember -Function @(
    'Submit-AlpacaOrder',
    'Get-AlpacaOrder',
    'Get-AlpacaOrders',
    'Remove-AlpacaOrder',
    'Remove-AllAlpacaOrders'
)
