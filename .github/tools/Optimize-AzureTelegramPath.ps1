#Requires -RunAsAdministrator
# ═════════════════════════════════════════════════════════════════════════════
#  Optimize-AzureTelegramPath.ps1
#  Aggressive Azure-NIC + TCP stack for bulk downloads (Telegram Desktop, curl).
#
#  This does NOT:
#    - bypass Telegram rate limits, Premium caps, or DC policy
#    - disable Windows Firewall or open inbound 3389
#    - route traffic through Tailscale / an exit node
#    - disable TLS validation
#
#  Telegram on this VM uses the Azure adapter (Ethernet / 10.x), not Tailscale.
#  Run elevated inside the RDP session, then restart Telegram Desktop.
#
#    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Optimize-AzureTelegramPath.ps1
# ═════════════════════════════════════════════════════════════════════════════
[CmdletBinding()]
param(
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Write-NetStep([string]$m) { Write-Host "── $m" -ForegroundColor Cyan }
function Write-NetLog([string]$m)  { Write-Host $m }
function Write-NetWarn([string]$m) { Write-Host $m -ForegroundColor Yellow }

function Get-AzureNics {
    # Physical Hyper-V NIC(s). Exclude Tailscale, virtual switches, loopback.
    Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Tailscale|WAN Miniport|Loopback|Bluetooth|Virtual Switch' -and
        (
            $_.InterfaceDescription -match 'Hyper-V Network Adapter|Mellanox|NetXtreme|ConnectX|Azure' -or
            $_.Name -match '^Ethernet' -or
            $_.HardwareInterface
        )
    }
}

function Get-TailscaleNics {
    Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -match 'Tailscale' -or $_.Name -match 'Tailscale'
    }
}

