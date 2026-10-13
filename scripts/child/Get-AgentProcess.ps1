[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$ProcessId)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$process = $null

try {
    $process = [Diagnostics.Process]::GetProcessById($ProcessId)
    $sessionId = $process.SessionId
    $startedAt = $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    if ($process.HasExited -or $sessionId -le 0) {
        throw 'The process must still be running in an interactive Windows session.'
    }
    @{ pid = $process.Id; sessionId = $sessionId; startedAt = $startedAt } | ConvertTo-Json -Compress
} catch {
    [Console]::Error.WriteLine('The agent process identity could not be verified in an interactive Windows session.')
    exit 1
} finally {
    if ($null -ne $process) { $process.Dispose() }
}
