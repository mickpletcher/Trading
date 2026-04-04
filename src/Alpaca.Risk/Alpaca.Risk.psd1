@{
    ModuleVersion     = '0.1.0'
    GUID              = '2fae43a1-1654-4554-9930-6459f40d6f35'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca risk guardrails: position limits, daily loss cap, kill switch, duplicate prevention.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Risk.psm1'
    FunctionsToExport = @(
        'Initialize-AlpacaRisk',
        'Get-AlpacaRiskConfig',
        'New-AlpacaClientOrderId',
        'Test-AlpacaDuplicateOrder',
        'Register-AlpacaOrderSent',
        'Test-AlpacaOrderRisk',
        'Invoke-AlpacaKillSwitch',
        'Test-AlpacaKillSwitch',
        'Reset-AlpacaKillSwitch',
        'Add-AlpacaDailyLoss',
        'Get-AlpacaDailyLoss'
    )
}
