[CmdletBinding()]
param(
    [switch]$Run,
    [ValidateSet('bettergi', 'cua-rdp')][string]$Preset = 'bettergi',
    [int]$Port = 3389,
    [int]$Width = 800,
    [int]$Height = 600,
    [int]$TimeoutSeconds = 45,
    [string]$LogPath,
    [ValidateSet('preset', 'nla-off', 'public-mode', 'dummy-creds', 'machine-name', 'send-enter', 'trusted-zone', 'mark-secure', 'activate', 'offscreen', 'ghost', 'keytest', 'interactive', 'peek')][string]$SecurityFlavor = 'preset',
    [switch]$PrivateDesktop,
    [ValidateSet('minimal', 'production', 'production-nolayout', 'production-nowek', 'production-clean')][string]$ClientSettings = 'minimal',
    [switch]$OwnedChild,
    [string]$OwnerPath,
    [switch]$Bisect
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if (-not $Run) {
    Write-Error 'This diagnostic creates a real Windows Child Session and must be invoked with -Run. It never enables system features.'
}
if ($Width -lt 200 -or $Width -gt 8192 -or $Height -lt 200 -or $Height -gt 8192 -or $TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 900) {
    Write-Error 'Invalid diagnostic parameters.'
}
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ('cua-rdp-diag-' + [Guid]::NewGuid().ToString('N') + '.log') }
if ($LogPath -match '\s') { Write-Error 'The keytest bootstrap cannot type a marker path containing spaces.' }
if (-not $OwnerPath) { $OwnerPath = Join-Path $env:LOCALAPPDATA 'CuaRdp\child-session.owner.json' }
if ($ClientSettings -ne 'minimal' -and $SecurityFlavor -cne 'keytest') { Write-Error 'Client-settings variants are only defined for the keytest flavor.' }
if ($OwnedChild -and $SecurityFlavor -cne 'keytest' -and $SecurityFlavor -cne 'peek') { Write-Error 'Owned-child resume is only supported for the keytest and peek flavors.' }

$nativeRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'ChildConnectHarness.cs'
$desktopSource = Join-Path $nativeRoot 'DesktopProcess.cs'
$childNativeSource = Join-Path $nativeRoot 'ChildSessionNative.cs'
$rdpWindowSource = Join-Path $nativeRoot 'RdpWindow.cs'
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$childArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-File', $PSCommandPath,
    '-Run', '-Preset', $Preset, '-SecurityFlavor', $SecurityFlavor, '-Port', [string]$Port, '-Width', [string]$Width,
    '-Height', [string]$Height, '-TimeoutSeconds', [string]$TimeoutSeconds, '-LogPath', $LogPath,
    '-ClientSettings', $ClientSettings)
if ($OwnedChild) { $childArguments += @('-OwnedChild', '-OwnerPath', $OwnerPath) }

