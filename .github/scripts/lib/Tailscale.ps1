# lib/Tailscale.ps1 — Phase 2 (fatal).
# v9.3 (audit fix 4): the MSI must be Authenticode-signed by Tailscale AND
# match the hash when FAB_TS_SHA256 is set. Version pin alone is not enough.
# Fresh copy — use this file, not a hand-cut block from the bundle.

function Invoke-FabricTailscale {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2: Tailscale mesh"

    $msi  = $Cfg.TsMsiPath
    $part = $Cfg.TsPartPath

    if ($Cfg.TsDlProc) {
        $waited = 0
        while (-not $Cfg.TsDlProc.HasExited -and $waited -lt 40) { Start-Sleep -Seconds 1; $waited++ }
        if (-not $Cfg.TsDlProc.HasExited) { try { $Cfg.TsDlProc.Kill() } catch {} }
        if (Test-FabricFile $part 1MB) { Move-Item -LiteralPath $part -Destination $msi -Force }
    }

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

    # ── integrity: signature always, hash when provided ──
    $sig = Get-AuthenticodeSignature -LiteralPath $msi -ErrorAction SilentlyContinue
    if (-not $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Tailscale') {
        throw "Tailscale MSI failed Authenticode verification (status=$($sig.Status))."
    }
    Write-FabricLog $Cfg "MSI signature OK ($($sig.SignerCertificate.Subject -replace ',.*',''))."
    if ($Cfg.TsSha256) {
        $h = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        if ($h -ne $Cfg.TsSha256.ToUpperInvariant()) { throw "Tailscale MSI SHA256 mismatch." }
        Save-FabricState $Cfg ([ordered]@{ ts_sha256_verified = $h })
        Write-FabricLog $Cfg "MSI SHA256 verified."
    } else {
        Write-FabricLog $Cfg "Signed + pinned to $($Cfg.TsVersion); set repo variable FAB_TS_SHA256 to also enforce a hash."
    }

    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -PassThru -Wait
    if ($p.ExitCode -notin 0, 1641, 3010) {
        Write-FabricLog $Cfg "msiexec exit $($p.ExitCode) — retrying once."
        Start-Sleep -Seconds 5
        $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -PassThru -Wait
    }
    if (-not (Test-Path -LiteralPath $Cfg.TsExe)) { throw "Tailscale installation failed (msiexec exit $($p.ExitCode))." }

    $parts = @('fab', "$env:RUN_ID", "$env:MATRIX_ID") | Where-Object { $_ -and $_.Trim() }
    $hn = (($parts -join '-') -replace '[^a-zA-Z0-9-]', '-').Trim('-').ToLowerInvariant()
    if ($hn.Length -gt 60) { $hn = $hn.Substring(0, 60).Trim('-') }
    $Cfg.TsHostname = $hn
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

    $pathLabel = 'unknown'
    $j = $null
    try { $j = (& $Cfg.TsExe status --json 2>$null | ConvertFrom-Json) } catch {}
    if ($j -and $j.Self -and [string]$j.Self.Relay -ne '') { $pathLabel = 'DERP relay' }
    $Cfg.TsDirect = ($pathLabel -eq 'unknown' -and $j -and $j.Self -and [string]$j.Self.CurAddr -ne '')

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

    $compNow = Set-FabricRdpPictureQuality $Cfg ($pathLabel -eq 'DERP relay')

    Save-FabricState $Cfg ([ordered]@{
        host=$Cfg.TsHostname; ip=$Cfg.TsIp
        path=$pathLabel; ts_direct=$Cfg.TsDirect
        rdp_compression_effective=$(if ($compNow) {'on'} else {'off'})
    })

    if ($Cfg.Notify) {
        $drop = Join-Path $Cfg.DataRoot 'Drop'
        $msg = "⚡ <b>Fabric Node Online v$($Cfg.Version)</b>`n`n🖥 <b>Host:</b> <code>$($Cfg.TsHostname)</code>`n🌐 <b>IP:</b> <code>$($Cfg.TsIp)</code>`n🔗 <b>Path:</b> <code>$pathLabel</code>`n👤 <b>User:</b> <code>$($Cfg.User)</code>`n🧠 <b>Profile:</b> <code>$($Cfg.Profile)</code>`n⚙️ <b>HW:</b> <code>$($Cfg.Cpu) CPU / $($Cfg.RamGB) GB</code>`n⏳ <b>Duration:</b> <code>$($Cfg.RuntimeMinutes)</code> min`n📁 <b>Drop:</b> <code>$drop</code>"
        Send-FabricNotify $Cfg $msg
    }

    Write-Host ("Tailscale online: {0} ({1}) path={2}" -f $Cfg.TsIp, $Cfg.TsHostname, $pathLabel) -ForegroundColor Green
    Write-FabricLog $Cfg ("CONNECT → {0} user={1} path={2} compression={3} (RDP accepts tailnet only)" -f `
        $Cfg.TsIp, $Cfg.User, $pathLabel, $(if ($compNow) {'on'} else {'off'}))
}

# Live re-check used by the hold loop.
function Get-FabricTailscalePath {
    param([pscustomobject]$Cfg)
    $j = $null
    try { $j = (& $Cfg.TsExe status --json 2>$null | ConvertFrom-Json) } catch {}
    if (-not ($j -and $j.Self)) { return $null }
    if ([string]$j.Self.Relay -ne '') { return 'DERP relay' }
    $peers = @($j.Peer.PSObject.Properties.Value)
    if (@($peers | Where-Object { $_.Active -and $_.CurAddr -and -not $_.Relay }).Count -gt 0) { return 'direct' }
    if ([string]$j.Self.CurAddr -ne '') { return 'direct' }
    return 'unknown'
}
