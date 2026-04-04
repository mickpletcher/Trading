#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca historical market data via REST.

.DESCRIPTION
    Functions for pulling historical bars, quotes, and trades from the Alpaca
    market data REST API. All calls go to data.alpaca.markets using the same
    auth headers as trading.

    Feed selection:
      'iex'         - free tier, IEX exchange data only
      'sip'         - paid subscription, consolidated tape (more liquid)
      'delayed_sip' - SIP data with 15-minute delay (available on free tier)

    Pagination:
      Alpaca returns data in pages. These functions handle pagination automatically
      by following next_page_token until all data is fetched.

.NOTES
    Date formats: Alpaca accepts ISO 8601 / RFC 3339. Use 'yyyy-MM-dd' for date-only
    or 'yyyy-MM-ddTHH:mm:ssZ' for precise timestamps.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


function Get-AlpacaBars {
    <#
    .SYNOPSIS
        Returns historical OHLCV bars for one or more symbols.

    .DESCRIPTION
        Fetches candlestick/bar data from the Alpaca market data API.
        Supports minute, hourly, and daily timeframes with automatic pagination.

        Returned bars have these fields:
          t  - timestamp (RFC 3339)
          o  - open price
          h  - high price
          l  - low price
          c  - close price
          v  - volume
          n  - number of trades
          vw - volume-weighted average price (VWAP)

    .PARAMETER Symbol
        One ticker symbol. For multiple symbols use Get-AlpacaMultiBars.
        Example: 'AAPL'

    .PARAMETER Timeframe
        Bar period. Supported values:
          1Min, 5Min, 15Min, 30Min - minute bars
          1Hour, 2Hour, 4Hour      - hourly bars
          1Day, 1Week, 1Month      - daily and above
        Defaults to '1Day'.

    .PARAMETER Start
        Start of date range. Format: 'yyyy-MM-dd' or ISO 8601.
        Example: '2025-01-01'

    .PARAMETER End
        End of date range. Format: 'yyyy-MM-dd' or ISO 8601.
        Defaults to today.

    .PARAMETER Feed
        Market data feed. Overrides the DefaultFeed in config.
        Values: iex, sip, delayed_sip.

    .PARAMETER Limit
        Maximum bars per page (Alpaca default 1000, max 10000).
        Pagination is automatic so you normally do not need to set this.

    .PARAMETER MaxPages
        Maximum pages to fetch. Safety limit to prevent runaway pagination.
        Defaults to 20 (up to 20,000 daily bars = ~80 years, or ~333 hours of 1Min).

    .PARAMETER Adjustment
        Price adjustment method for dividends/splits.
        Values: raw, split, dividend, all. Defaults to 'raw'.

    .EXAMPLE
        $bars = Get-AlpacaBars -Symbol 'AAPL' -Timeframe '1Day' -Start '2025-01-01'
        $bars | Select-Object t, o, h, l, c, v | Format-Table

    .EXAMPLE
        $bars = Get-AlpacaBars -Symbol 'SPY' -Timeframe '1Hour' -Start '2025-03-01' -End '2025-03-31'

    .OUTPUTS
        Array of PSCustomObject (bar objects)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [ValidateSet('1Min','5Min','15Min','30Min','1Hour','2Hour','4Hour','1Day','1Week','1Month')]
        [string]$Timeframe = '1Day',

        [string]$Start,
        [string]$End,

        [ValidateSet('iex', 'sip', 'delayed_sip')]
        [string]$Feed,

        [ValidateRange(1, 10000)]
        [int]$Limit = 1000,

        [ValidateRange(1, 200)]
        [int]$MaxPages = 20,

        [ValidateSet('raw', 'split', 'dividend', 'all')]
        [string]$Adjustment = 'raw'
    )

    $cfg     = Get-AlpacaConfig
    $feedVal = if ($Feed) { $Feed } else { $cfg.DefaultFeed }

    $query = @{
        timeframe  = $Timeframe
        limit      = [string]$Limit
        adjustment = $Adjustment
        feed       = $feedVal
    }

    if ($Start) { $query['start'] = $Start }
    if ($End)   { $query['end']   = $End   }

    $allBars  = [System.Collections.Generic.List[object]]::new()
    $page     = 0
    $nextToken = $null

    do {
        $page++

        if ($nextToken) {
            $query['page_token'] = $nextToken
        } else {
            $query.Remove('page_token')
        }

        $path   = "/v2/stocks/{0}/bars" -f [Uri]::EscapeDataString($Symbol.ToUpperInvariant())
        $result = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.MarketDataBaseUrl -Path $path -QueryParams $query

        if ($result.bars) {
            $allBars.AddRange([object[]]$result.bars)
            Write-Verbose "Page $page`: fetched $($result.bars.Count) bars. Total so far: $($allBars.Count)"
        }

        $nextToken = $result.next_page_token

    } while ($nextToken -and $page -lt $MaxPages)

    if ($nextToken -and $page -ge $MaxPages) {
        Write-Warning "Get-AlpacaBars: MaxPages ($MaxPages) reached. Results may be incomplete. Use a narrower date range or increase MaxPages."
    }

    Write-Verbose "Get-AlpacaBars complete: $($allBars.Count) bars for $Symbol ($Timeframe)"
    return $allBars.ToArray()
}


