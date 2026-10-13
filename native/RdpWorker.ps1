[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][int]$LauncherPid,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'ChildSessionRequest.ps1')
$request = $null
$password = $null
$credential = $null
try {
    $request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopProcess.cs'), (Join-Path $PSScriptRoot 'RdpWindow.cs'), (Join-Path $PSScriptRoot 'ChildSessionNative.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions
    $mode = Get-RdpRequestMode $request
    $expected = $null
    $interactiveAuthentication = Get-InteractiveAuthentication $request
    if ($mode -eq 'child-session') {
        $expected = Read-ChildSessionExpectation $request
        $userName = ''
        $domain = ''
        if (-not $SelfTest) { [CuaRdp.Native.ChildSessionGuard]::BeforeConnect([CuaRdp.Native.ChildSessionNative]::Capture(), $expected, [int]$request.port) }
    }
    elseif ($SelfTest) {
        $userName = 'self-test'
        $domain = ''
        $password = ''
    }
    else {
        $credential = Import-Clixml -LiteralPath $request.credentialPath
        if ($credential -isnot [Management.Automation.PSCredential]) { throw 'The credential file must contain an exported PSCredential.' }
        $network = $credential.GetNetworkCredential()
        $userName = $network.UserName
        $domain = $network.Domain
        $password = $network.Password
        $network = $null
    }
    $bootstrapPath = ''
    if ($null -ne $request.PSObject.Properties['bootstrapPath']) { $bootstrapPath = [string]$request.bootstrapPath }
    $guestRoot = 'C:\ProgramData\CuaRdp'
    if ($null -ne $request.PSObject.Properties['guestRoot']) { $guestRoot = [string]$request.guestRoot }
    [CuaRdp.Native.RdpWindow]::Run($request.statusPath, $request.stopPath, $bootstrapPath, $guestRoot, $LauncherPid, $request.address,
        [int]$request.port, [int]$request.width, [int]$request.height, $userName, $domain, $password, $SelfTest.IsPresent, $expected, $interactiveAuthentication)
    $status = [IO.File]::ReadAllText($request.statusPath) | ConvertFrom-Json
    if ($status.state -eq 'failed') { exit 1 }
}
catch {
    if ($null -ne $request) {
        $message = $_.Exception.Message
        $inner = $_.Exception.InnerException
        while ($null -ne $inner) { $message = $inner.Message; $inner = $inner.InnerException }
        if ($null -ne $password -and $password.Length -gt 0) { $message = $message.Replace($password, '[redacted]') }
        $data = @{ state = 'failed'; pid = $PID; error = $message; updatedAt = [DateTime]::UtcNow.ToString('o') }
        try {
            $temporary = $request.statusPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temporary, ($data | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            if ([IO.File]::Exists($request.statusPath)) { [IO.File]::Replace($temporary, $request.statusPath, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $request.statusPath) }
        }
        catch { }
    }
    exit 1
}
finally {
    $password = $null
    $credential = $null
}
