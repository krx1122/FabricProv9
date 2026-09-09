# ═════════════════════════════════════════════════════════════════════════════
#  RDP FABRIC PRO v9.1 — main entry
#  pwsh -NoProfile -File .github/scripts/Fabric.ps1 -Mode full [-Param ...]
#
#  Design (see RDP-Fabric-Rebuild-Guide):
#   * One $cfg object resolved once (env → param → default) and passed to every
#     phase. Nothing re-reads FAB_* env vars downstream.
#   * Phases are declared fatal or best-effort HERE, nowhere else.
#     Fatal: 0 Inventory, 1c RDP, 2 Tailscale. Everything else is best-effort.
#   * Modules dot-source from lib/; session scripts live in session/.
#   * v9.1: Net.ps1 wired as Phase 2.1 (after Tailscale — both NICs exist,
#     before runtimes). No cycles, no GH_PAT, no self-dispatch.
# ═════════════════════════════════════════════════════════════════════════════
[CmdletBinding()]
param(
    [string]$Mode             = '',
    [string]$WorkloadProfile  = '',
    [string]$RdpCompression   = '',
    [string]$QuickTest        = '',
    [string]$EnableRamdisk    = '',
    [string]$ReclaimDisk      = '',
    [string]$StartupUrl       = '',
    [string]$Notify           = '',
    [string]$TailscaleVersion = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$lib = Join-Path $PSScriptRoot 'lib'
foreach ($m in @('Config.ps1','Inventory.ps1','Tune.ps1','Disk.ps1','Rdp.ps1','Tailscale.ps1','Net.ps1','Runtimes.ps1','Workstation.ps1','Hold.ps1')) {
    $p = Join-Path $lib $m
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing module: $p" }
    . $p
}

$cfg = Resolve-FabricConfig -Mode $Mode -WorkloadProfile $WorkloadProfile -RdpCompression $RdpCompression `
        -QuickTest $QuickTest -EnableRamdisk $EnableRamdisk -ReclaimDisk $ReclaimDisk `
        -StartupUrl $StartupUrl -Notify $Notify -TailscaleVersion $TailscaleVersion
$cfg | Add-Member -NotePropertyName ScriptsDir -NotePropertyValue $PSScriptRoot -Force

$title = "RDP FABRIC PRO v$($cfg.Version) — mode: $($cfg.Mode)"
$w = [math]::Max($title.Length + 4, 52)
Write-Host ("╔" + ('═' * ($w - 2)) + "╗") -ForegroundColor Cyan
Write-Host ("║ " + $title.PadRight($w - 4) + " ║") -ForegroundColor Cyan
Write-Host ("╚" + ('═' * ($w - 2)) + "╝") -ForegroundColor Cyan

# Run order is the conflict-avoidance mechanism — do not reorder.
Invoke-FabricPhase -Cfg $cfg -Name 'Phase 0 — inventory'   -Fatal -Block { Invoke-FabricInventory $cfg }

if ($cfg.Mode -eq 'full') {
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 1a — tune services'  -Block { Invoke-FabricTuneServices $cfg }
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 1b — memory/sched'   -Block { Invoke-FabricMemory $cfg }
}
Invoke-FabricPhase -Cfg $cfg -Name 'Phase 1c — RDP'        -Fatal -Block { Invoke-FabricRdp $cfg }
if ($cfg.Mode -eq 'full') {
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 1d — disk'           -Block { Invoke-FabricDisk $cfg }
}
Invoke-FabricPhase -Cfg $cfg -Name 'Phase 2 — Tailscale'   -Fatal -Block { Invoke-FabricTailscale $cfg }
if ($cfg.Mode -eq 'full') {
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 2.1 — Azure NIC/TCP' -Block { Invoke-FabricNetStack $cfg }
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 2.5 — runtimes'      -Block { Invoke-FabricRuntimes $cfg }
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 2.7 — workstation'   -Block { Invoke-FabricWorkstation $cfg }
    Invoke-FabricPhase -Cfg $cfg -Name 'Phase 2.8 — session UX'    -Block { Register-FabricSessionUx $cfg }
}

Invoke-FabricHold $cfg
Write-FabricLog $cfg "engine exit (warnings: $($cfg.FailCount))."
