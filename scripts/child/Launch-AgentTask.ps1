[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$ChildSessionId,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId
)

# Starts the staged guest agent inside the Child Session through a temporary
# scheduled task that is deleted immediately after launch. No keyboard input is
# injected, so a Chinese IME in the child session cannot intercept the bootstrap,
# and no credential is stored: the task runs as the current user with an
# interactive token at the least privilege. The agent itself re-verifies the
# session identity before doing anything.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Runtime.Common.ps1')

$root = Assert-ChildRuntimePath $RuntimeRoot
$null = Assert-ChildRuntimeOwner $root
$null = Assert-ChildRuntimeFile (Join-Path $root 'Start-Agent.ps1')
$runRoot = Assert-ChildRuntimeDirectory (Join-Path (Join-Path $root 'runs') $RunId)
foreach ($name in @('owner.token', 'agent.json')) {
    Assert-ChildRuntimeFile (Join-Path $runRoot $name)
}
$agent = Read-ChildRuntimeJson (Join-Path $runRoot 'agent.json')
if ((Get-ChildRuntimeProperty $agent 'runId') -cne $RunId -or
    (Get-ChildRuntimeProperty $agent 'expectedSessionId') -isnot [int] -or
    $agent.expectedSessionId -ne $ChildSessionId) {
    throw '[cua-rdp] The staged run does not target this Child Session.'
}

$taskActionExecute = 0
$taskCreate = 2
$taskLogonInteractiveToken = 3
$taskRunLevelLeast = 0
$taskRunUseSessionId = 0x4

$schedulerType = [Type]::GetTypeFromProgID('Schedule.Service')
if ($null -eq $schedulerType) { throw '[cua-rdp] The Task Scheduler COM service is unavailable.' }
$taskName = 'CuaRdp-ChildSession-Agent-' + [Guid]::NewGuid().ToString('N')
$accountName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$entry = Join-Path $root 'Start-Agent.ps1'
$arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -RunId {1}' -f $entry, $RunId.ToLowerInvariant()

$scheduler = $null
$folder = $null
$definition = $null
$registered = $null
$running = $null
$registeredOk = $false
try {
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    $definition = $scheduler.NewTask(0)
    $definition.RegistrationInfo.Author = 'cua-rdp'
    $definition.RegistrationInfo.Description = 'Temporary cua-rdp agent launch into Child Session ' + $ChildSessionId
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Principal.UserId = $accountName
    $definition.Principal.LogonType = $taskLogonInteractiveToken
    $definition.Principal.RunLevel = $taskRunLevelLeast
    $action = $definition.Actions.Create($taskActionExecute)
    $action.Path = Join-Path $PSHOME 'powershell.exe'
    $action.Arguments = $arguments
    $action.WorkingDirectory = $root
    $registered = $folder.RegisterTaskDefinition($taskName, $definition, $taskCreate, $accountName, $null, $taskLogonInteractiveToken, $null)
    $registeredOk = $true
    $running = $registered.RunEx($null, $taskRunUseSessionId, $ChildSessionId, $null)
    if ($null -eq $running) { throw '[cua-rdp] The Task Scheduler did not return a running instance.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $enginePid = 0
        try { $enginePid = [int]$running.EnginePid } catch { }
        if ($enginePid -gt 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $enginePid = 0
    try { $enginePid = [int]$running.EnginePid } catch { }
    [PSCustomObject]@{ launched = $true; childSessionId = $ChildSessionId; enginePid = $enginePid } | ConvertTo-Json -Compress
} finally {
    if ($registeredOk -and $null -ne $folder) {
        try { $folder.DeleteTask($taskName, 0) } catch [Runtime.InteropServices.COMException] { }
    }
    foreach ($disposable in @($running, $registered, $definition, $folder, $scheduler)) {
        if ($null -ne $disposable -and [Runtime.InteropServices.Marshal]::IsComObject($disposable)) {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($disposable)
        }
    }
}
