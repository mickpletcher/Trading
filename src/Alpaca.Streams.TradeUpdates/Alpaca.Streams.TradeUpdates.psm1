#Requires -Version 5.1
<#
.SYNOPSIS
    Trade update WebSocket stream for Alpaca paper trading.

.DESCRIPTION
    Connects to the Alpaca paper trading trade_updates WebSocket stream and
    delivers order lifecycle events (new, fill, partial_fill, canceled, etc.)
    to a caller-supplied scriptblock callback.

    This is the CORRECT way to track order state. Do NOT poll GET /v2/orders
    as your primary mechanism - that is slow, wasteful, and misses nuance.
    The trade_updates stream gives you every status change in real time.

    How it works:
      1. Connect to wss://paper-api.alpaca.markets/stream
      2. Authenticate with API key and secret
      3. Listen for trade_updates events
      4. Parse each event and pass it to your -OnEvent scriptblock
      5. Reconnect automatically on disconnect (with exponential backoff)

    Stopping:
      Press Ctrl+C to disconnect cleanly. The function traps the interrupt and
      closes the WebSocket before returning.

    Protocol:
      Alpaca ws uses these JSON shapes for the trading stream:
        Authenticate : {"action":"authenticate","data":{"key_id":"...","secret_key":"..."}}
        Listen       : {"action":"listen","data":{"streams":["trade_updates"]}}
        Event msg    : {"stream":"trade_updates","data":{...}}
        Auth result  : {"stream":"authorization","data":{"status":"authorized",...}}

.NOTES
    Uses System.Net.WebSockets.ClientWebSocket (.NET 4.5+).
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
    All WebSocket operations are blocking (GetAwaiter().GetResult()) to stay
    simple and avoid async complexity in a PowerShell context.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


#region  Internal WebSocket helpers

function _New-WebSocket {
    # Creates a fresh ClientWebSocket with sensible defaults
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    return $ws
}

function _Send-WsMessage {
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Message,
        [System.Threading.CancellationToken]$Token
    )

    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $task    = $WebSocket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,          # end-of-message
        $Token
    )
    $task.GetAwaiter().GetResult()
}

function _Receive-WsMessage {
    # Reads one complete message from the WebSocket. Accumulates chunks until
    # the end-of-message flag is set. Returns the decoded UTF-8 string.
    param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [System.Threading.CancellationToken]$Token,
        [int]$BufferSize = 65536
    )

    $ms = New-Object System.IO.MemoryStream

    do {
        $buffer  = New-Object byte[] $BufferSize
        $segment = [System.ArraySegment[byte]]::new($buffer)
        $result  = $WebSocket.ReceiveAsync($segment, $Token).GetAwaiter().GetResult()

        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            # Server requested a graceful close
            $WebSocket.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                'Server requested close',
                $Token
            ).GetAwaiter().GetResult()
            return $null
        }

        $ms.Write($buffer, 0, $result.Count)

    } while (-not $result.EndOfMessage)

    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

#endregion


