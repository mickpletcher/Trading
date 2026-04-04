@{
    ModuleVersion     = '0.1.0'
    GUID              = '70a71585-2609-4f20-8b49-f8f68c44b59c'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca position queries and position close functions.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Trading.Positions.psm1'
    FunctionsToExport = @(
        'Get-AlpacaPosition',
        'Get-AlpacaPositions',
        'Close-AlpacaPosition',
        'Close-AllAlpacaPositions'
    )
}
