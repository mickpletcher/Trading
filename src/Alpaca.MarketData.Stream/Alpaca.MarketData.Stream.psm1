#Requires -Version 5.1
<#
.SYNOPSIS
    Real-time market data WebSocket stream for Alpaca.

.DESCRIPTION
    Connects to the Alpaca v2 market data WebSocket stream and delivers normalized
    trade, quote, and bar events to a caller-supplied scriptblock callback.

    Supports both real symbols and the FAKEPACA test symbol which sends synthetic
    data through the IEX feed at no cost - ideal for smoke testing your stream
    handling code without burning real data quota.

    Protocol (Alpaca v2 market data stream):
      1. Connect to wss://stream.data.alpaca.markets/v2/{feed}
      2. Server sends: [{"T":"success","msg":"connected"}]
      3. Client sends: {"action":"auth","key":"...","secret":"..."}
      4. Server sends: [{"T":"success","msg":"authenticated"}]
      5. Client sends: {"action":"subscribe","trades":["AAPL"],"quotes":["AAPL"],...}
      6. Server sends: [{"T":"subscription","trades":[...],"quotes":[...],...}]
      7. Data arrives as JSON arrays of event objects

    Event type codes:
      T = 't' -> trade
      T = 'q' -> quote
      T = 'b' -> bar (minute bars pushed in real time)
      T = 'u' -> updated bar
      T = 'd' -> daily bar
      T = 'status' -> trading status update

.NOTES
    FAKEPACA is a synthetic test ticker available on the IEX feed.
    Subscribe to it to get a steady stream of fake events without a paid subscription.
    Use: Start-AlpacaMarketDataStream -Trades @('FAKEPACA')
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


#region  Internal helpers (shared with TradeUpdates stream)

function _New-MarketDataWebSocket {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    return $ws
}

function _Send-MdWsMessage {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Message,
        [System.Threading.CancellationToken]$Token
    )
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $WebSocket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $Token).GetAwaiter().GetResult()
}

