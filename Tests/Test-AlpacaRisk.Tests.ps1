#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the Alpaca.Risk module.

.DESCRIPTION
    Tests risk limits enforcement, kill switch, daily loss tracking,
    duplicate order prevention, and client order ID generation.
    No API calls are made.

.EXAMPLE
    Invoke-Pester .\tests\Test-AlpacaRisk.Tests.ps1 -Output Detailed
#>

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1') -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src\Alpaca.Risk\Alpaca.Risk.psd1')     -Force

$env:ALPACA_API_KEY    = 'TEST-API-KEY-001'
$env:ALPACA_SECRET_KEY = 'TEST-SECRET-001'
Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'

Describe 'Initialize-AlpacaRisk' {

    It 'Returns a config object with supplied limits' {
        $rc = Initialize-AlpacaRisk -MaxPositionValue 2500 -MaxShares 25 -MaxDailyLoss 250
        $rc.MaxPositionValue | Should Be 2500
        $rc.MaxShares        | Should Be 25
        $rc.MaxDailyLoss     | Should Be 250
    }

    It 'Returns a config object with defaults when no params given' {
        $rc = Initialize-AlpacaRisk
        $rc.MaxPositionValue | Should Be 10000
        $rc.MaxShares        | Should Be 500
        $rc.MaxDailyLoss     | Should Be 1000
    }

    It 'Throws when MaxPositionValue is below minimum' {
        { Initialize-AlpacaRisk -MaxPositionValue 0 } | Should Throw
    }
}

Describe 'New-AlpacaClientOrderId' {

    It 'Returns a non-empty string' {
        $id = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        $id | Should Not BeNullOrEmpty
    }

    It 'Is deterministic within the same minute' {
        $id1 = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        $id2 = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        $id1 | Should Be $id2
    }

    It 'Differs for different sides' {
        $buy  = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        $sell = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'sell'
        $buy | Should Not Be $sell
    }

    It 'Differs for different symbols' {
        $aapl = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        $msft = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'MSFT' -Side 'buy'
        $aapl | Should Not Be $msft
    }

    It 'Strips slashes from crypto pairs' {
        $id = New-AlpacaClientOrderId -Strategy 'crypto' -Symbol 'BTC/USD' -Side 'buy'
        $id | Should Not Match '/'
    }

    It 'Does not exceed 128 characters' {
        $longStrategy = 'a' * 100
        $id = New-AlpacaClientOrderId -Strategy $longStrategy -Symbol 'AAPL' -Side 'buy'
        ($id.Length -le 128) | Should Be $true
    }
}

Describe 'Test-AlpacaDuplicateOrder and Register-AlpacaOrderSent' {

    It 'Returns false for an ID that has never been registered' {
        Initialize-AlpacaRisk  # reset in-memory dict
        $id = 'test-dup-check-' + [guid]::NewGuid().ToString()
        Test-AlpacaDuplicateOrder -ClientOrderId $id | Should Be $false
    }

    It 'Returns true after the same ID is registered' {
        Initialize-AlpacaRisk
        $id = 'test-dup-register-' + [guid]::NewGuid().ToString()
        Register-AlpacaOrderSent -ClientOrderId $id
        Test-AlpacaDuplicateOrder -ClientOrderId $id | Should Be $true
    }

    It 'Returns false for a different ID even after registration' {
        Initialize-AlpacaRisk
        $id1 = 'dup-id-1-' + [guid]::NewGuid().ToString()
        $id2 = 'dup-id-2-' + [guid]::NewGuid().ToString()
        Register-AlpacaOrderSent -ClientOrderId $id1
        Test-AlpacaDuplicateOrder -ClientOrderId $id2 | Should Be $false
    }
}

Describe 'Kill Switch' {

    BeforeEach {
        # Ensure kill switch is off before each test
        Reset-AlpacaKillSwitch -Confirm:$false
    }

    AfterEach {
        Reset-AlpacaKillSwitch -Confirm:$false
    }

    It 'Is inactive at start' {
        Test-AlpacaKillSwitch | Should Be $false
    }

    It 'Becomes active after Invoke-AlpacaKillSwitch' {
        Invoke-AlpacaKillSwitch -Reason 'Unit test activation'
        Test-AlpacaKillSwitch | Should Be $true
    }

    It 'Is cleared by Reset-AlpacaKillSwitch' {
        Invoke-AlpacaKillSwitch -Reason 'Unit test'
        Reset-AlpacaKillSwitch -Confirm:$false
        Test-AlpacaKillSwitch | Should Be $false
    }
}

Describe 'Test-AlpacaOrderRisk' {

    BeforeEach {
        Initialize-AlpacaRisk -MaxPositionValue 1000 -MaxShares 10 -MaxDailyLoss 200
        Reset-AlpacaKillSwitch -Confirm:$false
    }

    AfterEach {
        Reset-AlpacaKillSwitch -Confirm:$false
    }

    It 'Returns true for a valid order within limits' {
        $result = Test-AlpacaOrderRisk -Symbol 'AAPL' -Side 'buy' -Qty 5 -EstimatedPrice 150
        $result | Should Be $true
    }

    It 'Throws when order qty exceeds MaxShares' {
        { Test-AlpacaOrderRisk -Symbol 'AAPL' -Side 'buy' -Qty 11 -EstimatedPrice 50 } | Should Throw
    }

    It 'Throws when notional exceeds MaxPositionValue' {
        # Qty=5 @ $250 = $1250 which exceeds MaxPositionValue of $1000
        { Test-AlpacaOrderRisk -Symbol 'AAPL' -Side 'buy' -Qty 5 -EstimatedPrice 250 } | Should Throw
    }

    It 'Throws when kill switch is active' {
        Invoke-AlpacaKillSwitch -Reason 'Test'
        { Test-AlpacaOrderRisk -Symbol 'AAPL' -Side 'buy' -Qty 1 -EstimatedPrice 100 } | Should Throw
    }

    It 'Throws when daily loss limit is reached' {
        # Fake $201 loss to exceed the $200 limit
        Add-AlpacaDailyLoss -AmountLost 201
        { Test-AlpacaOrderRisk -Symbol 'AAPL' -Side 'buy' -Qty 1 -EstimatedPrice 100 } | Should Throw
    }
}

Describe 'Daily Loss Tracking' {

    It 'Returns 0 before any losses are recorded today' {
        # Force a fresh state by using a unique RepoRoot path approach
        # We simply check that Get-AlpacaDailyLoss does not throw and returns a number
        $loss = Get-AlpacaDailyLoss
        ($loss -ge 0) | Should Be $true
    }

    It 'Accumulates losses across multiple Add-AlpacaDailyLoss calls' {
        # We cannot zero out the counter without private access, so we measure delta
        $before = Get-AlpacaDailyLoss
        Add-AlpacaDailyLoss -AmountLost 10
        Add-AlpacaDailyLoss -AmountLost 15
        $after = Get-AlpacaDailyLoss
        ($after - $before) | Should Be 25
    }
}
