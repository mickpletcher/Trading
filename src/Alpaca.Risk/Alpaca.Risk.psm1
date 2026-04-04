#Requires -Version 5.1
<#
.SYNOPSIS
    Risk and safety guardrails for Alpaca paper trading.

.DESCRIPTION
    This module sits between strategy logic and order submission. Every automated
    or semi-automated order flow should pass through these checks before calling
    Submit-AlpacaOrder.

    What this module provides:
      - Test-AlpacaOrderRisk     : Validates a proposed order against configured limits
      - New-AlpacaClientOrderId  : Generates a deterministic, idempotent client order ID
      - Test-AlpacaDuplicateOrder: Detects if a matching order was recently submitted
      - Register-AlpacaOrderSent : Records a submitted order for duplicate detection
      - Invoke-AlpacaKillSwitch  : Halts all trading immediately (sets a lock file)
      - Test-AlpacaKillSwitch    : Returns $true if the kill switch is active
      - Reset-AlpacaKillSwitch   : Clears the kill switch (manual re-enable)
      - Add-AlpacaDailyLoss      : Records a realized loss for daily tracking
      - Get-AlpacaDailyLoss      : Returns today's cumulative realized loss
      - Initialize-AlpacaRisk    : Sets risk configuration limits

    State storage:
      Risk state (daily loss, recent order IDs, kill switch flag) is stored in
      Journal/alpaca_risk_state.json so it survives process restarts within
      the same trading day. The kill switch also creates Journal/alpaca_kill_switch.lock
      as an additional layer.

    Integration pattern:
      1. Initialize-AlpacaConfig
      2. Initialize-AlpacaRisk
      3. Before each order:
           Test-AlpacaKillSwitch   (throw if active)
           $coid = New-AlpacaClientOrderId ...
           Test-AlpacaDuplicateOrder $coid   (throw if duplicate)
           Test-AlpacaOrderRisk ...          (throw if limits exceeded)
           $order = Submit-AlpacaOrder ... -ClientOrderId $coid
           Register-AlpacaOrderSent $coid
      4. On fill: Add-AlpacaDailyLoss -AmountLost X  (if it was a loss)

.NOTES
    Paper mode enforcement is not in this module - it is in Assert-PaperMode
    (Alpaca.Config). This module adds a second protection layer for RISK limits,
    which are separate from the paper/live distinction.
#>

$_authPath = Join-Path $PSScriptRoot '..\Alpaca.Auth\Alpaca.Auth.psd1'
if (-not (Get-Module -Name 'Alpaca.Auth')) {
    Import-Module $_authPath -Force
}


#region  Module state

# Risk config - set by Initialize-AlpacaRisk
$script:RiskConfig = $null

# In-memory record of recently submitted client order IDs
# Key = client_order_id, Value = submission timestamp
$script:RecentOrders = [System.Collections.Generic.Dictionary[string,datetime]]::new()

# How long to remember a submitted order for duplicate detection (minutes)
$script:DuplicateWindowMinutes = 5

#endregion


#region  State file helpers

function _Get-RiskStateFile {
    $cfg  = Get-AlpacaConfig
    $dir  = Join-Path $cfg.RepoRoot 'Journal'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return Join-Path $dir 'alpaca_risk_state.json'
}

function _Get-KillSwitchFile {
    $cfg = Get-AlpacaConfig
    return Join-Path $cfg.RepoRoot 'Journal\alpaca_kill_switch.lock'
}

function _Load-RiskState {
    $file    = _Get-RiskStateFile
    $default = @{
        daily_loss          = 0.0
        daily_loss_date     = ''
        kill_switch_active  = $false
    }

    if (-not (Test-Path $file)) { return $default }

    try {
        $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        # Convert to hashtable for easy mutation
        $state = $default.Clone()
        if ($null -ne $data.daily_loss)         { $state['daily_loss']          = [double]$data.daily_loss }
        if ($null -ne $data.daily_loss_date)     { $state['daily_loss_date']      = [string]$data.daily_loss_date }
        if ($null -ne $data.kill_switch_active)  { $state['kill_switch_active']   = [bool]$data.kill_switch_active }
        return $state
    }
    catch {
        Write-Warning "Risk state file corrupt or unreadable. Starting fresh. ($_)"
        return $default
    }
}

