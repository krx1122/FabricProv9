# lib/Workstation.ps1 — Phase 2.7 (workstation mode) + Phase 2.8 (session UX).
# Both best-effort, full only.
# v9.3 (audit fixes 2+6): lockdown mode keeps UAC prompts, SmartScreen, and the
# default execution policy; startup_url arrives pre-validated (HTTPS-only) from
# Config and is refused here again defensively.

function Invoke-FabricWorkstation {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2.7: workstation mode (lockdown=$($Cfg.Lockdown))"

    $drop       = Join-Path $Cfg.DataRoot 'Drop'
    $tools      = Join-Path $Cfg.DataRoot 'Tools'
    $crashDumps = Join-Path $Cfg.DataRoot 'CrashDumps'
    New-Item -ItemType Directory -Path $drop, $tools, $crashDumps -Force | Out-Null

    if (-not $Cfg.Lockdown) {
        # Drop-an-exe-and-run mode: silent elevation for admins (UAC infra stays
        # enabled), SmartScreen off, no MOTW tagging. Only acceptable BECAUSE
        # 3389 is tailnet-scoped (Phase 1c). lockdown=true skips all of this.
        $lu = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Set-FabricReg $Cfg $lu "ConsentPromptBehaviorAdmin" 0
        Set-FabricReg $Cfg $lu "PromptOnSecureDesktop" 0
        Set-FabricReg $Cfg $lu "EnableInstallerDetection" 0
        Set-FabricReg $Cfg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" 0
        Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "SmartScreenEnabled" "Off" "String"
        $attach = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"
        Set-FabricReg $Cfg $attach "SaveZoneInformation" 1
        $ieZone = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3"
        Set-FabricReg $Cfg $ieZone "1806" 0
        Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" "ExecutionPolicy" "Bypass" "String"
        Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionPath @($Cfg.FabricRoot, $Cfg.DataRoot, $drop, $tools, $crashDumps) -ErrorAction SilentlyContinue
    } else {
        Write-FabricLog $Cfg "Lockdown: UAC prompts, SmartScreen, exec policy, Defender exclusions all left at stock."
    }

    # Crash dumps land in CrashDumps (harmless in both modes).
    $wer = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
    Set-FabricReg $Cfg $wer "DumpFolder" $crashDumps "ExpandString"
    Set-FabricReg $Cfg $wer "DumpType" 2
    Set-FabricReg $Cfg $wer "DumpCount" 10

    $wsh = New-Object -ComObject WScript.Shell
    foreach ($desk in @("C:\Users\$($Cfg.User)\Desktop", "C:\Users\Public\Desktop")) {
        if (Test-Path $desk) {
            $sc = $wsh.CreateShortcut((Join-Path $desk "Fabric Drop.lnk"))
            $sc.TargetPath = $drop; $sc.Description = "Fabric Drop"; $sc.Save()
            $sc2 = $wsh.CreateShortcut((Join-Path $desk "Crash Dumps.lnk"))
            $sc2.TargetPath = $crashDumps; $sc2.Save()
        }
    }

    foreach ($p in @($Cfg.FabricRoot, $Cfg.DataRoot, $drop, $tools, $crashDumps)) {
        icacls $p /grant "$($Cfg.User):(OI)(CI)F" /T /C /Q | Out-Null
        icacls $p /grant "Administrators:(OI)(CI)F" /T /C /Q | Out-Null
        icacls $p /grant "SYSTEM:(OI)(CI)F" /T /C /Q | Out-Null
    }

    # Ready-made .rdp profile in Drop (LAN quality, 32bpp, compression off).
    if ($Cfg.TsIp) {
        $rdpFile = Join-Path $drop 'Fabric-Node.rdp'
        $rdpBody = @(
            "full address:s:$($Cfg.TsIp)"
            "username:s:$($Cfg.User)"
            "screen mode id:i:2"
            "use multimon:i:0"
            "session bpp:i:32"
            "connection type:i:6"
            "networkautodetect:i:1"
            "bandwidthautodetect:i:1"
            "compression:i:0"
            "keyboardhook:i:2"
            "audiocapturemode:i:0"
            "audiomode:i:0"
            "redirectclipboard:i:1"
            "drivestoredirect:s:*"
            "authentication level:i:0"
            "promptcredentialonce:i:1"
            "negotiate security layer:i:1"
            "displayconnectionbar:i:1"
            "enableworkspacereconnect:i:0"
            "allow font smoothing:i:1"
            "allow desktop composition:i:1"
            "disable wallpaper:i:0"
            "disable full window drag:i:0"
            "disable menu anims:i:1"
            "disable themes:i:0"
            "disable cursor setting:i:0"
            "bitmapcachepersistenable:i:1"
            "remoteapplicationmode:i:0"
            "gatewayusagemethod:i:4"
        ) -join "`r`n"
        Set-Content -Path $rdpFile -Value $rdpBody -Encoding ASCII -Force
        Write-FabricLog $Cfg "Client profile ready: $rdpFile"
    }

    Write-FabricLog $Cfg ("Workstation armed. Drop: {0}" -f $drop)
    Save-FabricState $Cfg ([ordered]@{ drop = $drop; lockdown = $Cfg.Lockdown })
}

function Register-FabricSessionUx {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2.8: session UX (ONE logon task)"

    $userLogon = Join-Path $Cfg.ScriptsDir 'session\UserLogon.ps1'
    if (-not (Test-Path -LiteralPath $userLogon)) { throw "Missing session script: $userLogon" }

    # Defensive re-validation (Config already did it).
    $url = Test-FabricUrl $Cfg.StartupUrl

    $taskUser     = "$env:COMPUTERNAME\$($Cfg.User)"
    $deadlineFile = Join-Path $Cfg.FabricRoot 'deadline.txt'

    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$userLogon`" -DeadlineFile `"$deadlineFile`" -FallbackMinutes $($Cfg.RuntimeMinutes)"
    if ($url) { $arg += " -StartupUrl `"$url`"" }
    if (-not $Cfg.HasRealGpu) { $arg += ' -SoftwareGpu' }

    $act   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg   = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $trg.Delay = 'PT5S'
    $princ = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest
    $set   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'RDPFabric-Session' -Action $act -Trigger $trg -Principal $princ -Settings $set -Force | Out-Null

    if ($url) {
        $edgePol = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
        Set-FabricReg $Cfg $edgePol "RestoreOnStartup" 4
        $urls = Join-Path $edgePol 'RestoreOnStartupURLs'
        New-Item -Path $urls -Force | Out-Null
        Set-ItemProperty -Path $urls -Name "1" -Value $url -Type String -Force
        $bm = @(@{ toplevel_name = "RDP Fabric" }, @{ name = "Fabric App"; url = $url }) | ConvertTo-Json -Depth 5 -Compress
        Set-FabricReg $Cfg $edgePol "ManagedBookmarks" $bm "String"
        foreach ($desk in @("C:\Users\Public\Desktop", "C:\Users\$($Cfg.User)\Desktop")) {
            if (Test-Path $desk) {
                Set-Content -Path (Join-Path $desk "Fabric App.url") -Value "[InternetShortcut]`r`nURL=$url`r`n" -Encoding ASCII -Force
            }
        }
    }

    Write-FabricLog $Cfg ("Session UX armed: RDPFabric-Session AtLogOn as {0} (timer{1}{2})." -f `
        $Cfg.User, $(if ($url) {' + Edge'} else {' only'}), $(if (-not $Cfg.HasRealGpu) {' + software-GL'} else {''}))
}
