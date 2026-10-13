[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Name')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Name')][string]$VmName,
    [Parameter(Mandatory = $true, ParameterSetName = 'Id')][Guid]$VmId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$')][string]$RdpAddress,
    [Parameter(Mandatory = $true)][string]$GuestDriverPath,
    [string]$GuestNodePath = 'C:\Program Files\nodejs\node.exe',
    [string]$GuestRoot = 'C:\ProgramData\CuaRdp',
    [string]$ConfigPath = $(if ($env:CUA_RDP_CONFIG) { $env:CUA_RDP_CONFIG } else { Join-Path $env:LOCALAPPDATA 'CuaRdp\config.json' }),
    [ValidateRange(1, 65535)][int]$RdpPort = 3389,
    [ValidateRange(800, 3840)][int]$Width = 1600,
    [ValidateRange(600, 2160)][int]$Height = 900,
    [Management.Automation.PSCredential]$Credential,
    [bool]$AutoStartVm = $true,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')
$GuestRoot = Assert-CuaRdpGuestRoot $GuestRoot
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$dataRoot = Split-Path -Parent $ConfigPath
if ($dataRoot.Length -le 3) { throw '[cua-rdp] Use a dedicated private configuration directory, not a drive root.' }
Assert-CuaRdpPlainDirectory $dataRoot
if (Test-Path -LiteralPath $dataRoot) {
    $children = @(Get-ChildItem -LiteralPath $dataRoot -Force)
    if ($children.Count -gt 0 -and -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw '[cua-rdp] The configuration directory is not empty and has no existing CuaRdp configuration. Choose a dedicated directory.'
    }
}
if (Test-Path -LiteralPath $ConfigPath) {
    if ((Get-Item -LiteralPath $ConfigPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '[cua-rdp] The configuration must not be a link.' }
    $existing = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($existing.version -ne 1) { throw '[cua-rdp] Existing configuration does not have a supported CuaRdp format.' }
    if (-not $Force) { throw '[cua-rdp] Configuration already exists. Explicitly use -Force to replace the installation and save backups.' }
}
$credentialPath = Join-Path $dataRoot 'credential.clixml'
if (Test-Path -LiteralPath $credentialPath) {
    if ((Get-Item -LiteralPath $credentialPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '[cua-rdp] The credential file must not be a link.' }
    if (-not $Force) { throw '[cua-rdp] Saved credentials already exist. Explicit replacement is required.' }
}
$pluginRoot = Split-Path -Parent $PSScriptRoot
$sources = @(
    (Join-Path $pluginRoot 'dist\guest-agent.cjs'),
    (Join-Path $pluginRoot 'guest\Get-InteractiveState.ps1'),
    (Join-Path $pluginRoot 'guest\Start-Agent.ps1')
)
foreach ($file in $sources) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw '[cua-rdp] Guest deployment files are missing. Run npm ci and npm run build in the plugin directory first.' }
}
if ($PSCmdlet.ParameterSetName -eq 'Name') { $vm = Get-VM -Name $VmName }
else { $vm = Get-VM -Id $VmId }
if (@($vm).Count -ne 1 -or $vm.State -ne 'Running') { throw '[cua-rdp] Setup requires one existing, running local Hyper-V VM.' }
$VmId = $vm.Id
if (-not $PSCmdlet.ShouldProcess(('VM {0}; configuration {1}' -f $VmId, $ConfigPath), 'Install isolated desktop agent files and save DPAPI-encrypted guest credentials')) { return }
if ($null -eq $Credential) {
    $Credential = Get-Credential -Message 'Dedicated VM account (administrator for PowerShell Direct; also used for the isolated RDP desktop)'
}
if ($null -eq $Credential) { throw '[cua-rdp] A guest credential is required.' }
$hostGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
$session = $null
$installId = [Guid]::NewGuid().ToString('N')
try {
    $session = New-PSSession -VMId $VmId -Credential $Credential
    $facts = Invoke-Command -Session $session -ArgumentList $GuestRoot, $GuestNodePath, $GuestDriverPath, $RdpPort, $hostGuid, $Force.IsPresent -ScriptBlock {
        param($Root, $NodePath, $DriverPath, $Port, $HostGuid, $Replace)
        $ErrorActionPreference = 'Stop'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '[cua-rdp] Guest setup requires an administrator account for PowerShell Direct.' }
        $guid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
        if ([string]::IsNullOrWhiteSpace($guid) -or $guid -ieq $HostGuid) { throw '[cua-rdp] The guest must have a distinct Windows machine identity.' }
        foreach ($path in @($NodePath, $DriverPath)) {
            if (-not [IO.Path]::IsPathRooted($path) -or $path -notmatch '\.exe$' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw '[cua-rdp] Supply absolute paths to existing Node.js and cua-driver executables inside the VM.'
            }
        }
        $version = & $NodePath --version
        if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) { throw '[cua-rdp] The guest requires Node.js 22 or later.' }
        $terminal = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $listener = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        if ($terminal.fDenyTSConnections -ne 0 -or $listener.UserAuthentication -ne 1 -or $listener.PortNumber -ne $Port) {
            throw '[cua-rdp] RDP with NLA and the requested port must already be configured in the VM. Setup does not modify remote access or firewall settings.'
        }
        $parent = Split-Path -Parent $Root
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw '[cua-rdp] The guest installation parent directory must already exist.' }
        if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '[cua-rdp] Guest installation parent must not be a directory link.' }
        if (Test-Path -LiteralPath $Root) {
            $item = Get-Item -LiteralPath $Root -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '[cua-rdp] The guest installation path must be an ordinary directory.' }
            if (-not $Replace) { throw '[cua-rdp] Guest installation already exists; explicit -Force is required.' }
            $marker = Join-Path $Root 'guest-config.json'
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw '[cua-rdp] Refusing to replace a directory that is not a CuaRdp installation.' }
            $old = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.version -ne 1 -or $old.userSid -ne $identity.User.Value) { throw '[cua-rdp] The existing installation belongs to another account or version.' }
            $runs = Join-Path $Root 'runs'
            if ((Test-Path -LiteralPath $runs) -and @(Get-ChildItem -LiteralPath $runs -Force).Count -gt 0) {
                throw '[cua-rdp] Existing run directories must be inspected and cleaned up before replacing the guest installation.'
            }
        }
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress -Unique)
        @{ machineGuid = $guid; userSid = $identity.User.Value; addresses = $addresses }
    }
    $dnsAddresses = @([Net.Dns]::GetHostAddresses($RdpAddress))
    if (@($dnsAddresses | Where-Object { $_.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork }).Count -gt 0) {
        throw '[cua-rdp] RdpAddress must resolve to IPv4 only; mixed IPv4/IPv6 and IPv6-only names are not supported.'
    }
    $resolved = @($dnsAddresses | ForEach-Object { $_.ToString() })
    $local = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object -ExpandProperty IPAddress)
    if ($resolved.Count -eq 0 -or @($resolved | Where-Object { $_ -like '127.*' -or $_ -in $local -or $_ -notin $facts.addresses }).Count -gt 0) {
        throw '[cua-rdp] RdpAddress must resolve only to addresses of the selected guest, never loopback, the host or another machine.'
    }
    $stagePath = $GuestRoot + '.install-' + $installId
    Invoke-Command -Session $session -ArgumentList $stagePath, $facts.userSid -ScriptBlock {
        param($Stage, $UserSid)
        $ErrorActionPreference = 'Stop'
        if (Test-Path -LiteralPath $Stage) { throw '[cua-rdp] Guest staging path unexpectedly exists.' }
        $null = New-Item -ItemType Directory -Path $Stage
        $security = New-Object Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($UserSid, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
            $security.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Stage -AclObject $security
        $null = New-Item -ItemType Directory -Path (Join-Path $Stage 'runs')
    }
    foreach ($source in $sources) { Copy-Item -LiteralPath $source -Destination $stagePath -ToSession $session }
    $backup = Invoke-Command -Session $session -ArgumentList $stagePath, $GuestRoot, $installId, $GuestNodePath, $GuestDriverPath, $facts.userSid -ScriptBlock {
        param($Stage, $Root, $Id, $NodePath, $DriverPath, $UserSid)
        $ErrorActionPreference = 'Stop'
        $config = @{ version = 1; nodePath = $NodePath; driverPath = $DriverPath; userSid = $UserSid }
        [IO.File]::WriteAllText((Join-Path $Stage 'guest-config.json'), ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        $backup = $null
        if (Test-Path -LiteralPath $Root) {
            $backup = $Root + '.backup-' + $Id
            if (Test-Path -LiteralPath $backup) { throw '[cua-rdp] Guest backup path unexpectedly exists.' }
            Move-Item -LiteralPath $Root -Destination $backup
        }
        try { Move-Item -LiteralPath $Stage -Destination $Root }
        catch {
            if ($null -ne $backup -and -not (Test-Path -LiteralPath $Root)) { Move-Item -LiteralPath $backup -Destination $Root }
            throw
        }
        $backup
    }
    $hostSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Set-CuaRdpPrivateDirectory -Path $dataRoot -UserSid $hostSid
    foreach ($file in @($ConfigPath, $credentialPath)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Copy-Item -LiteralPath $file -Destination ($file + '.backup-' + $installId) }
    }
    $Credential | Export-Clixml -LiteralPath $credentialPath -Force
    $hostConfig = [ordered]@{
        version = 1; vmId = $VmId.ToString(); guestMachineGuid = $facts.machineGuid
        credentialPath = $credentialPath; guestRoot = $GuestRoot; autoStartVm = $AutoStartVm
        rdp = @{ address = $RdpAddress; port = $RdpPort; width = $Width; height = $Height }
    }
    $tempConfig = $ConfigPath + '.tmp-' + $installId
    [IO.File]::WriteAllText($tempConfig, ($hostConfig | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempConfig -Destination $ConfigPath -Force
    [ordered]@{
        configured = $true; configPath = $ConfigPath; vmId = $VmId.ToString(); guestRoot = $GuestRoot
        guestBackup = $backup; certificateValidation = 'Strict: the RDP certificate must already be trusted and match RdpAddress.'
        systemSettingsChanged = $false
    } | ConvertTo-Json -Depth 6
} finally {
    if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