function _Receive-MdWsMessage {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [System.Threading.CancellationToken]$Token,
        [int]$BufferSize = 65536
    )
    $ms = New-Object System.IO.MemoryStream
    do {
        $buf     = New-Object byte[] $BufferSize
        $segment = [System.ArraySegment[byte]]::new($buf)
        $result  = $WebSocket.ReceiveAsync($segment, $Token).GetAwaiter().GetResult()
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            $WebSocket.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                'Server close',
                $Token
            ).GetAwaiter().GetResult()
            return $null
        }
        $ms.Write($buf, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

#endregion


function Start-AlpacaMarketDataStream {
    <#
    .SYNOPSIS
        Connects to the Alpaca real-time market data stream and processes events.

    .DESCRIPTION
        Runs a blocking event loop that delivers normalized trade, quote, and bar
        objects to your -OnEvent scriptblock. Reconnects automatically on disconnect
        with exponential backoff.

        To test your connection and parsing code without real symbols, subscribe to
        the FAKEPACA test ticker which sends synthetic events on the IEX feed.

        Each event passed to -OnEvent is a PSCustomObject with these common fields:
          .EventType   - 'trade', 'quote', 'bar', 'updatedBar', 'dailyBar', or 'status'
          .Symbol      - Ticker symbol
          .Timestamp   - Event time (RFC 3339 string)

        Additional fields per type:
          trade  : .Price .Size .TradeId .Exchange .Conditions
          quote  : .BidPrice .BidSize .AskPrice .AskSize .BidExchange .AskExchange
          bar    : .Open .High .Low .Close .Volume .Vwap .TradeCount
          status : .StatusCode .StatusMessage .ReasonCode .ReasonMessage

        Press Ctrl+C to stop cleanly.

    .PARAMETER Trades
        Array of symbols to subscribe to trade events.
        Example: @('AAPL', 'MSFT')
        Use @('*') to subscribe to all symbols (paid SIP feed only).
        Use @('FAKEPACA') for synthetic test data.

    .PARAMETER Quotes
        Array of symbols to subscribe to quote events.

    .PARAMETER Bars
        Array of symbols to subscribe to real-time minute bar events.

    .PARAMETER Feed
        Market data feed: 'iex' or 'sip'. Defaults to config DefaultFeed.
        FAKEPACA only works on 'iex'.

    .PARAMETER OnEvent
        Scriptblock called for each incoming event. Receives one argument:
        the normalized event PSCustomObject.

    .PARAMETER LogFile
        Optional path to write structured log entries.

    .PARAMETER MaxReconnects
        Maximum reconnect attempts. Defaults to 10.

    .PARAMETER ReconnectBaseDelay
        Seconds for initial reconnect delay. Doubles each attempt. Defaults to 2.

    .EXAMPLE
        # Smoke test with FAKEPACA
        Initialize-AlpacaConfig
        Start-AlpacaMarketDataStream -Trades @('FAKEPACA') -OnEvent {
            param($e)
            Write-Host "[$($e.EventType)] $($e.Symbol) @ $($e.Price)"
        }

    .EXAMPLE
        # Subscribe to real symbols
        Start-AlpacaMarketDataStream `
            -Trades  @('AAPL','MSFT') `
            -Quotes  @('AAPL','MSFT') `
            -Bars    @('AAPL') `
            -OnEvent { param($e) $e | ConvertTo-Json -Compress | Write-Host }

    .NOTES
        This function blocks until Ctrl+C or MaxReconnects exhausted.
        At least one of Trades, Quotes, or Bars must be specified.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Trades  = @(),
        [string[]]$Quotes  = @(),
        [string[]]$Bars    = @(),

        [ValidateSet('iex', 'sip')]
        [string]$Feed,

        [Parameter(Mandatory)]
        [scriptblock]$OnEvent,

        [string]$LogFile,

        [ValidateRange(1, 50)]
        [int]$MaxReconnects = 10,

        [ValidateRange(1, 30)]
        [int]$ReconnectBaseDelay = 2
    )

    if ($Trades.Count -eq 0 -and $Quotes.Count -eq 0 -and $Bars.Count -eq 0) {
        throw "Specify at least one symbol in -Trades, -Quotes, or -Bars."
    }

    $cfg     = Get-AlpacaConfig
    $feedVal = if ($Feed) { $Feed } else { $cfg.DefaultFeed }

    # Build the WSS URL: base + /iex or /sip
    $wsUri   = [Uri]('{0}/{1}' -f $cfg.MarketDataWsUrl.TrimEnd('/'), $feedVal)

    Write-AlpacaLog -Level INFO -Message "Market data stream starting. Feed: $feedVal  Endpoint: $wsUri" -LogFile $LogFile

    $cts        = New-Object System.Threading.CancellationTokenSource
    $reconnects = 0

    $null = Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action { $cts.Cancel() }

    # Build the subscription message (only include non-empty symbol lists)
    $subMsg = @{ action = 'subscribe' }
    if ($Trades.Count -gt 0) { $subMsg['trades'] = $Trades }
    if ($Quotes.Count -gt 0) { $subMsg['quotes'] = $Quotes }
    if ($Bars.Count   -gt 0) { $subMsg['bars']   = $Bars   }
    $subJson = $subMsg | ConvertTo-Json -Compress -Depth 5

    try {
        while ($reconnects -le $MaxReconnects) {

            $ws = _New-MarketDataWebSocket

            try {
                # ---- Connect ----
                Write-AlpacaLog -Level INFO -Message "Connecting to market data stream (attempt $($reconnects + 1))..." -LogFile $LogFile
                $ws.ConnectAsync($wsUri, $cts.Token).GetAwaiter().GetResult()

                # ---- Read connected message ----
                # Expected: [{"T":"success","msg":"connected"}]
                $connMsg = _Receive-MdWsMessage -WebSocket $ws -Token $cts.Token
                Write-Verbose "MD stream connected msg: $connMsg"

                $connArray = $connMsg | ConvertFrom-Json
                if ($connArray[0].T -ne 'success') {
                    throw "Expected connected success message, got: $connMsg"
                }

                # ---- Authenticate ----
                $authJson = @{
                    action = 'auth'
                    key    = $cfg.ApiKey
                    secret = $cfg.SecretKey
                } | ConvertTo-Json -Compress

                _Send-MdWsMessage -WebSocket $ws -Message $authJson -Token $cts.Token

                $authResp = _Receive-MdWsMessage -WebSocket $ws -Token $cts.Token
                Write-Verbose "MD auth response: $authResp"

                $authArray = $authResp | ConvertFrom-Json
                if ($authArray[0].T -ne 'success' -or $authArray[0].msg -ne 'authenticated') {
                    $err = if ($authArray[0].msg) { $authArray[0].msg } else { $authResp }
                    throw "Market data stream authentication failed: $err"
                }

                Write-AlpacaLog -Level INFO -Message "Authenticated to $feedVal market data stream." -LogFile $LogFile

                # ---- Subscribe ----
                _Send-MdWsMessage -WebSocket $ws -Message $subJson -Token $cts.Token

                $subResp = _Receive-MdWsMessage -WebSocket $ws -Token $cts.Token
                Write-Verbose "MD subscribe response: $subResp"
                Write-AlpacaLog -Level INFO -Message "Subscription confirmed: $subResp" -LogFile $LogFile

                $reconnects = 0  # reset on successful connect + auth + subscribe

                # ---- Main receive loop ----
                while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $cts.IsCancellationRequested) {

                    $raw = _Receive-MdWsMessage -WebSocket $ws -Token $cts.Token

                    if ($null -eq $raw) {
                        Write-AlpacaLog -Level WARN -Message "Server closed market data stream connection." -LogFile $LogFile
                        break
                    }

                    Write-Verbose "MD message: $raw"

                    # Messages arrive as JSON arrays; each element is an event
                    try {
                        $events = $raw | ConvertFrom-Json

                        foreach ($rawEvent in $events) {
                            $event = _ConvertTo-MarketDataEvent -Raw $rawEvent

                            if ($null -ne $event) {
                                try {
                                    & $OnEvent $event
                                } catch {
                                    Write-AlpacaLog -Level ERROR -Message "OnEvent callback threw: $_" -LogFile $LogFile
                                }
                            }
                        }
                    }
                    catch {
                        Write-AlpacaLog -Level WARN -Message "Failed to parse market data message: $_  Raw: $raw" -LogFile $LogFile
                    }
                }

            }
            catch [System.OperationCanceledException] {
                Write-AlpacaLog -Level INFO -Message "Market data stream canceled by user." -LogFile $LogFile
                break
            }
            catch {
                $reconnects++
                if ($reconnects -gt $MaxReconnects) {
                    Write-AlpacaLog -Level ERROR -Message "Max reconnects ($MaxReconnects) exceeded." -LogFile $LogFile
                    throw
                }
                $delay = [math]::Min($ReconnectBaseDelay * [math]::Pow(2, $reconnects - 1), 60)
                Write-AlpacaLog -Level WARN -Message "Stream error: $_ Reconnect $reconnects/$MaxReconnects in ${delay}s..." -LogFile $LogFile
                Start-Sleep -Seconds ([int]$delay)
            }
            finally {
                if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                    try {
                        $ws.CloseAsync(
                            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                            'Closing',
                            [System.Threading.CancellationToken]::None
                        ).GetAwaiter().GetResult()
                    } catch { }
                }
                $ws.Dispose()
            }
        }

    }
    finally {
        $cts.Dispose()
        Unregister-Event -SourceIdentifier 'PowerShell.Exiting' -ErrorAction SilentlyContinue
        Write-AlpacaLog -Level INFO -Message "Market data stream stopped." -LogFile $LogFile
    }
}


