[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Runtime.Common.ps1')
$script:checks = 0
$script:processRows = @()
$script:queryFails = $false
$utf8 = New-Object Text.UTF8Encoding($false)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('cua-child-' + [Guid]::NewGuid().ToString('N'))
$plugin = Join-Path $fixture 'plugin'
$runtime = Join-Path $fixture 'runtime'
$foreign = Join-Path $fixture 'foreign'
$userSid = Get-ChildRuntimeUserSid
$machineGuid = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid
$token = 'b' * 64
$executable = Join-Path $PSHOME 'powershell.exe'
$junctions = New-Object 'Collections.Generic.List[string]'

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Test failed: ' + $Message) }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $failed = $false
    try { $null = & $Action } catch { $failed = $true }
    Assert-Test $failed $Message
}

function Invoke-TestScript {
    param([string]$Name, [string[]]$Arguments = @(), [string]$InputJson = '')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $executable
    $parts = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + (Join-Path $PSScriptRoot $Name) + '"'))
    foreach ($argument in $Arguments) {
        if ($argument.Contains('"')) { throw 'Invalid test argument.' }
        $parts += '"' + $argument + '"'
    }
    $info.Arguments = $parts -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($info)
    try {
        if ($InputJson) {
            $inputBytes = $utf8.GetBytes($InputJson + "`n")
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) { throw 'A read-only/private-file test script exceeded its deadline.' }
        @{ exitCode = $process.ExitCode; stdout = $stdout.Result; stderr = $stderr.Result }
    } finally { $process.Dispose() }
}

function Install-TestRuntime {
    param([string]$Root = $runtime, [string]$Driver = $executable, [string]$Node = $executable)
    Invoke-TestScript 'Initialize-Runtime.ps1' @('-RuntimeRoot', $Root, '-PluginRoot', $plugin, '-DriverPath', $Driver, '-NodePath', $Node)
}

function New-TestRun {
    param([switch]$Config, [switch]$Metadata)
    $id = [Guid]::NewGuid().ToString('N')
    $root = Join-Path (Join-Path $runtime 'runs') $id
    $null = [IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root 'owner.token'), $token, $utf8)
    if ($Config) {
        Write-ChildRuntimeJson (Join-Path $root 'agent.json') @{
            version = 1; runId = $id; token = $token; expectedSessionId = 42
            expectedUserSid = $userSid; expectedMachineGuid = $machineGuid
            expectedSessionLogonTime = '134000000000000000'
        }
    }
    if ($Metadata) {
        foreach ($name in @('startup.json', 'ready.json')) {
            Write-ChildRuntimeJson (Join-Path $root $name) @{
                runId = $id; pid = 123456; sessionId = 42; userSid = $userSid; machineGuid = $machineGuid
                logonTime = '134000000000000000'; startedAt = '2026-01-01T00:00:00.0000000Z'
            }
        }
    }
    @{ id = $id; root = $root; agentPath = (Join-Path $root 'agent.json') }
}

function Get-CimInstance {
    param($ClassName, $Property, $OperationTimeoutSec, $ErrorAction)
    if ($script:queryFails) { throw 'Mocked process query failure.' }
    $script:processRows
}

