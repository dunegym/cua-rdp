[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$OwnerPid
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Common.ps1')
$session = $null
$runs = @{}
$prepared = $false

function Assert-Owner {
    if (-not (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)) {
        throw '[cua-rdp] The owning MCP process has exited.'
    }
}

function Assert-Prepared {
    Assert-Owner
    if (-not $script:prepared -or $null -eq $script:session -or $script:session.State -ne 'Opened') {
        throw '[cua-rdp] The guest connection is not prepared or has closed.'
    }
}

function Assert-RunId {
    param([string]$RunId)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw '[cua-rdp] Invalid run identifier.' }
}

function Get-OwnedRun {
    param([string]$RunId)
    Assert-RunId $RunId
    if (-not $script:runs.ContainsKey($RunId)) { throw '[cua-rdp] This broker does not own the requested run.' }
    $script:runs[$RunId]
}

function Invoke-GuestHttp {
    param($Run, [string]$Operation, $Payload)
    if ($null -eq $Run.ready) { throw '[cua-rdp] The guest agent is not attached.' }
    if ($Payload -is [string]) { $body = $Payload }
    else { $body = ConvertTo-Json -InputObject $Payload -Depth 100 -Compress }
    $responseId = [Guid]::NewGuid().ToString('N')
    $memory = New-Object IO.MemoryStream
    try {
        $descriptor = Invoke-Command -Session $script:session -ArgumentList $script:config.guestRoot, $Run.runId, $responseId, ([int]$Run.ready.port), $Run.token, $Operation, $body -ScriptBlock {
            param($Root, $Id, $ResponseId, $Port, $Token, $Operation, $Body)
            $ErrorActionPreference = 'Stop'
            $request = [Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}/{1}' -f $Port, $Operation))
            $request.Method = 'POST'
            $request.Proxy = $null
            $request.AllowAutoRedirect = $false
            $timeout = 120000
            if ($Operation -eq 'shutdown') { $timeout = 5000 }
            $request.Timeout = $timeout
            $request.ReadWriteTimeout = $timeout
            $request.ContentType = 'application/json; charset=utf-8'
            $request.Headers['Authorization'] = 'Bearer ' + $Token
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentLength = $bytes.Length
            $requestStream = $request.GetRequestStream()
            try { $requestStream.Write($bytes, 0, $bytes.Length) } finally { $requestStream.Dispose() }
            $response = $request.GetResponse()
            try {
                if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 67108864) { throw 'Invalid guest response.' }
                $responsePath = Join-Path (Join-Path (Join-Path $Root 'runs') $Id) ('response-' + $ResponseId + '.json')
                $file = [IO.File]::Open($responsePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $stream = $response.GetResponseStream()
                $total = 0
                try {
                    $buffer = New-Object byte[] 32768
                    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $total += $count
                        if ($total -gt 67108864) { throw 'Guest response is too large.' }
                        $file.Write($buffer, 0, $count)
                    }
                } finally { $stream.Dispose(); $file.Dispose() }
                @{ bytes = $total }
            } finally { $response.Dispose() }
        }
        if ($descriptor.bytes -lt 1 -or $descriptor.bytes -gt 67108864) { throw '[cua-rdp] Invalid guest response size.' }
        # PowerShell Direct has no SessionOption size knobs; each transfer stays below default object/data quotas.
        $lastRenewed = [DateTime]::UtcNow
        for ($offset = 0; $offset -lt $descriptor.bytes; $offset += 262144) {
            Assert-Owner
            $length = [Math]::Min(262144, [int]$descriptor.bytes - $offset)
            $renewLease = $Operation -ne 'shutdown' -and ([DateTime]::UtcNow - $lastRenewed).TotalSeconds -ge 20
            $chunk = Invoke-Command -Session $script:session -ArgumentList $script:config.guestRoot, $Run.runId, $responseId, $offset, $length, $renewLease, ([int]$Run.ready.port), $Run.token -ScriptBlock {
                param($Root, $Id, $ResponseId, $Offset, $Length, $RenewLease, $Port, $Token)
                $ErrorActionPreference = 'Stop'
                if ($RenewLease) {
                    $heartbeat = [Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}/health' -f $Port))
                    $heartbeat.Method = 'POST'
                    $heartbeat.Proxy = $null
                    $heartbeat.AllowAutoRedirect = $false
                    $heartbeat.Timeout = 10000
                    $heartbeat.ReadWriteTimeout = 10000
                    $heartbeat.ContentLength = 0
                    $heartbeat.Headers['Authorization'] = 'Bearer ' + $Token
                    $heartbeatResponse = $heartbeat.GetResponse()
                    try {
                        $reader = New-Object IO.StreamReader($heartbeatResponse.GetResponseStream(), [Text.Encoding]::UTF8)
                        try { $health = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                        if ($null -ne $health.error -or $health.result.runId -cne $Id -or $health.result.protocol -ne 2 -or $health.result.state -ne 0 -or $health.result.inputDesktop -cne 'Default') {
                            throw '[cua-rdp] Guest session became unavailable while transferring the response; the original action was not replayed.'
                        }
                    } finally { $heartbeatResponse.Dispose() }
                }
                $path = Join-Path (Join-Path (Join-Path $Root 'runs') $Id) ('response-' + $ResponseId + '.json')
                $stream = [IO.File]::OpenRead($path)
                try {
                    if ($Offset -lt 0 -or $Length -lt 1 -or $Length -gt 262144 -or ($Offset + $Length) -gt $stream.Length) { throw 'Invalid response chunk.' }
                    $null = $stream.Seek($Offset, [IO.SeekOrigin]::Begin)
                    $buffer = New-Object byte[] $Length
                    $position = 0
                    while ($position -lt $Length) {
                        $count = $stream.Read($buffer, $position, $Length - $position)
                        if ($count -eq 0) { throw 'Truncated response chunk.' }
                        $position += $count
                    }
                    [Convert]::ToBase64String($buffer)
                } finally { $stream.Dispose() }
            }
            if ($renewLease) { $lastRenewed = [DateTime]::UtcNow }
            $bytes = [Convert]::FromBase64String([string]$chunk)
            if ($bytes.Length -ne $length) { throw '[cua-rdp] Guest response transfer was truncated.' }
            $memory.Write($bytes, 0, $bytes.Length)
        }
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $encoding.GetString($memory.ToArray())
    } finally {
        $memory.Dispose()
        if ($null -ne $script:session -and $script:session.State -eq 'Opened') {
            try {
                Invoke-Command -Session $script:session -ArgumentList $script:config.guestRoot, $Run.runId, $responseId -ScriptBlock {
                    param($Root, $Id, $ResponseId)
                    $path = Join-Path (Join-Path (Join-Path $Root 'runs') $Id) ('response-' + $ResponseId + '.json')
                    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -Confirm:$false }
                }
            } catch { }
        }
    }
}

