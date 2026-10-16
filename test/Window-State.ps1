[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('state', 'minimize', 'hide', 'show', 'restore', 'offscreen', 'close')][string]$Action
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class WinState {
    public delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static List<IntPtr> WindowsOf(uint pid) {
        var result = new List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner == pid && IsWindow(window)) result.Add(window);
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
$keeper = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -Property ProcessId, CommandLine |
    Where-Object { $_.CommandLine -like '*RdpWorker.ps1*' } | Select-Object -First 1)
if ($keeper.Count -eq 0) { throw 'RdpWorker keeper process not found.' }
$process = Get-Process -Id ([int]$keeper[0].ProcessId)
$windows = [WinState]::WindowsOf([uint32]$process.Id)
if ($windows.Count -eq 0) { throw ('Keeper has no top-level windows; MainWindowTitle was [' + $process.MainWindowTitle + '].') }
# Prefer the main form by its title; enumeration order puts unrelated mstscax top-level
# windows first, and sending window messages to those can destroy the control outright.
$hwnd = [IntPtr]::Zero
$builder = New-Object System.Text.StringBuilder 512
foreach ($candidate in $windows) {
    $builder.Clear() | Out-Null
    [void][WinState]::GetWindowTextW($candidate, $builder, $builder.Capacity)
    if ($builder.ToString().StartsWith('cua-rdp child session', [StringComparison]::Ordinal)) { $hwnd = $candidate; break }
}
if ($hwnd -eq [IntPtr]::Zero -and [WinState]::IsWindow($process.MainWindowHandle)) { $hwnd = $process.MainWindowHandle }
if ($hwnd -eq [IntPtr]::Zero) { $hwnd = $windows[0] }
switch ($Action) {
    'minimize' { [void][WinState]::ShowWindow($hwnd, 6) }
    'hide' { [void][WinState]::ShowWindow($hwnd, 0) }
    'show' { [void][WinState]::ShowWindow($hwnd, 5) }
    'close' { [void][WinState]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    'restore' {
        [void][WinState]::ShowWindow($hwnd, 9)
        [void][WinState]::SetWindowPos($hwnd, [IntPtr]::Zero, 32, 32, 0, 0, 0x0001 -bor 0x0004)
    }
    'offscreen' {
        [void][WinState]::ShowWindow($hwnd, 5)
        $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
        [void][WinState]::SetWindowPos($hwnd, [IntPtr]::Zero, $screen.Right + 64, $screen.Y, 0, 0, 0x0001 -bor 0x0004)
    }
    default { }
}
Start-Sleep -Milliseconds 300
$titleBuilder = New-Object System.Text.StringBuilder 512
[void][WinState]::GetWindowTextW($hwnd, $titleBuilder, $titleBuilder.Capacity)
$rect = New-Object WinState+RECT
[void][WinState]::GetWindowRect($hwnd, [ref]$rect)
[PSCustomObject]@{
    pid = $process.Id; hwnd = [int64]$hwnd; visible = [WinState]::IsWindowVisible($hwnd); minimized = [WinState]::IsIconic($hwnd)
    title = $titleBuilder.ToString()
    x = $rect.Left; y = $rect.Top; width = ($rect.Right - $rect.Left); height = ($rect.Bottom - $rect.Top)
    processMainWindowTitle = $process.MainWindowTitle; visibleTopLevelWindows = $windows.Count
} | ConvertTo-Json -Compress
