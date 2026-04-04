#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the Alpaca.Config module.

.DESCRIPTION
    Tests config loading, paper-mode enforcement, and environment isolation.
    These are unit tests that do NOT make API calls.

.EXAMPLE
    Invoke-Pester .\tests\Test-AlpacaConfig.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1') -Force
}

Describe 'Initialize-AlpacaConfig' {

    BeforeEach {
        # Reset module state between tests by re-importing
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Alpaca.Config\Alpaca.Config.psd1') -Force
    }

    It 'Throws when ALPACA_API_KEY is missing' {
        $saved = $env:ALPACA_API_KEY
        $env:ALPACA_API_KEY = ''
        try {
            { Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env' } | Should -Throw
        } finally {
            $env:ALPACA_API_KEY = $saved
        }
    }

    It 'Throws when ALPACA_SECRET_KEY is missing' {
        $savedKey    = $env:ALPACA_API_KEY
        $savedSecret = $env:ALPACA_SECRET_KEY
        $env:ALPACA_API_KEY    = 'test-key-000'
        $env:ALPACA_SECRET_KEY = ''
        try {
            { Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env' } | Should -Throw
        } finally {
            $env:ALPACA_API_KEY    = $savedKey
            $env:ALPACA_SECRET_KEY = $savedSecret
        }
    }

    It 'Returns config with paper TradingBaseUrl when credentials are present' {
        $savedKey    = $env:ALPACA_API_KEY
        $savedSecret = $env:ALPACA_SECRET_KEY
        $env:ALPACA_API_KEY    = 'TESTKEY123'
        $env:ALPACA_SECRET_KEY = 'TESTSECRET456'
        try {
            $cfg = Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'
            $cfg.TradingBaseUrl | Should -Be 'https://paper-api.alpaca.markets'
        } finally {
            $env:ALPACA_API_KEY    = $savedKey
            $env:ALPACA_SECRET_KEY = $savedSecret
        }
    }

    It 'Returns config with LiveTradingEnabled = false' {
        $savedKey    = $env:ALPACA_API_KEY
        $savedSecret = $env:ALPACA_SECRET_KEY
        $env:ALPACA_API_KEY    = 'TESTKEY123'
        $env:ALPACA_SECRET_KEY = 'TESTSECRET456'
        try {
            $cfg = Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'
            $cfg.LiveTradingEnabled | Should -Be $false
        } finally {
            $env:ALPACA_API_KEY    = $savedKey
            $env:ALPACA_SECRET_KEY = $savedSecret
        }
    }

    It 'Uses DefaultFeed parameter correctly' {
        $savedKey    = $env:ALPACA_API_KEY
        $savedSecret = $env:ALPACA_SECRET_KEY
        $env:ALPACA_API_KEY    = 'TESTKEY123'
        $env:ALPACA_SECRET_KEY = 'TESTSECRET456'
        try {
            $cfg = Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env' -DefaultFeed 'sip'
            $cfg.DefaultFeed | Should -Be 'sip'
        } finally {
            $env:ALPACA_API_KEY    = $savedKey
            $env:ALPACA_SECRET_KEY = $savedSecret
        }
    }

    It 'Loads .env file values when env vars are not set' {
        # Write a temp .env file
        $tmpEnv = Join-Path $env:TEMP 'alpaca_test.env'
        "ALPACA_API_KEY=envfile-key`nALPACA_SECRET_KEY=envfile-secret" | Set-Content $tmpEnv -Encoding UTF8

        $savedKey    = $env:ALPACA_API_KEY
        $savedSecret = $env:ALPACA_SECRET_KEY
        [System.Environment]::SetEnvironmentVariable('ALPACA_API_KEY',    '', 'Process')
        [System.Environment]::SetEnvironmentVariable('ALPACA_SECRET_KEY', '', 'Process')

        try {
            $cfg = Initialize-AlpacaConfig -EnvFilePath $tmpEnv
            $cfg.ApiKey    | Should -Be 'envfile-key'
            $cfg.SecretKey | Should -Be 'envfile-secret'
        } finally {
            $env:ALPACA_API_KEY    = $savedKey
            $env:ALPACA_SECRET_KEY = $savedSecret
            Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-AlpacaConfig' {

    It 'Throws when config has not been initialized' {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Alpaca.Config\Alpaca.Config.psd1') -Force
        { Get-AlpacaConfig } | Should -Throw
    }
}

Describe 'Assert-PaperMode' {

    BeforeEach {
        $env:ALPACA_API_KEY    = 'TESTKEY123'
        $env:ALPACA_SECRET_KEY = 'TESTSECRET456'
        Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'
    }

    It 'Does not throw when in paper mode' {
        { Assert-PaperMode } | Should -Not -Throw
    }
}
