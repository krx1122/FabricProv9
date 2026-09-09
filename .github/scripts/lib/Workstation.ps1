# lib/Workstation.ps1 — Phase 2.7 (workstation mode) + Phase 2.8 (session UX).
# Both best-effort, full only.
# v9.1: S3 — the logon task carries -SoftwareGpu when the node has no real GPU
# (UserLogon then sets WARP/software-GL env and launches Edge with GPU off).

function Invoke-FabricWorkstation {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2.7: workstation mode"

    $drop       = Join-Path $Cfg.DataRoot 'Drop'
    $tools      = Join-Path $Cfg.DataRoot 'Tools'
    $crashDumps = Join-Path $Cfg.DataRoot 'CrashDumps'
    New-Item -ItemType Directory -Path $drop, $tools, $crashDumps -Force | Out-Null

    # Drop-an-exe-and-run stays ON (that is the workflow), but UAC infra stays
    # enabled — silent elevation for admins instead of killing LUA entirely.
    # This is only acceptable BECAUSE 3389 is tailnet-scoped (Phase 1c).
    $lu = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-FabricReg $Cfg $lu "ConsentPromptBehaviorAdmin" 0
    Set-FabricReg $Cfg $lu "PromptOnSecureDesktop" 0
    Set-FabricReg $Cfg $lu "EnableInstallerDetection" 0

    # SmartScreen off; no MOTW tagging on new downloads.
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" 0
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "SmartScreenEnabled" "Off" "String"
    $attach = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"
    Set-FabricReg $Cfg $attach "SaveZoneInformation" 1
    $ieZone = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3"
    Set-FabricReg $Cfg $ieZone "1806" 0

    # Crash dumps land in CrashDumps.
    $wer = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
    Set-FabricReg $Cfg $wer "DumpFolder" $crashDumps "ExpandString"
    Set-FabricReg $Cfg $wer "DumpType" 2
    Set-FabricReg $Cfg $wer "DumpCount" 10

    # Their automation runs unsigned scripts.
    Set-FabricReg $Cfg "HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" "ExecutionPolicy" "Bypass" "String"
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

    # Defender exclusions for the fabric paths ONLY — not half the drive.
    Add-MpPreference -ExclusionPath @($Cfg.FabricRoot, $Cfg.DataRoot, $drop, $tools, $crashDumps) -ErrorAction SilentlyContinue

    # Desktop shortcuts.
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($desk in @("C:\Users\$($Cfg.User)\Desktop", "C:\Users\Public\Desktop")) {
        if (Test-Path $desk) {
            $sc = $wsh.CreateShortcut((Join-Path $desk "Fabric Drop.lnk"))
            $sc.TargetPath = $drop; $sc.Description = "No MOTW, Defender-excluded"; $sc.Save()
            $sc2 = $wsh.CreateShortcut((Join-Path $desk "Crash Dumps.lnk"))
            $sc2.TargetPath = $crashDumps; $sc2.Save()
        }
    }

    # ACLs: the RDP user + Administrators + SYSTEM. No Everyone.
    foreach ($p in @($Cfg.FabricRoot, $Cfg.DataRoot, $drop, $tools, $crashDumps)) {
        icacls $p /grant "$($Cfg.User):(OI)(CI)F" /T /C /Q | Out-Null
        icacls $p /grant "Administrators:(OI)(CI)F" /T /C /Q | Out-Null
        icacls $p /grant "SYSTEM:(OI)(CI)F" /T /C /Q | Out-Null
    }

    Write-FabricLog $Cfg ("Workstation armed. Drop: {0}" -f $drop)
    Save-FabricState $Cfg ([ordered]@{ drop = $drop })
}

function Register-FabricSessionUx {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 2.8: session UX (ONE logon task)"

    $userLogon = Join-Path $Cfg.ScriptsDir 'session\UserLogon.ps1'
    if (-not (Test-Path -LiteralPath $userLogon)) { throw "Missing session script: $userLogon" }

    $taskUser     = "$env:COMPUTERNAME\$($Cfg.User)"
    $deadlineFile = Join-Path $Cfg.FabricRoot 'deadline.txt'

    # One task, one path: AtLogOn as the RDP user, 5s delay, elevated (the
    # logon script also does the one-time service nudge). This is a raw task
    # command line (Task Scheduler parses it) — quoted paths are correct here.
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$userLogon`" -DeadlineFile `"$deadlineFile`" -FallbackMinutes $($Cfg.RuntimeMinutes)"
    if ($Cfg.StartupUrl) { $arg += " -StartupUrl `"$($Cfg.StartupUrl)`"" }
    # S3: software rendering flag for GPU-less RDP sessions.
    if (-not $Cfg.HasRealGpu) { $arg += ' -SoftwareGpu' }

    $act   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg   = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
    $trg.Delay = 'PT5S'
    $princ = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest
    $set   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'RDPFabric-Session' -Action $act -Trigger $trg -Principal $princ -Settings $set -Force | Out-Null

    # Edge policies only when a startup URL is actually configured (empty = no
    # auto-open, no surprise traffic).
    if ($Cfg.StartupUrl) {
        $edgePol = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
        Set-FabricReg $Cfg $edgePol "RestoreOnStartup" 4
        $urls = Join-Path $edgePol 'RestoreOnStartupURLs'
        New-Item -Path $urls -Force | Out-Null
        Set-ItemProperty -Path $urls -Name "1" -Value $Cfg.StartupUrl -Type String -Force
        $bm = @(@{ toplevel_name = "RDP Fabric" }, @{ name = "Fabric App"; url = $Cfg.StartupUrl }) | ConvertTo-Json -Depth 5 -Compress
        Set-FabricReg $Cfg $edgePol "ManagedBookmarks" $bm "String"
        foreach ($desk in @("C:\Users\Public\Desktop", "C:\Users\$($Cfg.User)\Desktop")) {
            if (Test-Path $desk) {
                Set-Content -Path (Join-Path $desk "Fabric App.url") -Value "[InternetShortcut]`r`nURL=$($Cfg.StartupUrl)`r`n" -Encoding ASCII -Force
            }
        }
    }

    Write-FabricLog $Cfg ("Session UX armed: RDPFabric-Session AtLogOn as {0} (timer{1}{2})." -f `
        $Cfg.User, $(if ($Cfg.StartupUrl) {' + Edge'} else {' only'}), $(if (-not $Cfg.HasRealGpu) {' + software-GL'} else {''}))
}
