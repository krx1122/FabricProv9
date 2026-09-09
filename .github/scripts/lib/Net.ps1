# lib/Net.ps1 — Phase 2.1 (best-effort, full only): Azure NIC + global TCP for
# hop A (Telegram CDN → Ethernet). Tailscale NIC stays MTU 1280 only (Phase 2).
# Does not disable the firewall, open inbound 3389, or evade Telegram policy.
# v9.1: S10 hop-A probe → state.probe_mbps (skipped on quick_test, never fails).

function Get-FabricAzureNics {
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

function Invoke-FabricNetStack {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2.1: Azure NIC + TCP stack (Telegram path)"

    $tcp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Set-FabricReg $Cfg $tcp 'Tcp1323Opts' 1
    Set-FabricReg $Cfg $tcp 'SackOpts' 1
    Set-FabricReg $Cfg $tcp 'DefaultTTL' 64
    Set-FabricReg $Cfg $tcp 'EnablePMTUDiscovery' 1
    Set-FabricReg $Cfg $tcp 'EnablePMTUBHDetect' 0
    Set-FabricReg $Cfg $tcp 'TcpTimedWaitDelay' 30
    Set-FabricReg $Cfg $tcp 'MaxUserPort' 65534
    Set-FabricReg $Cfg $tcp 'TcpMaxDataRetransmissions' 5
    Set-FabricReg $Cfg $tcp 'EnableRSS' 1
    Set-FabricReg $Cfg $tcp 'EnableTCPChimney' 0
    Set-FabricReg $Cfg $tcp 'EnableWsd' 0
    Set-FabricReg $Cfg $tcp 'DisableTaskOffload' 0
    # Never set GlobalMaxTcpWindowSize — that caps the window and kills scaling.

    netsh int ipv4 set dynamicport tcp start=1025 num=64510 | Out-Null
    netsh int ipv4 set dynamicport udp start=1025 num=64510 | Out-Null
    netsh winhttp reset proxy | Out-Null
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
    # S1: profile=network means "interactive + this module" — autotune stays
    # normal; v8's 'experimental' breaks some Azure paths and is refused.
    if ($Cfg.Profile -eq 'network') {
        Write-FabricLog $Cfg "profile=network → autotune stays 'normal'; the Net stack IS the network profile."
    }

    # Prefer IPv4 for public dual-stack; IPv6 stays up (Tailscale needs it).
    try {
        netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 100 4 | Out-Null
    } catch {}

    $nics = @(Get-FabricAzureNics)
    if ($nics.Count -eq 0) {
        $nics = @(Get-NetAdapter | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Tailscale|Loopback|WAN Miniport'
        })
    }
    foreach ($nic in $nics) {
        try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        try { Enable-NetAdapterRss -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        try { Enable-NetAdapterRsc -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        try { Enable-NetAdapterChecksumOffload -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        try { Enable-NetAdapterLso -Name $nic.Name -ErrorAction SilentlyContinue } catch {}
        $adv = @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)
        foreach ($p in @(
            'Receive Side Scaling',
            'Recv Segment Coalescing (IPv4)', 'Recv Segment Coalescing (IPv6)',
            'IPv4 Checksum Offload',
            'TCP Checksum Offload (IPv4)', 'TCP Checksum Offload (IPv6)',
            'UDP Checksum Offload (IPv4)', 'UDP Checksum Offload (IPv6)',
            'Large Send Offload V2 (IPv4)', 'Large Send Offload V2 (IPv6)'
        )) {
            if ($adv | Where-Object { $_.DisplayName -eq $p }) {
                Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p -DisplayValue 'Enabled' -ErrorAction SilentlyContinue
            }
        }
        # Jumbo frames break Azure PMTU — pin 1514.
        if ($adv | Where-Object { $_.DisplayName -eq 'Jumbo Packet' }) {
            Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName 'Jumbo Packet' -DisplayValue '1514' -ErrorAction SilentlyContinue
        }
        # Max out driver buffers where the NIC exposes numeric choices.
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
        if (Test-Path $netbt) { Set-FabricReg $Cfg $netbt 'NetbiosOptions' 2 }
        Write-FabricLog $Cfg ("NIC tuned: {0}" -f $nic.Name)
    }
    Set-FabricReg $Cfg 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' 'EnableLMHOSTS' 0

    # DNS cache: no negative caching.
    $dnsc = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
    Set-FabricReg $Cfg $dnsc 'MaxCacheTtl' 3600
    Set-FabricReg $Cfg $dnsc 'MaxNegativeCacheTtl' 0
    Set-FabricReg $Cfg $dnsc 'NegativeCacheTime' 0
    Set-FabricReg $Cfg $dnsc 'NetFailureCacheTime' 0
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    foreach ($s in @('DoSvc', 'bits', 'PeerDistSvc')) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
    }

    Save-FabricState $Cfg ([ordered]@{ net_stack = 'azure-aggressive-v9.1' })
    Write-FabricLog $Cfg "Azure NIC/TCP stack applied (heuristics off, autotune=normal, CUBIC, IPv4 preferred)."

    # ── S10: hop-A probe (Cloudflare ~20 MB) — best-effort, never fatal ──
    if (-not $Cfg.QuickTest) {
        try {
            $probeDir = Join-Path $Cfg.DataRoot 'Temp'
            New-Item -ItemType Directory -Path $probeDir -Force -ErrorAction SilentlyContinue | Out-Null
            $probe = Join-Path $probeDir 'hopA-probe.bin'
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            & curl.exe -sS -L --max-time 20 -o $probe "https://speed.cloudflare.com/__down?bytes=20000000"
            $sw.Stop()
            $bytes = 0
            if (Test-Path -LiteralPath $probe) { $bytes = (Get-Item -LiteralPath $probe).Length; Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
            if ($bytes -gt 1MB -and $sw.Elapsed.TotalSeconds -gt 0) {
                $mbps = [math]::Round(($bytes * 8) / $sw.Elapsed.TotalSeconds / 1MB, 1)
                Save-FabricState $Cfg ([ordered]@{ probe_mbps = $mbps })
                Write-FabricLog $Cfg "Hop-A probe: $mbps Mbps (Cloudflare 20 MB)."
            } else {
                Write-FabricLog $Cfg "Hop-A probe inconclusive (Azure outbound constrained this run)."
            }
        } catch { Write-FabricLog $Cfg "Hop-A probe skipped: $($_.Exception.Message)" }
    }
}
