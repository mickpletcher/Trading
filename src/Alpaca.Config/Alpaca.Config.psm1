#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca configuration loader and paper-mode enforcement.

.DESCRIPTION
    This module handles all configuration for the Alpaca PowerShell integration.
    It reads credentials from environment variables (with optional .env file support),
    defines all API endpoints (paper only), and provides a paper-mode safety gate
    that every order-submitting function must call before touching the API.

    Live trading endpoints are intentionally absent from this module.
    The LiveTradingEnabled flag defaults to $false and is never set to $true here.

.NOTES
    Call Initialize-AlpacaConfig once at the start of your script.
    All other modules in this project call Get-AlpacaConfig and Assert-PaperMode
    rather than reading credentials directly.
#>

# Module-scope config object. $null until Initialize-AlpacaConfig is called.
$script:Config = $null

<#
.SYNOPSIS
    Reads key=value pairs from a .env file into a hashtable.

.DESCRIPTION
    Internal helper. Skips blank lines and comments. Strips inline comments and
    surrounding quotes. Does NOT overwrite existing environment variables.
    Only loaded values that have no existing env var are applied.
#>
function Read-DotEnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = @{}

    if (-not (Test-Path $Path)) {
        Write-Verbose "No .env file found at: $Path"
        return $result
    }

    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        $trimmed = $line.Trim()

        # Skip blank lines and comment lines
        if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        # Find the first '=' separator
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) {
            continue
        }

        $key   = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()

        # Strip inline comments:  KEY=value # comment  ->  value
        if ($value -match '^(.*?)\s+#') {
            $value = $Matches[1].TrimEnd()
        }

        # Strip surrounding single or double quotes
        if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
            $value = $Matches[1]
        }

        $result[$key] = $value
    }

    return $result
}


function Initialize-AlpacaConfig {
    <#
    .SYNOPSIS
        Loads Alpaca configuration from environment variables and an optional .env file.

    .DESCRIPTION
        Call this once at the start of any script that uses the Alpaca modules.
        It locates your .env file, loads any missing variables into the current process
        environment, validates that credentials exist, and builds the config object
        used by every other module in this project.

        The resulting config is PAPER ONLY. No live trading URLs exist here.
        The hard stop in Assert-PaperMode prevents accidental live endpoint use even
        if someone tries to manually swap a URL.

    .PARAMETER EnvFilePath
        Path to a .env file. Defaults to '.env' in the repo root (two levels above
        this module at src/Alpaca.Config/). Set this explicitly if your secrets file
        lives somewhere else.

    .PARAMETER DefaultFeed
        Market data feed: 'iex' (free tier) or 'sip' (paid subscription required).
        Defaults to 'iex'. Historical and streaming market data modules read this.

    .PARAMETER TimeoutSeconds
        HTTP request timeout in seconds for REST calls. Defaults to 15.

    .PARAMETER MaxRetries
        How many times to retry a failed request before giving up. Defaults to 3.
        Only retried on 429, 408, and 5xx responses. 4xx errors fail immediately.

    .PARAMETER RetryDelaySeconds
        Base delay in seconds between retries. Actual delay doubles each attempt
        (exponential backoff). Defaults to 2.

    .EXAMPLE
        Import-Module .\src\Alpaca.Config\Alpaca.Config.psd1
        Initialize-AlpacaConfig

        # Loads .env from repo root, reads ALPACA_API_KEY and ALPACA_SECRET_KEY.

    .EXAMPLE
        Initialize-AlpacaConfig -EnvFilePath 'C:\secrets\alpaca.env' -DefaultFeed 'iex' -Verbose

    .OUTPUTS
        PSCustomObject with all config values. Also stored in module scope and
        returned by Get-AlpacaConfig.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$EnvFilePath,

        [ValidateSet('iex', 'sip', 'delayed_sip')]
        [string]$DefaultFeed = 'iex',

        [ValidateRange(5, 120)]
        [int]$TimeoutSeconds = 15,

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,

        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 2
    )

    # Resolve .env path: module lives at src/Alpaca.Config/ so repo root is ../../
    if (-not $EnvFilePath) {
        $moduleDir = $PSScriptRoot
        $repoRoot  = Split-Path (Split-Path $moduleDir -Parent) -Parent
        $EnvFilePath = Join-Path $repoRoot '.env'
    }

    # Load .env values. Already-set env vars are NOT overwritten (env vars take priority).
    $envValues = Read-DotEnvFile -Path $EnvFilePath
    foreach ($pair in $envValues.GetEnumerator()) {
        if (-not [System.Environment]::GetEnvironmentVariable($pair.Key, 'Process')) {
            [System.Environment]::SetEnvironmentVariable($pair.Key, $pair.Value, 'Process')
            Write-Verbose "Loaded from .env: $($pair.Key)"
        }
    }

    # Validate that credentials are present
    $apiKey    = $env:ALPACA_API_KEY
    $secretKey = $env:ALPACA_SECRET_KEY

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw [System.InvalidOperationException]::new(
            "ALPACA_API_KEY is not set.`n" +
            "Set it as an environment variable or add it to your .env file.`n" +
            "  `$env:ALPACA_API_KEY = 'YOUR_PAPER_KEY'`n" +
            "  -- or in .env --`n" +
            "  ALPACA_API_KEY=YOUR_PAPER_KEY"
        )
    }

    if ([string]::IsNullOrWhiteSpace($secretKey)) {
        throw [System.InvalidOperationException]::new(
            "ALPACA_SECRET_KEY is not set.`n" +
            "Set it as an environment variable or add it to your .env file.`n" +
            "  `$env:ALPACA_SECRET_KEY = 'YOUR_PAPER_SECRET'"
        )
    }

    # Resolve the repo root for state/log files used by other modules
    $moduleDir = $PSScriptRoot
    $repoRoot  = Split-Path (Split-Path $moduleDir -Parent) -Parent

    # Build the config object.
    # PAPER ONLY. Live endpoints are intentionally absent.
    # The TradingWsUrl uses the Alpaca v2 streaming protocol for trade_updates.
    # The MarketDataWsUrl is the v2 stock data stream base (append /iex or /sip).
    $script:Config = [PSCustomObject][ordered]@{
        ApiKey             = $apiKey
        SecretKey          = $secretKey
        TradingMode        = 'paper'

        # REST endpoints
        TradingBaseUrl     = 'https://paper-api.alpaca.markets'
        MarketDataBaseUrl  = 'https://data.alpaca.markets'

        # WebSocket endpoints
        TradingWsUrl       = 'wss://paper-api.alpaca.markets/stream'
        MarketDataWsUrl    = 'wss://stream.data.alpaca.markets/v2'

        # Default market data feed
        DefaultFeed        = $DefaultFeed

        # HTTP request settings
        TimeoutSeconds     = $TimeoutSeconds
        MaxRetries         = $MaxRetries
        RetryDelaySeconds  = $RetryDelaySeconds

        # Paper-mode lock. This field must remain $false.
        # Changing it to $true will not enable live trading - it will trigger Assert-PaperMode.
        LiveTradingEnabled = $false

        # Repo root for resolving log and state file paths
        RepoRoot           = $repoRoot
    }

    Write-Verbose "Alpaca config initialized. Mode=paper  Feed=$DefaultFeed  Timeout=${TimeoutSeconds}s  MaxRetries=$MaxRetries"
    return $script:Config
}


