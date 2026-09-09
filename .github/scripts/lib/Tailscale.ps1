# lib/Tailscale.ps1 — Phase 2 (fatal).
# v9.1: M1 (Start-Process ArgumentList arrays take raw paths), S8 (--reset
# only on github-hosted), S2 (honest path detection: Self.Relay proves DERP,
# an active peer with CurAddr proves direct — otherwise 'unknown', and
# compression stays on until direct is proven).

function Invoke-FabricTailscale {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2: Tailscale mesh"

    $msi  = $Cfg.TsMsiPath
    $part = $Cfg.TsPartPath

    # ── settle the background download started in Phase 0 (cap ~40s) ──
    if ($Cfg.TsDlProc) {
        $waited = 0
        while (-not $Cfg.TsDlProc.HasExited -and $waited -lt 40) { Start-Sleep -Seconds 1; $waited++ }
        if (-not $Cfg.TsDlProc.HasExited) { try { $Cfg.TsDlProc.Kill() } catch {} }
        if (Test-FabricFile $part 1MB) { Move-Item -LiteralPath $part -Destination $msi -Force }
    }

    # ── synchronous fallback ──
    if (-not (Test-FabricFile $msi 1MB)) {
        Write-FabricLog $Cfg "MSI not cached — synchronous fetch ($($Cfg.TsVersion))..."
        New-Item -ItemType Directory -Path (Split-Path $msi) -Force | Out-Null
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        $ok = $false
        for ($i = 0; $i -lt 4 -and -not $ok; $i++) {
            & curl.exe -sS -L --retry 3 --retry-all-errors -m 300 --connect-timeout 15 -o $part $Cfg.TsMsiUrl
            if ($LASTEXITCODE -eq 0 -and (Test-FabricFile $part 1MB)) {
                Move-Item -LiteralPath $part -Destination $msi -Force
                $ok = $true
            } else { Start-Sleep -Seconds 3 }
        }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        if (-not $ok) { throw "Tailscale MSI download failed ($($Cfg.TsMsiUrl))." }
    }

    # ── optional integrity check (repo variable FAB_TS_SHA256) ──
    if ($Cfg.TsSha256) {
        $h = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        if ($h -ne $Cfg.TsSha256.ToUpperInvariant()) { throw "Tailscale MSI SHA256 mismatch." }
        Write-FabricLog $Cfg "MSI SHA256 verified."
    } else {
        Write-FabricLog $Cfg "Version pinned to $($Cfg.TsVersion); set repo variable FAB_TS_SHA256 to enforce a hash."
    }

    # ── install (0/1641/3010 = binary should exist). M1: raw paths in arrays. ──
    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -PassThru -Wait
    if ($p.ExitCode -notin 0, 1641, 3010) {
        Write-FabricLog $Cfg "msiexec exit $($p.ExitCode) — retrying once."
        Start-Sleep -Seconds 5
        $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -PassThru -Wait
    }
    if (-not (Test-Path -LiteralPath $Cfg.TsExe)) { throw "Tailscale installation failed (msiexec exit $($p.ExitCode))." }

    # ── up (use an EPHEMERAL, TAGGED auth key — a reusable key outlives the VM) ──
    $parts = @('fab', "$env:RUN_ID", "$env:MATRIX_ID") | Where-Object { $_ -and $_.Trim() }
    $hn = (($parts -join '-') -replace '[^a-zA-Z0-9-]', '-').Trim('-').ToLowerInvariant()
    if ($hn.Length -gt 60) { $hn = $hn.Substring(0, 60).Trim('-') }
    $Cfg.TsHostname = $hn
    # S8: --reset only on hosted runners — a self-hosted node keeps its identity.
    $up = @('up', "--authkey=$env:TS_AUTHKEY", "--hostname=$($Cfg.TsHostname)",
            '--accept-routes=false', '--accept-dns=false', '--unattended')
    if ($env:RUNNER_ENVIRONMENT -eq 'github-hosted') { $up += '--reset' }
    & $Cfg.TsExe @up

    $backend = $null
    for ($i = 0; $i -lt 40; $i++) {
        try { $backend = (& $Cfg.TsExe status --json 2>$null | ConvertFrom-Json).BackendState } catch {}
        if ($backend -eq 'Running') { break }
        Start-Sleep -Seconds 1
    }
    if ($backend -ne 'Running') { throw "Tailscale BackendState='$backend' — check the auth key." }

    $ip = ''; $t = 30
    while ($ip -notmatch '^100\.' -and $t -gt 0) {
        Start-Sleep -Seconds 1
        $ip = (& $Cfg.TsExe ip -4 | Out-String).Trim(); $t--
    }
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Failed to acquire a Tailscale IPv4." }
    $Cfg.TsIp = $ip

    # ── S2: honest path detection. At provision time no peer is connected yet,
    # so the honest answer is usually 'unknown' — compression stays ON until a
    # direct peer path is proven (safe default for DERP, minor cost if direct).
    $Cfg.TsDirect = $false
    $pathLabel = 'unknown'
    $j = $null
    try { $j = (& $Cfg.TsExe status --json 2>$null | ConvertFrom-Json) } catch {}
    if ($j -and $j.Self) {
        if ([string]$j.Self.Relay -ne '') {
            $pathLabel = 'DERP relay'
        } else {
            $peers = @($j.Peer.PSObject.Properties.Value)
            $directPeer = @($peers | Where-Object { $_.Active -and $_.CurAddr -and -not $_.Relay })
            if ($directPeer.Count -gt 0) { $Cfg.TsDirect = $true; $pathLabel = 'direct' }
        }
    }

    # ── the TCP knobs that actually matter on this path: MTU + no-delay ──
    $tsAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Tailscale' -or $_.Name -match 'Tailscale' } | Select-Object -First 1
    if ($tsAdapter) {
        netsh interface ipv4 set subinterface "$($tsAdapter.Name)" mtu=1280 store=persistent | Out-Null
        $ifKey = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DhcpIPAddress -eq $Cfg.TsIp -or
                           (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).IPAddress -contains $Cfg.TsIp } |
            Select-Object -First 1
        if (-not $ifKey) { $ifKey = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($tsAdapter.InterfaceGuid)" -ErrorAction SilentlyContinue }
        if ($ifKey) {
            Set-FabricReg $Cfg $ifKey.PSPath "TcpAckFrequency" 1
            Set-FabricReg $Cfg $ifKey.PSPath "TCPNoDelay" 1
            Set-FabricReg $Cfg $ifKey.PSPath "TcpDelAckTicks" 0
        }
    }

    # ── compression: auto = off only when direct is PROVEN ──
    $wantComp = switch ($Cfg.RdpCompression) {
        'on'  { $true }
        'off' { $false }
        default { -not $Cfg.TsDirect }
    }
    $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    Set-FabricReg $Cfg $rdpTcp "fDisableCompression" $(if ($wantComp) {0} else {1}) -Important
    Set-FabricReg $Cfg $rdpTcp "MaxCompressionLevel" $(if ($wantComp) {2} else {0}) -Important

    Save-FabricState $Cfg ([ordered]@{
        host=$Cfg.TsHostname; ip=$Cfg.TsIp
        path=$pathLabel; ts_direct=$Cfg.TsDirect
        rdp_compression_effective=$(if ($wantComp) {'on'} else {'off'})
    })

    if ($Cfg.Notify) {
        $drop = Join-Path $Cfg.DataRoot 'Drop'
        $msg = "⚡ <b>Fabric Node Online v$($Cfg.Version)</b>`n`n🖥 <b>Host:</b> <code>$($Cfg.TsHostname)</code>`n🌐 <b>IP:</b> <code>$($Cfg.TsIp)</code>`n🔗 <b>Path:</b> <code>$pathLabel</code>`n👤 <b>User:</b> <code>$($Cfg.User)</code>`n🧠 <b>Profile:</b> <code>$($Cfg.Profile)</code>`n⚙️ <b>HW:</b> <code>$($Cfg.Cpu) CPU / $($Cfg.RamGB) GB</code>`n⏳ <b>Duration:</b> <code>$($Cfg.RuntimeMinutes)</code> min`n📁 <b>Drop:</b> <code>$drop</code>"
        Send-FabricNotify $Cfg $msg
    }

    Write-Host ("Tailscale online: {0} ({1}) path={2}" -f $Cfg.TsIp, $Cfg.TsHostname, $pathLabel) -ForegroundColor Green
    Write-FabricLog $Cfg ("CONNECT → {0} user={1} path={2} compression={3} (RDP accepts tailnet only)" -f `
        $Cfg.TsIp, $Cfg.User, $pathLabel, $(if ($wantComp) {'on'} else {'off'}))
}