function Get-AlpacaLatestBar {
    <#
    .SYNOPSIS
        Returns the most recent bar for a symbol.

    .PARAMETER Symbol
        Ticker symbol. Example: 'AAPL'.

    .PARAMETER Feed
        Market data feed override. Defaults to config DefaultFeed.

    .EXAMPLE
        $bar = Get-AlpacaLatestBar -Symbol 'SPY'
        Write-Host "SPY VWAP: $($bar.vw)"

    .OUTPUTS
        PSCustomObject (single bar)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [ValidateSet('iex', 'sip', 'delayed_sip')]
        [string]$Feed
    )

    $cfg     = Get-AlpacaConfig
    $feedVal = if ($Feed) { $Feed } else { $cfg.DefaultFeed }
    $path    = "/v2/stocks/{0}/bars/latest" -f [Uri]::EscapeDataString($Symbol.ToUpperInvariant())

    $result = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.MarketDataBaseUrl -Path $path -QueryParams @{ feed = $feedVal }
    return $result.bar
}


function Get-AlpacaLatestQuote {
    <#
    .SYNOPSIS
        Returns the most recent bid/ask quote for a symbol.

    .DESCRIPTION
        Returns the latest NBBO (or IEX) quote with bid price, bid size,
        ask price, ask size, and timestamp.

    .PARAMETER Symbol
        Ticker symbol. Example: 'AAPL'.

    .PARAMETER Feed
        Market data feed override.

    .EXAMPLE
        $q = Get-AlpacaLatestQuote -Symbol 'AAPL'
        Write-Host "Bid: $($q.bp)  Ask: $($q.ap)"

    .OUTPUTS
        PSCustomObject with: ap (ask price), as (ask size), bp (bid price),
        bs (bid size), ax (ask exchange), bx (bid exchange), t (timestamp)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [ValidateSet('iex', 'sip', 'delayed_sip')]
        [string]$Feed
    )

    $cfg     = Get-AlpacaConfig
    $feedVal = if ($Feed) { $Feed } else { $cfg.DefaultFeed }
    $path    = "/v2/stocks/{0}/quotes/latest" -f [Uri]::EscapeDataString($Symbol.ToUpperInvariant())

    $result = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.MarketDataBaseUrl -Path $path -QueryParams @{ feed = $feedVal }
    return $result.quote
}


function Get-AlpacaLatestTrade {
    <#
    .SYNOPSIS
        Returns the most recent trade (last sale) for a symbol.

    .PARAMETER Symbol
        Ticker symbol.

    .PARAMETER Feed
        Market data feed override.

    .EXAMPLE
        $trade = Get-AlpacaLatestTrade -Symbol 'MSFT'
        Write-Host "Last price: $($trade.p)"

    .OUTPUTS
        PSCustomObject with: p (price), s (size), t (timestamp), x (exchange)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [ValidateSet('iex', 'sip', 'delayed_sip')]
        [string]$Feed
    )

    $cfg     = Get-AlpacaConfig
    $feedVal = if ($Feed) { $Feed } else { $cfg.DefaultFeed }
    $path    = "/v2/stocks/{0}/trades/latest" -f [Uri]::EscapeDataString($Symbol.ToUpperInvariant())

    $result = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.MarketDataBaseUrl -Path $path -QueryParams @{ feed = $feedVal }
    return $result.trade
}


function Get-AlpacaSnapshot {
    <#
    .SYNOPSIS
        Returns a snapshot (latest bar, quote, and trade) for a symbol.

    .DESCRIPTION
        The snapshot endpoint combines the latest bar, minute bar, daily bar,
        quote, and trade into a single API call. More efficient than calling
        each endpoint separately when you need all of them.

    .PARAMETER Symbol
        Ticker symbol.

    .PARAMETER Feed
        Market data feed override.

    .EXAMPLE
        $snap = Get-AlpacaSnapshot -Symbol 'AAPL'
        Write-Host "Daily bar close: $($snap.dailyBar.c)"
        Write-Host "Latest quote ask: $($snap.latestQuote.ap)"

    .OUTPUTS
        PSCustomObject with: latestTrade, latestQuote, minuteBar, dailyBar, prevDailyBar
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [ValidateSet('iex', 'sip', 'delayed_sip')]
        [string]$Feed
    )

    $cfg     = Get-AlpacaConfig
    $feedVal = if ($Feed) { $Feed } else { $cfg.DefaultFeed }
    $path    = "/v2/stocks/{0}/snapshot" -f [Uri]::EscapeDataString($Symbol.ToUpperInvariant())

    Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.MarketDataBaseUrl -Path $path -QueryParams @{ feed = $feedVal }
}


Export-ModuleMember -Function @(
    'Get-AlpacaBars',
    'Get-AlpacaLatestBar',
    'Get-AlpacaLatestQuote',
    'Get-AlpacaLatestTrade',
    'Get-AlpacaSnapshot'
)
