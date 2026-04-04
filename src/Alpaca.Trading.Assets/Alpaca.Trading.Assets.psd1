@{
    ModuleVersion     = '0.1.0'
    GUID              = '39ce8ed9-0b3f-4d63-9f5a-6ab21f6de6b0'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca asset lookup by symbol and asset class.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Trading.Assets.psm1'
    FunctionsToExport = @(
        'Get-AlpacaAsset',
        'Get-AlpacaAssets'
    )
}
