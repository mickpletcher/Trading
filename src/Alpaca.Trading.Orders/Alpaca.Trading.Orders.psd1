@{
    ModuleVersion     = '0.1.0'
    GUID              = '0e06e39f-4b76-4ea3-9d5f-b8e4ec067a57'
    Author            = 'Mick Pletcher'
    Description       = 'Alpaca paper order submission, query, and cancellation.'
    PowerShellVersion = '5.1'
    RootModule        = 'Alpaca.Trading.Orders.psm1'
    FunctionsToExport = @(
        'Submit-AlpacaOrder',
        'Get-AlpacaOrder',
        'Get-AlpacaOrders',
        'Remove-AlpacaOrder',
        'Remove-AllAlpacaOrders'
    )
}