if ($PrivateDesktop) {
    Add-Type -Path $desktopSource
    $inputBefore = [CuaRdp.Native.DesktopProcess]::InputDesktopName()
    $child = [CuaRdp.Native.DesktopProcess]::Start($executable, $childArguments)
    try { while (-not $child.HasExited) { Start-Sleep -Milliseconds 250 }; $exit = $child.ExitCode }
    finally { $child.Dispose() }
    Write-Output ('inputDesktopBefore=' + $inputBefore + ' inputDesktopAfter=' + [CuaRdp.Native.DesktopProcess]::InputDesktopName())
}
elseif ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    & $executable @childArguments | Out-Host
    $exit = $LASTEXITCODE
}
else {
    Add-Type -Path $source, $desktopSource, $childNativeSource, $rdpWindowSource -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions, UIAutomationClient, UIAutomationTypes
    # This comparison harness is not the plugin controller; never take over an existing child.
    $lease = [CuaRdp.Native.ChildSessionControllerLease]::Acquire($false)
    try {
        $snapshot = [CuaRdp.Native.ChildSessionNative]::Capture()
        $expected = $null
        if ($null -ne $snapshot.childSessionId) {
            if (-not $OwnedChild) { throw 'Debug harness refuses every existing child. Use test/probe-child-session.mjs, or -OwnedChild with the exact plugin owner record.' }
            if (-not (Test-Path -LiteralPath $OwnerPath)) { throw 'The plugin owner record is missing; cannot resume an owned child.' }
            $owner = [IO.File]::ReadAllText($OwnerPath) | ConvertFrom-Json
            if ($owner.version -ne 1 -or
                [string]$owner.machineGuid -ine [string]$snapshot.machineGuid -or
                [string]$owner.userSid -cne [string]$snapshot.userSid -or
                $owner.parentSessionId -ne $snapshot.parentSessionId -or
                [string]$owner.parentLogonTime -cne [string]$snapshot.parentLogonTime -or
                $owner.childSessionId -ne $snapshot.childSessionId -or
                [string]$owner.childLogonTime -cne [string]$snapshot.childLogonTime) {
                throw 'The existing child does not exactly match the plugin owner record; it is not resumed.'
            }
            if ($snapshot.childState -ne 4) { throw 'The owned child is not disconnected; it is not resumed.' }
            if ([string]$snapshot.childUserSid -cne [string]$snapshot.userSid) { throw 'The owned child user changed; it is not resumed.' }
            Write-Output ('owned-resume childSessionId=' + $snapshot.childSessionId)
            $expected = [CuaRdp.Native.ChildSessionExpectation]::new($snapshot.parentSessionId, $snapshot.parentLogonTime, $snapshot.childSessionId, $snapshot.childLogonTime)
        }
        if ($null -eq $expected) { $expected = [CuaRdp.Native.ChildSessionExpectation]::new($snapshot.parentSessionId, $snapshot.parentLogonTime, $null, $null) }
        [CuaRdp.Native.ChildSessionGuard]::BeforeConnect($snapshot, $expected, $Port)
        $exit = [CuaRdp.Diag.ChildConnectForm]::Run($LogPath, $Preset, $Port, $Width, $Height, $TimeoutSeconds, $SecurityFlavor, $ClientSettings, $expected)
    }
    finally { $lease.Dispose() }
}

function Show-Mru {
    $mruKey = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' -ErrorAction SilentlyContinue
    if ($null -eq $mruKey) { Write-Output 'runMRU=absent'; return }
    $entries = @()
    foreach ($name in $mruKey.GetValueNames()) {
        if ($name -cne 'MRUList') { $entries += (($name) + '=' + ((([string]$mruKey.GetValue($name)) -replace '\x01$', ''))) }
    }
    $lastWrite = 'unreadable'
    try { $lastWrite = $mruKey.LastWriteTimeUtc.ToString('o') } catch { }
    Write-Output ('runMRU.lastWrite=' + $lastWrite)
    foreach ($entry in $entries) { Write-Output ('runMRU.' + $entry) }
}

Write-Output ('logPath=' + $LogPath)
Get-Content -LiteralPath $LogPath | Write-Output
Show-Mru

if ($Bisect) {
    # The first single attempt already ran above; report its outcome, then narrow the culprit set.
    $firstPass = ($exit -eq 0)
    Write-Output ('bisect.' + $ClientSettings + '=' + ($(if ($firstPass) { 'pass' } else { 'fail' })))
    if (-not $firstPass) {
        $remaining = @()
        if ($ClientSettings -ceq 'production') { $remaining = @('production-clean', 'minimal') }
        elseif ($ClientSettings -ceq 'production-clean') { $remaining = @('minimal') }
        foreach ($variant in $remaining) {
            Write-Output ('bisect: running ' + $variant + '; enter the Windows password when prompted')
            $variantLog = Join-Path ([IO.Path]::GetDirectoryName($LogPath)) (([IO.Path]::GetFileNameWithoutExtension($LogPath)) + '.' + $variant + '.log')
            & $executable -NoLogo -NoProfile -NonInteractive -STA -File $PSCommandPath -Run -Preset $Preset -SecurityFlavor $SecurityFlavor `
                -Port $Port -Width $Width -Height $Height -TimeoutSeconds $TimeoutSeconds -LogPath $variantLog -ClientSettings $variant `
                $(if ($OwnedChild) { @('-OwnedChild', '-OwnerPath', $OwnerPath) } else { @() }) | Write-Output
            $variantExit = $LASTEXITCODE
            Get-Content -LiteralPath $variantLog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'keytest|result' } | Write-Output
            Write-Output ('bisect.' + $variant + '=' + ($(if ($variantExit -eq 0) { 'pass' } else { 'fail' })))
            if ($variantExit -eq 0) { break }
        }
        Show-Mru
    }
}
exit $exit
