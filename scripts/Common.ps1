function Assert-CuaRdpGuestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+$' -or $Path.Length -gt 160) {
        throw '[cua-rdp] GuestRoot must be an absolute Windows path of at most 160 characters using only ASCII letters, numbers, spaces, dots, underscores and hyphens.'
    }
    $parts = $Path.Substring(3).TrimEnd('\').Split('\')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_.EndsWith('.') -or $_.EndsWith(' ') -or $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }).Count -gt 0) {
        throw '[cua-rdp] GuestRoot must not contain relative, ambiguous or reserved Windows path segments.'
    }
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-CuaRdpPlainDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '[cua-rdp] A managed directory must be a normal directory, not a link or file.'
        }
    }
}

function Set-CuaRdpPrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$UserSid)
    Assert-CuaRdpPlainDirectory $Path
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path }
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @($UserSid, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-CuaRdpSafeError {
    param([Parameter(Mandatory = $true)]$ErrorRecord, [string]$Operation = 'operation')
    $message = [string]$ErrorRecord.Exception.Message
    if ($message.StartsWith('[cua-rdp] ')) { return $message.Substring(10) }
    switch ($Operation) {
        'prepare' { return 'Hyper-V or PowerShell Direct preparation failed. Verify host administrative access, guest credentials, VM state and installed guest prerequisites.' }
        'stage' { return 'Guest staging failed. Verify that the dedicated account has exactly one active RDP session and that the guest installation is intact.' }
        'attach' { return 'Guest agent attachment failed. Verify that the RDP desktop is unlocked, Explorer is running and the guest bootstrap diagnostic is clear.' }
        'request' { return 'The isolated guest request failed or timed out. Its outcome may be unknown; do not automatically repeat a computer action.' }
        'stop' { return 'Guest cleanup was incomplete. The agent lease will expire; the VM and unrelated applications were not stopped.' }
        default { return 'CuaRdp operation failed. Check configuration, permissions and the documented prerequisites.' }
    }
}