function Start-AlpacaTradeUpdateStream {
    <#
    .SYNOPSIS
        Connects to the Alpaca paper trade_updates WebSocket stream and processes events.

    .DESCRIPTION
        Runs a blocking event loop that delivers normalized trade update objects to
        your -OnEvent scriptblock. Reconnects automatically with exponential backoff
        when the connection drops.

        Each event object passed to -OnEvent has these guaranteed fields:
          .EventType    - The event name: new, fill, partial_fill, canceled,
                          expired, pending_cancel, replaced, etc.
          .OrderId      - Alpaca order UUID
          .ClientOrderId- Your client_order_id if you set one
          .Symbol       - Ticker symbol
          .Side         - buy or sell
          .Qty          - Order quantity
          .FilledQty    - Shares filled so far
          .FilledAvgPx  - Average fill price (0 if unfilled)
          .Status       - Order status string
          .OrderType    - market, limit, stop, etc.
          .RawData      - The full original data object from Alpaca for anything else

        Press Ctrl+C to stop cleanly.

    .PARAMETER OnEvent
        Scriptblock called for each trade update event. Receives one argument:
        the normalized event PSCustomObject.

        Example:
          -OnEvent { param($e) Write-Host "$($e.EventType): $($e.Symbol) $($e.Side) $($e.Qty)" }

    .PARAMETER LogFile
        Optional path to write structured log entries.

    .PARAMETER MaxReconnects
        Maximum reconnect attempts before giving up. Defaults to 10.

    .PARAMETER ReconnectBaseDelay
        Seconds for initial reconnect wait. Doubles each attempt. Defaults to 2.

    .EXAMPLE
        Import-Module .\src\Alpaca.Auth\Alpaca.Auth.psd1
        Import-Module .\src\Alpaca.Streams.TradeUpdates\Alpaca.Streams.TradeUpdates.psd1
        Initialize-AlpacaConfig

        Start-AlpacaTradeUpdateStream -OnEvent {
            param($event)
            Write-Host "[$($event.EventType)] $($event.Symbol) $($event.Side) $($event.FilledQty)/$($event.Qty) @ $($event.FilledAvgPx)"
        }

    .NOTES
        This function blocks until Ctrl+C is pressed or MaxReconnects is exhausted.
        Run it as a background job or in a separate runspace if you need it alongside
        other work in the same script.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$OnEvent,

        [string]$LogFile,

        [ValidateRange(1, 50)]
        [int]$MaxReconnects = 10,

        [ValidateRange(1, 30)]
        [int]$ReconnectBaseDelay = 2
    )

    $cfg        = Get-AlpacaConfig
    $wsUri      = [Uri]$cfg.TradingWsUrl
    $reconnects = 0

    Write-AlpacaLog -Level INFO -Message "Trade update stream starting. Endpoint: $wsUri" -LogFile $LogFile

    # Trap Ctrl+C so we can close the socket cleanly
    $cts = New-Object System.Threading.CancellationTokenSource
    $null = Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
        $cts.Cancel()
    }

    try {
        while ($reconnects -le $MaxReconnects) {

            $ws = _New-WebSocket

            try {
                # ---- Connect ----
                Write-AlpacaLog -Level INFO -Message "Connecting to trade_updates stream (attempt $($reconnects + 1))..." -LogFile $LogFile
                $ws.ConnectAsync($wsUri, $cts.Token).GetAwaiter().GetResult()
                Write-AlpacaLog -Level INFO -Message "WebSocket connected." -LogFile $LogFile

                # ---- Read welcome / initial message(s) ----
                # Alpaca may send an authorization status message immediately on connect
                $welcome = _Receive-WsMessage -WebSocket $ws -Token $cts.Token
                Write-Verbose "WS welcome: $welcome"

                # ---- Authenticate ----
                $authMsg = @{
                    action = 'authenticate'
                    data   = @{
                        key_id     = $cfg.ApiKey
                        secret_key = $cfg.SecretKey
                    }
                } | ConvertTo-Json -Compress -Depth 5

                _Send-WsMessage -WebSocket $ws -Message $authMsg -Token $cts.Token
                Write-Verbose "Auth message sent."

                $authResp = _Receive-WsMessage -WebSocket $ws -Token $cts.Token
                Write-Verbose "Auth response: $authResp"

                $authObj = $authResp | ConvertFrom-Json
                if ($authObj.stream -eq 'authorization' -and $authObj.data.status -ne 'authorized') {
                    $reason = $authObj.data.status
                    Write-AlpacaLog -Level ERROR -Message "Authentication failed: $reason" -LogFile $LogFile
                    throw "Trade update stream authentication failed: $reason"
                }

                Write-AlpacaLog -Level INFO -Message "Authenticated to trade_updates stream." -LogFile $LogFile

                # ---- Subscribe to trade_updates ----
                $listenMsg = @{
                    action = 'listen'
                    data   = @{ streams = @('trade_updates') }
                } | ConvertTo-Json -Compress -Depth 5

                _Send-WsMessage -WebSocket $ws -Message $listenMsg -Token $cts.Token

                $listenResp = _Receive-WsMessage -WebSocket $ws -Token $cts.Token
                Write-Verbose "Listen response: $listenResp"
                Write-AlpacaLog -Level INFO -Message "Subscribed to trade_updates." -LogFile $LogFile

                # Reset reconnect counter on successful connection + auth
                $reconnects = 0

                # ---- Main receive loop ----
                while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $cts.IsCancellationRequested) {

                    $raw = _Receive-WsMessage -WebSocket $ws -Token $cts.Token

                    if ($null -eq $raw) {
                        # Server sent a close frame
                        Write-AlpacaLog -Level WARN -Message "Server closed trade_updates connection." -LogFile $LogFile
                        break
                    }

                    Write-Verbose "WS message: $raw"

                    try {
                        $msg = $raw | ConvertFrom-Json

                        # The trading stream wraps events as: {"stream":"trade_updates","data":{...}}
                        if ($msg.stream -eq 'trade_updates' -and $null -ne $msg.data) {
                            $event = _ConvertTo-TradeUpdateEvent -Data $msg.data
                            Write-AlpacaLog -Level INFO -Message "TradeUpdate [$($event.EventType)] $($event.Symbol) $($event.Side) $($event.FilledQty)/$($event.Qty)" -LogFile $LogFile

                            # Invoke the caller's handler in a try/catch so a bad callback
                            # does not crash the stream loop
                            try {
                                & $OnEvent $event
                            } catch {
                                Write-AlpacaLog -Level ERROR -Message "OnEvent callback threw: $_" -LogFile $LogFile
                            }
                        }
                        # Heartbeat / other stream messages are silently ignored
                    }
                    catch {
                        Write-AlpacaLog -Level WARN -Message "Failed to parse message: $_  Raw: $raw" -LogFile $LogFile
                    }
                }

            }
            catch [System.OperationCanceledException] {
                Write-AlpacaLog -Level INFO -Message "Trade update stream canceled by user." -LogFile $LogFile
                break
            }
            catch {
                $reconnects++
                if ($reconnects -gt $MaxReconnects) {
                    Write-AlpacaLog -Level ERROR -Message "Max reconnects ($MaxReconnects) exceeded. Giving up." -LogFile $LogFile
                    throw
                }

                $delay = $ReconnectBaseDelay * [math]::Pow(2, $reconnects - 1)
                $delay = [math]::Min($delay, 60)  # cap at 60s
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

        } # end while reconnect loop

    }
    finally {
        $cts.Dispose()
        Unregister-Event -SourceIdentifier 'PowerShell.Exiting' -ErrorAction SilentlyContinue
        Write-AlpacaLog -Level INFO -Message "Trade update stream stopped." -LogFile $LogFile
    }
}


