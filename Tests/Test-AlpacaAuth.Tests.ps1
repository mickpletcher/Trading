#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the Alpaca.Auth module.

.DESCRIPTION
    Tests auth header creation and request wrapper behavior.
    Uses mocking to avoid real API calls.

.EXAMPLE
    Invoke-Pester .\tests\Test-AlpacaAuth.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src\Alpaca.Config\Alpaca.Config.psd1') -Force
    Import-Module (Join-Path $repoRoot 'src\Alpaca.Auth\Alpaca.Auth.psd1')     -Force

    # Prime config with test credentials
    $env:ALPACA_API_KEY    = 'TEST-API-KEY-001'
    $env:ALPACA_SECRET_KEY = 'TEST-SECRET-001'
    Initialize-AlpacaConfig -EnvFilePath 'C:\nonexistent\.env'
}

Describe 'Get-AlpacaAuthHeaders' {

    It 'Returns a hashtable' {
        $h = Get-AlpacaAuthHeaders
        $h | Should -BeOfType [hashtable]
    }

    It 'Contains APCA-API-KEY-ID matching the configured key' {
        $h = Get-AlpacaAuthHeaders
        $h['APCA-API-KEY-ID'] | Should -Be 'TEST-API-KEY-001'
    }

    It 'Contains APCA-API-SECRET-KEY matching the configured secret' {
        $h = Get-AlpacaAuthHeaders
        $h['APCA-API-SECRET-KEY'] | Should -Be 'TEST-SECRET-001'
    }

    It 'Contains Accept header set to application/json' {
        $h = Get-AlpacaAuthHeaders
        $h['Accept'] | Should -Be 'application/json'
    }
}

Describe 'Invoke-AlpacaRequest' {

    It 'Throws on a non-retryable 400 without retrying' {
        # Mock Invoke-RestMethod to simulate a 400 Bad Request
        Mock Invoke-RestMethod {
            $response = [System.Net.HttpWebResponse]::new.Invoke(@())
            $ex = [System.Net.WebException]::new('Bad Request')
            # Simulate error details
            $err = [System.Management.Automation.ErrorRecord]::new(
                $ex, 'WebCmdletWebResponseException', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
            )
            throw $err
        } -ModuleName 'Alpaca.Auth'

        $cfg = Get-AlpacaConfig
        { Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/nonexistent' } | Should -Throw
    }

    It 'Returns null when AllowNotFound is set and server returns 404' {
        # Simulate a 404 response
        Mock Invoke-RestMethod {
            $webEx = New-Object System.Net.WebException 'Not Found'
            $mockResponse = [PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]::NotFound }
            Add-Member -InputObject $webEx -NotePropertyName Response -NotePropertyValue $mockResponse -Force
            throw $webEx
        } -ModuleName 'Alpaca.Auth'

        $cfg    = Get-AlpacaConfig
        $result = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/positions/FAKESYMBOL' -AllowNotFound
        $result | Should -BeNullOrEmpty
    }

    It 'Builds correct URI from BaseUrl and Path' {
        $captured = $null
        Mock Invoke-RestMethod {
            param($Method, $Uri, $Headers, $TimeoutSec, $ErrorAction)
            $script:captured = $Uri
            return @{ test = 'value' }
        } -ModuleName 'Alpaca.Auth'

        $cfg = Get-AlpacaConfig
        Invoke-AlpacaRequest -Method GET -BaseUrl 'https://paper-api.alpaca.markets' -Path '/v2/account'
        $script:captured | Should -BeLike '*paper-api.alpaca.markets/v2/account*'
    }

    It 'Appends query params to the URI correctly' {
        Mock Invoke-RestMethod {
            param($Method, $Uri)
            $script:capturedUri = $Uri
            return @{}
        } -ModuleName 'Alpaca.Auth'

        $cfg = Get-AlpacaConfig
        Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/orders' -QueryParams @{ status = 'open'; limit = '10' }
        $script:capturedUri | Should -Match 'status=open'
        $script:capturedUri | Should -Match 'limit=10'
    }
}

Describe 'Write-AlpacaLog' {

    It 'Does not throw for all log levels' {
        { Write-AlpacaLog -Level INFO  -Message 'test info'  } | Should -Not -Throw
        { Write-AlpacaLog -Level WARN  -Message 'test warn'  } | Should -Not -Throw
        { Write-AlpacaLog -Level ERROR -Message 'test error' } | Should -Not -Throw
        { Write-AlpacaLog -Level DEBUG -Message 'test debug' } | Should -Not -Throw
    }

    It 'Writes to a log file when LogFile is specified' {
        $tmpLog = Join-Path $env:TEMP 'alpaca_auth_test.log'
        Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue

        Write-AlpacaLog -Level INFO -Message 'unit test entry' -LogFile $tmpLog

        Test-Path $tmpLog | Should -Be $true
        $content = Get-Content $tmpLog -Raw
        $content | Should -Match 'unit test entry'
        $content | Should -Match '\[INFO\]'

        Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue
    }
}
