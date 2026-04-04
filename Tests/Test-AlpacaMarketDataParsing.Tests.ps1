#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for market data message parsing in Alpaca.MarketData.Stream.

.DESCRIPTION
    Tests the module-private _ConvertTo-MarketDataEvent function using
    InModuleScope. Uses payloads that are compatible with PowerShell 5.1
    object key casing behavior.
#>

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.MarketData.Stream\Alpaca.MarketData.Stream.psd1') -Force

$env:ALPACA_API_KEY = 'TEST-API-KEY-003'
$env:ALPACA_SECRET_KEY = 'TEST-SECRET-003'
Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'

Describe '_ConvertTo-MarketDataEvent' {

    It 'Parses trade frames with symbol, price, and exchange' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            $raw = [pscustomobject]@{
                T = 't'
                S = 'AAPL'
                p = '182.50'
                x = 'V'
                i = '1001'
            }

            $evt = _ConvertTo-MarketDataEvent -Raw $raw
            $evt.EventType | Should Be 'trade'
            $evt.Symbol | Should Be 'AAPL'
            $evt.Price | Should Be 182.50
            $evt.Exchange | Should Be 'V'
            $evt.TradeId | Should Be '1001'
        }
    }

    It 'Parses quote frames' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            $raw = [pscustomobject]@{
                T = 'q'
                S = 'MSFT'
                bp = '310.00'
                bs = 2
                ap = '310.01'
                as = 5
                bx = 'V'
                ax = 'Q'
            }

            $evt = _ConvertTo-MarketDataEvent -Raw $raw
            $evt.EventType | Should Be 'quote'
            $evt.Symbol | Should Be 'MSFT'
            $evt.BidPrice | Should Be 310.00
            $evt.AskPrice | Should Be 310.01
            $evt.BidSize | Should Be 2
            $evt.AskSize | Should Be 5
        }
    }

    It 'Parses bar frames' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            $raw = [pscustomobject]@{
                T = 'b'
                S = 'SPY'
                o = '440.10'
                h = '441.50'
                l = '439.80'
                c = '441.20'
                v = 1500000
                vw = '440.77'
                n = 12050
            }

            $evt = _ConvertTo-MarketDataEvent -Raw $raw
            $evt.EventType | Should Be 'bar'
            $evt.Symbol | Should Be 'SPY'
            $evt.Open | Should Be 440.10
            $evt.High | Should Be 441.50
            $evt.Low | Should Be 439.80
            $evt.Close | Should Be 441.20
            $evt.Volume | Should Be 1500000
            $evt.Vwap | Should Be 440.77
        }
    }

    It 'Parses updated and daily bars' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            $updated = [pscustomobject]@{ T = 'u'; S = 'QQQ'; c = '361.75' }
            $daily = [pscustomobject]@{ T = 'd'; S = 'IWM'; c = '191.80' }

            (_ConvertTo-MarketDataEvent -Raw $updated).EventType | Should Be 'updatedBar'
            (_ConvertTo-MarketDataEvent -Raw $daily).EventType | Should Be 'dailyBar'
        }
    }

    It 'Parses status frames' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            $raw = [pscustomobject]@{
                T = 'status'
                S = 'AAPL'
                sc = 'T'
                sm = 'Trading'
                rc = ''
                rm = ''
            }

            $evt = _ConvertTo-MarketDataEvent -Raw $raw
            $evt.EventType | Should Be 'status'
            $evt.Symbol | Should Be 'AAPL'
            $evt.StatusCode | Should Be 'T'
        }
    }

    It 'Returns null for control frames and unknown frames' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            (_ConvertTo-MarketDataEvent -Raw ([pscustomobject]@{ T = 'subscription' })) | Should Be $null
            (_ConvertTo-MarketDataEvent -Raw ([pscustomobject]@{ T = 'success' })) | Should Be $null
            (_ConvertTo-MarketDataEvent -Raw ([pscustomobject]@{ T = 'error' })) | Should Be $null
            (_ConvertTo-MarketDataEvent -Raw ([pscustomobject]@{ T = 'unknownType' })) | Should Be $null
        }
    }

    It 'Parses FAKEPACA trade frames' {
        InModuleScope 'Alpaca.MarketData.Stream' {
            $raw = [pscustomobject]@{ T = 't'; S = 'FAKEPACA'; p = '100.00'; x = 'V' }
            $evt = _ConvertTo-MarketDataEvent -Raw $raw
            $evt.EventType | Should Be 'trade'
            $evt.Symbol | Should Be 'FAKEPACA'
            $evt.Price | Should Be 100.00
        }
    }
}
