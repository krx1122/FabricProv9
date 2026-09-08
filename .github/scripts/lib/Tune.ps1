# lib/Tune.ps1 — Phase 1a (services/power, image-aware) + Phase 1b
# (memory/scheduler). Best-effort, full mode only.

function Invoke-FabricTuneServices {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 1a: services & power (image: $($Cfg.Image))"

    # Defender realtime off. SecurityHealthService is protected on Server 2025
    # — left alone on purpose.
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableIOAVProtection $true `
          -DisableBehaviorMonitoring $true -DisableBlockAtFirstSeen $true -Force -ErrorAction SilentlyContinue
    } catch {}
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" "DisableAntiSpyware" 1
    foreach ($svc in @('WinDefend','Sense','WdNisSvc')) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }

    # Search / SysMain / Update / telemetry / Xbox etc.
    $starve = @('WSearch','DiagTrack','SysMain','DoSvc','wuauserv','UsoSvc','bits','WerSvc',
                'MapsBroker','RetailDemo','dmwappushservice','WMPNetworkSvc','XblAuthManager',
                'XblGameSave','XboxGipSvc','XboxNetApiSvc','PcaSvc','Fax','PrintNotify',
                'TabletInputService','FrameServer','WbioSrvc','lfsvc','SharedAccess')
    foreach ($name in $starve) {
        Get-Service -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }

    # Biggest real win on the GHA image: stop baked-in heavy stacks the RDP
    # session never uses. (interactive/auto only — compute may want them.)
    if ($Cfg.Image -eq 'GhaWindowsLatest' -and $Cfg.Profile -ne 'compute') {
        foreach ($name in @('docker','com.docker.service','WSLService','W3SVC','WAS','AppHostSvc',
                            'ServiceFabricLocalClusterManager','sshd')) {
            Get-Service -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
                Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
            }
        }
        Write-FabricLog $Cfg "Starved: Docker/WSL/IIS/ServiceFabric/sshd."
    }

    # Keep alive — never touch mpssvc (the firewall owns the 3389 scope).
    foreach ($svc in @('Spooler','LanmanServer','LanmanWorkstation','Winmgmt','CryptSvc','EventLog',
                       'RpcSs','DcomLaunch','ProfSvc','Schedule','TermService','UmRdpService',
                       'SessionEnv','Audiosrv','AudioEndpointBuilder','mpssvc')) {
        Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }

    # Windows Update: no surprise reboot/download mid-session.
    $wuAu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Set-FabricReg $Cfg $wuAu "NoAutoRebootWithLoggedOnUsers" 1 -Important
    Set-FabricReg $Cfg $wuAu "NoAutoUpdate" 1
    Set-FabricReg $Cfg $wuAu "AUOptions" 2
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0

    # Power: High Performance + no timeouts. No Ultimate-scheme hunt, no
    # timer-resolution games on this SKU (they do not move the needle here).
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-ac 0     | Out-Null
    powercfg /hibernate off                | Out-Null
    powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null

    # Lift multimedia network throttling for the RDP stream (cheap, real).
    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-FabricReg $Cfg $mmProfile "NetworkThrottlingIndex" 0xFFFFFFFF -Important
    Set-FabricReg $Cfg $mmProfile "SystemResponsiveness" 0 -Important

    # RDP encoder: H.264 everywhere; AVC444/GPU-scheduler keys only on real GPUs.
    $tsPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Set-FabricReg $Cfg $tsPol "fEnableH264" 1
    if ($Cfg.HasRealGpu) {
        Set-FabricReg $Cfg $tsPol "fEnableH264444" 1
        Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2
        Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "TdrDelay" 20
        Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "TdrDdiDelay" 20
    } else {
        Write-FabricLog $Cfg "Virtual display only — AVC444/HwSchMode/TDR skipped (cosmetic here)."
    }
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2
}

function Invoke-FabricMemory {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 1b: memory & scheduler (minimal, no-reboot-only flips)"

    # Adaptive scheduling: interactive foreground boost vs memory background bias.
    $win32ps = if ($Cfg.Profile -eq 'memory') { 24 } else { 38 }
    Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" $win32ps -Important

    # Memory compression takes effect live via MMAgent — only for memory profile.
    if ($Cfg.Profile -eq 'memory') {
        try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
    }

    # Cheap file-system wins.
    $fs = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    Set-FabricReg $Cfg $fs "NtfsDisableLastAccessUpdate" 0x80000001
    Set-FabricReg $Cfg $fs "NtfsDisable8dot3NameCreation" 1
    Set-FabricReg $Cfg $fs "LongPathsEnabled" 1
    fsutil behavior set disablelastaccess 1 | Out-Null
    fsutil behavior set disable8dot3 1     | Out-Null

    # Fast service shutdown at teardown; no WER UI mid-session.
    Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control" "WaitToKillServiceTimeout" "2000" "String"
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "DontShowUI" 1

    # NOTE: no HKCU writes here (that hive belongs to SYSTEM in this context —
    # per-user tweaks run in session\UserLogon.ps1 as the RDP user).
    Write-FabricLog $Cfg "Scheduler=$win32ps profile=$($Cfg.Profile)"
}
