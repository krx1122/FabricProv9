# teardown.ps1 — runs with if: always().
# GitHub-hosted: Tailscale logout + task cleanup (the VM dies anyway).
# Self-hosted / persistent runner: also remove the admin account, the firewall
# rules, and the widened ACLs — otherwise the next job inherits an admin.
$ErrorActionPreference = 'SilentlyContinue'

$root = $env:FABRIC_ROOT
if (-not $root) { $root = 'C:\ProgramData\RDPFabric' }
$user = $env:RDP_USER
if (-not $user) { $user = 'FabricAdmin' }

$st = $null
try { $st = Get-Content -LiteralPath (Join-Path $root 'state.json') -Raw | ConvertFrom-Json } catch {}
$hosted = ($env:FAB_RUNNER_IMAGE -eq 'windows-latest') -or ($st -and $st.image -eq 'GhaWindowsLatest')

# ── always ──
$tsPath = 'C:\Program Files\Tailscale\tailscale.exe'
if (Test-Path -LiteralPath $tsPath) { & $tsPath logout 2>$null | Out-Null; Write-Host "Tailscale logged out." }
if (Test-Path -LiteralPath 'C:\Program Files\ImDisk\imdisk.exe') { & 'C:\Program Files\ImDisk\imdisk.exe' -d -m R: 2>$null | Out-Null }
Unregister-ScheduledTask -TaskName 'RDPFabric-Session' -Confirm:$false -ErrorAction SilentlyContinue

# ── self-hosted only ──
if (-not $hosted) {
    Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName 'RDP-TCP-In-Tailscale','RDP-UDP-In-Tailscale','Tailscale-In-UDP','Tailscale-Out-UDP' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    if ($st -and $st.data_root) {
        foreach ($p in @($st.data_root, (Join-Path $st.data_root 'Drop'), (Join-Path $st.data_root 'Tools'), (Join-Path $st.data_root 'CrashDumps'))) {
            if (Test-Path -LiteralPath $p) { icacls $p /remove:g "$user" /T /C /Q | Out-Null }
        }
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } }
    Write-Host "Self-hosted cleanup done (user removed, scoped rules removed, ACLs restored, pagefile system-managed)."
}

Write-Host "Teardown complete (hosted=$hosted)."
