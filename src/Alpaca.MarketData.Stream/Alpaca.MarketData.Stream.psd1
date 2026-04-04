@{
    ModuleVersion     = '0.1.0'
    GUID              = 'e771bb87-0cdb-4938-a216-6a8858d2464b'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca real-time market data WebSocket stream. Supports FAKEPACA test symbol.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.MarketData.Stream.psm1'
    FunctionsToExport = @(
        'Start-AlpacaMarketDataStream'
    )
}
