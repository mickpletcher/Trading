#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for trade update message parsing in Alpaca.Streams.TradeUpdates.

.DESCRIPTION
    Tests the module-private _ConvertTo-TradeUpdateEvent function using
    InModuleScope. No WebSocket connections are made.

.EXAMPLE
    Invoke-Pester .\tests\Test-AlpacaTradeUpdateParsing.Tests.ps1 -Output Detailed
#>

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1')            -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')                -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Streams.TradeUpdates\Alpaca.Streams.TradeUpdates.psd1') -Force

$env:ALPACA_API_KEY    = 'TEST-API-KEY-002'
$env:ALPACA_SECRET_KEY = 'TEST-SECRET-002'
Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'

Describe '_ConvertTo-TradeUpdateEvent' {

    It 'Parses a fill event correctly' {
        InModuleScope 'Alpaca.Streams.TradeUpdates' {
            $raw = [pscustomobject]@{
                event = 'fill'
                order = [pscustomobject]@{
                    id               = 'order-id-fill-001'
                    client_order_id  = 'coi-fill-001'
                    symbol           = 'AAPL'
                    side             = 'buy'
                    qty              = '10'
                    filled_qty       = '10'
                    filled_avg_price = '182.50'
                    status           = 'filled'
                    order_type       = 'market'
                    time_in_force    = 'day'
                    limit_price      = $null
                    stop_price       = $null
                }
                price    = '182.50'
                qty      = '10'
                position_qty = '10'
            }

            $evt = _ConvertTo-TradeUpdateEvent -Data $raw

            $evt.EventType      | Should Be 'fill'
            $evt.OrderId        | Should Be 'order-id-fill-001'
            $evt.ClientOrderId  | Should Be 'coi-fill-001'
            $evt.Symbol         | Should Be 'AAPL'
            $evt.Side           | Should Be 'buy'
            $evt.Qty            | Should Be 10
            $evt.FilledQty      | Should Be 10
            $evt.FilledAvgPx    | Should Be 182.50
            $evt.Status         | Should Be 'filled'
            $evt.OrderType      | Should Be 'market'
            $evt.TimeInForce    | Should Be 'day'
            $evt.LimitPrice     | Should Be $null
            $evt.StopPrice      | Should Be $null
            $evt.Price          | Should Be 182.50
            $evt.PositionQty    | Should Be 10
        }
    }

    It 'Parses a partial_fill event correctly' {
        InModuleScope 'Alpaca.Streams.TradeUpdates' {
            $raw = [pscustomobject]@{
                event = 'partial_fill'
                order = [pscustomobject]@{
                    id               = 'order-id-pfill-001'
                    client_order_id  = 'coi-pfill-001'
                    symbol           = 'MSFT'
                    side             = 'buy'
                    qty              = '20'
                    filled_qty       = '5'
                    filled_avg_price = '310.00'
                    status           = 'partially_filled'
                    order_type       = 'limit'
                    time_in_force    = 'gtc'
                    limit_price      = '310.00'
                    stop_price       = $null
                }
                price    = '310.00'
                qty      = '5'
                position_qty = '5'
            }

            $evt = _ConvertTo-TradeUpdateEvent -Data $raw

            $evt.EventType   | Should Be 'partial_fill'
            $evt.Symbol      | Should Be 'MSFT'
            $evt.FilledQty   | Should Be 5
            $evt.Qty         | Should Be 20
            $evt.Status      | Should Be 'partially_filled'
            $evt.LimitPrice  | Should Be 310.00
        }
    }

    It 'Parses a canceled event correctly' {
        InModuleScope 'Alpaca.Streams.TradeUpdates' {
            $raw = [pscustomobject]@{
                event = 'canceled'
                order = [pscustomobject]@{
                    id               = 'order-id-cancel-001'
                    client_order_id  = 'coi-cancel-001'
                    symbol           = 'TSLA'
                    side             = 'sell'
                    qty              = '3'
                    filled_qty       = '0'
                    filled_avg_price = $null
                    status           = 'canceled'
                    order_type       = 'limit'
                    time_in_force    = 'day'
                    limit_price      = '200.00'
                    stop_price       = $null
                }
                price    = $null
                qty      = $null
                position_qty = '3'
            }

            $evt = _ConvertTo-TradeUpdateEvent -Data $raw

            $evt.EventType  | Should Be 'canceled'
            $evt.Symbol     | Should Be 'TSLA'
            $evt.Status     | Should Be 'canceled'
            $evt.FilledQty  | Should Be 0
            $evt.FilledAvgPx | Should Be $null
        }
    }

    It 'Parses a new event correctly' {
        InModuleScope 'Alpaca.Streams.TradeUpdates' {
            $raw = [pscustomobject]@{
                event = 'new'
                order = [pscustomobject]@{
                    id               = 'order-id-new-001'
                    client_order_id  = 'coi-new-001'
                    symbol           = 'SPY'
                    side             = 'buy'
                    qty              = '1'
                    filled_qty       = '0'
                    filled_avg_price = $null
                    status           = 'new'
                    order_type       = 'market'
                    time_in_force    = 'day'
                    limit_price      = $null
                    stop_price       = $null
                }
                price        = $null
                qty          = $null
                position_qty = '0'
            }

            $evt = _ConvertTo-TradeUpdateEvent -Data $raw

            $evt.EventType  | Should Be 'new'
            $evt.Symbol     | Should Be 'SPY'
            $evt.Status     | Should Be 'new'
            $evt.FilledQty  | Should Be 0
        }
    }

    It 'Preserves the raw data object on all events' {
        InModuleScope 'Alpaca.Streams.TradeUpdates' {
            $raw = [pscustomobject]@{
                event = 'fill'
                order = [pscustomobject]@{
                    id               = 'raw-preserve-001'
                    client_order_id  = 'coi-raw-001'
                    symbol           = 'NVDA'
                    side             = 'buy'
                    qty              = '2'
                    filled_qty       = '2'
                    filled_avg_price = '900.00'
                    status           = 'filled'
                    order_type       = 'market'
                    time_in_force    = 'day'
                    limit_price      = $null
                    stop_price       = $null
                }
                price        = '900.00'
                qty          = '2'
                position_qty = '2'
            }

            $evt = _ConvertTo-TradeUpdateEvent -Data $raw
            $evt.RawData | Should Not BeNullOrEmpty
            $evt.RawData.event | Should Be 'fill'
        }
    }

    It 'Handles numeric strings for quantities' {
        InModuleScope 'Alpaca.Streams.TradeUpdates' {
            $raw = [pscustomobject]@{
                event = 'fill'
                order = [pscustomobject]@{
                    id               = 'numeric-str-001'
                    client_order_id  = 'coi-num-001'
                    symbol           = 'AMD'
                    side             = 'sell'
                    qty              = '100'
                    filled_qty       = '100'
                    filled_avg_price = '175.50'
                    status           = 'filled'
                    order_type       = 'market'
                    time_in_force    = 'day'
                    limit_price      = $null
                    stop_price       = $null
                }
                price        = '175.50'
                qty          = '100'
                position_qty = '0'
            }

            $evt = _ConvertTo-TradeUpdateEvent -Data $raw
            $evt.Qty.GetType().Name | Should Be 'Double'
            $evt.FilledQty.GetType().Name | Should Be 'Double'
            $evt.FilledAvgPx.GetType().Name | Should Be 'Double'
        }
    }
}