function Set-RegDword([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction SilentlyContinue
}

function Invoke-Report {
    Write-NetStep "Path report"
    Write-NetLog ("OS: {0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)
    Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
        Write-NetLog ("IF {0}  IPv4={1}  GW={2}  DNS={3}" -f `
            $_.InterfaceAlias,
            (($_.IPv4Address.IPAddress) -join ','),
            (($_.IPv4DefaultGateway.NextHop) -join ','),
            (($_.DNSServer.ServerAddresses) -join ','))
    }
    Write-NetLog ""
    Write-NetLog "TCP global:"
    netsh int tcp show global
    Write-NetLog ""
    Write-NetLog "Autotune / heuristics:"
    netsh int tcp show heuristics
}

if ($ReportOnly) { Invoke-Report; return }

Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Azure NIC / TCP path tune  (Telegram hop A)        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── 1. Global TCP (affects Telegram CDN → Azure NIC) ────────────────────────
Write-NetStep "Global TCP stack"
$tcp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
Set-RegDword $tcp 'Tcp1323Opts'         1        # RFC 1323 window scaling
Set-RegDword $tcp 'SackOpts'            1        # selective ACK
Set-RegDword $tcp 'DefaultTTL'          64
Set-RegDword $tcp 'EnablePMTUDiscovery' 1
Set-RegDword $tcp 'EnablePMTUBHDetect'  0        # BH-detect hurts more than it helps on Azure
Set-RegDword $tcp 'TcpTimedWaitDelay'   30
Set-RegDword $tcp 'MaxUserPort'         65534
Set-RegDword $tcp 'TcpMaxDataRetransmissions' 5
Set-RegDword $tcp 'EnableRSS'           1
Set-RegDword $tcp 'EnableTCPChimney'    0
Set-RegDword $tcp 'EnableWsd'           0
Set-RegDword $tcp 'DisableTaskOffload'  0
# Do NOT set GlobalMaxTcpWindowSize to 65535 — that caps the window and kills scaling.

netsh int ipv4 set dynamicport tcp start=1025 num=64510 | Out-Null
netsh int ipv4 set dynamicport udp start=1025 num=64510 | Out-Null
netsh winhttp reset proxy | Out-Null

# Heuristics "restricted" is the usual silent throttle on Windows Server.
netsh int tcp set heuristics disabled | Out-Null
netsh int tcp set global autotuninglevel=normal | Out-Null
netsh int tcp set global rss=enabled | Out-Null
netsh int tcp set global rsc=enabled | Out-Null
netsh int tcp set global chimney=disabled | Out-Null
netsh int tcp set global ecncapability=disabled | Out-Null
netsh int tcp set global timestamps=disabled | Out-Null
netsh int tcp set global nonsackrttresiliency=disabled | Out-Null
netsh int tcp set global initialrto=1000 | Out-Null
netsh int tcp set global maxsynretransmissions=2 | Out-Null
netsh int tcp set global fastopen=enabled | Out-Null
netsh int tcp set global fastopenfallback=enabled | Out-Null
netsh int tcp set global pacingprofile=off | Out-Null

foreach ($tpl in @('Internet', 'Datacenter', 'InternetCustom', 'DatacenterCustom', 'Automatic')) {
    try {
        Set-NetTCPSetting -SettingName $tpl `
            -CongestionProvider CUBIC `
            -AutoTuningLevelLocal Normal `
            -EcnCapability Disabled `
            -Timestamps Disabled `
            -InitialCongestionWindowMss 10 `
            -ErrorAction Stop | Out-Null
    } catch {}
}

# Multimedia scheduler must not throttle background transfers.
Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' ([int]0xFFFFFFFF)
Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 0

# Delivery Optimization / BITS should not compete (Fabric already starves them).
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

Write-NetLog "Global TCP: scaling+SACK on, heuristics off, autotune=normal, CUBIC, chimney off, ECN off."

# ── 2. Prefer IPv4 (Telegram IPv6 from Azure is often the slow path) ────────
Write-NetStep "Prefer IPv4 for dual-stack destinations"
# Prefix policy only — do not disable IPv6 (breaks Tailscale v6).
try {
    netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 100 4 | Out-Null
    netsh interface ipv6 set prefixpolicy ::1/128 50 0 | Out-Null
    netsh interface ipv6 set prefixpolicy ::/0 10 1 | Out-Null
} catch {}
Write-NetLog "IPv6 stays up (Tailscale needs it). IPv4-mapped prefixes preferred for public dual-stack."

# ── 3. Azure / Hyper-V NIC — power, RSS, offloads, buffers ──────────────────
Write-NetStep "Physical NIC (Azure path)"
$nics = @(Get-AzureNics)
if ($nics.Count -eq 0) {
    Write-NetWarn "No Azure/Hyper-V NIC matched; applying power-mgmt disable to all non-Tailscale Up adapters."
    $nics = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Tailscale|Loopback|WAN Miniport' })
}
foreach ($nic in $nics) {
    Write-NetLog ("Tuning {0} [{1}]" -f $nic.Name, $nic.InterfaceDescription)
    try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
    try { Enable-NetAdapterRss -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
    try { Enable-NetAdapterRsc -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
    try { Enable-NetAdapterChecksumOffload -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
    try { Enable-NetAdapterLso -Name $nic.Name -ErrorAction SilentlyContinue } catch {}

    $adv = @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)
    $enableNames = @(
        'Receive Side Scaling',
        'Recv Segment Coalescing (IPv4)',
        'Recv Segment Coalescing (IPv6)',
        'IPv4 Checksum Offload',
        'TCP Checksum Offload (IPv4)',
        'TCP Checksum Offload (IPv6)',
        'UDP Checksum Offload (IPv4)',
        'UDP Checksum Offload (IPv6)',
        'Large Send Offload V2 (IPv4)',
        'Large Send Offload V2 (IPv6)'
    )
    foreach ($p in $enableNames) {
        if ($adv | Where-Object { $_.DisplayName -eq $p }) {
            Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p -DisplayValue 'Enabled' -ErrorAction SilentlyContinue
        }
    }
    # Jumbo frames break Azure PMTU — leave at 1514.
    if ($adv | Where-Object { $_.DisplayName -eq 'Jumbo Packet' }) {
        Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'Jumbo Packet' -DisplayValue '1514' -ErrorAction SilentlyContinue
    }
    foreach ($buf in @('Receive Buffers', 'Send Buffers', 'Receive Buffer Size', 'Transmit Buffers')) {
        $prop = $adv | Where-Object { $_.DisplayName -eq $buf } | Select-Object -First 1
        if ($prop -and $prop.ValidDisplayValues) {
            $best = $prop.ValidDisplayValues | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Measure-Object -Maximum
            if ($best.Maximum -gt 0) {
                Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $buf -DisplayValue "$($best.Maximum)" -ErrorAction SilentlyContinue
            }
        }
    }
    $netbt = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_$($nic.InterfaceGuid)"
    if (Test-Path $netbt) { Set-RegDword $netbt 'NetbiosOptions' 2 }  # disable NetBIOS on this NIC
}
Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' 'EnableLMHOSTS' 0

# ── 4. Tailscale NIC — leave it alone except MTU 1280 (RDP path only) ───────
Write-NetStep "Tailscale NIC (RDP only — not Telegram)"
foreach ($ts in @(Get-TailscaleNics)) {
    netsh interface ipv4 set subinterface "$($ts.Name)" mtu=1280 store=persistent | Out-Null
    Write-NetLog ("{0}: MTU 1280. No Nagle-off on Azure NIC; Telegram does not use this adapter." -f $ts.Name)
}

# ── 5. DNS — fast resolvers + no negative cache ─────────────────────────────
Write-NetStep "DNS"
$dnsc = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
Set-RegDword $dnsc 'MaxCacheTtl'          3600
Set-RegDword $dnsc 'MaxNegativeCacheTtl'  0
Set-RegDword $dnsc 'NegativeCacheTime'    0
Set-RegDword $dnsc 'NetFailureCacheTime'  0
Set-RegDword $dnsc 'MaxCacheSize'         8192
try {
    foreach ($nic in $nics) {
        # Keep Azure fabric DNS (168.63.129.16) first; append Cloudflare as fallback.
        $current = @((Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $want = @('168.63.129.16', '1.1.1.1', '1.0.0.1')
        if ($current -contains '168.63.129.16' -or $nic.InterfaceDescription -match 'Hyper-V') {
            Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $want -ErrorAction SilentlyContinue
        }
    }
} catch {}
Clear-DnsClientCache -ErrorAction SilentlyContinue
Write-NetLog "Negative DNS cache cleared and disabled."

# ── 6. Do not fight the firewall; only ensure outbound is allowed ───────────
Write-NetStep "Outbound policy (no inbound change)"
# Default Azure image allows outbound. Do not Enable-NetFirewallRule Remote Desktop.
try {
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    foreach ($p in $fw) {
        if ($p.DefaultOutboundAction -eq 'Block') {
            Write-NetWarn ("Profile {0} outbound is Block — leaving it. Fix policy, do not disable the firewall." -f $p.Name)
        }
    }
} catch {}

# ── 7. Quiet competing services (bandwidth, not "security bypass") ──────────
Write-NetStep "Stop competing transfer services"
foreach ($s in @('DoSvc', 'bits', 'PeerDistSvc', 'WMPNetworkSvc')) {
    Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
}

# ── 8. Telegram Desktop hints (if installed) ────────────────────────────────
Write-NetStep "Telegram Desktop"
$tgDirs = @(
    "$env:APPDATA\Telegram Desktop",
    "$env:APPDATA\AyuGram",
    "$env:APPDATA\AyuGram Desktop",
    'C:\Program Files\Telegram Desktop',
    'C:\Program Files (x86)\Telegram Desktop'
)
$found = $false
foreach ($d in $tgDirs) { if (Test-Path $d) { Write-NetLog "Found: $d"; $found = $true } }
if (-not $found) { Write-NetLog "Telegram Desktop not in default paths — launch it from D:\ drop after this script." }
Write-NetLog "After this script: fully quit Telegram (tray) and reopen. Save files to D:\RDPFabric\Data\Drop, not a mapped local drive."

# ── 9. Quick probe ──────────────────────────────────────────────────────────
Write-NetStep "Probe (50 MB via Cloudflare — hop A sanity)"
$probe = Join-Path $env:TEMP ('tg-path-probe-{0}.bin' -f [guid]::NewGuid().ToString('N'))
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& curl.exe -sS -L --max-time 25 -o $probe "https://speed.cloudflare.com/__down?bytes=50000000"
$sw.Stop()
$bytes = 0
if (Test-Path $probe) { $bytes = (Get-Item $probe).Length; Remove-Item $probe -Force -ErrorAction SilentlyContinue }
if ($bytes -gt 1MB -and $sw.Elapsed.TotalSeconds -gt 0) {
    $mbps = [math]::Round(($bytes * 8) / $sw.Elapsed.TotalSeconds / 1MB, 1)
    $MBps = [math]::Round($bytes / $sw.Elapsed.TotalSeconds / 1MB, 1)
    Write-Host ("Cloudflare probe: {0} MB in {1:n1}s  →  {2} MB/s ({3} Mbps)" -f `
        [math]::Round($bytes/1MB,1), $sw.Elapsed.TotalSeconds, $MBps, $mbps) -ForegroundColor Green
    Write-NetLog "If this number is high and Telegram is still slow, Telegram DC/cloud-IP policy is the cap — no NIC registry beats that."
} else {
    Write-NetWarn "Probe failed or too small. Azure outbound may be constrained this run."
}

Write-Host ""
Write-Host "Done. Restart Telegram Desktop. This script cannot raise Telegram Premium/DC caps." -ForegroundColor Cyan
Invoke-Report
