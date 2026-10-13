[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$ParentPid,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'ChildSessionRequest.ps1')

function Write-KeeperStatus([string]$State, [string]$Message) {
    $record = @{ state = $State; pid = $PID; desktop = $desktopName; updatedAt = [DateTime]::UtcNow.ToString('o') }
    if ($Message) { $record.error = $Message }
    $temporary = $request.statusPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    try {
        if ([IO.File]::Exists($request.statusPath)) { [IO.File]::Replace($temporary, $request.statusPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $request.statusPath) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

$child = $null
$owner = $null
$request = $null
$desktopName = $null
$exitCode = 1
$stopRequested = $false
$controllerLease = $null
$mode = 'hyperv'
try {
    if (-not [IO.Path]::IsPathRooted($RequestPath)) { throw 'RequestPath must be absolute.' }
    $request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
    $mode = Get-RdpRequestMode $request
    $interactiveAuthentication = Get-InteractiveAuthentication $request
    $paths = @('statusPath', 'stopPath')
    if ($mode -eq 'hyperv') { $paths += 'credentialPath' }
    foreach ($name in $paths) {
        if (-not [IO.Path]::IsPathRooted([string]$request.$name)) { throw "$name must be absolute." }
    }
    if ($null -ne $request.PSObject.Properties['bootstrapPath'] -and -not [IO.Path]::IsPathRooted([string]$request.bootstrapPath)) { throw 'bootstrapPath must be absolute.' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($request.statusPath))) { throw 'The status directory must already exist.' }
    if ([string]::IsNullOrWhiteSpace([string]$request.address) -or $request.address -match '[\r\n\x00]') { throw 'Invalid RDP address.' }
    if ($mode -eq 'hyperv') {
        $targets = [Net.Dns]::GetHostAddresses([string]$request.address)
        if ($targets.Count -eq 0) { throw 'The RDP address did not resolve.' }
        $localAddresses = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object { $_.GetIPProperties().UnicastAddresses | ForEach-Object { $_.Address.ToString() } })
        foreach ($target in $targets) {
            $normalized = $target
            if ($target.IsIPv4MappedToIPv6) { $normalized = $target.MapToIPv4() }
            if ($normalized.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
                throw 'This backend requires an IPv4-only RDP destination.'
            }
            if ([Net.IPAddress]::IsLoopback($normalized) -or $normalized.Equals([Net.IPAddress]::Any) -or $normalized.Equals([Net.IPAddress]::IPv6Any) -or $localAddresses -contains $normalized.ToString()) {
                throw 'The remote RDP destination is this host. Use mode child-session for a native Child Session, or a dedicated VM for hyperv mode.'
            }
        }
    }
    if ([int]$request.port -lt 1 -or [int]$request.port -gt 65535) { throw 'Invalid RDP port.' }
    if ([int]$request.width -lt 640 -or [int]$request.width -gt 7680 -or [int]$request.height -lt 480 -or [int]$request.height -gt 4320) { throw 'Invalid RDP dimensions.' }
    if ([IO.File]::Exists($request.stopPath)) { throw 'A stop marker already exists; use a fresh runtime directory.' }
    $owner = [Diagnostics.Process]::GetProcessById($ParentPid)
    $null = $owner.Handle
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopProcess.cs'), (Join-Path $PSScriptRoot 'ChildSessionNative.cs')
    if ($mode -eq 'child-session') {
        $expected = Read-ChildSessionExpectation $request
        if ($null -eq $request.PSObject.Properties['guestRoot'] -or [string]::IsNullOrWhiteSpace([string]$request.guestRoot) -or ([string]$request.guestRoot).Length -gt 160) {
            throw 'Child Session guestRoot is required and must be at most 160 characters.'
        }
        $controllerLease = [CuaRdp.Native.ChildSessionControllerLease]::Acquire($SelfTest.IsPresent)
        if (-not $SelfTest) {
            if ($owner.SessionId -ne $expected.ParentSessionId) { throw 'The owner process is not in the expected parent session.' }
            [CuaRdp.Native.ChildSessionGuard]::BeforeConnect([CuaRdp.Native.ChildSessionNative]::Capture(), $expected, [int]$request.port)
        }
    }
    if ($owner.HasExited) { throw 'The owner process exited before the RDP worker could start.' }
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-File', (Join-Path $PSScriptRoot 'RdpWorker.ps1'), '-RequestPath', $RequestPath, '-LauncherPid', [string]$PID)
    if ($SelfTest) { $arguments += '-SelfTest' }
    Write-KeeperStatus 'connecting' $null
    # Child Session uses Default; only explicit interactive authentication may show a logon window.
    if ($mode -eq 'child-session') { $child = [CuaRdp.Native.DesktopProcess]::StartOnCurrentDesktop($executable, [string[]]$arguments) }
    else { $child = [CuaRdp.Native.DesktopProcess]::Start($executable, [string[]]$arguments) }
    $desktopName = $child.DesktopName
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $loginTimeout = 40
    if ($mode -eq 'hyperv') { $loginTimeout = 130 }
    elseif ($interactiveAuthentication) { $loginTimeout = 315 }
    while (-not $child.HasExited) {
        if ($owner.HasExited -or [IO.File]::Exists($request.stopPath)) { $exitCode = 0; $stopRequested = $true; break }
        if ([IO.File]::Exists($request.statusPath)) {
            try {
                $status = [IO.File]::ReadAllText($request.statusPath) | ConvertFrom-Json
                if ($status.state -in @('connected', 'self-test-passed')) { $started = $true }
                if ($status.state -eq 'failed') { break }
            }
            catch [IO.IOException] { }
        }
        if (-not $started -and $timer.Elapsed.TotalSeconds -gt $loginTimeout) {
            Write-KeeperStatus 'failed' ('The RDP worker did not finish login within ' + $loginTimeout + ' seconds.')
            break
        }
        [Threading.Thread]::Sleep(250)
    }
    if ($child.HasExited) {
        $exitCode = $child.ExitCode
        $status = [IO.File]::ReadAllText($request.statusPath) | ConvertFrom-Json
        if ($status.state -notin @('failed', 'stopped', 'self-test-passed')) {
            Write-KeeperStatus 'failed' 'The RDP worker exited unexpectedly.'
            $exitCode = 1
        }
    }
}
catch {
    $message = $_.Exception.GetBaseException().Message
    [Console]::Error.WriteLine('RDP keeper failed: ' + $message)
    if ($null -ne $request -and $null -ne $request.PSObject.Properties['statusPath']) {
        try { Write-KeeperStatus 'failed' $message } catch { }
    }
}
finally {
    if ($null -ne $child) {
        $child.Dispose()
        if ($stopRequested) { try { Write-KeeperStatus 'stopped' $null } catch { } }
    }
    if ($null -ne $controllerLease) { $controllerLease.Dispose() }
    if ($null -ne $owner) { $owner.Dispose() }
}
exit $exitCode
