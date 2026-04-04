#Requires -Version 5.1
<#
.SYNOPSIS
    Alpaca authentication headers and shared HTTP request wrapper.

.DESCRIPTION
    This module provides two things:
      1. Get-AlpacaAuthHeaders  - returns the APCA-API-KEY-ID / APCA-API-SECRET-KEY
                                  header hashtable needed by every API call.
      2. Invoke-AlpacaRequest   - wraps Invoke-RestMethod with auth injection,
                                  retry logic (exponential backoff), structured error
                                  handling, and X-Request-ID capture.
      3. Write-AlpacaLog        - structured log writer used across all modules.

    All other trading and market data modules call Invoke-AlpacaRequest rather
    than calling Invoke-RestMethod directly. This keeps auth, retry, and error
    handling in one place.

.NOTES
    Depends on Alpaca.Config. Will auto-import it from the sibling directory
    if not already loaded.
#>

# Auto-import Alpaca.Config if not already loaded
$_configPath = Join-Path $PSScriptRoot '..\Alpaca.Config\Alpaca.Config.psd1'
if (-not (Get-Module -Name 'Alpaca.Config')) {
    Import-Module $_configPath -Force
}


function Get-AlpacaAuthHeaders {
    <#
    .SYNOPSIS
        Returns the HTTP auth headers required by all Alpaca API endpoints.

    .DESCRIPTION
        Reads the API key and secret from the active config (loaded by
        Initialize-AlpacaConfig) and returns them as a hashtable ready to pass
        to Invoke-RestMethod or Invoke-WebRequest.

        Never reads credentials from disk or environment variables directly.
        Always goes through Get-AlpacaConfig so the config is the single source
        of truth.

    .EXAMPLE
        $headers = Get-AlpacaAuthHeaders
        Invoke-RestMethod -Uri '...' -Headers $headers

    .OUTPUTS
        Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $cfg = Get-AlpacaConfig

    return @{
        'APCA-API-KEY-ID'     = $cfg.ApiKey
        'APCA-API-SECRET-KEY' = $cfg.SecretKey
        'Accept'              = 'application/json'
    }
}