function _Save-RiskState {
    param([hashtable]$State)
    $file = _Get-RiskStateFile
    $State | ConvertTo-Json | Set-Content -Path $file -Encoding UTF8 -Force
}

#endregion


function Initialize-AlpacaRisk {
    <#
    .SYNOPSIS
        Sets risk configuration limits for the session.

    .DESCRIPTION
        Call this once after Initialize-AlpacaConfig, before any trading activity.
        Sets the per-order and per-day limits that Test-AlpacaOrderRisk enforces.

        All dollar values are for the paper account. They only cap simulated losses.

    .PARAMETER MaxPositionValue
        Maximum dollar value for a single position entry. Orders that would exceed
        this are rejected. Defaults to $10,000.

    .PARAMETER MaxShares
        Maximum shares/units in a single order. Defaults to 500.

    .PARAMETER MaxDailyLoss
        Maximum cumulative realized loss allowed in a single trading day.
        When exceeded, further orders are blocked until the next trading day
        or until Reset-AlpacaKillSwitch is called manually.
        Defaults to $1,000.

    .PARAMETER DuplicateWindowMinutes
        How long (in minutes) to remember a submitted client order ID for
        duplicate detection. Defaults to 5 minutes.

    .EXAMPLE
        Initialize-AlpacaRisk -MaxPositionValue 5000 -MaxDailyLoss 500

    .EXAMPLE
        Initialize-AlpacaRisk  # use all defaults

    .OUTPUTS
        PSCustomObject (the risk config)
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 10000000)]
        [double]$MaxPositionValue = 10000,

        [ValidateRange(1, 100000)]
        [int]$MaxShares = 500,

        [ValidateRange(1, 1000000)]
        [double]$MaxDailyLoss = 1000,

        [ValidateRange(1, 1440)]
        [int]$DuplicateWindowMinutes = 5
    )

    $script:RiskConfig = [PSCustomObject]@{
        MaxPositionValue       = $MaxPositionValue
        MaxShares              = $MaxShares
        MaxDailyLoss           = $MaxDailyLoss
        DuplicateWindowMinutes = $DuplicateWindowMinutes
    }

    $script:DuplicateWindowMinutes = $DuplicateWindowMinutes

    Write-Verbose "Risk config: MaxPos=`$$MaxPositionValue  MaxShares=$MaxShares  MaxDailyLoss=`$$MaxDailyLoss  DupWindow=${DuplicateWindowMinutes}m"
    return $script:RiskConfig
}


function Get-AlpacaRiskConfig {
    <#
    .SYNOPSIS
        Returns the current risk configuration.

    .EXAMPLE
        Get-AlpacaRiskConfig | Format-List
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:RiskConfig) {
        throw "Risk config is not initialized. Call Initialize-AlpacaRisk first."
    }
    return $script:RiskConfig
}


