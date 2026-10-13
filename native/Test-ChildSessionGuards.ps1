[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not ('CuaRdp.Native.ChildSessionNative' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ChildSessionNative.cs')
}
. (Join-Path $PSScriptRoot 'ChildSessionRequest.ps1')
$script:guardCases = 0

function Assert-Accepts([string]$Name, [scriptblock]$Action) {
    try { $null = & $Action }
    catch { throw ($Name + ' unexpectedly failed: ' + $_.Exception.GetBaseException().Message) }
    $script:guardCases++
}

function Assert-Rejects([string]$Name, [scriptblock]$Action) {
    $rejected = $false
    try { $null = & $Action }
    catch { $rejected = $true }
    if (-not $rejected) { throw ($Name + ' was not rejected.') }
    $script:guardCases++
}

function New-TestSnapshot {
    $snapshot = New-Object CuaRdp.Native.ChildSessionState
    $snapshot.enabled = $true
    $snapshot.parentSessionId = 11
    $snapshot.parentLogonTime = '134362541354702428'
    $snapshot.parentState = 0
    $snapshot.parentProtocol = 0
    $snapshot.activeConsoleSessionId = 11
    $snapshot.isConsoleParent = $true
    $snapshot.userSid = 'S-1-5-21-1-2-3-1001'
    $snapshot.machineGuid = '12345678-1234-1234-1234-123456789abc'
    $snapshot.rdpPort = 3389
    return $snapshot
}

function New-ChildSnapshot([int]$State = 4) {
    $snapshot = New-TestSnapshot
    $snapshot.childSessionId = 12
    $snapshot.childLogonTime = '134362541454702428'
    $snapshot.childState = $State
    $snapshot.childProtocol = 2
    $snapshot.childUserSid = $snapshot.userSid
    return $snapshot
}

function New-ChildRequest {
    return [PSCustomObject]@{
        mode = 'child-session'; address = 'localhost'
        expectedParentSessionId = 11; expectedParentLogonTime = '134362541354702428'
        expectedChildSessionId = $null; expectedChildLogonTime = $null
    }
}

$fresh = [CuaRdp.Native.ChildSessionExpectation]::new(11, '134362541354702428', $null, $null)
$resume = [CuaRdp.Native.ChildSessionExpectation]::new(11, '134362541354702428', 12, '134362541454702428')
Assert-Accepts 'WTSINFO layout' { [CuaRdp.Native.ChildSessionNative]::ValidateLayout() }
Assert-Accepts 'fresh connection' { [CuaRdp.Native.ChildSessionGuard]::BeforeConnect((New-TestSnapshot), $fresh, 3389) }
Assert-Accepts 'owned disconnected resume' { [CuaRdp.Native.ChildSessionGuard]::BeforeConnect((New-ChildSnapshot), $resume, 3389) }
Assert-Accepts 'fresh successful login' { [CuaRdp.Native.ChildSessionGuard]::AfterLogin((New-ChildSnapshot 0), $fresh, 3389) }
Assert-Accepts 'resumed successful login' { [CuaRdp.Native.ChildSessionGuard]::AfterLogin((New-ChildSnapshot 0), $resume, 3389) }
Assert-Accepts 'matching connected heartbeat' {
    $s = New-ChildSnapshot 0
    [CuaRdp.Native.ChildSessionGuard]::WhileConnected($s, $resume, 3389, $s.userSid, $s.machineGuid)
}

$parentMutations = @(
    @{ name = 'disabled feature'; change = { param($s) $s.enabled = $false } },
    @{ name = 'RDP Wrapper'; change = { param($s) $s.rdpWrapper = $true } },
    @{ name = 'Session 0'; change = { param($s) $s.parentSessionId = 0; $s.activeConsoleSessionId = 0 } },
    @{ name = 'disconnected parent'; change = { param($s) $s.parentState = 4 } },
    @{ name = 'RDP parent'; change = { param($s) $s.parentProtocol = 2 } },
    @{ name = 'ineligible console parent'; change = { param($s) $s.isConsoleParent = $false } },
    @{ name = 'no active console'; change = { param($s) $s.activeConsoleSessionId = $null } },
    @{ name = 'different active console'; change = { param($s) $s.activeConsoleSessionId = 10 } },
    @{ name = 'different parent ID'; change = { param($s) $s.parentSessionId = 10; $s.activeConsoleSessionId = 10 } },
    @{ name = 'recycled parent ID'; change = { param($s) $s.parentLogonTime = '134362541354702429' } },
    @{ name = 'missing parent generation'; change = { param($s) $s.parentLogonTime = $null } },
    @{ name = 'missing user identity'; change = { param($s) $s.userSid = $null } },
    @{ name = 'missing machine identity'; change = { param($s) $s.machineGuid = $null } },
    @{ name = 'changed listener port'; change = { param($s) $s.rdpPort = 3390 } }
)
foreach ($case in $parentMutations) {
    Assert-Rejects $case.name {
        $s = New-TestSnapshot
        & $case.change $s
        [CuaRdp.Native.ChildSessionGuard]::BeforeConnect($s, $fresh, 3389)
    }
}
Assert-Rejects 'unowned disconnected child' { [CuaRdp.Native.ChildSessionGuard]::BeforeConnect((New-ChildSnapshot), $fresh, 3389) }
Assert-Rejects 'unowned active child' { [CuaRdp.Native.ChildSessionGuard]::BeforeConnect((New-ChildSnapshot 0), $fresh, 3389) }
Assert-Rejects 'orphaned child identity' {
    $s = New-TestSnapshot; $s.childLogonTime = '134362541454702428'
    [CuaRdp.Native.ChildSessionGuard]::BeforeConnect($s, $fresh, 3389)
}
Assert-Rejects 'owned active child cannot be taken over' { [CuaRdp.Native.ChildSessionGuard]::BeforeConnect((New-ChildSnapshot 0), $resume, 3389) }
$childMutations = @(
    @{ name = 'missing child'; change = { param($s) $s.childSessionId = $null } },
    @{ name = 'child Session 0'; change = { param($s) $s.childSessionId = 0 } },
    @{ name = 'child equals parent'; change = { param($s) $s.childSessionId = 11 } },
    @{ name = 'different child'; change = { param($s) $s.childSessionId = 13 } },
    @{ name = 'recycled child ID'; change = { param($s) $s.childLogonTime = '134362541454702429' } },
    @{ name = 'missing child generation'; change = { param($s) $s.childLogonTime = $null } },
    @{ name = 'foreign child user'; change = { param($s) $s.childUserSid = 'S-1-5-21-1-2-3-1002' } },
    @{ name = 'missing child user'; change = { param($s) $s.childUserSid = $null } },
    @{ name = 'unknown child protocol'; change = { param($s) $s.childProtocol = 1 } },
    @{ name = 'missing child protocol'; change = { param($s) $s.childProtocol = $null } }
)
foreach ($case in $childMutations) {
    Assert-Rejects ('resume: ' + $case.name) {
        $s = New-ChildSnapshot
        & $case.change $s
        [CuaRdp.Native.ChildSessionGuard]::BeforeConnect($s, $resume, 3389)
    }
    Assert-Rejects ('heartbeat: ' + $case.name) {
        $s = New-ChildSnapshot 0
        & $case.change $s
        [CuaRdp.Native.ChildSessionGuard]::WhileConnected($s, $resume, 3389, $s.userSid, $s.machineGuid)
    }
}
# Windows drops a disconnected child session's RDP protocol association (observed protocol 0), so a resume
# must accept the association-less value while the active/heartbeat checks keep requiring protocol 2.
Assert-Accepts 'resume accepts a disconnected child without its protocol association' {
    $s = New-ChildSnapshot 4
    $s.childProtocol = 0
    [CuaRdp.Native.ChildSessionGuard]::BeforeConnect($s, $resume, 3389)
}
Assert-Rejects 'login without active child' { [CuaRdp.Native.ChildSessionGuard]::AfterLogin((New-ChildSnapshot 4), $fresh, 3389) }
Assert-Rejects 'resumed login with recycled child' {
    $s = New-ChildSnapshot 0; $s.childLogonTime = '134362541454702429'
    [CuaRdp.Native.ChildSessionGuard]::AfterLogin($s, $resume, 3389)
}
Assert-Rejects 'unbound heartbeat' {
    $s = New-ChildSnapshot 0
    [CuaRdp.Native.ChildSessionGuard]::WhileConnected($s, $fresh, 3389, $s.userSid, $s.machineGuid)
}
Assert-Rejects 'disconnected heartbeat' {
    $s = New-ChildSnapshot 4
    [CuaRdp.Native.ChildSessionGuard]::WhileConnected($s, $resume, 3389, $s.userSid, $s.machineGuid)
}
Assert-Rejects 'changed user heartbeat' {
    $s = New-ChildSnapshot 0
    [CuaRdp.Native.ChildSessionGuard]::WhileConnected($s, $resume, 3389, 'S-1-5-21-1-2-3-1002', $s.machineGuid)
}
Assert-Rejects 'changed machine heartbeat' {
    $s = New-ChildSnapshot 0
    [CuaRdp.Native.ChildSessionGuard]::WhileConnected($s, $resume, 3389, $s.userSid, '87654321-4321-4321-4321-cba987654321')
}
foreach ($generation in @($null, '', '0', '-1', '01', ' 1', '1 ', '1.0', '1e18', '9223372036854775808')) {
    Assert-Rejects ('invalid generation ' + $generation) { [CuaRdp.Native.ChildSessionGuard]::ValidateLogonTime($generation) }
}
Assert-Rejects 'generation without child' { [CuaRdp.Native.ChildSessionExpectation]::new(11, '134362541354702428', $null, '134362541454702428') }
Assert-Rejects 'child without generation' { [CuaRdp.Native.ChildSessionExpectation]::new(11, '134362541354702428', 12, $null) }
Assert-Rejects 'expected child equals parent' { [CuaRdp.Native.ChildSessionExpectation]::new(11, '134362541354702428', 11, '134362541454702428') }
Assert-Accepts 'ULONG_MAX absence' {
    if ($null -ne [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($true, [uint32]::MaxValue, 5)) { throw 'Expected no child.' }
}
Assert-Accepts 'ERROR_NOT_FOUND absence' {
    if ($null -ne [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($false, 0, 1168)) { throw 'Expected no child.' }
}
Assert-Accepts 'positive child ID result' {
    if (12 -ne [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($true, 12, 1168)) { throw 'Expected child 12.' }
}
Assert-Rejects 'access denied is not absence' { [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($false, [uint32]::MaxValue, 5) }
Assert-Rejects 'unknown error is not absence' { [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($false, 0, 0) }
Assert-Rejects 'zero child ID result' { [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($true, 0, 0) }
Assert-Rejects 'out of range child ID' { [CuaRdp.Native.ChildSessionNative]::DecodeChildSessionId($true, 2147483648, 0) }
Assert-Accepts 'fresh request schema' { Read-ChildSessionExpectation (New-ChildRequest) }
Assert-Accepts 'resume request schema' {
    $r = New-ChildRequest; $r.expectedChildSessionId = 12; $r.expectedChildLogonTime = '134362541454702428'
    Read-ChildSessionExpectation $r
}
Assert-Accepts 'legacy remote mode' { if ('hyperv' -ne (Get-RdpRequestMode ([PSCustomObject]@{}))) { throw 'Legacy mode changed.' } }
Assert-Rejects 'unknown mode' { Get-RdpRequestMode ([PSCustomObject]@{ mode = 'other' }) }
Assert-Rejects 'nonlocalhost child endpoint' { $r = New-ChildRequest; $r.address = '127.0.0.1'; Read-ChildSessionExpectation $r }
Assert-Rejects 'numeric parent generation' { $r = New-ChildRequest; $r.expectedParentLogonTime = 134362541354702428; Read-ChildSessionExpectation $r }
Assert-Rejects 'string parent ID' { $r = New-ChildRequest; $r.expectedParentSessionId = '11'; Read-ChildSessionExpectation $r }
Assert-Rejects 'fractional child ID' { $r = New-ChildRequest; $r.expectedChildSessionId = 12.5; $r.expectedChildLogonTime = '134362541454702428'; Read-ChildSessionExpectation $r }
Assert-Rejects 'unpaired child request fields' { $r = New-ChildRequest; $r.expectedChildLogonTime = ''; Read-ChildSessionExpectation $r }
Assert-Rejects 'missing expected child field' { $r = New-ChildRequest; $r.PSObject.Properties.Remove('expectedChildSessionId'); Read-ChildSessionExpectation $r }
Assert-Rejects 'credential-bearing child request' { $r = New-ChildRequest; Add-Member -InputObject $r -NotePropertyName credentialPath -NotePropertyValue 'C:\unused.xml'; Read-ChildSessionExpectation $r }

Assert-Accepts 'background authentication default' { if (Get-InteractiveAuthentication ([PSCustomObject]@{})) { throw 'Default became interactive.' } }
Assert-Accepts 'explicit child interactive authentication' { if (-not (Get-InteractiveAuthentication ([PSCustomObject]@{ mode = 'child-session'; authentication = 'interactive' }))) { throw 'Explicit mode was lost.' } }
Assert-Rejects 'interactive remote authentication' { Get-InteractiveAuthentication ([PSCustomObject]@{ authentication = 'interactive' }) }
Assert-Rejects 'unknown authentication mode' { Get-InteractiveAuthentication ([PSCustomObject]@{ mode = 'child-session'; authentication = 'automatic' }) }
Assert-Rejects 'nonstrings cannot enable authentication UI' { Get-InteractiveAuthentication ([PSCustomObject]@{ mode = 'child-session'; authentication = $true }) }

[PSCustomObject]@{ result = 'passed'; guardCases = $script:guardCases; wtsInfoSize = [CuaRdp.Native.ChildSessionNative]::WtsInfoSize; logonTimeOffset = [CuaRdp.Native.ChildSessionNative]::LogonTimeOffset; connectionAttempted = $false; enableAttempted = $false }
