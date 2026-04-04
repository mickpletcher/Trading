#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca asset lookup functions.

.DESCRIPTION
    Functions for querying tradable assets from the Alpaca paper API.
    Read only. Does not place orders.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


function Get-AlpacaAsset {
    <#
    .SYNOPSIS
        Returns details for a single asset by symbol or asset ID.

    .DESCRIPTION
        Returns tradability, asset class, exchange, fractionable status,
        and other metadata for a single symbol.

    .PARAMETER Symbol
        Stock or crypto symbol. Examples: AAPL, BTC/USD, FAKEPACA.

    .EXAMPLE
        Get-AlpacaAsset -Symbol 'AAPL'

    .EXAMPLE
        Get-AlpacaAsset -Symbol 'BTC/USD'

    .OUTPUTS
        PSCustomObject with asset fields, or $null if the symbol is not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol
    )

    $cfg = Get-AlpacaConfig

    # '/' must be encoded as '%2F' in the path segment for crypto pairs like BTC/USD
    $encodedSymbol = [Uri]::EscapeDataString($Symbol)

    Invoke-AlpacaRequest -Method GET `
        -BaseUrl $cfg.TradingBaseUrl `
        -Path    "/v2/assets/$encodedSymbol" `
        -AllowNotFound
}


function Get-AlpacaAssets {
    <#
    .SYNOPSIS
        Returns a filtered list of tradable assets.

    .DESCRIPTION
        Returns all assets matching the specified status and asset class.
        Useful for building a universe of symbols to trade.

    .PARAMETER Status
        Filter by asset status. 'active' returns tradable assets only.
        Defaults to 'active'.

    .PARAMETER AssetClass
        Filter by asset class. 'us_equity' for stocks and ETFs,
        'crypto' for cryptocurrencies.
        Defaults to 'us_equity'.

    .PARAMETER Exchange
        Optional exchange filter. e.g. 'NYSE', 'NASDAQ', 'ARCA'.

    .EXAMPLE
        $stocks = Get-AlpacaAssets

    .EXAMPLE
        $crypto = Get-AlpacaAssets -AssetClass 'crypto'

    .EXAMPLE
        Get-AlpacaAssets -AssetClass 'us_equity' -Exchange 'NYSE'

    .OUTPUTS
        Array of PSCustomObject
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('active', 'inactive')]
        [string]$Status = 'active',

        [ValidateSet('us_equity', 'crypto')]
        [string]$AssetClass = 'us_equity',

        [string]$Exchange
    )

    $cfg    = Get-AlpacaConfig
    $query  = @{
        status      = $Status
        asset_class = $AssetClass
    }

    if ($Exchange) {
        $query['exchange'] = $Exchange
    }

    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/assets' -QueryParams $query
}


Export-ModuleMember -Function @(
    'Get-AlpacaAsset',
    'Get-AlpacaAssets'
)
