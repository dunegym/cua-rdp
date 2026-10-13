[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'native\DesktopProcess.cs')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CuaRdpParentObservation {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x, y; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetCursorPos(out Point point);
}
'@
$point = New-Object CuaRdpParentObservation+Point
if (-not [CuaRdpParentObservation]::GetCursorPos([ref]$point)) { throw 'Parent cursor position could not be observed.' }
@{
    sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    inputDesktop = [CuaRdp.Native.DesktopProcess]::InputDesktopName()
    foregroundWindow = [CuaRdpParentObservation]::GetForegroundWindow().ToInt64().ToString()
    clipboardSequence = [CuaRdpParentObservation]::GetClipboardSequenceNumber()
    cursor = @{ x = $point.x; y = $point.y }
} | ConvertTo-Json -Compress
