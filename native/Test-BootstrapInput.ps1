[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopProcess.cs'), (Join-Path $PSScriptRoot 'RdpWindow.cs'), (Join-Path $PSScriptRoot 'ChildSessionNative.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
function New-InputState([bool]$Focused) {
    $state = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $state['clientConnected'] = [int]1
    foreach ($key in @('formVisible','controlVisible','inputCapturePresent','inputCaptureVisible','inputCaptureEnabled')) { $state[$key] = $true }
    $state['threadFocusIsInputCapture'] = $Focused
    $state['foregroundIsKeeper'] = $Focused
    return ,$state
}
$lost = New-InputState $false
if ([CuaRdp.Native.BootstrapInputGate]::CanSend($true, $false, $lost)) {
    throw 'Lost RDP input focus must wait before the first SendKeys call, not attempt Win+R.'
}
$checks = 1
foreach ($interactive in @($true,$false)) {
    foreach ($started in @($true,$false)) {
        if (-not [CuaRdp.Native.BootstrapInputGate]::CanSend($interactive, $started, (New-InputState $true))) { throw 'A ready focused capture was refused.' }
        $checks++
    }
}
function Assert-Refused($State, [bool]$Interactive, [bool]$Started) {
    try { [void][CuaRdp.Native.BootstrapInputGate]::CanSend($Interactive, $Started, $State) }
    catch {
        if ($_.Exception.GetBaseException().Message -notmatch 'No input was sent') { throw }
        return
    }
    throw 'Missing input readiness/focus must stop before sending keys.'
}
Assert-Refused $lost $true $true; $checks++
foreach ($started in @($true,$false)) {
    if (-not [CuaRdp.Native.BootstrapInputGate]::CanSend($false, $started, $lost)) { throw 'Background startup must preserve the remote-only SendKeys path without acquiring local focus.' }
    $checks++
}
foreach ($key in @('formVisible','controlVisible','inputCapturePresent','inputCaptureVisible','inputCaptureEnabled','clientConnected')) {
    $invalid = New-InputState $true
    $invalid.Remove($key) | Out-Null
    Assert-Refused $invalid $true $false
    Assert-Refused $invalid $true $true
    $checks += 2
}
$noForeground = New-InputState $true
$noForeground['foregroundIsKeeper'] = $false
if ([CuaRdp.Native.BootstrapInputGate]::CanSend($true, $false, $noForeground)) { throw 'Interactive preparation must wait for user-provided foreground focus.' }
Assert-Refused $noForeground $true $true
if (-not [CuaRdp.Native.BootstrapInputGate]::CanSend($false, $false, $noForeground)) { throw 'Background mode must not require parent foreground activation.' }
$checks += 3
[PSCustomObject]@{ result = 'passed'; inputGateCases = $checks; connectionAttempted = $false; inputSent = $false; focusChanged = $false }