function Get-AlpacaConfig {
    <#
    .SYNOPSIS
        Returns the active Alpaca configuration object.

    .DESCRIPTION
        Returns the object built by Initialize-AlpacaConfig.
        Throws a clear error if Initialize-AlpacaConfig has not yet been called.
        All other modules call this rather than holding their own config references.

    .EXAMPLE
        $cfg = Get-AlpacaConfig
        Write-Host $cfg.TradingBaseUrl
        Write-Host $cfg.DefaultFeed

    .OUTPUTS
        PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($null -eq $script:Config) {
        throw [System.InvalidOperationException]::new(
            "Alpaca config is not initialized. Call Initialize-AlpacaConfig before using any Alpaca module."
        )
    }

    return $script:Config
}


function Assert-PaperMode {
    <#
    .SYNOPSIS
        Safety gate that throws if any sign of live trading is detected.

    .DESCRIPTION
        Every function that submits orders, cancels orders, closes positions,
        or modifies account state should call Assert-PaperMode before making
        any API request.

        Checks performed:
          - LiveTradingEnabled must be $false
          - TradingMode must be 'paper'
          - TradingBaseUrl must contain 'paper-api.alpaca.markets'

        If any check fails, an exception is thrown with a clear message.
        This is intentionally strict to prevent accidental real-money trades.

    .EXAMPLE
        # Called internally by Submit-AlpacaOrder, Close-AlpacaPosition, etc.
        Assert-PaperMode
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-AlpacaConfig

    if ($cfg.LiveTradingEnabled -eq $true) {
        throw [System.InvalidOperationException]::new(
            "LIVE TRADING BLOCK: LiveTradingEnabled is set to true. " +
            "This build does not support live trading. Reset the config to paper mode."
        )
    }

    if ($cfg.TradingMode -ne 'paper') {
        throw [System.InvalidOperationException]::new(
            "LIVE TRADING BLOCK: TradingMode is '$($cfg.TradingMode)'. Only 'paper' is allowed in this build."
        )
    }

    if ($cfg.TradingBaseUrl -notmatch 'paper-api\.alpaca\.markets') {
        throw [System.InvalidOperationException]::new(
            "LIVE TRADING BLOCK: TradingBaseUrl '$($cfg.TradingBaseUrl)' does not look like a paper endpoint. " +
            "Only 'https://paper-api.alpaca.markets' is permitted."
        )
    }
}


Export-ModuleMember -Function @(
    'Initialize-AlpacaConfig',
    'Get-AlpacaConfig',
    'Assert-PaperMode'
)
