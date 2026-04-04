@{
    ModuleVersion     = '0.1.0'
    GUID              = '3ea91c1f-8f4c-4cb4-94df-d9f9a2dbf0ae'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca auth header builder and shared HTTP request wrapper with retry logic.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Auth.psm1'
    RequiredModules   = @(
        @{ ModuleName = 'Alpaca.Config'; ModuleVersion = '0.1.0' }
    )
    FunctionsToExport = @(
        'Get-AlpacaAuthHeaders',
        'Invoke-AlpacaRequest',
        'Write-AlpacaLog'
    )
}
