# lib/Tune.ps1 — Phase 1a (services/power, image-aware) + Phase 1b
# (memory/scheduler). Best-effort, full mode only.
# v9.3 (audit fix 2): with cfg.Lockdown, Defender realtime, SmartScreen, and
# service startup types are left at stock — only the low-risk starve list and
# power plan run. Default stays the drop-and-run behavior the product needs.

function Invoke-FabricTuneServices {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 1a: services & power (image: $($Cfg.Image), lockdown=$($Cfg.Lockdown))"

    if (-not $Cfg.Lockdown) {
        # Defender realtime off. SecurityHealthService is protected on Server
        # 2025 — left alone on purpose.
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -DisableIOAVProtection $true `
              -DisableBehaviorMonitoring $true -DisableBlockAtFirstSeen $true -Force -ErrorAction SilentlyContinue
        } catch {}
        Set-FabricReg $Cfg "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" "DisableAntiSpyware" 1
        foreach ($svc in @('WinDefend','Sense','WdNisSvc')) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    } else {
        Write-FabricLog $Cfg "Lockdown: Defender left enabled."
    }

    # Starve list is safe in both modes — these compete for cycles, not security.
    $starve = @('WSearch','DiagTrack','SysMain','DoSvc','wuauserv','UsoSvc','bits',
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
    # session never uses.
    if ($Cfg.Image -eq 'GhaWindowsLatest' -and $Cfg.Profile -ne 'compute') {
        foreach ($name in @('docker','com.docker.service','WSLService','W3SVC','WAS','AppHostSvc',
                            'ServiceFabricLocalClusterManager','sshd','Spooler','WinRM')) {
            Get-Service -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
                Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
            }
        }
        Write-FabricLog $Cfg "Starved: Docker/WSL/IIS/ServiceFabric/sshd/Spooler/WinRM."
    }

    # Keep alive — never touch mpssvc (the firewall owns the 3389 scope).
    foreach ($svc in @('LanmanServer','LanmanWorkstation','Winmgmt','CryptSvc','EventLog',
                       'RpcSs','DcomLaunch','ProfSvc','Schedule','TermService','UmRdpService',
                       'SessionEnv','Audiosrv','AudioEndpointBuilder','mpssvc')) {
        Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }

    # Windows Update: no surprise reboot/download mid-session (both modes).
    $wuAu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Set-FabricReg $Cfg $wuAu "NoAutoRebootWithLoggedOnUsers" 1 -Important
    Set-FabricReg $Cfg $wuAu "NoAutoUpdate" 1
    Set-FabricReg $Cfg $wuAu "AUOptions" 2
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0

    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-ac 0     | Out-Null
    powercfg /hibernate off                | Out-Null
    powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null

    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-FabricReg $Cfg $mmProfile "NetworkThrottlingIndex" 0xFFFFFFFF -Important
    Set-FabricReg $Cfg $mmProfile "SystemResponsiveness" 0 -Important

    $tsPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Set-FabricReg $Cfg $tsPol "fEnableH264" 1
    if ($Cfg.HasRealGpu) {
        Set-FabricReg $Cfg $tsPol "fEnableH264444" 1
        Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2
        Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "TdrDelay" 20
        Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "TdrDdiDelay" 20
    } else {
        Write-FabricLog $Cfg "Virtual display only — AVC444/HwSchMode/TDR skipped."
    }
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2
}

function Invoke-FabricMemory {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 1b: memory & scheduler (minimal, no-reboot-only flips)"

    $win32ps = if ($Cfg.Profile -eq 'memory') { 24 } else { 38 }
    Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" $win32ps -Important

    if ($Cfg.Profile -eq 'memory') {
        try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
    }

    $fs = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    Set-FabricReg $Cfg $fs "NtfsDisableLastAccessUpdate" 0x80000001
    Set-FabricReg $Cfg $fs "NtfsDisable8dot3NameCreation" 1
    Set-FabricReg $Cfg $fs "LongPathsEnabled" 1
    fsutil behavior set disablelastaccess 1 | Out-Null
    fsutil behavior set disable8dot3 1     | Out-Null

    Set-FabricReg $Cfg "HKLM:\SYSTEM\CurrentControlSet\Control" "WaitToKillServiceTimeout" "2000" "String"
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "DontShowUI" 1

    Write-FabricLog $Cfg "Scheduler=$win32ps profile=$($Cfg.Profile)"
}
