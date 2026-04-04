@{
    ModuleVersion     = '0.1.0'
    GUID              = '6b2bb3a7-4f5d-4e2b-9f7f-32fbd18d2e11'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca configuration loader and paper-mode enforcement. Paper only. No live trading.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Config.psm1'
    FunctionsToExport = @(
        'Initialize-AlpacaConfig',
        'Get-AlpacaConfig',
        'Assert-PaperMode'
    )
}
