Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.ps1')

function Get-ChildRuntimeUserSid {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Assert-ChildRuntimePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-CuaRdpGuestRoot $Path
    Assert-ChildRuntimeDirectory $full
}

function Assert-ChildRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw '[cua-rdp] Runtime directories and their ancestors must not be files or directory links.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    $full
}

function Assert-ChildRuntimeFile {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Optional)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Optional) { return }
        throw '[cua-rdp] A required runtime file is missing.'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '[cua-rdp] Runtime files must be ordinary files, not links or directories.'
    }
}

function Set-ChildRuntimePrivateAcl {
    param([string]$Path, [string]$UserSid, [switch]$Directory)
    if ($Directory) {
        $null = Assert-ChildRuntimeDirectory $Path
        $null = [IO.Directory]::CreateDirectory($Path)
        $security = [IO.Directory]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        Assert-ChildRuntimeFile $Path
        $security = [IO.File]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $security.SetAccessRuleProtection($true, $false)
    foreach ($rule in $security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) {
        $security.RemoveAccessRuleSpecific($rule)
    }
    foreach ($sid in @($UserSid, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    if ($Directory) { [IO.Directory]::SetAccessControl($Path, $security) }
    else { [IO.File]::SetAccessControl($Path, $security) }
}

function Read-ChildRuntimeJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-ChildRuntimeFile $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 65536) { throw '[cua-rdp] Runtime metadata is too large.' }
    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $value -or $value -is [array] -or $value -isnot [pscustomobject]) {
        throw '[cua-rdp] Runtime metadata must be a JSON object.'
    }
    $value
}

function Get-ChildRuntimeProperty {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name }
}

function Write-ChildRuntimeJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    Assert-ChildRuntimeFile $Path -Optional
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12 -Compress))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Assert-ChildRuntimeOwner {
    param([Parameter(Mandatory = $true)][string]$Root)
    $owner = Read-ChildRuntimeJson (Join-Path $Root 'runtime-owner.json')
    if ((Get-ChildRuntimeProperty $owner 'version') -ne 1 -or
        (Get-ChildRuntimeProperty $owner 'kind') -cne 'cua-rdp-child-runtime' -or
        (Get-ChildRuntimeProperty $owner 'userSid') -cne (Get-ChildRuntimeUserSid) -or
        (Get-ChildRuntimeProperty $owner 'root') -ine $Root) {
        throw '[cua-rdp] This runtime directory does not belong to the current user and Child Session backend.'
    }
    $owner
}

function Find-ChildRunProcesses {
    param([Parameter(Mandatory = $true)][string]$AgentPath, [int[]]$KnownPids = @())
    $rows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, SessionId, CommandLine -OperationTimeoutSec 2 -ErrorAction Stop)
    $pattern = '(?i)(?:^|\s)--config\s+(?:"' + [regex]::Escape($AgentPath) + '"|' + [regex]::Escape($AgentPath) + ')(?=\s|$)'
    foreach ($row in $rows) {
        $command = [string]$row.CommandLine
        if (-not [string]::IsNullOrEmpty($command)) {
            if ($command -match $pattern) { $row }
        } elseif ([int]$row.ProcessId -in $KnownPids) {
            throw '[cua-rdp] The recorded agent process is still present but its identity cannot be verified.'
        }
    }
}

function Test-ChildRunFileName {
    param([string]$Name)
    if ($Name -cin @('owner.token', 'agent.json', 'ready.json', 'startup.json', 'startup.json.tmp',
        'bootstrap.lock', 'bootstrap.started', 'bootstrap-error.txt', 'agent.stdout.log', 'agent.stderr.log', 'stop.requested')) {
        return $true
    }
    $Name -cmatch '^(agent|ready|startup)\.json\.[0-9]+\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$'
}