function New-AlpacaClientOrderId {
    <#
    .SYNOPSIS
        Generates a deterministic client order ID for idempotent order submission.

    .DESCRIPTION
        The generated ID encodes the strategy name, symbol, side, and a UTC minute
        timestamp so that re-submitting the same logical order within the same minute
        produces the same ID. Alpaca will reject a duplicate client_order_id for an
        already-active order, which prevents double fills.

        Format: {strategy}-{symbol}-{side}-{yyyyMMddHHmm}
        Example: ema-AAPL-buy-202504051430

        If you want per-second uniqueness (multiple orders of same type per minute),
        set -UniquePerSecond.

    .PARAMETER Strategy
        Short label for the strategy placing the order. Example: 'ema', 'rsi', 'manual'.

    .PARAMETER Symbol
        Ticker symbol. Will be uppercased, slashes removed for crypto pairs.

    .PARAMETER Side
        'buy' or 'sell'.

    .PARAMETER UniquePerSecond
        If set, appends seconds to the timestamp for finer granularity.

    .EXAMPLE
        $coid = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        # ema-AAPL-buy-202504051430

    .OUTPUTS
        String (client order ID, max 128 chars)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Strategy,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [Parameter(Mandatory)]
        [ValidateSet('buy', 'sell')]
        [string]$Side,

        [switch]$UniquePerSecond
    )

    # Sanitize: remove any char that is not alphanumeric or hyphen
    $cleanStrategy = ($Strategy -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $cleanSymbol   = ($Symbol   -replace '[^a-zA-Z0-9]', '').ToUpperInvariant()

    $fmt = if ($UniquePerSecond) { 'yyyyMMddHHmmss' } else { 'yyyyMMddHHmm' }
    $ts  = (Get-Date).ToUniversalTime().ToString($fmt)

    $id  = '{0}-{1}-{2}-{3}' -f $cleanStrategy, $cleanSymbol, $Side.ToLowerInvariant(), $ts

    # Truncate to 128 chars (Alpaca limit) - strategy + symbol names are typically short
    return $id.Substring(0, [math]::Min($id.Length, 128))
}


function Test-AlpacaDuplicateOrder {
    <#
    .SYNOPSIS
        Returns $true if a matching client order ID was recently submitted.

    .DESCRIPTION
        Checks the in-memory recent orders dictionary for a matching client_order_id.
        Entries older than DuplicateWindowMinutes are pruned automatically.

        This is a session-level check. It does NOT query the Alpaca API.
        For cross-session deduplication, also check Get-AlpacaOrders for an open
        order with the same client_order_id.

    .PARAMETER ClientOrderId
        The client order ID to check. Use the value from New-AlpacaClientOrderId.

    .EXAMPLE
        $coid = New-AlpacaClientOrderId -Strategy 'ema' -Symbol 'AAPL' -Side 'buy'
        if (Test-AlpacaDuplicateOrder -ClientOrderId $coid) {
            Write-Warning "Duplicate order detected - skipping"
        } else {
            Submit-AlpacaOrder ...
            Register-AlpacaOrderSent -ClientOrderId $coid
        }

    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientOrderId
    )

    # Prune expired entries
    $cutoff   = (Get-Date).AddMinutes(-$script:DuplicateWindowMinutes)
    $toRemove = $script:RecentOrders.Keys |
                Where-Object { $script:RecentOrders[$_] -lt $cutoff }
    foreach ($key in $toRemove) {
        $script:RecentOrders.Remove($key) | Out-Null
    }

    return $script:RecentOrders.ContainsKey($ClientOrderId)
}


function Register-AlpacaOrderSent {
    <#
    .SYNOPSIS
        Records a client order ID as submitted for duplicate detection.

    .DESCRIPTION
        Call this immediately after a successful Submit-AlpacaOrder call.
        The ID will be remembered for DuplicateWindowMinutes (set in Initialize-AlpacaRisk).

    .PARAMETER ClientOrderId
        The client order ID that was successfully submitted to Alpaca.

    .EXAMPLE
        $order = Submit-AlpacaOrder -Symbol 'AAPL' -Qty 1 -Side 'buy' -ClientOrderId $coid
        Register-AlpacaOrderSent -ClientOrderId $coid
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientOrderId
    )

    $script:RecentOrders[$ClientOrderId] = Get-Date
    Write-Verbose "Registered order: $ClientOrderId"
}


