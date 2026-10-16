[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$package = Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($package.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version.' }
foreach ($bundle in @('desktop-server.mjs', 'guest-agent.cjs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root ('dist\' + $bundle)) -PathType Leaf)) { throw 'Run npm run build before packaging.' }
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'ui\panel.html') -PathType Leaf)) { throw 'Run npm run build before packaging.' }

$paths = @('plugin.json', '.zcode-plugin', '.claude-plugin', '.agents\plugins', 'mcp.json', '.mcp.json', 'skills', 'agents', 'extensions', 'ui', 'ui-src', 'src', 'guest', 'native', 'docs', 'README.md', 'LICENSE', 'package.json')
$files = @(
    foreach ($relative in $paths) {
        $item = Get-Item -LiteralPath (Join-Path $root $relative) -Force
        if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force }
        else { $item }
    }
    foreach ($relative in @('dist\desktop-server.mjs', 'dist\guest-agent.cjs', 'scripts\Common.ps1', 'scripts\Broker.ps1', 'scripts\Initialize-CuaRdp.ps1', 'scripts\New-CuaRdpVm.ps1')) {
        Get-Item -LiteralPath (Join-Path $root $relative)
    }
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts\child') -File
) | Where-Object {
    $_.FullName -notlike (Join-Path $root 'native\debug\*') -and
    $_.Name -notlike 'Test-*' -and $_.Name -ne 'evals.json'
} | Sort-Object FullName -Unique

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archivePath = Join-Path $root ('dist\cua-rdp-' + $package.version + '.zip')
$temporary = $archivePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$archive = $null
try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package inputs must be ordinary files.' }
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, ('cua-rdp/' + $relative), [IO.Compression.CompressionLevel]::Optimal)
    }
    $archive.Dispose()
    $archive = $null
    Move-Item -LiteralPath $temporary -Destination $archivePath -Force
    [PSCustomObject]@{ archive = $archivePath; files = @($files).Count } | ConvertTo-Json -Compress
} finally {
    if ($null -ne $archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