function Invoke-AlpacaRequest {
    <#
    .SYNOPSIS
        Authenticated HTTP wrapper for all Alpaca REST API calls.

    .DESCRIPTION
        Every REST call in this project goes through this function. It handles:
          - Injecting auth headers automatically
          - Building the full URI from BaseUrl + Path + QueryParams
          - Serializing the request body to JSON if provided
          - Retrying on transient errors (429, 408, 5xx) with exponential backoff
          - Extracting and logging the X-Request-ID response header
          - Returning parsed PowerShell objects from the JSON response
          - Throwing a clean error message on non-retryable failures

        Retry behavior uses the MaxRetries and RetryDelaySeconds values from config.
        Delay doubles each attempt: attempt 1 = delay, attempt 2 = delay*2, etc.

        4xx errors (except 429 and 408) are NOT retried. They indicate a problem
        with the request itself (bad symbol, wrong params, etc.) that a retry will
        not fix.

    .PARAMETER Method
        HTTP verb. One of: GET, POST, DELETE, PUT, PATCH.

    .PARAMETER BaseUrl
        Root URL for this request. Pass $cfg.TradingBaseUrl for trading endpoints
        or $cfg.MarketDataBaseUrl for market data endpoints.

    .PARAMETER Path
        API path with leading slash. Example: '/v2/account' or '/v2/orders'.

    .PARAMETER QueryParams
        Optional hashtable of query string key/value pairs. Values will be
        URL-encoded. Example: @{ status = 'open'; limit = '50' }

    .PARAMETER Body
        Optional request body. Accepts a hashtable or PSCustomObject.
        Will be serialized to JSON automatically.

    .PARAMETER AllowNotFound
        If specified, a 404 response returns $null instead of throwing an error.
        Useful for "get position if it exists" patterns.

    .EXAMPLE
        $cfg = Get-AlpacaConfig
        $account = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/account'

    .EXAMPLE
        $order = Invoke-AlpacaRequest -Method POST -BaseUrl $cfg.TradingBaseUrl -Path '/v2/orders' -Body @{
            symbol        = 'AAPL'
            qty           = 1
            side          = 'buy'
            type          = 'market'
            time_in_force = 'day'
        }

    .EXAMPLE
        $pos = Invoke-AlpacaRequest -Method GET -BaseUrl $cfg.TradingBaseUrl -Path '/v2/positions/XYZ' -AllowNotFound
        if ($null -ne $pos) { Write-Host "Have position in XYZ" }

    .OUTPUTS
        PSCustomObject array or single PSCustomObject depending on the endpoint.
        Returns $null if AllowNotFound is set and the server returned 404.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'DELETE', 'PUT', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$Path,

        [hashtable]$QueryParams,

        [object]$Body,

        [switch]$AllowNotFound
    )

    $cfg     = Get-AlpacaConfig
    $headers = Get-AlpacaAuthHeaders

    # Build the full URI
    $uri = '{0}{1}' -f $BaseUrl.TrimEnd('/'), $Path

    if ($QueryParams -and $QueryParams.Count -gt 0) {
        $qs  = ($QueryParams.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [Uri]::EscapeDataString($_.Key), [Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
        $uri = '{0}?{1}' -f $uri, $qs
    }

    # Build the Invoke-RestMethod parameter set
    $irmParams = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        TimeoutSec  = $cfg.TimeoutSeconds
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $irmParams['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $irmParams['ContentType'] = 'application/json'
    }

    $attempt   = 0
    $lastError = $null

    while ($attempt -le $cfg.MaxRetries) {
        $attempt++

        try {
            Write-Verbose "Alpaca [$Method] $uri  (attempt $attempt)"

            # Use -ResponseHeadersVariable to capture X-Request-ID from Alpaca responses.
            # This header is logged for debugging; include it when filing Alpaca support tickets.
            $respHeaders = $null
            $irmParams['ResponseHeadersVariable'] = 'respHeaders'

            $response = Invoke-RestMethod @irmParams

            if ($respHeaders -and $respHeaders['X-Request-ID']) {
                Write-Verbose "X-Request-ID: $($respHeaders['X-Request-ID'])"
            }

            return $response
        }
        catch {
            $lastError  = $_
            $statusCode = $null

            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # 404 - return null if caller said that is acceptable
            if ($AllowNotFound -and $statusCode -eq 404) {
                Write-Verbose "[$Method] $Path returned 404 - returning null (AllowNotFound set)"
                return $null
            }

            # Decide whether to retry.
            # We retry: network errors (no status), 408 (timeout), 429 (rate limit), 5xx (server error).
            # We do NOT retry: 4xx client errors (bad request, unauthorized, etc.).
            $retryable = (
                ($null -eq $statusCode) -or
                ($statusCode -eq 408) -or
                ($statusCode -eq 429) -or
                ($statusCode -ge 500)
            )

            if (-not $retryable -or $attempt -gt $cfg.MaxRetries) {
                # Extract a readable error message from the response body when possible
                $errorDetail = $null
                if ($_.ErrorDetails.Message) {
                    try {
                        $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                    } catch { }
                }

                $msg = if ($errorDetail -and $errorDetail.message) {
                    $errorDetail.message
                } elseif ($_.ErrorDetails.Message) {
                    $_.ErrorDetails.Message
                } else {
                    $_.Exception.Message
                }

                $httpLabel = if ($statusCode) { "HTTP $statusCode" } else { 'network error' }
                $fullMsg   = "Alpaca API [$Method $Path] $httpLabel`: $msg"

                Write-Error $fullMsg
                throw $fullMsg
            }

            # Exponential backoff: delay * 2^(attempt-1)
            $delay = $cfg.RetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-Warning "[$Method] $Path failed (HTTP $statusCode). Retry $attempt/$($cfg.MaxRetries) in ${delay}s..."
            Start-Sleep -Seconds ([int]$delay)
        }
    }

    throw "Alpaca API [$Method $Path] failed after $($cfg.MaxRetries) retries: $($lastError.Exception.Message)"
}


function Write-AlpacaLog {
    <#
    .SYNOPSIS
        Writes a timestamped, leveled log entry to the console and optionally a file.

    .DESCRIPTION
        All Alpaca modules log through this function for consistent output.
        Each entry has a UTC timestamp, a level tag, and a message.

        Console colors: INFO=Cyan, WARN=Yellow, ERROR=Red, DEBUG=DarkGray.

        When LogFile is specified, the same formatted text is appended to the file.
        The file is created if it does not exist. Append errors are non-fatal and
        emit a Write-Warning rather than throwing.

    .PARAMETER Level
        Log level. One of: INFO, WARN, ERROR, DEBUG. Defaults to INFO.

    .PARAMETER Message
        The log message text.

    .PARAMETER LogFile
        Optional path to a log file. Appended to, not overwritten.

    .EXAMPLE
        Write-AlpacaLog -Level INFO  -Message "Trade update received: filled AAPL"
        Write-AlpacaLog -Level WARN  -Message "Rate limit hit. Backing off."
        Write-AlpacaLog -Level ERROR -Message "WebSocket disconnected unexpectedly."

    .EXAMPLE
        Write-AlpacaLog -Message "Connected to trade_updates stream" -LogFile 'C:\logs\alpaca.log'
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$LogFile
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $entry     = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Cyan' }
    }

    Write-Host $entry -ForegroundColor $color

    if ($LogFile) {
        try {
            $dir = Split-Path $LogFile -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Add-Content -Path $LogFile -Value $entry -Encoding UTF8
        }
        catch {
            Write-Warning "Write-AlpacaLog: could not write to log file '$LogFile': $_"
        }
    }
}


Export-ModuleMember -Function @(
    'Get-AlpacaAuthHeaders',
    'Invoke-AlpacaRequest',
    'Write-AlpacaLog'
)
