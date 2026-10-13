[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopProcess.cs'), (Join-Path $PSScriptRoot 'RdpWindow.cs'), (Join-Path $PSScriptRoot 'ChildSessionNative.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
$guards = & (Join-Path $PSScriptRoot 'Test-ChildSessionGuards.ps1')
if ($guards.result -ne 'passed') { throw 'The Child Session ownership guards did not pass.' }
$snapshotBefore = & (Join-Path $PSScriptRoot 'Get-ChildSessionState.ps1') | ConvertFrom-Json
foreach ($field in @('enabled', 'parentSessionId', 'parentLogonTime', 'parentState', 'parentProtocol', 'activeConsoleSessionId', 'isConsoleParent', 'userSid', 'machineGuid', 'childSessionId', 'childLogonTime', 'childState', 'childProtocol', 'childUserSid', 'rdpPort', 'rdpWrapper', 'elevated')) {
    if ($null -eq $snapshotBefore.PSObject.Properties[$field]) { throw ('The native snapshot is missing ' + $field) }
}
if ($snapshotBefore.parentLogonTime -isnot [string] -or $snapshotBefore.parentLogonTime -notmatch '^[1-9][0-9]*$') { throw 'Parent generation was not serialized as a FILETIME string.' }
if ($null -ne $snapshotBefore.childSessionId -and ($snapshotBefore.childLogonTime -isnot [string] -or $snapshotBefore.childLogonTime -notmatch '^[1-9][0-9]*$')) { throw 'Child generation was not serialized as a FILETIME string.' }
$validRoots = @('C:\ProgramData\CuaRdp', 'D:\RDP-Guests\test_root.1', 'D:\RDP-Guests\test_root.1\')
foreach ($root in $validRoots) {
    $normalized = [CuaRdp.Native.BootstrapKeyboard]::ValidateGuestRoot($root)
    if ($normalized -ne $root.TrimEnd('\')) { throw 'Guest-root normalization failed.' }
    $command = [CuaRdp.Native.BootstrapKeyboard]::CommandFor(('a' * 32), $root)
    $encoded = [CuaRdp.Native.BootstrapKeyboard]::EncodeAscii($command)
    if ($encoded.Length -lt $command.Length * 2) { throw 'Custom guest-root keyboard encoding failed.' }
    $caps = [CuaRdp.Native.BootstrapKeyboard]::EncodeCapsAscii($command)
    if ($caps.Length -lt $command.Length * 2) { throw 'Custom guest-root caps keyboard encoding failed.' }
}
$invalidRoots = @('', 'relative', 'C:\', 'C:\..\Windows', 'D:\RDP Guests\test_root.1', 'C:\.\Agent', 'C:\Agent\\Child', 'C:\Agent&other', 'C:\Agent"other', 'C:\Agent:stream', 'C:\Agent ', 'C:\Agent.', '\\server\share', 'C:\NUL\Agent', 'C:\路径')
foreach ($root in $invalidRoots) {
    $rejected = $false
    try { $null = [CuaRdp.Native.BootstrapKeyboard]::ValidateGuestRoot($root) }
    catch { $rejected = $true }
    if (-not $rejected) { throw ('Unsafe guest root was accepted: ' + $root) }
}
$before = [CuaRdp.Native.DesktopProcess]::InputDesktopName()
$directory = Join-Path ([IO.Path]::GetTempPath()) ('cua-rdp-native-test-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($directory)
$keeper = Join-Path $PSScriptRoot 'Start-RdpKeeper.ps1'
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-ProcessExited([int]$ProcessId) {
    try {
        $remaining = [Diagnostics.Process]::GetProcessById($ProcessId)
        $alive = -not $remaining.HasExited
        $remaining.Dispose()
        if ($alive) { throw ('An owned native-test child survived shutdown: ' + $ProcessId) }
    }
    catch [ArgumentException] { }
}

function Invoke-KeeperSelfTest([string]$Mode, [string]$Authentication = 'background') {
    $requestPath = Join-Path $directory ($Mode + '-request.json')
    $statusPath = Join-Path $directory ($Mode + '-status.json')
    $request = @{
        address = '192.0.2.1'; port = 3389; width = 1280; height = 720
        guestRoot = 'D:\RDP-Guests\test_root.1'
        statusPath = $statusPath
        stopPath = (Join-Path $directory ($Mode + '-stop'))
        bootstrapPath = (Join-Path $directory ($Mode + '-bootstrap.json'))
    }
    if ($Mode -eq 'child-session') {
        $request.mode = 'child-session'
        $request.authentication = $Authentication
        $request.address = 'localhost'
        $request.port = $snapshotBefore.rdpPort
        $request.expectedParentSessionId = $snapshotBefore.parentSessionId
        $request.expectedParentLogonTime = $snapshotBefore.parentLogonTime
        $request.expectedChildSessionId = $snapshotBefore.childSessionId
        $request.expectedChildLogonTime = $snapshotBefore.childLogonTime
    }
    else { $request.credentialPath = Join-Path $directory 'unused-credential.xml' }
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    & $executable -NoLogo -NoProfile -NonInteractive -File $keeper -RequestPath $requestPath -ParentPid $PID -SelfTest
    if ($LASTEXITCODE -ne 0) {
        if ([IO.File]::Exists($statusPath)) { throw [IO.File]::ReadAllText($statusPath) }
        throw 'The keeper self-test failed before writing status.'
    }
    $status = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
    if ($status.backgroundReady -ne $true -or $status.bootstrapPhase -isnot [string] -or $status.inputFocusRequired -ne $false) { throw 'Native self-test did not confirm its hidden background state.' }
    if ($status.state -ne 'self-test-passed') { throw ('Unexpected self-test status: ' + $status.state) }
    $heartbeat = [DateTimeOffset]::Parse([string]$status.updatedAt, [Globalization.CultureInfo]::InvariantCulture)
    if (([DateTimeOffset]::UtcNow - $heartbeat).TotalSeconds -gt 15) { throw 'The status heartbeat is stale.' }
    if ($Mode -eq 'child-session') {
        if ($status.desktop -cne 'Default' -or $before -cne 'Default') { throw 'The child-session worker did not stay on the interactive desktop.' }
    }
    elseif ($status.desktop -notlike 'cua-rdp-*' -or $status.desktop -eq $before) { throw 'The worker did not run on an isolated desktop.' }
    if ($status.connectToChildSession -isnot [bool] -or $status.connectToChildSession -ne ($Mode -eq 'child-session')) { throw 'The actual COM Child Session property was not verified.' }
    if ($null -ne $status.PSObject.Properties['childSessionId']) { throw 'Self-test incorrectly claimed an actual Child Session identity.' }
    if ($before -ne [CuaRdp.Native.DesktopProcess]::InputDesktopName()) { throw 'The input desktop changed.' }
    Assert-ProcessExited ([int]$status.pid)
    return $status
}

$remoteStatus = Invoke-KeeperSelfTest 'hyperv'
$childStatus = Invoke-KeeperSelfTest 'child-session'
$interactiveStatus = Invoke-KeeperSelfTest 'child-session' 'interactive'
$lease = [CuaRdp.Native.ChildSessionControllerLease]::Acquire($true)
try {
    $probe = "Add-Type -Path '" + (Join-Path $PSScriptRoot 'ChildSessionNative.cs').Replace("'", "''") + "'; " + @'
$lease = $null
try {
    $lease = [CuaRdp.Native.ChildSessionControllerLease]::Acquire($true)
    [Console]::Error.WriteLine('A duplicate self-test controller acquired the mutex.')
    exit 2
}
catch {
    if ($_.Exception.GetBaseException().Message -notlike '*already running*') {
        [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
        exit 1
    }
    [Console]::Out.WriteLine('blocked')
}
finally { if ($null -ne $lease) { $lease.Dispose() } }
'@
    $probeOutput = & $executable -NoLogo -NoProfile -NonInteractive -Command $probe
    if ($LASTEXITCODE -ne 0 -or $probeOutput -ne 'blocked') { throw 'The machine-wide self-test mutex did not exclude another process.' }
}
finally { $lease.Dispose() }
$lease = [CuaRdp.Native.ChildSessionControllerLease]::Acquire($true)
$lease.Dispose()
$jobChild = [CuaRdp.Native.DesktopProcess]::Start($executable, [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[Threading.Thread]::Sleep(60000)'))
$jobChildId = $jobChild.ProcessId
if ($jobChild.HasExited) { $jobChild.Dispose(); throw 'The job-lifetime test child exited before the test.' }
$jobChild.Dispose()
Assert-ProcessExited $jobChildId
$snapshotAfter = & (Join-Path $PSScriptRoot 'Get-ChildSessionState.ps1') | ConvertFrom-Json
foreach ($field in @('enabled', 'parentSessionId', 'parentLogonTime', 'childSessionId', 'childLogonTime')) {
    if ($snapshotBefore.$field -cne $snapshotAfter.$field) { throw ('Windows session state changed during the read-only self-test: ' + $field) }
}
$after = [CuaRdp.Native.DesktopProcess]::InputDesktopName()
if ($before -ne $after) { throw 'The input desktop changed.' }
[PSCustomObject]@{
    result = 'passed'; activeDesktop = $after; workerDesktop = $remoteStatus.desktop; childWorkerDesktop = $childStatus.desktop
    workerExited = $true; killOnJobClose = $true; machineMutex = $true
    guestRootCases = ($validRoots.Count + $invalidRoots.Count); childGuardCases = $guards.guardCases
    wtsInfoSize = $guards.wtsInfoSize; logonTimeOffset = $guards.logonTimeOffset; readOnlySnapshot = $true
    interactiveConfiguration = ($interactiveStatus.state -eq 'self-test-passed'); visibleAuthenticationAttempted = $false
    childSessionProperty = $childStatus.connectToChildSession; remoteSessionProperty = $remoteStatus.connectToChildSession
    heartbeat = $childStatus.updatedAt; connectionAttempted = $false; enableAttempted = $false; runtimeDirectory = $directory
}
