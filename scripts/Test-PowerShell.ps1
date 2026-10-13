[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @('scripts\Common.ps1', 'scripts\Broker.ps1', 'scripts\Initialize-CuaRdp.ps1', 'scripts\New-CuaRdpVm.ps1', 'guest\Get-InteractiveState.ps1', 'guest\Start-Agent.ps1')
$checks = 0
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('PowerShell parser rejected ' + $file) }
    $checks++
}
. (Join-Path $PSScriptRoot 'Common.ps1')
foreach ($path in @('C:\ProgramData\CuaRdp', 'D:\Private Guest\Cua-Rdp_1.0')) {
    $actual = Assert-CuaRdpGuestRoot $path
    if ($actual -cne $path) { throw 'A valid guest path was not preserved.' }
    $checks++
}
foreach ($path in @('C:\', '\\server\share', 'C:\a\..\b', 'C:\a\.', 'C:\a&b', 'C:\a$b', 'C:\a;b', 'C:\a"b', 'C:\bad.', 'C:\bad ', 'C:\a\\b', 'C:\CON', 'C:\aux.txt', 'C:\a\PRN', 'C:\NUL.log', 'C:\COM1', 'C:\Lpt9.ini', ('C:\' + ('a' * 158)))) {
    $rejected = $false
    try { $null = Assert-CuaRdpGuestRoot $path } catch { $rejected = $true }
    if (-not $rejected) { throw 'An unsafe guest bootstrap path was accepted.' }
    $checks++
}
try { throw 'SENSITIVE_TEST_MARKER' } catch { $message = Get-CuaRdpSafeError $_ 'request' }
if ($message.Contains('SENSITIVE_TEST_MARKER') -or -not $message.Contains('outcome may be unknown')) { throw 'Broker exception sanitization failed.' }
$checks++
$state = & (Join-Path $root 'guest\Get-InteractiveState.ps1') | ConvertFrom-Json
if ($state.sessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or $state.userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
    throw 'The session diagnostic did not report the actual process identity.'
}
if ([string]::IsNullOrWhiteSpace($state.machineGuid)) { throw 'The session diagnostic omitted the machine identity.' }
$checks++
$nativeState = & (Join-Path $root 'native\Get-ChildSessionState.ps1') | ConvertFrom-Json
if ($state.logonTime -isnot [string] -or $state.logonTime -cnotmatch '^[1-9][0-9]{0,19}$' -or $state.logonTime -cne $nativeState.parentLogonTime) {
    throw 'Guest and native diagnostics disagree about the actual session logon generation.'
}
$checks++
$all = & (Join-Path $root 'guest\Get-InteractiveState.ps1') -ListSessions | ConvertFrom-Json
if (@($all.sessions | Where-Object { $_.sessionId -eq $state.sessionId }).Count -ne 1) { throw 'WTS enumeration did not include the current session exactly once.' }
$checks++
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$missing = Join-Path $env:TEMP ('cua-rdp-missing-' + [Guid]::NewGuid().ToString('N') + '.json')
$info.Arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ConfigPath "{1}" -OwnerPid {2}' -f (Join-Path $PSScriptRoot 'Broker.ps1'), $missing, $PID
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($info)
try {
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Missing-config broker test timed out.' }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if ($process.ExitCode -ne 1 -or $stdout.Length -ne 0 -or -not $stderr.Contains('preparation failed')) { throw 'The broker did not fail closed with protocol-clean output for missing configuration.' }
    $checks++
} finally { $process.Dispose() }
$tokens = $null
$errors = $null
$brokerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Broker.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in @('Assert-RunId', 'Get-OwnedRun', 'Stop-OwnedRun')) {
    $definition = $brokerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
    if ($null -eq $definition) { throw 'A tested broker function is missing.' }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Invoke-Command {
    param($Session, [object[]]$ArgumentList, [scriptblock]$ScriptBlock)
    & $ScriptBlock @ArgumentList
}
function Invoke-GuestHttp {
    param($Run, [string]$Operation, $Payload)
    if ($Operation -ne 'shutdown') { throw 'A stop test attempted a non-shutdown operation.' }
    $script:shutdowns++
    @{}
}
function Get-CimInstance { param([string]$ClassName) @() }
$testRoot = Join-Path $env:TEMP ('cua-rdp-stop-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'runs')
$script:config = @{ guestRoot = $testRoot; guestMachineGuid = 'test-machine' }
$script:session = [pscustomobject]@{ State = 'Opened' }
$script:guestUserSid = 'test-user'
$script:runs = @{}
$script:shutdowns = 0
$utf8 = New-Object Text.UTF8Encoding($false)
function New-TestRun {
    param([switch]$WithAgent, [switch]$WithReady, [switch]$Foreign)
    $id = [Guid]::NewGuid().ToString('N')
    $token = 'a' * 64
    $path = Join-Path (Join-Path $testRoot 'runs') $id
    $null = New-Item -ItemType Directory -Path $path
    $owner = $token
    if ($Foreign) { $owner = 'b' * 64 }
    [IO.File]::WriteAllText((Join-Path $path 'owner.token'), $owner, $utf8)
    if ($WithAgent) {
        $agent = @{ runId = $id; token = $token; expectedSessionId = 42; expectedUserSid = 'test-user'; expectedMachineGuid = 'test-machine' }
        [IO.File]::WriteAllText((Join-Path $path 'agent.json'), ($agent | ConvertTo-Json -Compress), $utf8)
    }
    if ($WithReady) {
        $ready = @{ runId = $id; sessionId = 42; userSid = 'test-user'; machineGuid = 'test-machine'; port = 54321; pid = 123456 }
        [IO.File]::WriteAllText((Join-Path $path 'ready.json'), ($ready | ConvertTo-Json -Compress), $utf8)
    }
    $script:runs[$id] = @{ runId = $id; token = $token; identity = $null; ready = $null }
    @{ id = $id; path = $path }
}
$heldLock = $null
try {
    $run = New-TestRun
    $result = Stop-OwnedRun $run.id
    if (-not $result.stopped -or $result.retained -or (Test-Path -LiteralPath $run.path) -or $script:runs.ContainsKey($run.id)) { throw 'A staged-only owned run was not cleaned safely.' }
    $checks++
    $run = New-TestRun -WithAgent -WithReady
    $result = Stop-OwnedRun $run.id
    if (-not $result.stopped -or $result.retained -or $script:shutdowns -ne 1 -or $script:runs.ContainsKey($run.id)) { throw 'Late readiness was not discovered and shut down.' }
    $checks++
    $run = New-TestRun -WithAgent
    $heldLock = [IO.File]::Open((Join-Path $run.path 'bootstrap.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $result = Stop-OwnedRun $run.id
    if ($result.stopped -or -not $result.retained -or -not $script:runs.ContainsKey($run.id) -or -not (Test-Path -LiteralPath (Join-Path $run.path 'stop.requested'))) { throw 'A live bootstrap did not retain ownership and receive its stop marker.' }
    $checks++
    $heldLock.Dispose()
    $heldLock = $null
    $result = Stop-OwnedRun $run.id
    if (-not $result.stopped -or $result.retained -or $script:runs.ContainsKey($run.id)) { throw 'Cleanup could not be retried after the bootstrap exited.' }
    $checks++
    $run = New-TestRun -Foreign
    $rejected = $false
    try { $null = Stop-OwnedRun $run.id } catch { $rejected = $true }
    if (-not $rejected -or -not (Test-Path -LiteralPath $run.path) -or -not $script:runs.ContainsKey($run.id)) { throw 'Foreign run ownership was not preserved.' }
    $checks++
} finally {
    if ($null -ne $heldLock) { $heldLock.Dispose() }
    $testItem = Get-Item -LiteralPath $testRoot -Force
    if ($testItem.PSIsContainer -and -not ($testItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -Confirm:$false }
}
[pscustomobject]@{ passed = $checks; sessionProtocol = $state.protocol; sessionState = $state.state; inputDesktop = $state.inputDesktop; systemChanges = $false }
