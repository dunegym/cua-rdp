[CmdletBinding()]
param(
    [Parameter()][ValidateSet('background', 'interactive', 'both')][string]$Variant = 'both',
    # 'hide-show' mirrors the production BecomeWatchWindow registration fix; 'none'
    # reproduces the lost-taskbar-entry bug (button registers only on a later shell event).
    [Parameter()][ValidateSet('none', 'hide-show', 'activate')][string]$Strategy = 'hide-show'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'Test-WatchWindow.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions,UIAutomationClient,UIAutomationTypes

$variants = if ($Variant -eq 'both') { @('background', 'interactive') } else { @($Variant) }
$results = @()
foreach ($name in $variants) {
    $interactive = $name -eq 'interactive'
    Write-Host ("== variant: " + $name + " strategy: " + $Strategy)
    $probe = New-Object CuaRdp.Native.WatchProbe($interactive, $Strategy)
    [System.Windows.Forms.Application]::Run($probe)
    $payload = $probe.Report | ConvertFrom-Json
    # The taskbar names an unknown-AUMID window's group after the process ("Windows
    # PowerShell"), not the window title, so the button assertion is a count delta against
    # the baseline phase: the probe registered a button iff it added one such group.
    function Count-Phase([object]$phases, [string]$name) {
        $phase = $phases | Where-Object { $_.phase -eq $name } | Select-Object -First 1
        if ($null -eq $phase -or -not $phase.buttonNames) { return -1 }
        return ([regex]::Matches($phase.buttonNames, 'Windows PowerShell')).Count
    }
    $baseline = Count-Phase $payload.phases 'baseline'
    foreach ($phase in $payload.phases) {
        $count = -1
        if ($phase.buttonNames) { $count = ([regex]::Matches($phase.buttonNames, 'Windows PowerShell')).Count }
        Write-Host ("{0,-22} psButtons={1,-3} delta={2,-3} iconic={3,-5} parked={4,-5} exStyle={5} x={6}" -f $phase.phase, $count, ($count - $baseline), $phase.iconic, $phase.parked, $phase.exStyle, $phase.x)
    }
    if ($payload.fatal) { Write-Host ("FATAL: " + $payload.fatal) }
    $watchDelta = (Count-Phase $payload.phases 'watch-settled') - $baseline
    $parkedDelta = (Count-Phase $payload.phases 'min-parked') - $baseline
    $parkedIconic = [bool]($payload.phases | Where-Object { $_.phase -eq 'min-parked' } | Select-Object -ExpandProperty iconic)
    $parkedVisible = ($payload.phases | Where-Object { $_.phase -eq 'min-parked' } | Select-Object -ExpandProperty visible)
    $taskbarRestoredX = ($payload.phases | Where-Object { $_.phase -eq 'taskbar-restored' } | Select-Object -ExpandProperty x)
    $closeParkedAlive = [bool]($payload.phases | Where-Object { $_.phase -eq 'close-parked' })
    $externalCloseAlive = [bool]($payload.phases | Where-Object { $_.phase -eq 'external-close-parked' })
    $trayRestoredX = ($payload.phases | Where-Object { $_.phase -eq 'tray-restored' } | Select-Object -ExpandProperty x)
    $results += [PSCustomObject]@{
        variant            = $name
        strategy           = $Strategy
        watchButton        = ($watchDelta -ge 1)
        parkedButton       = ($parkedDelta -ge 1)
        parkedIconic       = $parkedIconic
        parkedVisible      = [bool]$parkedVisible
        # SetForegroundWindow from a probe process can be denied by the foreground lock in
        # the interactive variant; only the background variant asserts the click restore.
        taskbarRestoreWorks = if ($name -eq 'background') { ($taskbarRestoredX -lt 1000) } else { $null }
        closeParks         = $closeParkedAlive
        externalCloseParks = $externalCloseAlive
        trayRestoreWorks   = ($trayRestoredX -lt 1000)
    }
}

$failed = @($results | Where-Object {
    -not $_.watchButton -or -not $_.parkedButton -or $_.parkedIconic -or -not $_.parkedVisible -or
    ($_.taskbarRestoreWorks -eq $false) -or -not $_.closeParks -or -not $_.externalCloseParks -or -not $_.trayRestoreWorks
})
Write-Host ''
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($failed.Count -gt 0) {
    Write-Host 'FAIL: the watch window lost its taskbar button (or stayed minimized) in at least one variant.'
    exit 1
}
Write-Host 'PASS: the watch window kept a taskbar button through every park in every variant.'
