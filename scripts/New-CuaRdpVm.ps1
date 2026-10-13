[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,63}$')][string]$Name,
    [Parameter(Mandatory = $true)][string]$BaseVhdPath,
    [Parameter(Mandatory = $true)][string]$VmDirectory,
    [Parameter(Mandatory = $true)][string]$SwitchName,
    [ValidateRange(2147483648, 68719476736)][long]$MemoryStartupBytes = 4294967296,
    [ValidateRange(1, 16)][int]$ProcessorCount = 2
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$BaseVhdPath = [IO.Path]::GetFullPath($BaseVhdPath)
$VmDirectory = [IO.Path]::GetFullPath($VmDirectory).TrimEnd('\')
if (-not (Test-Path -LiteralPath $BaseVhdPath -PathType Leaf) -or [IO.Path]::GetExtension($BaseVhdPath) -ine '.vhdx') {
    throw '[cua-rdp] Supply an existing bootable Windows VHDX prepared and licensed by the administrator.'
}
if ($VmDirectory.Length -le 3 -or (Test-Path -LiteralPath $VmDirectory)) { throw '[cua-rdp] VmDirectory must be a new directory; existing paths are never overwritten.' }
$parent = Split-Path -Parent $VmDirectory
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw '[cua-rdp] The VM parent directory must already exist.' }
Assert-CuaRdpPlainDirectory $parent
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw '[cua-rdp] A VM with this name already exists.' }
$switch = Get-VMSwitch -Name $SwitchName
if (@($switch).Count -ne 1) { throw '[cua-rdp] Select exactly one existing Hyper-V virtual switch.' }
$base = Get-VHD -Path $BaseVhdPath
if ($base.Attached) { throw '[cua-rdp] The base VHDX is attached. Use an offline immutable image.' }
$attached = @(Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $BaseVhdPath })
if ($attached.Count -gt 0) { throw '[cua-rdp] The base VHDX is attached to a VM. Use a separate offline immutable image.' }
if (-not $PSCmdlet.ShouldProcess(('VM {0} at {1}' -f $Name, $VmDirectory), 'Create a Generation 2 VM and a differencing VHDX without modifying the base image')) { return }
$null = New-Item -ItemType Directory -Path $VmDirectory
$diskPath = Join-Path $VmDirectory 'desktop.vhdx'
$null = New-VHD -Path $diskPath -ParentPath $BaseVhdPath -Differencing
$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $diskPath -SwitchName $switch.Name -Path $VmDirectory
Set-VMProcessor -VM $vm -Count $ProcessorCount
[ordered]@{
    created = $true; vmId = $vm.Id.ToString(); name = $vm.Name; state = [string]$vm.State
    diskPath = $diskPath; baseVhdPath = $BaseVhdPath
    note = 'The VM is not started. Keep the parent image immutable. Windows licensing, guest credentials, Node.js, cua-driver, RDP/NLA and a trusted RDP certificate are administrator prerequisites.'
} | ConvertTo-Json
