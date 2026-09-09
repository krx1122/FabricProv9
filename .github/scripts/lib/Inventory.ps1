# lib/Inventory.ps1 — Phase 0 (fatal).
# Does: secret checks (incl. Windows password policy), deadline.txt (once),
# hardware/disk measure, image fingerprint (RUNNER_ENVIRONMENT), profile
# resolution, async pinned Tailscale fetch, state contract.
# Must NOT: touch Defender, pagefile, HKCU, or redirect TEMP yet.
# v9.1: M1 (curl args unquoted), M3 (fingerprint), S7 (password check matches
# the real Windows policy — no invented substring bans).

# Pre-flight the password against the Server 2025 policy so a bad secret fails
# in Phase 0 with a readable reason instead of an InvalidPasswordException in 1c.
function Test-FabricPassword {
    param([string]$Password, [string]$User)
    if ($Password.Length -lt 8) { return 'under 8 characters' }
    $classes = 0
    if ($Password -match '[a-z]')       { $classes++ }
    if ($Password -match '[A-Z]')       { $classes++ }
    if ($Password -match '\d')          { $classes++ }
    if ($Password -match '[^a-zA-Z0-9]') { $classes++ }
    if ($classes -lt 3) { return 'needs at least 3 of: lowercase, uppercase, digit, symbol' }
    if ($User -and $Password -match ('(?i)' + [regex]::Escape($User))) { return "must not contain the account name '$User'" }
    return $null
}