function Stop-OwnedRun {
    param([string]$RunId)
    $run = Get-OwnedRun $RunId
    if ($null -eq $script:session -or $script:session.State -ne 'Opened') {
        return @{ stopped = $false; retained = $true; leaseMs = 180000 }
    }
    $discovered = Invoke-Command -Session $script:session -ArgumentList $script:config.guestRoot, $RunId, $run.token, $script:config.guestMachineGuid, $script:guestUserSid, $run.identity -ScriptBlock {
        param($Root, $Id, $Token, $MachineGuid, $UserSid, $KnownIdentity)
        $ErrorActionPreference = 'Stop'
        $path = Join-Path (Join-Path $Root 'runs') $Id
        if (-not (Test-Path -LiteralPath $path)) { return @{ exists = $false; owned = $true } }
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '[cua-rdp] Refusing cleanup of a linked or invalid run directory.' }
        $ownerPath = Join-Path $path 'owner.token'
        if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return @{ exists = $true; owned = $false } }
        if ((Get-Item -LiteralPath $ownerPath).Length -ne 64 -or [IO.File]::ReadAllText($ownerPath) -cne $Token) { throw '[cua-rdp] Run ownership metadata does not match; cleanup was not attempted.' }
        [IO.File]::WriteAllText((Join-Path $path 'stop.requested'), [DateTime]::UtcNow.ToString('o'), (New-Object Text.UTF8Encoding($false)))
        $identity = $null
        $ready = $null
        $agentPath = Join-Path $path 'agent.json'
        if (Test-Path -LiteralPath $agentPath -PathType Leaf) {
            if ((Get-Item -LiteralPath $agentPath).Length -gt 16384) { throw '[cua-rdp] Invalid run configuration size.' }
            $agent = Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($agent.runId -cne $Id -or $agent.token -cne $Token -or $agent.expectedMachineGuid -ine $MachineGuid -or $agent.expectedUserSid -ne $UserSid -or $agent.expectedSessionId -le 0) {
                throw '[cua-rdp] Run configuration does not match this broker ownership.'
            }
            if ($null -ne $KnownIdentity -and $agent.expectedSessionId -ne $KnownIdentity.sessionId) { throw '[cua-rdp] The staged session identity changed.' }
            $identity = @{ machineGuid = $MachineGuid; userSid = $UserSid; sessionId = [int]$agent.expectedSessionId }
            $readyPath = Join-Path $path 'ready.json'
            if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
                try {
                    if ((Get-Item -LiteralPath $readyPath).Length -gt 16384) { throw '[cua-rdp] Invalid readiness descriptor size.' }
                    $ready = Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                } catch {
                    if (Test-Path -LiteralPath $readyPath) { throw }
                    $ready = $null
                }
                if ($null -ne $ready -and ($ready.runId -cne $Id -or $ready.sessionId -ne $identity.sessionId -or $ready.userSid -ne $UserSid -or $ready.machineGuid -ine $MachineGuid -or $ready.port -lt 1024 -or $ready.port -gt 65535 -or $ready.pid -le 0)) {
                    throw '[cua-rdp] Guest readiness descriptor does not match the owned RDP run.'
                }
            }
        }
        @{ exists = $true; owned = $true; identity = $identity; ready = $ready }
    }
    if (-not $discovered.exists) {
        $script:runs.Remove($RunId)
        return @{ stopped = $true; retained = $false }
    }
    if (-not $discovered.owned) { return @{ stopped = $false; retained = $true; reason = 'ownership-metadata-incomplete' } }
    if ($null -ne $discovered.identity) { $run.identity = $discovered.identity }
    if ($null -ne $discovered.ready) { $run.ready = $discovered.ready }
    if ($null -ne $run.ready) { try { $null = Invoke-GuestHttp $run 'shutdown' @{} } catch { } }
    $cleanup = Invoke-Command -Session $script:session -ArgumentList $script:config.guestRoot, $RunId, $run.token -ScriptBlock {
        param($Root, $Id, $Token)
        $ErrorActionPreference = 'Stop'
        $path = Join-Path (Join-Path $Root 'runs') $Id
        if (-not (Test-Path -LiteralPath $path)) { return @{ stopped = $true; retained = $false } }
        $ownerPath = Join-Path $path 'owner.token'
        if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf) -or [IO.File]::ReadAllText($ownerPath) -cne $Token) { throw '[cua-rdp] Run ownership changed during cleanup.' }
        $agentPath = Join-Path $path 'agent.json'
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            $lock = $null
            try {
                $lock = [IO.File]::Open((Join-Path $path 'bootstrap.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch [IO.IOException] { }
            if ($null -ne $lock) {
                try {
                    $live = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($agentPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                    if ($live.Count -eq 0) {
                        foreach ($child in Get-ChildItem -LiteralPath $path -Force) {
                            if ($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '[cua-rdp] Unexpected content in the run directory; cleanup was not attempted.' }
                        }
                        # The stop marker prevents a new bootstrap after the lifetime lock is released.
                        $lock.Dispose()
                        $lock = $null
                        Remove-Item -LiteralPath $path -Recurse -Force -Confirm:$false
                        return @{ stopped = $true; retained = $false }
                    }
                } finally { if ($null -ne $lock) { $lock.Dispose() } }
            }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        @{ stopped = $false; retained = $true; leaseMs = 180000 }
    }
    if ($cleanup.stopped -eq $true -and $cleanup.retained -eq $false) { $script:runs.Remove($RunId) }
    $cleanup
}

try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.version -ne 1) { throw '[cua-rdp] Unsupported configuration version.' }
    $vmId = [Guid]::Parse([string]$config.vmId)
    $config.guestRoot = Assert-CuaRdpGuestRoot $config.guestRoot
    if (-not [IO.Path]::IsPathRooted($config.credentialPath) -or -not (Test-Path -LiteralPath $config.credentialPath -PathType Leaf)) {
        throw '[cua-rdp] Saved guest credentials were not found.'
    }
    $credential = Import-Clixml -LiteralPath $config.credentialPath
    if ($credential -isnot [Management.Automation.PSCredential]) { throw '[cua-rdp] Invalid saved credentials.' }
    $hostGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid

    while ($null -ne ($line = [Console]::In.ReadLine())) {
        $id = $null
        $method = 'operation'
        try {
            Assert-Owner
            if ($line.Length -gt 16777216) { throw '[cua-rdp] Broker request is too large.' }
            $request = $line | ConvertFrom-Json
            if ($null -eq $request.id -or
                ($request.id -isnot [int] -and $request.id -isnot [long] -and $request.id -isnot [double]) -or
                [double]$request.id -ne [Math]::Truncate([double]$request.id) -or [Math]::Abs([double]$request.id) -gt 9007199254740991) {
                throw '[cua-rdp] Broker request requires an integer identifier.'
            }
            $id = $request.id
            $method = [string]$request.method
            $arguments = $request.params
            $result = $null
            switch ($method) {
                'prepare' {
                    if ($prepared) { Assert-Prepared; $result = $facts; break }
                    $vm = Get-VM -Id $vmId
                    if ($vm.State -eq 'Off' -and $config.autoStartVm -eq $true) { $null = Start-VM -VM $vm }
                    elseif ($vm.State -ne 'Running') { throw '[cua-rdp] The configured VM must be running, or autoStartVm must permit starting an off VM.' }
                    $deadline = [DateTime]::UtcNow.AddSeconds(60)
                    do {
                        try { $session = New-PSSession -VMId $vmId -Credential $credential; break }
                        catch {
                            if ([DateTime]::UtcNow -ge $deadline) { throw }
                            Assert-Owner
                            Start-Sleep -Milliseconds 1000
                        }
                    } while ($true)
                    $guestFacts = Invoke-Command -Session $session -ArgumentList $config.guestRoot, $config.guestMachineGuid, $hostGuid, ([int]$config.rdp.port) -ScriptBlock {
                        param($Root, $ExpectedGuid, $HostGuid, $ExpectedPort)
                        $ErrorActionPreference = 'Stop'
                        $guid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
                        if ($guid -ine $ExpectedGuid -or $guid -ieq $HostGuid) { throw '[cua-rdp] The guest machine identity is not the pinned isolated VM.' }
                        $settings = Get-Content -LiteralPath (Join-Path $Root 'guest-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                        if ($settings.version -ne 1 -or $settings.userSid -ne $sid) { throw '[cua-rdp] Saved credentials do not match the installed guest account.' }
                        foreach ($file in @('guest-agent.cjs', 'Get-InteractiveState.ps1', 'Start-Agent.ps1')) {
                            if (-not (Test-Path -LiteralPath (Join-Path $Root $file) -PathType Leaf)) { throw '[cua-rdp] Guest agent files are missing. Run explicit setup first.' }
                        }
                        foreach ($file in @($settings.nodePath, $settings.driverPath)) {
                            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw '[cua-rdp] A configured guest runtime is missing.' }
                        }
                        $terminal = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
                        $listener = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
                        if ($terminal.fDenyTSConnections -ne 0 -or $listener.UserAuthentication -ne 1 -or $listener.PortNumber -ne $ExpectedPort) {
                            throw '[cua-rdp] Guest RDP with NLA and the configured port must be prepared by the administrator; the plugin does not alter it.'
                        }
                        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress -Unique)
                        @{ guestMachineGuid = $guid; computerName = $env:COMPUTERNAME; addresses = $addresses; userSid = $sid }
                    }
                    $guestUserSid = $guestFacts.userSid
                    $facts = [ordered]@{ hostMachineGuid = $hostGuid; guestMachineGuid = $guestFacts.guestMachineGuid; addresses = @($guestFacts.addresses); computerName = $guestFacts.computerName }
                    $prepared = $true
                    $result = $facts
                }
                'stage' {
                    Assert-Prepared
                    $runId = [string]$arguments.runId
                    Assert-RunId $runId
                    if ($arguments.token -cnotmatch '^[0-9a-f]{64}$') { throw '[cua-rdp] Invalid run token.' }
                    if ($runs.Count -gt 0) { throw '[cua-rdp] This broker already owns a desktop run.' }
                    $runs[$runId] = @{ runId = $runId; token = [string]$arguments.token; identity = $null; ready = $null }
                    $identity = Invoke-Command -Session $session -ArgumentList $config.guestRoot, $runId, ([string]$arguments.token), $config.guestMachineGuid, $guestUserSid -ScriptBlock {
                        param($Root, $Id, $Token, $ExpectedGuid, $ExpectedSid)
                        $ErrorActionPreference = 'Stop'
                        $installed = Get-Content -LiteralPath (Join-Path $Root 'guest-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                        $state = & (Join-Path $Root 'Get-InteractiveState.ps1') -ListSessions | ConvertFrom-Json
                        if ($state.machineGuid -ine $ExpectedGuid -or $state.userSid -ne $installed.userSid -or $state.userSid -ne $ExpectedSid) { throw '[cua-rdp] Guest account or machine identity changed.' }
                        $matches = @($state.sessions | Where-Object { $_.userSid -eq $installed.userSid -and $_.protocol -eq 2 -and $_.state -eq 0 -and $_.sessionId -gt 0 })
                        if ($matches.Count -ne 1) { throw '[cua-rdp] Exactly one active RDP session for the installed account is required.' }
                        $runsRoot = Join-Path $Root 'runs'
                        $runsItem = Get-Item -LiteralPath $runsRoot -Force
                        if (-not $runsItem.PSIsContainer -or ($runsItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '[cua-rdp] The guest run directory is invalid.' }
                        $path = Join-Path $runsRoot $Id
                        if (Test-Path -LiteralPath $path) { throw '[cua-rdp] The run directory already exists.' }
                        $null = New-Item -ItemType Directory -Path $path
                        [IO.File]::WriteAllText((Join-Path $path 'owner.token'), $Token, (New-Object Text.UTF8Encoding($false)))
                        $agent = [ordered]@{
                            version = 1; runId = $Id; token = $Token; expectedMachineGuid = $ExpectedGuid
                            expectedSessionId = [int]$matches[0].sessionId; expectedUserSid = $installed.userSid
                            driverPath = $installed.driverPath; readyPath = (Join-Path $path 'ready.json'); leaseMs = 180000
                        }
                        [IO.File]::WriteAllText((Join-Path $path 'agent.json.tmp'), ($agent | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
                        [IO.File]::Move((Join-Path $path 'agent.json.tmp'), (Join-Path $path 'agent.json'))
                        @{ sessionId = [int]$matches[0].sessionId; userSid = $installed.userSid; machineGuid = $ExpectedGuid }
                    }
                    $runs[$runId].identity = $identity
                    $result = $identity
                }
                'attach' {
                    Assert-Prepared
                    $runId = [string]$arguments.runId
                    $run = Get-OwnedRun $runId
                    $ready = Invoke-Command -Session $session -ArgumentList $config.guestRoot, $runId, $run.identity -ScriptBlock {
                        param($Root, $Id, $Expected)
                        $ErrorActionPreference = 'Stop'
                        $path = Join-Path (Join-Path $Root 'runs') $Id
                        $readyPath = Join-Path $path 'ready.json'
                        $deadline = [DateTime]::UtcNow.AddSeconds(30)
                        do {
                            if (Test-Path -LiteralPath (Join-Path $path 'bootstrap-error.txt')) { throw '[cua-rdp] Guest bootstrap failed; inspect the run directory diagnostic.' }
                            if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
                                if ((Get-Item -LiteralPath $readyPath).Length -gt 16384) { throw '[cua-rdp] Invalid guest readiness descriptor size.' }
                                $ready = Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                if ($ready.runId -cne $Id -or $ready.sessionId -ne $Expected.sessionId -or $ready.userSid -ne $Expected.userSid -or $ready.machineGuid -ine $Expected.machineGuid -or
                                    $ready.port -lt 1024 -or $ready.port -gt 65535 -or $ready.pid -le 0) {
                                    throw '[cua-rdp] Guest readiness descriptor does not match the expected RDP session.'
                                }
                                return $ready
                            }
                            Start-Sleep -Milliseconds 200
                        } while ([DateTime]::UtcNow -lt $deadline)
                        throw '[cua-rdp] Guest agent did not become ready within 30 seconds. Check the unlocked Explorer desktop, keyboard layout and runtime installation.'
                    }
                    $run.ready = $ready
                    $result = $ready
                }
                'request' {
                    Assert-Prepared
                    $run = Get-OwnedRun ([string]$arguments.runId)
                    if ([string]$arguments.operation -cnotin @('health', 'listTools', 'callTool', 'listResources', 'readResource')) { throw '[cua-rdp] Unsupported guest operation.' }
                    $payload = [string]$arguments.payloadJson
                    if ([string]::IsNullOrEmpty($payload)) { $payload = '{}' }
                    if ($payload.Length -gt 2097152) { throw '[cua-rdp] Guest request exceeds 2 MiB.' }
                    $result = @{ json = (Invoke-GuestHttp $run ([string]$arguments.operation) $payload) }
                }
                'stop' {
                    $result = Stop-OwnedRun ([string]$arguments.runId)
                }
                default { throw '[cua-rdp] Unknown broker method.' }
            }
            $response = @{ id = $id; result = $result }
        } catch {
            $response = @{ id = $id; error = @{ message = (Get-CuaRdpSafeError $_ $method) } }
        }
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $response -Depth 100 -Compress))
        [Console]::Out.Flush()
    }
} catch {
    [Console]::Error.WriteLine((Get-CuaRdpSafeError $_ 'prepare'))
    exit 1
} finally {
    foreach ($ownedId in @($runs.Keys)) { try { $null = Stop-OwnedRun $ownedId } catch { } }
    if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