function Test-AlpacaOrderRisk {
    <#
    .SYNOPSIS
        Validates a proposed order against current risk limits.

    .DESCRIPTION
        Checks:
          1. Kill switch is not active
          2. Daily loss has not exceeded MaxDailyLoss
          3. Order quantity does not exceed MaxShares
          4. Estimated notional value does not exceed MaxPositionValue

        Throws a descriptive exception if any check fails.
        Returns $true if all checks pass. Use with -ErrorAction Stop.

        EstimatedPrice is used only for the notional check. If not supplied,
        only the shares check is performed for notional (both are checked if
        estimated price is provided).

    .PARAMETER Symbol
        Ticker being ordered.

    .PARAMETER Side
        'buy' or 'sell'.

    .PARAMETER Qty
        Number of shares/units in the proposed order.

    .PARAMETER EstimatedPrice
        Optional estimated fill price. Used to calculate estimated notional.
        Get this from Get-AlpacaLatestTrade (last price) or Get-AlpacaSnapshot.

    .EXAMPLE
        $price = (Get-AlpacaLatestTrade -Symbol 'AAPL').p
        Test-AlpacaOrderRisk -Symbol 'AAPL' -Side 'buy' -Qty 10 -EstimatedPrice $price

    .OUTPUTS
        $true if all checks pass. Throws otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Symbol,

        [Parameter(Mandatory)]
        [ValidateSet('buy', 'sell')]
        [string]$Side,

        [Parameter(Mandatory)]
        [ValidateRange(0.00001, 1000000)]
        [double]$Qty,

        [double]$EstimatedPrice
    )

    # Ensure risk config is loaded
    if ($null -eq $script:RiskConfig) {
        throw "Risk config not initialized. Call Initialize-AlpacaRisk first."
    }

    $rc = $script:RiskConfig

    # 1. Kill switch
    if (Test-AlpacaKillSwitch) {
        throw "RISK BLOCK: Kill switch is ACTIVE. No orders permitted. Call Reset-AlpacaKillSwitch to re-enable."
    }

    # 2. Daily loss limit
    $dailyLoss = Get-AlpacaDailyLoss
    if ($dailyLoss -ge $rc.MaxDailyLoss) {
        throw ("RISK BLOCK: Daily loss limit reached. Today's loss: `${0:N2} / `${1:N2}. " +
               "No further orders until tomorrow or manual reset." -f $dailyLoss, $rc.MaxDailyLoss)
    }

    # 3. Share quantity limit
    if ($Qty -gt $rc.MaxShares) {
        throw ("RISK BLOCK: Order qty {0} exceeds MaxShares limit of {1}." -f $Qty, $rc.MaxShares)
    }

    # 4. Notional value limit (only if EstimatedPrice is provided)
    if ($EstimatedPrice -gt 0) {
        $notional = $Qty * $EstimatedPrice
        if ($notional -gt $rc.MaxPositionValue) {
            throw ("RISK BLOCK: Estimated notional `${0:N2} exceeds MaxPositionValue limit of `${1:N2}." -f $notional, $rc.MaxPositionValue)
        }
    }

    Write-Verbose "Risk check passed: $Side $Symbol x$Qty"
    return $true
}


function Invoke-AlpacaKillSwitch {
    <#
    .SYNOPSIS
        Activates the kill switch to halt all order activity immediately.

    .DESCRIPTION
        Sets a flag in the risk state file AND creates a lock file so the kill
        switch survives process restarts. Once active, Test-AlpacaOrderRisk and
        Test-AlpacaKillSwitch will both block order submission.

        After activating the kill switch you typically want to:
          Remove-AllAlpacaOrders (cancel open orders)
          Close-AllAlpacaPositions (flatten positions)

    .PARAMETER Reason
        Description of why the kill switch was activated. Logged for audit.

    .EXAMPLE
        Invoke-AlpacaKillSwitch -Reason "3 consecutive losses hit"
        Remove-AllAlpacaOrders
        Close-AllAlpacaPositions -CancelOrders
    #>
    [CmdletBinding()]
    param(
        [string]$Reason = 'Manual kill switch activation'
    )

    $state = _Load-RiskState
    $state['kill_switch_active'] = $true
    _Save-RiskState $state

    # Write the lock file as a belt-and-suspenders measure
    $lockFile = _Get-KillSwitchFile
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    "$timestamp KILL SWITCH ACTIVE: $Reason" | Set-Content -Path $lockFile -Encoding UTF8 -Force

    Write-AlpacaLog -Level ERROR -Message "KILL SWITCH ACTIVATED: $Reason"
}