function Invoke-FabricInventory {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 0: inventory, profile, image fingerprint, async Tailscale fetch"

    if (-not $env:RDP_PASS)   { throw "RDP_PASSWORD secret is missing (env RDP_PASS)." }
    if (-not $env:TS_AUTHKEY) { throw "TAILSCALE_AUTH_KEY secret is missing (env TS_AUTHKEY)." }
    $pwProblem = Test-FabricPassword -Password $env:RDP_PASS -User $Cfg.User
    if ($pwProblem) { throw "RDP_PASSWORD rejected by Windows policy: $pwProblem." }

    New-Item -ItemType Directory -Path $Cfg.FabricRoot -Force | Out-Null
    $Cfg.LogReady = $true

    # Single source of truth for the countdown overlay — written ONCE.
    $Cfg.Deadline = (Get-Date).AddMinutes($Cfg.RuntimeMinutes)
    Set-Content -Path (Join-Path $Cfg.FabricRoot 'deadline.txt') -Value $Cfg.Deadline.ToString('o') -Encoding ASCII -Force

    # ── hardware / OS ──
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $Cfg.OsCaption = [string]$os.Caption
    $Cfg.RamGB     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $Cfg.FreeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $Cfg.Cpu       = [int]$cs.NumberOfLogicalProcessors
    if ($Cfg.Cpu -le 0) { $Cfg.Cpu = [Environment]::ProcessorCount }
    $coreSum = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    $Cfg.CpuCores = if ($coreSum) { [int]$coreSum } else { [int]$cs.NumberOfProcessors }
    $Cfg.CpuName  = [string]$cs.Name
    if (-not $Cfg.CpuName) { $Cfg.CpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name }

    # ── disks: scratch on the biggest non-system NTFS volume with >= 8 GB free ──
    $sysLetter = $env:SystemDrive.TrimEnd(':')
    $volumes   = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -match 'NTFS' })
    foreach ($v in $volumes) {
        $free = [math]::Round($v.SizeRemaining / 1GB, 1)
        if ($v.DriveLetter -eq $sysLetter) { $Cfg.CFreeGB = $free }
        elseif ($free -gt $Cfg.DFreeGB)    { $Cfg.DFreeGB = $free }
    }
    $alt  = @($volumes | Where-Object { $_.DriveLetter -ne $sysLetter } | Sort-Object SizeRemaining -Descending)
    $best = $null
    if ($alt.Count -gt 0 -and ($alt[0].SizeRemaining / 1GB) -ge 8) { $best = $alt[0] }
    else { $best = ($volumes | Sort-Object SizeRemaining -Descending | Select-Object -First 1) }
    $Cfg.BestLetter = if ($best) { [string]$best.DriveLetter } else { $sysLetter }
    $Cfg.DataRoot   = if ($best -and $best.DriveLetter -ne $sysLetter) { "$($best.DriveLetter):\RDPFabric\Data" }
                      else { Join-Path $Cfg.FabricRoot 'Data' }

    # ── image fingerprint (M3: key off RUNNER_ENVIRONMENT, not a label string) ──
    $hasIdeBits = (Test-Path 'C:\Program Files\Microsoft Visual Studio') -or
                  (Test-Path "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView")
    $Cfg.Image = if ($env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and $hasIdeBits) { 'GhaWindowsLatest' }
                 elseif ($Cfg.OsCaption -match 'Server') { 'ServerGeneric' }
                 else { 'ClientGeneric' }

    $gpuNames = @((Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue).Name)
    $Cfg.HasRealGpu = @($gpuNames | Where-Object { $_ -and ($_ -notmatch 'Hyper-V|Remote Display|Basic') }).Count -gt 0

    # ── profile: resolve auto, refuse compute on small nodes ──
    if ($Cfg.Profile -eq 'auto') {
        if     ($Cfg.RamGB -lt 12)                       { $Cfg.Profile = 'memory' }
        elseif ($Cfg.Cpu -ge 8 -and $Cfg.RamGB -ge 24)   { $Cfg.Profile = 'compute' }
        else                                             { $Cfg.Profile = 'interactive' }
    } elseif ($Cfg.Profile -eq 'compute' -and ($Cfg.Cpu -lt 8 -or $Cfg.RamGB -lt 24)) {
        Write-FabricLog $Cfg "profile=compute REFUSED on $($Cfg.Cpu)t/$($Cfg.RamGB)GB (needs >= 8 threads and >= 24 GB) — using interactive."
        $Cfg.Profile = 'interactive'
    }

    # ── ramdisk: only when asked AND the RAM is actually there ──
    $Cfg.Ramdisk = $Cfg.RamdiskRequested -and $Cfg.RamGB -ge 28 -and $Cfg.FreeRamGB -ge 12
    if ($Cfg.RamdiskRequested -and -not $Cfg.Ramdisk) {
        Write-FabricLog $Cfg "ramdisk requested but disabled (needs >= 28 GB RAM and >= 12 GB free)."
    }

    # ── async Tailscale MSI (pinned version) into FabricRoot\cache ──
    # Started NOW, before any TEMP redirect; a bare curl process, no wrapper
    # script, no marker file — Phase 2 waits on the handle and verifies size.
    # M1: ArgumentList array items are passed raw — PowerShell quotes paths
    # itself. Embedding quotes makes curl create a file whose name contains ".
    $cacheDir = Split-Path $Cfg.TsMsiPath
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    Remove-Item -LiteralPath $Cfg.TsMsiPath, $Cfg.TsPartPath -Force -ErrorAction SilentlyContinue
    $Cfg.TsDlProc = Start-Process -FilePath 'curl.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-sS','-L','--retry','3','--retry-all-errors','-m','300','--connect-timeout','15',
        '-o', $Cfg.TsPartPath, $Cfg.TsMsiUrl)
    Write-FabricLog $Cfg "Tailscale $($Cfg.TsVersion) MSI downloading in background (pid $($Cfg.TsDlProc.Id))."

    # ── state contract ──
    Save-FabricState $Cfg ([ordered]@{
        version=$Cfg.Version; mode=$Cfg.Mode; minutes=$Cfg.RuntimeMinutes; job_timeout_min=$Cfg.JobTimeoutMin
        deadline=$Cfg.Deadline.ToString('o'); user=$Cfg.User; fab_root=$Cfg.FabricRoot
        data_root=$Cfg.DataRoot; best_letter=$Cfg.BestLetter; profile=$Cfg.Profile
        ram_gb=$Cfg.RamGB; free_ram_gb=$Cfg.FreeRamGB; cpu=$Cfg.Cpu; cpu_cores=$Cfg.CpuCores
        cpu_name=$Cfg.CpuName; os_caption=$Cfg.OsCaption; hostname=$Cfg.NodeName
        gha=$Cfg.IsGHA; runner_env=$env:RUNNER_ENVIRONMENT; image=$Cfg.Image
        c_free_gb=$Cfg.CFreeGB; d_free_gb=$Cfg.DFreeGB
        has_real_gpu=$Cfg.HasRealGpu; ramdisk=$Cfg.Ramdisk; rdp_compression=$Cfg.RdpCompression
        reclaim_disk=$Cfg.ReclaimDisk; notify=$Cfg.Notify
        startup_url_set=(-not [string]::IsNullOrWhiteSpace($Cfg.StartupUrl)); ts_version=$Cfg.TsVersion
    })

    # Exit contract — Phase 1c must not start without these.
    if (-not (Test-Path -LiteralPath (Join-Path $Cfg.FabricRoot 'deadline.txt'))) { throw "exit contract: deadline.txt missing." }
    $st = Get-FabricState $Cfg
    foreach ($k in @('ram_gb','cpu','profile','data_root','c_free_gb','d_free_gb','image')) {
        if ($null -eq $st.$k) { throw "exit contract: state.json missing '$k'." }
    }

    Write-FabricLog $Cfg ("Node: {0} | {1}c/{2}t | {3}GB RAM ({4}GB free) | image={5} profile={6} scratch={7}: C:={8}GB D:~{9}GB" -f `
        $Cfg.CpuName, $Cfg.CpuCores, $Cfg.Cpu, $Cfg.RamGB, $Cfg.FreeRamGB, $Cfg.Image, $Cfg.Profile, $Cfg.BestLetter, $Cfg.CFreeGB, $Cfg.DFreeGB)
    Write-Host ("Session: {0} min (deadline {1}, job cap {2} min)" -f $Cfg.RuntimeMinutes, $Cfg.Deadline.ToString('HH:mm:ss'), $Cfg.JobTimeoutMin) -ForegroundColor Cyan
}
