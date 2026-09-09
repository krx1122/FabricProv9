# session/UserLogon.ps1 — runs ONCE at FabricAdmin logon via the single
# RDPFabric-Session scheduled task (elevated, 5s delay). Because it runs as
# the RDP user, HKCU writes land in the right hive.
#
#   1. HKCU desktop timeouts / visual effects
#   2. One-time service nudge (then the hold loop leaves services alone)
#   3. Software-rendering env when -SoftwareGpu (no real GPU → RDP session)
#   4. Start the countdown timer (sibling FabricTimer.ps1, self-mutexed)
#   5. If -StartupUrl: start Edge once (sibling EdgeEnsure.ps1, self-mutexed)
param(
    [string]$StartupUrl = '',
    [string]$DeadlineFile = 'C:\ProgramData\RDPFabric\deadline.txt',
    [int]$FallbackMinutes = 345,
    [switch]$SoftwareGpu
)
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\RDPFabric\session.log'
function Write-SessionLog([string]$m) {
    try { "$('{0:o}' -f (Get-Date))  $m" | Add-Content -Path $log -Encoding UTF8 } catch {}
}

try {
    # 1. per-user desktop tweaks
    $desk = 'HKCU:\Control Panel\Desktop'
    New-Item -Path $desk -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $desk -Name 'HungAppTimeout'       -Value '2000' -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $desk -Name 'WaitToKillAppTimeout' -Value '2000' -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $desk -Name 'AutoEndTasks'         -Value '1'    -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $desk -Name 'ForegroundLockTimeout' -Value 0     -Type DWord  -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $desk -Name 'MenuShowDelay'        -Value '40'   -Type String -Force -ErrorAction SilentlyContinue
    $ve = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    New-Item -Path $ve -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ve -Name 'VisualFXSetting' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-SessionLog 'HKCU tweaks applied (as RDP user).'

    # 2. one-time service nudge — once after logon, then stop
    try { Set-MpPreference -DisableRealtimeMonitoring $true -Force -ErrorAction SilentlyContinue } catch {}
    foreach ($s in @('WSearch','SysMain','DoSvc','wuauserv','bits','WerSvc')) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
    }
    Write-SessionLog 'Service nudge done (one-shot).'

    # 3. S4: software rendering for GPU-less RDP — fixes "works on console,
    # dies in RDP" for many tools. User scope (apps launched later) AND process
    # scope (children started below inherit it immediately).
    if ($SoftwareGpu) {
        foreach ($k in 'D3D_FORCE_WARP','QT_OPENGL','LIBGL_ALWAYS_SOFTWARE') {
            $v = if ($k -eq 'QT_OPENGL') { 'software' } else { '1' }
            [Environment]::SetEnvironmentVariable($k, $v, 'User')
            Set-Item -Path "env:$k" -Value $v
        }
        Write-SessionLog 'Software-GL env set (no real GPU).'
    }

    # 4. countdown timer
    $timer = Join-Path $PSScriptRoot 'FabricTimer.ps1'
    if (Test-Path -LiteralPath $timer) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$timer`"",
            '-DeadlineFile',"`"$DeadlineFile`"",'-FallbackMinutes',"$FallbackMinutes")
        Write-SessionLog "timer started ($DeadlineFile)."
    } else { Write-SessionLog "MISSING: $timer" }

    # 5. optional Edge auto-open
    if ($StartupUrl) {
        $edge = Join-Path $PSScriptRoot 'EdgeEnsure.ps1'
        $match = [regex]::Escape($StartupUrl)
        try { $h = ([uri]$StartupUrl).Host; if ($h) { $match = [regex]::Escape($h) } } catch {}
        if (Test-Path -LiteralPath $edge) {
            $edgeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$edge`"",
                          '-Url',"`"$StartupUrl`"",'-Match',"`"$match`"")
            if ($SoftwareGpu) { $edgeArgs += '-SoftwareGpu' }
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $edgeArgs
            Write-SessionLog "edge launched once ($StartupUrl)."
        } else { Write-SessionLog "MISSING: $edge" }
    }

    Write-SessionLog 'UserLogon complete.'
} catch {
    Write-SessionLog "UserLogon error: $($_.Exception.Message)"
}
