@{
    ModuleVersion     = '0.1.0'
    GUID              = 'f3e1f76d-5f43-41c6-9a79-f4c2a8bb9584'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca account status, market clock, and calendar.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Trading.Account.psm1'
    FunctionsToExport = @(
        'Get-AlpacaAccount',
        'Get-AlpacaClock',
        'Get-AlpacaCalendar',
        'Show-AlpacaAccountSummary'
    )
}
