[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not ('CuaRdp.Native.ChildSessionNative' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ChildSessionNative.cs')
}
if ([CuaRdp.Native.ChildSessionNative]::IsEnabled()) {
    [PSCustomObject]@{ enabled = $true; changed = $false }
    return
}
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Enable Windows RDP Child Sessions system-wide using WTSEnableChildSessions(true)')) {
    [CuaRdp.Native.ChildSessionNative]::Enable()
    if (-not [CuaRdp.Native.ChildSessionNative]::IsEnabled()) { throw 'Windows did not retain the Child Sessions enabled state.' }
    [PSCustomObject]@{ enabled = $true; changed = $true }
}
