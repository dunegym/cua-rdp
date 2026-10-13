[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (-not ('CuaRdp.Native.ChildSessionNative' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ChildSessionNative.cs')
}
[CuaRdp.Native.ChildSessionNative]::Capture() | ConvertTo-Json -Depth 4 -Compress