try {
    $null = [IO.Directory]::CreateDirectory((Join-Path $plugin 'dist'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $plugin 'guest'))
    foreach ($name in @('dist\guest-agent.cjs', 'guest\Get-InteractiveState.ps1', 'guest\Start-Agent.ps1')) {
        [IO.File]::WriteAllText((Join-Path $plugin $name), 'fixture-only-never-executed', $utf8)
    }
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
        $syntaxTokens = $null
        $syntaxErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$syntaxTokens, [ref]$syntaxErrors)
        Assert-Test ($syntaxErrors.Count -eq 0) ('PowerShell syntax: ' + $file.Name)
        if ($file.Name -notlike 'Test-*' -and $file.Name -cne 'Launch-AgentTask.ps1') {
            # Launch-AgentTask.ps1 intentionally starts the staged agent through a temporary,
            # immediately deleted session-bound scheduled task (COM, no cmdlet, no persistence);
            # every other script must stay free of launch, persistence and system-change commands.
            $unsafeCalls = @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -match '^(Register-ScheduledTask|New-ScheduledTask|Start-Process|Stop-Process|New-Service|Start-Service|Set-Service|Set-ItemProperty|New-NetFirewallRule|Set-NetFirewallRule|Import-Certificate|Add-LocalGroupMember|Restart-Computer)$'
            }, $true))
            Assert-Test ($unsafeCalls.Count -eq 0) ('No launch, persistence, system-change or termination commands: ' + $file.Name)
        }
    }
    $result = Install-TestRuntime
    Assert-Test ($result.exitCode -eq 0) ('Fresh private runtime installation: ' + $result.stderr)
    $installed = $result.stdout | ConvertFrom-Json
    Assert-Test ($installed.installed -and $installed.userSid -ceq $userSid -and $installed.runtimeRoot -ieq $runtime) 'Installation identity result'
    $config = Read-ChildRuntimeJson (Join-Path $runtime 'guest-config.json')
    Assert-Test ($config.version -eq 1 -and $config.nodePath -ieq $executable -and $config.driverPath -ieq $executable -and $config.userSid -ceq $userSid) 'Guest config contract'
    foreach ($name in @('guest-agent.cjs', 'Get-InteractiveState.ps1', 'Start-Agent.ps1')) {
        Assert-Test ([IO.File]::ReadAllText((Join-Path $runtime $name)) -ceq 'fixture-only-never-executed') ('Runtime file copied: ' + $name)
    }
    foreach ($path in @($runtime, (Join-Path $runtime 'runs')) + @((Get-ChildItem -LiteralPath $runtime -File).FullName)) {
        $acl = Get-Acl -LiteralPath $path
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $outsiders = @($rules | Where-Object { $_.IdentityReference.Value -cnotin @($userSid, 'S-1-5-18', 'S-1-5-32-544') })
        Assert-Test ($outsiders.Count -eq 0 -and $rules.Count -ge 3) 'Only current user, SYSTEM and Administrators can access runtime content'
    }
    Assert-Test ((Get-Acl -LiteralPath $runtime).AreAccessRulesProtected) 'Root ACL inheritance disabled'
    [IO.File]::WriteAllText((Join-Path $runtime 'session-owner.json'), '{"test":true}', $utf8)
    [IO.File]::WriteAllText((Join-Path $plugin 'dist\guest-agent.cjs'), 'updated-fixture-never-executed', $utf8)
    $result = Invoke-TestScript 'Initialize-Runtime.ps1' @('-RuntimeRoot', $runtime, '-PluginRoot', $plugin, '-DriverPath', $executable, '-NodePath', $executable, '-Verbose')
    Assert-Test ($result.exitCode -eq 0 -and [IO.File]::ReadAllText((Join-Path $runtime 'guest-agent.cjs')) -ceq 'updated-fixture-never-executed') ('Owned idle installation updates: ' + $result.stderr + $result.stdout)
    Assert-Test ([IO.File]::ReadAllText((Join-Path $runtime 'session-owner.json')) -ceq '{"test":true}') 'Parent ownership record preserved'
    $installLock = [IO.File]::Open((Join-Path $runtime 'install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $result = Install-TestRuntime
        Assert-Test ($result.exitCode -ne 0 -and $result.stderr.Contains('installation is in progress')) 'Competing runtime installers are refused'
    } finally {
        $installLock.Dispose()
        [IO.File]::Delete((Join-Path $runtime 'install.lock'))
    }
    $null = [IO.Directory]::CreateDirectory($foreign)
    [IO.File]::WriteAllText((Join-Path $foreign 'keep.txt'), 'foreign-user-data', $utf8)
    $result = Install-TestRuntime $foreign
    Assert-Test ($result.exitCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $foreign 'keep.txt')) -ceq 'foreign-user-data') 'Foreign nonempty root refused without changing files'
    $emptyRoot = Join-Path $fixture 'empty'
    $null = [IO.Directory]::CreateDirectory($emptyRoot)
    $result = Install-TestRuntime $emptyRoot
    Assert-Test ($result.exitCode -eq 0) ('Current-user-owned empty root accepted: ' + $result.stderr)
    $owner = Read-ChildRuntimeJson (Join-Path $runtime 'runtime-owner.json')
    $owner.userSid = 'S-1-5-18'
    Write-ChildRuntimeJson (Join-Path $runtime 'runtime-owner.json') $owner
    $result = Install-TestRuntime
    Assert-Test ($result.exitCode -ne 0) 'Different-user ownership marker refused'
    $owner.userSid = $userSid
    Write-ChildRuntimeJson (Join-Path $runtime 'runtime-owner.json') $owner
    $result = Install-TestRuntime $runtime (Join-Path $fixture 'missing.exe')
    Assert-Test ($result.exitCode -ne 0) 'Missing driver path refused'
    foreach ($path in @('C:\', 'relative', 'C:\bad..\..\runtime', 'C:\bad\CON', 'C:\bad\name.', 'C:\bad\a&b', 'C:\bad\name ', ('C:\' + ('x' * 158)))) {
        Assert-Throws { Assert-ChildRuntimePath $path } ('Unsafe runtime root refused: ' + $path)
    }
    $run = New-TestRun
    $result = Install-TestRuntime
    Assert-Test ($result.exitCode -ne 0 -and (Test-Path -LiteralPath $run.root)) 'Any existing run prevents runtime update'
    Assert-Throws { Stop-ChildRuntimeAgent $runtime $run.id ('c' * 64) -WaitSeconds 0 } 'Wrong owner token refused'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $run.root 'stop.requested'))) 'Wrong token does not request stop'
    Assert-Throws { Stop-ChildRuntimeAgent $runtime $run.id ('B' * 64) -WaitSeconds 0 } 'Uppercase ownership token refused'
    Assert-Throws { Stop-ChildRuntimeAgent $runtime '../foreign' $token -WaitSeconds 0 } 'Run traversal refused'
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test ($result.stopped -and -not $result.retained -and -not (Test-Path -LiteralPath $run.root)) 'Incomplete staging safely removed using token ownership'
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test ($result.stopped -and -not $result.retained) 'Already-removed run confirms no matching process'
    $run = New-TestRun -Config -Metadata
    $lock = [IO.File]::Open((Join-Path $run.root 'bootstrap.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
        Assert-Test (-not $result.stopped -and $result.retained) 'Live bootstrap lifetime lock prevents cleanup'
        Assert-Test ((Test-Path -LiteralPath (Join-Path $run.root 'stop.requested')) -and (Test-Path -LiteralPath $run.agentPath)) 'Stop marker set while all active run data stays in place'
    } finally { $lock.Dispose() }
    $script:processRows = @([pscustomobject]@{ ProcessId = 123456; SessionId = 42; CommandLine = ('node.exe guest-agent.cjs --config "' + $run.agentPath + '"') })
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test (-not $result.stopped -and $result.retained -and (Test-Path -LiteralPath $run.root)) 'Actual config command line prevents cleanup even without bootstrap lock'
    $script:processRows = @([pscustomobject]@{ ProcessId = 123456; SessionId = 0; CommandLine = $null })
    Assert-Throws { Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0 } 'Unreadable recorded process identity fails closed'
    Assert-Test (Test-Path -LiteralPath $run.agentPath) 'Query uncertainty preserves run config'
    $script:processRows = @([pscustomobject]@{ ProcessId = 123456; SessionId = 42; CommandLine = ('node.exe --config "' + $run.agentPath + '.different"') })
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test ($result.stopped -and -not $result.retained) 'Reused PID with different exact config argument is not the agent'
    $script:processRows = @()
    $run = New-TestRun -Config
    $script:queryFails = $true
    Assert-Throws { Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0 } 'Process enumeration failures are not successful cleanup'
    $script:queryFails = $false
    Assert-Test (Test-Path -LiteralPath $run.root) 'Enumeration failure retains files'
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test $result.stopped 'Cleanup can retry after a transient query failure'
    $run = New-TestRun -Config -Metadata
    $ready = Read-ChildRuntimeJson (Join-Path $run.root 'ready.json')
    $ready.sessionId = 43
    Write-ChildRuntimeJson (Join-Path $run.root 'ready.json') $ready
    Assert-Throws { Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0 } 'Mismatched ready session refused'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $run.root 'stop.requested'))) 'Untrusted session metadata is not used to request stop'
    $ready.sessionId = 42
    $ready.logonTime = '134000000000000001'
    Write-ChildRuntimeJson (Join-Path $run.root 'ready.json') $ready
    Assert-Throws { Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0 } 'Recycled session generation in ready metadata is rejected'
    $ready.logonTime = '134000000000000000'
    Write-ChildRuntimeJson (Join-Path $run.root 'ready.json') $ready
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test $result.stopped 'Matching startup and ready identity permit exited-agent cleanup'
    foreach ($kind in @('file', 'directory')) {
        $run = New-TestRun -Config
        $unknown = Join-Path $run.root 'keep-unknown'
        if ($kind -eq 'file') { [IO.File]::WriteAllText($unknown, 'do-not-delete', $utf8) }
        else { $null = [IO.Directory]::CreateDirectory($unknown) }
        $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
        Assert-Test (-not $result.stopped -and $result.retained -and (Test-Path -LiteralPath $unknown)) ('Unknown ' + $kind + ' prevents all cleanup')
        Assert-Test (Test-Path -LiteralPath $run.agentPath) 'Unexpected run contents preserve existing agent metadata'
        if ($kind -eq 'file') { [IO.File]::Delete($unknown) } else { [IO.Directory]::Delete($unknown, $false) }
        $null = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    }
    $run = New-TestRun -Config
    $tombstone = $run.root + '.stopping'
    [IO.File]::WriteAllText((Join-Path $run.root 'stop.requested'), 'test-stop', $utf8)
    [IO.Directory]::Move($run.root, $tombstone)
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test ($result.stopped -and -not (Test-Path -LiteralPath $tombstone)) 'Interrupted atomic cleanup resumes from owned stopping directory'
    $run = New-TestRun -Config
    $temporary = Join-Path $run.root ('ready.json.123.' + [Guid]::NewGuid().ToString() + '.tmp')
    [IO.File]::WriteAllText($temporary, 'interrupted-owned-json-write', $utf8)
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test $result.stopped 'Known atomic JSON temporary filename can be removed'
    $run = New-TestRun -Config
    $junction = Join-Path $run.root 'linked-folder'
    $null = New-Item -ItemType Junction -Path $junction -Value $foreign
    $junctions.Add($junction)
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test (-not $result.stopped -and $result.retained -and [IO.File]::ReadAllText((Join-Path $foreign 'keep.txt')) -ceq 'foreign-user-data') 'Linked content inside a run is not traversed or deleted'
    [IO.Directory]::Delete($junction, $false)
    $null = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    $junction = Join-Path $fixture 'linked-root'
    $null = New-Item -ItemType Junction -Path $junction -Value $foreign
    $junctions.Add($junction)
    $result = Install-TestRuntime (Join-Path $junction 'nested')
    Assert-Test ($result.exitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $foreign 'nested'))) 'Linked ancestor refuses installation before writing'
    $result = Install-TestRuntime $junction
    Assert-Test ($result.exitCode -ne 0) 'Linked runtime root refused'
    [IO.Directory]::Delete($junction, $false)
    $binaryDirectory = Join-Path $fixture 'binaries'
    $null = [IO.Directory]::CreateDirectory($binaryDirectory)
    $unicodeName = ([string][char]0x6d4b) + ([string][char]0x8bd5) + '.exe'
    [IO.File]::WriteAllText((Join-Path $binaryDirectory $unicodeName), 'fixture-executable-never-run', $utf8)
    $junction = Join-Path $fixture 'binary-link'
    $null = New-Item -ItemType Junction -Path $junction -Value $binaryDirectory
    $junctions.Add($junction)
    $result = Install-TestRuntime $runtime (Join-Path $junction $unicodeName) (Join-Path $binaryDirectory $unicodeName)
    Assert-Test ($result.exitCode -eq 0) ('Executable paths may be Unicode and live under a junction: ' + $result.stderr)
    [IO.Directory]::Delete($junction, $false)
    $longRoot = Join-Path $fixture ('x' * (160 - $fixture.Length - 1))
    $result = Install-TestRuntime $longRoot
    Assert-Test ($result.exitCode -eq 0 -and $longRoot.Length -eq 160) ('Maximum supported runtime root length: ' + $result.stderr)
    $shortRoot = $runtime
    $runtime = $longRoot
    $run = New-TestRun -Config
    $result = Stop-ChildRuntimeAgent $runtime $run.id $token -WaitSeconds 0
    Assert-Test $result.stopped 'Run paths may extend beyond the runtime root length limit'
    $runtime = $shortRoot
    $result = Invoke-TestScript 'Get-AgentProcess.ps1' @('-ProcessId', [string]$PID)
    Assert-Test ($result.exitCode -eq 0) ('Read-only process identity: ' + $result.stderr)
    $identity = $result.stdout | ConvertFrom-Json
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        Assert-Test ($identity.pid -eq $PID -and $identity.sessionId -eq $self.SessionId) 'Inspector reports actual OS PID and session'
        Assert-Test ($identity.startedAt -ceq $self.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)) 'Inspector uses actual UTC creation timestamp'
    } finally { $self.Dispose() }
    $result = Invoke-TestScript 'Get-AgentProcess.ps1' @('-ProcessId', '2147483647')
    Assert-Test ($result.exitCode -ne 0 -and [string]::IsNullOrWhiteSpace($result.stdout)) 'Missing process is an error, not a fabricated identity'
    $run = New-TestRun
    $result = Invoke-TestScript 'Stop-Agent.ps1' @('-RuntimeRoot', $runtime, '-RunId', $run.id) ('{"token":"' + ('c' * 64) + '"}')
    $stopped = $result.stdout | ConvertFrom-Json
    Assert-Test ($result.exitCode -ne 0 -and -not $stopped.stopped -and $stopped.retained -and (Test-Path -LiteralPath $run.root)) 'CLI rejects wrong stdin token and preserves files'
    $result = Invoke-TestScript 'Stop-Agent.ps1' @('-RuntimeRoot', $runtime, '-RunId', $run.id) ('{"token":"' + $token + '"}')
    Assert-Test ($result.exitCode -eq 0) ('Valid stdin token cleanup diagnostics: ' + $result.stdout + $result.stderr)
    $stopped = $result.stdout | ConvertFrom-Json
    Assert-Test ($result.exitCode -eq 0 -and $stopped.stopped -and -not $stopped.retained -and -not (Test-Path -LiteralPath $run.root)) ('CLI accepts stdin token and confirms cleanup: ' + $result.stderr + $result.stdout)
    Assert-Test (-not $result.stdout.Contains($token) -and -not $result.stderr.Contains($token)) 'CLI never echoes ownership token'
    $run = New-TestRun
    $result = Invoke-TestScript 'Stop-Agent.ps1' @('-RuntimeRoot', $runtime, '-RunId', $run.id) (([string][char]0xFEFF) + '{"token":"' + $token + '"}')
    Assert-Test ($result.exitCode -eq 0 -and ($result.stdout | ConvertFrom-Json).stopped) 'CLI also accepts a UTF-8 BOM before the stdin JSON envelope'
    $result = Invoke-TestScript 'Stop-Agent.ps1' @('-RuntimeRoot', $runtime, '-RunId', $run.id) '{"token":123}'
    Assert-Test ($result.exitCode -ne 0 -and ($result.stdout | ConvertFrom-Json).retained) 'Malformed stdin token is a retained failure'
    # The task launcher is only exercised through its validation failures: a success path
    # would register a real scheduled task, which offline tests never do.
    $run = New-TestRun -Config
    $result = Invoke-TestScript 'Launch-AgentTask.ps1' @('-ChildSessionId', '42', '-RuntimeRoot', $runtime, '-RunId', ('Z' * 32))
    Assert-Test ($result.exitCode -ne 0) 'Task launcher rejects a non-hex run id'
    $bare = New-TestRun
    $result = Invoke-TestScript 'Launch-AgentTask.ps1' @('-ChildSessionId', '42', '-RuntimeRoot', $runtime, '-RunId', $bare.id)
    Assert-Test ($result.exitCode -ne 0) 'Task launcher refuses a run staged without an agent config'
    $result = Invoke-TestScript 'Launch-AgentTask.ps1' @('-ChildSessionId', '7', '-RuntimeRoot', $runtime, '-RunId', $run.id)
    Assert-Test ($result.exitCode -ne 0) 'Task launcher refuses a mismatched child session id'
    $result = Invoke-TestScript 'Launch-AgentTask.ps1' @('-ChildSessionId', '42', '-RuntimeRoot', '../foreign', '-RunId', $run.id)
    Assert-Test ($result.exitCode -ne 0) 'Task launcher refuses traversal runtime roots'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $run.root 'bootstrap.started'))) 'Task launcher validation never starts the agent'
    @{ passed = $true; checks = $script:checks; realChildSessionActions = 0; realDriverLaunches = 0; systemSettingsChanged = $false } | ConvertTo-Json -Compress
} finally {
    foreach ($junction in $junctions) {
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) }
    }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -Confirm:$false }
}
