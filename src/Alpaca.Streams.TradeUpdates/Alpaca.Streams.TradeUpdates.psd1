@{
    ModuleVersion     = '0.1.0'
    GUID              = 'bd27b2b7-4f9e-49e0-a5b5-4ab12c8f14b6'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca trade_updates WebSocket stream. Primary order state source. Paper only.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Streams.TradeUpdates.psm1'
    FunctionsToExport = @(
        'Start-AlpacaTradeUpdateStream'
    )
}
