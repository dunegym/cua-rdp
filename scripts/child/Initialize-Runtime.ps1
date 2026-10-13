[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$PluginRoot,
    [Parameter(Mandatory = $true)][string]$DriverPath,
    [Parameter(Mandatory = $true)][string]$NodePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Runtime.Common.ps1')
$installLock = $null

try {
    $root = Assert-ChildRuntimePath $RuntimeRoot
    if (-not [IO.Path]::IsPathRooted($PluginRoot) -or -not (Test-Path -LiteralPath $PluginRoot -PathType Container)) {
        throw '[cua-rdp] PluginRoot must identify the installed plugin directory.'
    }
    $plugin = [IO.Path]::GetFullPath($PluginRoot).TrimEnd('\')
    if ($root -ieq $plugin -or $root.StartsWith($plugin + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $plugin.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '[cua-rdp] RuntimeRoot must not overlap the plugin installation.'
    }
    foreach ($executable in @($DriverPath, $NodePath)) {
        if ($executable -notmatch '^[A-Za-z]:\\' -or $executable -match '[\x00-\x1f"]' -or
            [IO.Path]::GetExtension($executable) -ine '.exe' -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw '[cua-rdp] DriverPath and NodePath must be existing absolute local executable paths.'
        }
    }
    $sources = [ordered]@{
        'guest-agent.cjs' = Join-Path $plugin 'dist\guest-agent.cjs'
        'Get-InteractiveState.ps1' = Join-Path $plugin 'guest\Get-InteractiveState.ps1'
        'Start-Agent.ps1' = Join-Path $plugin 'guest\Start-Agent.ps1'
    }
    foreach ($source in $sources.Values) { Assert-ChildRuntimeFile $source }
    $userSid = Get-ChildRuntimeUserSid
    $markerPath = Join-Path $root 'runtime-owner.json'
    if (Test-Path -LiteralPath $root) {
        if (Test-Path -LiteralPath $markerPath) { $null = Assert-ChildRuntimeOwner $root }
        else {
            $ownerSid = (Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($ownerSid -cne $userSid -or @(Get-ChildItem -LiteralPath $root -Force).Count -gt 0) {
                throw '[cua-rdp] Refusing to overwrite a directory without this user''s Child Session runtime ownership marker.'
            }
        }
    }
    $runsRoot = Join-Path $root 'runs'
    $null = Assert-ChildRuntimeDirectory $runsRoot
    if ((Test-Path -LiteralPath $runsRoot) -and @(Get-ChildItem -LiteralPath $runsRoot -Force).Count -gt 0) {
        throw '[cua-rdp] Runtime updates are refused while any run files remain. Stop or recover the existing run first.'
    }
    foreach ($name in @($sources.Keys) + @('guest-config.json', 'runtime-owner.json', 'install.lock')) {
        Assert-ChildRuntimeFile (Join-Path $root $name) -Optional
    }
    Set-ChildRuntimePrivateAcl -Path $root -UserSid $userSid -Directory
    $lockPath = Join-Path $root 'install.lock'
    try { $installLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw '[cua-rdp] Another runtime installation is in progress.' }
    if ((Test-Path -LiteralPath $runsRoot) -and @(Get-ChildItem -LiteralPath $runsRoot -Force).Count -gt 0) {
        throw '[cua-rdp] Runtime updates are refused while any run files remain.'
    }
    if (-not (Test-Path -LiteralPath $markerPath)) {
        Write-ChildRuntimeJson $markerPath @{ version = 1; kind = 'cua-rdp-child-runtime'; userSid = $userSid; root = $root }
    }
    Set-ChildRuntimePrivateAcl -Path $runsRoot -UserSid $userSid -Directory
    foreach ($name in $sources.Keys) {
        $target = Join-Path $root $name
        $temporary = Join-Path $root ($name + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy($sources[$name], $temporary, $false)
            if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $target) }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    Write-ChildRuntimeJson (Join-Path $root 'guest-config.json') @{
        version = 1; nodePath = [IO.Path]::GetFullPath($NodePath)
        driverPath = [IO.Path]::GetFullPath($DriverPath); userSid = $userSid
    }
    foreach ($name in @($sources.Keys) + @('guest-config.json', 'runtime-owner.json')) {
        Set-ChildRuntimePrivateAcl -Path (Join-Path $root $name) -UserSid $userSid
    }
    @{ installed = $true; runtimeRoot = $root; userSid = $userSid; version = 1 } | ConvertTo-Json -Compress
} catch {
    Write-Verbose ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
    [Console]::Error.WriteLine((Get-CuaRdpSafeError $_ 'initialize-child-runtime'))
    exit 1
} finally {
    if ($null -ne $installLock) {
        $installLock.Dispose()
        try { [IO.File]::Delete($lockPath) } catch { }
    }
}
