[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$RunId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Runtime.Common.ps1')

try {
    $line = [Console]::In.ReadLine()
    if ([string]::IsNullOrEmpty($line) -or $line.Length -gt 256) { throw '[cua-rdp] Expected a bounded stdin JSON ownership token.' }
    $inputValue = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json
    $token = Get-ChildRuntimeProperty $inputValue 'token'
    if ($token -isnot [string] -or $token -cnotmatch '^[0-9a-f]{64}$') { throw '[cua-rdp] Invalid stdin ownership token.' }
    Stop-ChildRuntimeAgent -RuntimeRoot $RuntimeRoot -RunId $RunId -Token $token | ConvertTo-Json -Compress
} catch {
    Write-Verbose ($_.FullyQualifiedErrorId + ' ' + $_.ScriptStackTrace)
    @{ stopped = $false; retained = $true; reason = (Get-CuaRdpSafeError $_ 'stop-child-runtime') } | ConvertTo-Json -Compress
    exit 1
}
