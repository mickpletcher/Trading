@{
    ModuleVersion     = '0.1.0'
    GUID              = '95c2ff0a-4f7a-4bd1-8617-c7065ac0c4ad'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca historical market data: bars, quotes, trades, snapshots.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.MarketData.Historical.psm1'
    FunctionsToExport = @(
        'Get-AlpacaBars',
        'Get-AlpacaLatestBar',
        'Get-AlpacaLatestQuote',
        'Get-AlpacaLatestTrade',
        'Get-AlpacaSnapshot'
    )
}