function _ConvertTo-TradeUpdateEvent {
    <#
        Internal. Normalizes a raw Alpaca trade_update data object into a consistent
        PSCustomObject with named fields. Reduces the chance of downstream code
        breaking when the API adds or renames fields.
    #>
    param([object]$Data)

    $order = $Data.order

    [PSCustomObject]@{
        EventType     = [string]($Data.event)
        EventAt       = [string]($Data.timestamp)
        OrderId       = [string]($order.id)
        ClientOrderId = [string]($order.client_order_id)
        Symbol        = [string]($order.symbol)
        Side          = [string]($order.side)
        Qty           = if ($order.qty)       { [double]$order.qty }       else { 0 }
        FilledQty     = if ($order.filled_qty){ [double]$order.filled_qty } else { 0 }
        FilledAvgPx   = if ($order.filled_avg_price -and $order.filled_avg_price -ne $null -and $order.filled_avg_price -ne '') {
            [double]$order.filled_avg_price
        } else { 0.0 }
        Status        = [string]($order.status)
        OrderType     = [string]($order.type)
        TimeInForce   = [string]($order.time_in_force)
        LimitPrice    = if ($order.limit_price -and $order.limit_price -ne $null) { [double]$order.limit_price } else { $null }
        StopPrice     = if ($order.stop_price  -and $order.stop_price  -ne $null) { [double]$order.stop_price  } else { $null }
        PositionQty   = if ($Data.position_qty) { [double]$Data.position_qty } else { 0 }
        Price         = if ($Data.price -and $Data.price -ne $null) { [double]$Data.price } else { $null }
        RawData       = $Data
    }
}


Export-ModuleMember -Function @(
    'Start-AlpacaTradeUpdateStream'
)