function Stop-ChildRuntimeAgent {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Token,
        [ValidateRange(0, 10)][int]$WaitSeconds = 10
    )
    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or $Token -cnotmatch '^[0-9a-f]{64}$') {
        throw '[cua-rdp] Invalid run ownership identifier.'
    }
    $root = Assert-ChildRuntimePath $RuntimeRoot
    $null = Assert-ChildRuntimeOwner $root
    $runsRoot = Assert-ChildRuntimeDirectory (Join-Path $root 'runs')
    $originalRunRoot = Join-Path $runsRoot $RunId
    $tombstoneRoot = $originalRunRoot + '.stopping'
    $agentPath = Join-Path $originalRunRoot 'agent.json'
    if ((Test-Path -LiteralPath $originalRunRoot) -and (Test-Path -LiteralPath $tombstoneRoot)) {
        throw '[cua-rdp] Conflicting run directories were retained for inspection.'
    }
    $runRoot = $originalRunRoot
    if (-not (Test-Path -LiteralPath $runRoot) -and (Test-Path -LiteralPath $tombstoneRoot)) { $runRoot = $tombstoneRoot }
    if (-not (Test-Path -LiteralPath $runRoot)) {
        if (@(Find-ChildRunProcesses $agentPath).Count -gt 0) {
            return @{ stopped = $false; retained = $true; reason = 'agent-still-running' }
        }
        return @{ stopped = $true; retained = $false }
    }
    $null = Assert-ChildRuntimeDirectory $runRoot
    $ownerPath = Join-Path $runRoot 'owner.token'
    Assert-ChildRuntimeFile $ownerPath
    if ((Get-Item -LiteralPath $ownerPath).Length -ne 64 -or [IO.File]::ReadAllText($ownerPath) -cne $Token) {
        throw '[cua-rdp] Run ownership does not match; stop and cleanup were not attempted.'
    }
    $knownPids = @()
    $agent = $null
    $configPath = Join-Path $runRoot 'agent.json'
    if (Test-Path -LiteralPath $configPath) {
        $agent = Read-ChildRuntimeJson $configPath
        if ((Get-ChildRuntimeProperty $agent 'version') -ne 1 -or
            (Get-ChildRuntimeProperty $agent 'runId') -cne $RunId -or
            (Get-ChildRuntimeProperty $agent 'token') -cne $Token -or
            (Get-ChildRuntimeProperty $agent 'expectedUserSid') -cne (Get-ChildRuntimeUserSid) -or
            (Get-ChildRuntimeProperty $agent 'expectedMachineGuid') -ine (Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid) -or
            (Get-ChildRuntimeProperty $agent 'expectedSessionId') -isnot [int] -or
            $agent.expectedSessionId -le 0) {
            throw '[cua-rdp] The run configuration does not match this runtime ownership.'
        }
    }
    foreach ($name in @('startup.json', 'ready.json')) {
        $metadataPath = Join-Path $runRoot $name
        if (-not (Test-Path -LiteralPath $metadataPath)) { continue }
        try { $metadata = Read-ChildRuntimeJson $metadataPath }
        catch {
            if (Test-Path -LiteralPath $metadataPath) { throw }
            continue
        }
        if ((Get-ChildRuntimeProperty $metadata 'runId') -cne $RunId -or
            (Get-ChildRuntimeProperty $metadata 'pid') -isnot [int] -or $metadata.pid -le 0 -or
            (Get-ChildRuntimeProperty $metadata 'userSid') -cne (Get-ChildRuntimeUserSid) -or
            (Get-ChildRuntimeProperty $metadata 'sessionId') -isnot [int] -or $metadata.sessionId -le 0) {
            throw '[cua-rdp] Agent process metadata does not match the owned run.'
        }
        if ($null -ne $agent -and ($metadata.sessionId -ne $agent.expectedSessionId -or
            (Get-ChildRuntimeProperty $metadata 'machineGuid') -ine (Get-ChildRuntimeProperty $agent 'expectedMachineGuid') -or
            ($null -ne (Get-ChildRuntimeProperty $agent 'expectedSessionLogonTime') -and
                (Get-ChildRuntimeProperty $metadata 'logonTime') -cne $agent.expectedSessionLogonTime))) {
            throw '[cua-rdp] Agent process metadata identifies a different session, logon generation or machine.'
        }
        $knownPids += [int]$metadata.pid
    }
    $stopPath = Join-Path $runRoot 'stop.requested'
    Assert-ChildRuntimeFile $stopPath -Optional
    if (-not [IO.File]::Exists($stopPath)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes([DateTime]::UtcNow.ToString('o'))
        $marker = [IO.File]::Open($stopPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $marker.Write($bytes, 0, $bytes.Length) } finally { $marker.Dispose() }
    }
    $lockPath = Join-Path $runRoot 'bootstrap.lock'
    Assert-ChildRuntimeFile $lockPath -Optional
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $lock = $null
        try {
            try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] { }
            if ($null -ne $lock) {
                if (@(Find-ChildRunProcesses $agentPath $knownPids).Count -eq 0) {
                    Assert-ChildRuntimeFile $ownerPath
                    if ([IO.File]::ReadAllText($ownerPath) -cne $Token) { throw '[cua-rdp] Run ownership changed during cleanup.' }
                    $children = @(Get-ChildItem -LiteralPath $runRoot -Force)
                    foreach ($child in $children) {
                        if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                            -not (Test-ChildRunFileName $child.Name)) {
                            return @{ stopped = $false; retained = $true; reason = 'unexpected-run-content' }
                        }
                    }
                    # Keep the stop marker until the bootstrap path disappears atomically.
                    $lock.Dispose()
                    $lock = $null
                    try {
                        if ($runRoot -ine $tombstoneRoot) {
                            $null = Assert-ChildRuntimeDirectory $tombstoneRoot
                            [IO.Directory]::Move($runRoot, $tombstoneRoot)
                            $runRoot = $tombstoneRoot
                            $ownerPath = Join-Path $runRoot 'owner.token'
                            $stopPath = Join-Path $runRoot 'stop.requested'
                        }
                        $children = @(Get-ChildItem -LiteralPath $runRoot -Force)
                        foreach ($child in $children) {
                            if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                                -not (Test-ChildRunFileName $child.Name)) {
                                return @{ stopped = $false; retained = $true; reason = 'run-content-changed' }
                            }
                        }
                        foreach ($child in $children | Where-Object { $_.Name -cnotin @('owner.token', 'stop.requested') }) {
                            Assert-ChildRuntimeFile $child.FullName
                            [IO.File]::Delete($child.FullName)
                        }
                        $remaining = @(Get-ChildItem -LiteralPath $runRoot -Force)
                        if (@($remaining | Where-Object { $_.Name -cnotin @('owner.token', 'stop.requested') }).Count -gt 0) {
                            return @{ stopped = $false; retained = $true; reason = 'run-content-changed' }
                        }
                        [IO.File]::Delete($stopPath)
                        [IO.File]::Delete($ownerPath)
                        [IO.Directory]::Delete($runRoot, $false)
                        return @{ stopped = $true; retained = $false }
                    } catch [IO.IOException] {
                        return @{ stopped = $false; retained = $true; reason = 'run-files-still-open' }
                    } catch [UnauthorizedAccessException] {
                        return @{ stopped = $false; retained = $true; reason = 'run-files-not-removable' }
                    }
                }
            }
        } finally { if ($null -ne $lock) { $lock.Dispose() } }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 200
    } while ($true)
    @{ stopped = $false; retained = $true; reason = 'agent-or-bootstrap-still-running'; leaseMs = 180000 }
}
