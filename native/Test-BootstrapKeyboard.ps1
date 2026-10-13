[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopProcess.cs'), (Join-Path $PSScriptRoot 'RdpWindow.cs'), (Join-Path $PSScriptRoot 'ChildSessionNative.cs'), (Join-Path $PSScriptRoot 'Test-KeyboardInterop.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
$checks = 0
function Assert-Strokes([string]$Text, [string[]]$Expected) {
    $actual = @([CuaRdp.Native.BootstrapKeyboard]::EncodeAscii($Text) | ForEach-Object { $_.ToString('X8') })
    if (($actual -join ',') -cne ($Expected -join ',')) {
        throw ('SendKeys scan-code mismatch for "' + $Text + '": expected ' + ($Expected -join ',') + '; got ' + ($actual -join ','))
    }
    $script:checks++
}

# Wire contract: raw set-1 scan code in bits 0..7, 0x0100 marks extended keys, and the
# separate VARIANT_BOOL array (derived from the sign bit here) carries TRUE for key up.
Assert-Strokes 'a' @('0000001E', '8000001E')
Assert-Strokes 'A' @('0000002A', '0000001E', '8000001E', '8000002A')
Assert-Strokes ':' @('0000002A', '00000027', '80000027', '8000002A')
Assert-Strokes '\' @('0000002B', '8000002B')
Assert-Strokes '0' @('0000000B', '8000000B')
[int[][]]$batches = [CuaRdp.Native.BootstrapKeyboard]::EncodeBatches('ABcD-EF0123456789_')
$flattened = @($batches | ForEach-Object { $_ })
$whole = [CuaRdp.Native.BootstrapKeyboard]::EncodeAscii('ABcD-EF0123456789_')
if (($flattened -join ',') -cne ($whole -join ',')) { throw 'Keyboard batching dropped or reordered strokes.' }
foreach ($batch in $batches) {
    if ($batch.Length -gt 20 -or $batch.Length -lt 1) { throw 'Invalid atomic batch length.' }
    $held = @{}
    foreach ($stroke in $batch) {
        $scan = $stroke -band 0x1FF
        if ($stroke -lt 0) {
            if (-not $held.ContainsKey($scan)) { throw 'Key release was split from its press.' }
            $held.Remove($scan)
        }
        else { $held[$scan] = $true }
    }
    if ($held.Count -ne 0) { throw 'A modifier was left pressed across batches.' }
    $checks++
}
if ([CuaRdp.Native.BootstrapKeyboard]::KeyData(0x5B, $false, $true).ToString('X8') -cne '0000015B' -or
    [CuaRdp.Native.BootstrapKeyboard]::KeyData(0x5B, $true, $true).ToString('X8') -cne '8000015B') { throw 'Extended Win key encoding is incorrect.' }
$checks++
function Assert-CapsStrokes([string]$Text, [string[]]$Expected) {
    $actual = @([CuaRdp.Native.BootstrapKeyboard]::EncodeCapsAscii($Text) | ForEach-Object { $_.ToString('X8') })
    if (($actual -join ',') -cne ($Expected -join ',')) {
        throw ('Caps SendKeys scan-code mismatch for "' + $Text + '": expected ' + ($Expected -join ',') + '; got ' + ($actual -join ','))
    }
    $script:checks++
}
# Caps Lock supplies upper case directly: letters must be typed bare, without Shift.
Assert-CapsStrokes 'P' @('00000019', '80000019')
Assert-CapsStrokes 'p' @('00000019', '80000019')
Assert-CapsStrokes '5' @('00000006', '80000006')
Assert-CapsStrokes '.' @('00000034', '80000034')
Assert-CapsStrokes ':' @('0000002A', '00000027', '80000027', '8000002A')
Assert-CapsStrokes '\' @('0000002B', '8000002B')
Assert-CapsStrokes '_' @('0000002A', '0000000C', '8000000C', '8000002A')
Assert-CapsStrokes '/' @('00000035', '80000035')
$tap = @([CuaRdp.Native.BootstrapKeyboard]::Tap(0x3A) | ForEach-Object { $_.ToString('X8') })
if (($tap -join ',') -cne '0000003A,8000003A') { throw 'Caps Lock tap encoding is incorrect.' }
$checks++
[int[][]]$capsBatches = [CuaRdp.Native.BootstrapKeyboard]::EncodeCapsBatches('POWERSHELL.EXE -NOPROFILE -FILE C:\PROGRAMDATA\CUARDP\START-AGENT.PS1 -RUNID 0123456789ABCDEF0123456789ABCDEF')
$capsFlattened = @($capsBatches | ForEach-Object { $_ })
$capsWhole = [CuaRdp.Native.BootstrapKeyboard]::EncodeCapsAscii('POWERSHELL.EXE -NOPROFILE -FILE C:\PROGRAMDATA\CUARDP\START-AGENT.PS1 -RUNID 0123456789ABCDEF0123456789ABCDEF')
if (($capsFlattened -join ',') -cne ($capsWhole -join ',')) { throw 'Caps batching dropped or reordered strokes.' }
foreach ($batch in $capsBatches) {
    if ($batch.Length -gt 20 -or $batch.Length -lt 1) { throw 'Invalid atomic caps batch length.' }
    $held = @{}
    foreach ($stroke in $batch) {
        $scan = $stroke -band 0x1FF
        if ($stroke -lt 0) {
            if (-not $held.ContainsKey($scan)) { throw 'Key release was split from its press.' }
            $held.Remove($scan)
        }
        else { $held[$scan] = $true }
    }
    if ($held.Count -ne 0) { throw 'A modifier was left pressed across caps batches.' }
    $checks++
}
$expectedCommand = 'POWERSHELL.EXE -NOPROFILE -FILE C:\PROGRAMDATA\CUARDP\START-AGENT.PS1 -RUNID 51DC77CB76BA73CD64116F3F7E3970D4'
if ([CuaRdp.Native.BootstrapKeyboard]::CommandFor('51dc77cb76ba73cd64116f3f7e3970d4', 'C:\ProgramData\CuaRdp') -cne $expectedCommand) { throw 'The fixed caps bootstrap command shape changed.' }
$checks++
$rejected = $false
try { $null = [CuaRdp.Native.BootstrapKeyboard]::ValidateGuestRoot('C: b') } catch { $rejected = $true }
if (-not $rejected) { throw 'A space-containing guest root was accepted for the keyboard bootstrap.' }
$checks++
$checks += [CuaRdp.Native.KeyboardInteropTest]::Run()
[PSCustomObject]@{ result = 'passed'; keyboardCases = $checks; connectionAttempted = $false }