function Test-AlpacaKillSwitch {
    <#
    .SYNOPSIS
        Returns $true if the kill switch is currently active.

    .DESCRIPTION
        Checks both the risk state JSON and the lock file. Either one being present
        is sufficient to return $true.

    .EXAMPLE
        if (Test-AlpacaKillSwitch) { throw "Trading halted" }

    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Check the lock file first (survives process restarts independently of JSON state)
    if (Test-Path (_Get-KillSwitchFile)) {
        return $true
    }

    $state = _Load-RiskState
    return [bool]$state['kill_switch_active']
}


function Reset-AlpacaKillSwitch {
    <#
    .SYNOPSIS
        Manually clears the kill switch to allow trading to resume.

    .DESCRIPTION
        Removes the lock file and clears the flag in the state JSON.
        Use only after investigating and resolving the reason the kill switch fired.

    .EXAMPLE
        Reset-AlpacaKillSwitch
        Write-Host "Kill switch cleared. Verify positions and orders before resuming."
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('kill switch', 'Reset')) {
        $lockFile = _Get-KillSwitchFile
        if (Test-Path $lockFile) {
            Remove-Item $lockFile -Force
            Write-Verbose "Kill switch lock file removed."
        }

        $state = _Load-RiskState
        $state['kill_switch_active'] = $false
        _Save-RiskState $state

        Write-AlpacaLog -Level WARN -Message "Kill switch CLEARED. Review positions before resuming automated trading."
    }
}


function Add-AlpacaDailyLoss {
    <#
    .SYNOPSIS
        Records a realized loss against today's daily loss counter.

    .DESCRIPTION
        Call this whenever a trade closes at a loss. Accumulates in the risk state
        JSON and is checked by Test-AlpacaOrderRisk against MaxDailyLoss.

        The counter resets automatically when today's date differs from the stored date.

        Gains (negative loss amounts) are accepted but do NOT reduce the daily loss
        counter below zero - this prevents a profitable trade from "re-granting"
        loss capacity.

    .PARAMETER AmountLost
        Positive dollar amount lost on the trade.
        Example: if you bought 10 shares at $100 and sold at $95, AmountLost = $50.

    .EXAMPLE
        # After a $75 losing trade:
        Add-AlpacaDailyLoss -AmountLost 75

    .OUTPUTS
        Double (new cumulative daily loss total)
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 10000000)]
        [double]$AmountLost
    )

    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $state = _Load-RiskState

    # Reset if the stored date is a different day
    if ($state['daily_loss_date'] -ne $today) {
        $state['daily_loss']      = 0.0
        $state['daily_loss_date'] = $today
        Write-Verbose "Daily loss counter reset for new trading day: $today"
    }

    $state['daily_loss'] = [double]$state['daily_loss'] + $AmountLost
    _Save-RiskState $state

    $currentLossFmt = ([double]$state['daily_loss']).ToString('N2')
    $maxLossFmt     = ([double]$script:RiskConfig.MaxDailyLoss).ToString('N2')
    Write-Verbose ("Daily loss updated: `${0} / `${1}" -f $currentLossFmt, $maxLossFmt)
    return [double]$state['daily_loss']
}


function Get-AlpacaDailyLoss {
    <#
    .SYNOPSIS
        Returns today's cumulative realized loss amount.

    .DESCRIPTION
        Returns the running total set by Add-AlpacaDailyLoss.
        Returns 0 if today's counter has not been set yet (no losing trades today).

    .EXAMPLE
        $loss = Get-AlpacaDailyLoss
        Write-Host "Today's loss: `$$($loss:N2)"

    .OUTPUTS
        Double
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param()

    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $state = _Load-RiskState

    if ($state['daily_loss_date'] -ne $today) {
        return 0.0
    }

    return [double]$state['daily_loss']
}


Export-ModuleMember -Function @(
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