function _Get-MdRawValue {
    param(
        [Parameter(Mandatory)][object]$Raw,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Raw) { return $null }

    if ($Raw -is [System.Collections.IDictionary]) {
        foreach ($key in $Raw.Keys) {
            if ([string]$key -ceq $Name) {
                return $Raw[$key]
            }
        }
        return $null
    }

    foreach ($p in $Raw.PSObject.Properties) {
        if ($p.Name -ceq $Name) {
            return $p.Value
        }
    }

    return $null
}


function _ConvertTo-MarketDataEvent {
    <#
        Internal. Normalizes a raw Alpaca market data event object (one element from
        the incoming JSON array) to a consistent PSCustomObject.
        Returns $null for subscription confirmations and other control frames.
    #>
    param([object]$Raw)

    $typeCode = [string](_Get-MdRawValue -Raw $Raw -Name 'T')

    switch ($typeCode) {
        't' {
            $price = _Get-MdRawValue -Raw $Raw -Name 'p'
            $size  = _Get-MdRawValue -Raw $Raw -Name 's'
            return [PSCustomObject]@{
                EventType  = 'trade'
                Symbol     = [string](_Get-MdRawValue -Raw $Raw -Name 'S')
                Timestamp  = [string](_Get-MdRawValue -Raw $Raw -Name 't')
                Price      = if ($null -ne $price) { [double]$price } else { 0.0 }
                Size       = if ($null -ne $size)  { [double]$size }  else { 0 }
                TradeId    = [string](_Get-MdRawValue -Raw $Raw -Name 'i')
                Exchange   = [string](_Get-MdRawValue -Raw $Raw -Name 'x')
                Conditions = (_Get-MdRawValue -Raw $Raw -Name 'c')
                RawData    = $Raw
            }
        }
        'q' {
            $bp = _Get-MdRawValue -Raw $Raw -Name 'bp'
            $bs = _Get-MdRawValue -Raw $Raw -Name 'bs'
            $ap = _Get-MdRawValue -Raw $Raw -Name 'ap'
            $as = _Get-MdRawValue -Raw $Raw -Name 'as'
            return [PSCustomObject]@{
                EventType   = 'quote'
                Symbol      = [string](_Get-MdRawValue -Raw $Raw -Name 'S')
                Timestamp   = [string](_Get-MdRawValue -Raw $Raw -Name 't')
                BidPrice    = if ($null -ne $bp) { [double]$bp } else { 0.0 }
                BidSize     = if ($null -ne $bs) { [double]$bs } else { 0 }
                AskPrice    = if ($null -ne $ap) { [double]$ap } else { 0.0 }
                AskSize     = if ($null -ne $as) { [double]$as } else { 0 }
                BidExchange = [string](_Get-MdRawValue -Raw $Raw -Name 'bx')
                AskExchange = [string](_Get-MdRawValue -Raw $Raw -Name 'ax')
                Conditions  = (_Get-MdRawValue -Raw $Raw -Name 'c')
                RawData     = $Raw
            }
        }
        'b' {
            $o  = _Get-MdRawValue -Raw $Raw -Name 'o'
            $h  = _Get-MdRawValue -Raw $Raw -Name 'h'
            $l  = _Get-MdRawValue -Raw $Raw -Name 'l'
            $c  = _Get-MdRawValue -Raw $Raw -Name 'c'
            $v  = _Get-MdRawValue -Raw $Raw -Name 'v'
            $vw = _Get-MdRawValue -Raw $Raw -Name 'vw'
            $n  = _Get-MdRawValue -Raw $Raw -Name 'n'
            return [PSCustomObject]@{
                EventType  = 'bar'
                Symbol     = [string](_Get-MdRawValue -Raw $Raw -Name 'S')
                Timestamp  = [string](_Get-MdRawValue -Raw $Raw -Name 't')
                Open       = if ($null -ne $o)  { [double]$o }  else { 0.0 }
                High       = if ($null -ne $h)  { [double]$h }  else { 0.0 }
                Low        = if ($null -ne $l)  { [double]$l }  else { 0.0 }
                Close      = if ($null -ne $c)  { [double]$c }  else { 0.0 }
                Volume     = if ($null -ne $v)  { [double]$v }  else { 0 }
                Vwap       = if ($null -ne $vw) { [double]$vw } else { 0.0 }
                TradeCount = if ($null -ne $n)  { [int]$n }     else { 0 }
                RawData    = $Raw
            }
        }
        'u' {
            # Updated (revised) bar - same shape as bar
            $o  = _Get-MdRawValue -Raw $Raw -Name 'o'
            $h  = _Get-MdRawValue -Raw $Raw -Name 'h'
            $l  = _Get-MdRawValue -Raw $Raw -Name 'l'
            $c  = _Get-MdRawValue -Raw $Raw -Name 'c'
            $v  = _Get-MdRawValue -Raw $Raw -Name 'v'
            $vw = _Get-MdRawValue -Raw $Raw -Name 'vw'
            $n  = _Get-MdRawValue -Raw $Raw -Name 'n'
            return [PSCustomObject]@{
                EventType  = 'updatedBar'
                Symbol     = [string](_Get-MdRawValue -Raw $Raw -Name 'S')
                Timestamp  = [string](_Get-MdRawValue -Raw $Raw -Name 't')
                Open       = if ($null -ne $o)  { [double]$o }  else { 0.0 }
                High       = if ($null -ne $h)  { [double]$h }  else { 0.0 }
                Low        = if ($null -ne $l)  { [double]$l }  else { 0.0 }
                Close      = if ($null -ne $c)  { [double]$c }  else { 0.0 }
                Volume     = if ($null -ne $v)  { [double]$v }  else { 0 }
                Vwap       = if ($null -ne $vw) { [double]$vw } else { 0.0 }
                TradeCount = if ($null -ne $n)  { [int]$n }     else { 0 }
                RawData    = $Raw
            }
        }
        'd' {
            $o  = _Get-MdRawValue -Raw $Raw -Name 'o'
            $h  = _Get-MdRawValue -Raw $Raw -Name 'h'
            $l  = _Get-MdRawValue -Raw $Raw -Name 'l'
            $c  = _Get-MdRawValue -Raw $Raw -Name 'c'
            $v  = _Get-MdRawValue -Raw $Raw -Name 'v'
            $vw = _Get-MdRawValue -Raw $Raw -Name 'vw'
            $n  = _Get-MdRawValue -Raw $Raw -Name 'n'
            return [PSCustomObject]@{
                EventType  = 'dailyBar'
                Symbol     = [string](_Get-MdRawValue -Raw $Raw -Name 'S')
                Timestamp  = [string](_Get-MdRawValue -Raw $Raw -Name 't')
                Open       = if ($null -ne $o)  { [double]$o }  else { 0.0 }
                High       = if ($null -ne $h)  { [double]$h }  else { 0.0 }
                Low        = if ($null -ne $l)  { [double]$l }  else { 0.0 }
                Close      = if ($null -ne $c)  { [double]$c }  else { 0.0 }
                Volume     = if ($null -ne $v)  { [double]$v }  else { 0 }
                Vwap       = if ($null -ne $vw) { [double]$vw } else { 0.0 }
                TradeCount = if ($null -ne $n)  { [int]$n }     else { 0 }
                RawData    = $Raw
            }
        }
        { $_ -in @('status', 'trading_status') } {
            return [PSCustomObject]@{
                EventType      = 'status'
                Symbol         = [string](_Get-MdRawValue -Raw $Raw -Name 'S')
                Timestamp      = [string](_Get-MdRawValue -Raw $Raw -Name 't')
                StatusCode     = [string](_Get-MdRawValue -Raw $Raw -Name 'sc')
                StatusMessage  = [string](_Get-MdRawValue -Raw $Raw -Name 'sm')
                ReasonCode     = [string](_Get-MdRawValue -Raw $Raw -Name 'rc')
                ReasonMessage  = [string](_Get-MdRawValue -Raw $Raw -Name 'rm')
                RawData        = $Raw
            }
        }
        { $_ -in @('subscription', 'success', 'error') } {
            # Control frames - log but don't call OnEvent
            Write-Verbose "MD control frame [T=$typeCode]: $($Raw | ConvertTo-Json -Compress)"
            return $null
        }
        default {
            Write-Verbose "MD unknown event type [$typeCode]: $($Raw | ConvertTo-Json -Compress)"
            return $null
        }
    }
}


Export-ModuleMember -Function @(
    'Start-AlpacaMarketDataStream'
)
