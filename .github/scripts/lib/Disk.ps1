# lib/Disk.ps1 — Phase 1d (best-effort, full only).
# Honest pagefile: a live resize only fully applies at boot, so we record the
# ACTUAL size in state instead of claiming the target.

function Invoke-FabricDisk {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 1d: disk reclaim, pagefile, scratch layout"

    if ($Cfg.ReclaimDisk) {
        @("$env:SystemRoot\Temp\*", "$env:SystemRoot\Minidump\*", "$env:SystemDrive\Windows\MEMORY.DMP") |
            ForEach-Object { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }
    }

    # Contract dirs (also re-created in Workstation defensively).
    foreach ($d in @($Cfg.DataRoot, (Join-Path $Cfg.DataRoot 'Temp'),
                     (Join-Path $Cfg.DataRoot 'Drop'), (Join-Path $Cfg.DataRoot 'Tools'))) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    # ── pagefile: prefer the scratch volume ──
    $vol = Get-Volume -DriveLetter $Cfg.BestLetter -ErrorAction SilentlyContinue
    $freeGB = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 1) } else { 0 }
    $targetMB = [math]::Min([math]::Floor($Cfg.RamGB * 2 * 1024), 65536)
    $capMB = [math]::Floor($freeGB * 0.45 * 1024)
    if ($capMB -gt 0) { $targetMB = [math]::Min($targetMB, $capMB) }

    $pfPath = "$($Cfg.BestLetter):\pagefile.sys"
    $sysLetter = $env:SystemDrive.TrimEnd(':')
    try {
        $mm = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
        $existing = @()
        try { $existing = @((Get-ItemProperty -Path $mm -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles) } catch {}
        $hasC = $existing | Where-Object { $_ -match ("^" + [regex]::Escape("${sysLetter}:")) }
        if (-not $hasC) { $existing = @("${sysLetter}:\pagefile.sys 0 0") + @($existing | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($pfPath)) }) }
        if ($targetMB -ge 2048 -and $Cfg.BestLetter -ne $sysLetter) {
            $existing = @($existing | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($pfPath)) }) + @("$pfPath $targetMB $targetMB")
        }
        Set-ItemProperty -Path $mm -Name "PagingFiles" -Value $existing -Type MultiString -Force
        Write-FabricLog $Cfg ("Pagefile config: {0}" -f ($existing -join ' | '))
    } catch { Write-FabricLog $Cfg "Pagefile registry untouched: $($_.Exception.Message)" }

    if ($targetMB -ge 2048 -and $Cfg.BestLetter -ne $sysLetter) {
        $job = Start-Job -ScriptBlock {
            param($mb, $path)
            $ErrorActionPreference = 'Stop'
            $cs = Get-CimInstance Win32_ComputerSystem
            if ($cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } }
            $already = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $path }
            if (-not $already) {
                New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $path; InitialSize = [int]$mb; MaximumSize = [int]$mb } | Out-Null
            } else {
                $already | Set-CimInstance -Property @{ InitialSize = [int]$mb; MaximumSize = [int]$mb }
            }
        } -ArgumentList $targetMB, $pfPath
        if (-not (Wait-Job $job -Timeout 20)) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Write-FabricLog $Cfg "Pagefile CIM job timed out (20s) — existing pagefile stays."
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    # Record reality, not the target.
    $pfMb = [int]((Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Measure-Object AllocatedBaseSize -Sum).Sum)
    Save-FabricState $Cfg ([ordered]@{ pagefile_mb = $pfMb })
    Write-FabricLog $Cfg "Pagefile actual: ${pfMb} MB this session (target ${targetMB} MB applies fully after a boot that never comes)."

    # ── scratch env: TEMP/TMP + package caches onto the scratch volume ──
    # Safe now: the Tailscale MSI download started in Phase 0 targets
    # FabricRoot\cache and never touches TEMP.
    $scratch = Join-Path $Cfg.DataRoot 'Temp'
    $envMap = [ordered]@{
        'TEMP'             = $scratch
        'TMP'              = $scratch
        'NUGET_PACKAGES'   = (Join-Path $Cfg.DataRoot 'nuget')
        'PIP_CACHE_DIR'    = (Join-Path $Cfg.DataRoot 'pip-cache')
        'npm_config_cache' = (Join-Path $Cfg.DataRoot 'npm-cache')
        'DOTNET_CLI_HOME'  = (Join-Path $Cfg.DataRoot 'dotnet')
    }
    foreach ($k in $envMap.Keys) { [Environment]::SetEnvironmentVariable($k, $envMap[$k], 'Machine') }

    # ── ramdisk: only ever on big self-hosted nodes (never on 16 GB) ──
    if ($Cfg.Ramdisk) {
        try {
            $imdisk = "C:\Program Files\ImDisk\imdisk.exe"
            if (-not (Test-Path -LiteralPath $imdisk)) {
                $zip = "$env:TEMP\imdisktk.zip"; $ex = "$env:TEMP\imdisktk"; $ok = $false
                foreach ($u in @("https://downloads.sourceforge.net/project/imdisk-toolkit/20240113/ImDiskTk-x64.zip","https://sourceforge.net/projects/imdisk-toolkit/files/latest/download")) {
                    & curl.exe -sS -L --retry 2 -m 240 -o "$zip.part" $u
                    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath "$zip.part") -and (Get-Item -LiteralPath "$zip.part").Length -gt 1MB) {
                        Move-Item -LiteralPath "$zip.part" -Destination $zip -Force; $ok = $true; break
                    }
                }
                if ($ok) {
                    Expand-Archive -Path $zip -DestinationPath $ex -Force -ErrorAction SilentlyContinue
                    $setup = Get-ChildItem -Path $ex -Recurse -Include "install.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($setup) { Start-Process -FilePath $setup.FullName -ArgumentList "install" -WorkingDirectory (Split-Path $setup.FullName) -Wait -WindowStyle Hidden }
                }
            }
            if (Test-Path -LiteralPath $imdisk) {
                $freeMB = [math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
                $sizeMB = [math]::Min(4096, [math]::Floor($freeMB * 0.15))
                if ($sizeMB -ge 1024) {
                    & $imdisk -a -s ${sizeMB}M -m R: -p "/fs:ntfs /q /y" | Out-Null
                    if (Test-Path "R:\") {
                        New-Item -ItemType Directory -Path "R:\Temp" -Force | Out-Null
                        [Environment]::SetEnvironmentVariable('TEMP', 'R:\Temp', 'Machine')
                        [Environment]::SetEnvironmentVariable('TMP', 'R:\Temp', 'Machine')
                        Write-FabricLog $Cfg "RAM disk R: ${sizeMB} MB mounted."
                    }
                }
            }
        } catch { Write-FabricLog $Cfg "RAM disk skipped: $($_.Exception.Message)" }
    }
    Write-FabricLog $Cfg "Scratch layout ready ($($Cfg.DataRoot))."
}
