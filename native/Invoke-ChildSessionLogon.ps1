[CmdletBinding()]
param([switch]$Run)

$ErrorActionPreference = 'Stop'
if (-not $Run) {
    throw 'This explicit helper opens Windows authentication for the real plugin connection, runs a read-only acceptance probe, then disconnects. Credentials are never saved. Use -Run only when you want a visible logon window; Windows may require a password on every connection.'
}
$node = (Get-Command node -CommandType Application -ErrorAction Stop).Source
& $node (Join-Path (Split-Path -Parent $PSScriptRoot) 'test\probe-child-session.mjs') --run --interactive-authentication
exit $LASTEXITCODE
