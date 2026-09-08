# lib/Hold.ps1 — Phase 4: quiet hold until the deadline.
#   every 30s:  Tailscale Running? else re-up.  3389 LISTEN? else re-assert
#               the SCOPED rules (never the built-in group).
#   every 60s:  heartbeat log line.
#   every 10m:  MOTW strip on Drop only + state refresh (keeps failure alerts
#               complete).
#   never:      EmptyWorkingSet on a 16 GB box; Enable-NetFirewallRule on the
#               "Remote Desktop" group; logging off the console session.

function Invoke-FabricMotwSweep {
    param([pscustomobject]$Cfg)
    $drop = Join-Path $Cfg.DataRoot 'Drop'
    if (Test-Path -LiteralPath $drop) {
        Get-ChildItem -Path $drop -Recurse -File -Force -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    }
}

function Invoke-FabricHold {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 4: hold until deadline"
    Write-FabricLog $Cfg "Holding $($Cfg.RuntimeMinutes) min (watchdog 30s, MOTW 10m Drop-only)."

    $gov = Join-Path $Cfg.ScriptsDir 'session\Governor.ps1'
    $tick = 0
    while ($Cfg.Deadline -and (Get-Date) -lt $Cfg.Deadline) {
        Start-Sleep -Seconds 30
        $tick++
        $left = [math]::Max(0, [math]::Round(($Cfg.Deadline - (Get-Date)).TotalMinutes, 1))

        # ── Tailscale ──
        $tsOk = $false
        if (Test-Path -LiteralPath $Cfg.TsExe) {
            $backend = $null
            try { $backend = (& $Cfg.TsExe status --json 2>$null | ConvertFrom-Json).BackendState } catch {}
            $tsOk = ($backend -eq 'Running')
            if (-not $tsOk) {
                Write-FabricLog $Cfg "Tailscale '$backend' — re-upping."
                & $Cfg.TsExe up --authkey="$env:TS_AUTHKEY" --hostname="$($Cfg.TsHostname)" --accept-routes=false --accept-dns=false --unattended 2>$null | Out-Null
            }
        }

        # ── RDP listener ──
        $rdpOk = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
        if (-not $rdpOk) {
            Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 0 -Important
            Set-FabricRdpFirewall $Cfg
            Write-FabricLog $Cfg "RDP listener re-armed (scoped rules re-asserted)."
        }

        # ── heartbeat log every 60s ──
        if (($tick % 2) -eq 0) {
            Write-FabricLog $Cfg ("Heartbeat: {0} TS:{1} RDP:{2} free={3}MB left={4}min" -f `
                $Cfg.TsHostname, $(if ($tsOk) {'ok'} else {'recovering'}), $(if ($rdpOk) {'ok'} else {'recovering'}), (Get-FreeMemMB), $left)
        }

        # ── every 10 min: MOTW (Drop only) + state refresh + governor (big nodes) ──
        if (($tick % 20) -eq 0) {
            if ($Cfg.Mode -eq 'full' -and $Cfg.DataRoot) { Invoke-FabricMotwSweep $Cfg }
            try {
                $cFree = [math]::Round(((Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue).SizeRemaining / 1GB), 1)
                $dFree = 0
                if ($Cfg.BestLetter) {
                    $dv = Get-Volume -DriveLetter $Cfg.BestLetter -ErrorAction SilentlyContinue
                    if ($dv) { $dFree = [math]::Round($dv.SizeRemaining / 1GB, 1) }
                }
                $pfMb = [int]((Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Measure-Object AllocatedBaseSize -Sum).Sum)
                Save-FabricState $Cfg ([ordered]@{
                    heartbeat=(Get-Date).ToString('o'); free_ram_mb=(Get-FreeMemMB)
                    c_free_gb=$cFree; d_free_gb=$dFree; pagefile_mb=$pfMb
                    ts_running=$tsOk; rdp_listening=$rdpOk; minutes_left=$left
                })
            } catch {}
            $freeMb = Get-FreeMemMB
            if ($Cfg.RamGB -ge 24 -and $freeMb -lt 1536 -and (Test-Path -LiteralPath $gov)) {
                try { $freeMb = [int](& $gov -PressureMb 1536) } catch {}
                Write-FabricLog $Cfg "Governor trim → ${freeMb} MB free."
            }
        }
    }

    Save-FabricState $Cfg ([ordered]@{ ended = (Get-Date).ToString('o'); minutes_left = 0 })
    Write-FabricLog $Cfg "Deadline reached — engine returning; teardown step takes over."
}
