[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('(?i)^[0-9a-f]{32}$')]
    [string]$RunId
)

# The keyboard bootstrap types upper case while Caps Lock holds direct-English input.
$RunId = $RunId.ToLowerInvariant()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$runRoot = Join-Path (Join-Path $PSScriptRoot 'runs') $RunId
$runConfigPath = Join-Path $runRoot 'agent.json'
$stopPath = Join-Path $runRoot 'stop.requested'
$bootstrapLock = $null
$process = $null

try {
    if (-not (Test-Path -LiteralPath $runRoot -PathType Container) -or (Test-Path -LiteralPath $stopPath)) { exit 0 }
    try { $bootstrapLock = [IO.File]::Open((Join-Path $runRoot 'bootstrap.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { exit 0 }
    if (Test-Path -LiteralPath $stopPath) { exit 0 }
    [IO.File]::WriteAllText((Join-Path $runRoot 'bootstrap.started'), [DateTime]::UtcNow.ToString('o'), (New-Object Text.UTF8Encoding($false)))
    $installed = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guest-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $run = Get-Content -LiteralPath $runConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($installed.version -ne 1 -or $run.version -ne 1 -or $run.runId -cne $RunId) {
        throw 'Invalid guest configuration.'
    }
    if ($run.token -cnotmatch '^[0-9a-f]{64}$' -or $run.leaseMs -ne 180000) {
        throw 'Invalid run configuration.'
    }
    $expectedReady = Join-Path $runRoot 'ready.json'
    if ([IO.Path]::GetFullPath($run.readyPath) -ine [IO.Path]::GetFullPath($expectedReady)) {
        throw 'Ready descriptor must remain inside the run directory.'
    }
    if ($run.driverPath -ine $installed.driverPath -or $run.expectedUserSid -ne $installed.userSid) {
        throw 'Run identity does not match the installation.'
    }
    foreach ($path in @($installed.nodePath, $installed.driverPath, (Join-Path $PSScriptRoot 'guest-agent.cjs'))) {
        if (-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'A required guest executable is missing.'
        }
    }
    $actual = & (Join-Path $PSScriptRoot 'Get-InteractiveState.ps1') | ConvertFrom-Json
    if ($actual.machineGuid -ine $run.expectedMachineGuid -or
        $actual.userSid -ne $run.expectedUserSid -or
        $actual.sessionId -ne $run.expectedSessionId -or
        $actual.sessionId -le 0 -or $actual.protocol -ne 2 -or
        $actual.state -ne 0 -or $actual.inputDesktop -cne 'Default' -or
        ($null -ne $run.expectedSessionLogonTime -and
            ($run.expectedSessionLogonTime -isnot [string] -or $run.expectedSessionLogonTime -cnotmatch '^[1-9][0-9]{0,19}$' -or $actual.logonTime -cne $run.expectedSessionLogonTime))) {
        throw 'The agent requires the expected active, unlocked RDP session.'
    }
    if (Test-Path -LiteralPath $stopPath) { exit 0 }
    $entry = Join-Path $PSScriptRoot 'guest-agent.cjs'
    $arguments = '"{0}" --config "{1}"' -f $entry, $runConfigPath
    $process = Start-Process -FilePath $installed.nodePath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runRoot 'agent.stdout.log') -RedirectStandardError (Join-Path $runRoot 'agent.stderr.log') -PassThru
    $startup = @{ runId = $RunId; pid = $process.Id; sessionId = $actual.sessionId; machineGuid = $actual.machineGuid; userSid = $actual.userSid; logonTime = $actual.logonTime; startedAt = $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    $startupTemp = Join-Path $runRoot 'startup.json.tmp'
    [IO.File]::WriteAllText($startupTemp, ($startup | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($startupTemp, (Join-Path $runRoot 'startup.json'))
    $process.WaitForExit()
    exit $process.ExitCode
} catch {
    if ($null -ne $process) { try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null } } catch { } }
    if (Test-Path -LiteralPath $runRoot -PathType Container) {
        # The specific failure reason travels to the controller through this file; keep it a
        # short sanitized message (never config, tokens or child-desktop content).
        $reason = [string]$_.Exception.Message
        while ($null -ne $_.Exception.InnerException) { $reason = [string]$_.Exception.InnerException.Message; $_ = @{ Exception = $_.Exception.InnerException } }
        if ($reason.Length -gt 400) { $reason = $reason.Substring(0, 400) }
        [IO.File]::WriteAllText((Join-Path $runRoot 'bootstrap-error.txt'), 'Guest bootstrap failed: ' + $reason, (New-Object Text.UTF8Encoding($false)))
    }
    [Console]::Error.WriteLine('CuaRdp guest bootstrap failed; see the run directory diagnostic.')
    exit 1
} finally {
    if ($null -ne $process) { $process.Dispose() }
    if ($null -ne $bootstrapLock) { $bootstrapLock.Dispose() }
}
