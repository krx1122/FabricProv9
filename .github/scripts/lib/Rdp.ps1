# lib/Rdp.ps1 — Phase 1c (fatal).
# Verified local admin + tailnet-scoped firewall. The built-in any/any
# "Remote Desktop" group is disabled and never re-enabled — the watchdog
# repairs only the scoped rules below.

function Ensure-LocalAdmin {
    param([pscustomobject]$Cfg)
    $secPass = ConvertTo-SecureString $env:RDP_PASS -AsPlainText -Force
    $existing = Get-LocalUser -Name $Cfg.User -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-LocalUser -Name $Cfg.User -Password $secPass -Description "Fabric RDP User" `
            -AccountNeverExpires -PasswordNeverExpires -ErrorAction Stop | Out-Null
    } else {
        # Always reset — a leftover SAM entry must not keep a stale password.
        Set-LocalUser -Name $Cfg.User -Password $secPass -ErrorAction Stop
        if (-not $existing.Enabled) { Enable-LocalUser -Name $Cfg.User -ErrorAction SilentlyContinue }
    }
    foreach ($g in @('Administrators','Remote Desktop Users')) {
        if (-not (Get-LocalGroupMember -Group $g -Member $Cfg.User -ErrorAction SilentlyContinue)) {
            Add-LocalGroupMember -Group $g -Member $Cfg.User -ErrorAction Stop
        }
    }
    if (-not (Get-LocalUser -Name $Cfg.User -ErrorAction SilentlyContinue)) {
        throw "Local user '$($Cfg.User)' provisioning failed."
    }
}

function Set-FabricRdpFirewall {
    param([pscustomobject]$Cfg)
    Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    $tailnet = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
    Ensure-FabricFirewallRule 'RDP-TCP-In-Tailscale' -Direction Inbound  -Protocol TCP -Port 3389  -RemoteAddress $tailnet
    Ensure-FabricFirewallRule 'RDP-UDP-In-Tailscale' -Direction Inbound  -Protocol UDP -Port 3389  -RemoteAddress $tailnet
    Ensure-FabricFirewallRule 'Tailscale-In-UDP'     -Direction Inbound  -Protocol UDP -Port 41641
    Ensure-FabricFirewallRule 'Tailscale-Out-UDP'    -Direction Outbound -Protocol UDP -Port 41641 -Remote
}

function Invoke-FabricRdp {
    param([pscustomobject]$Cfg)
    Write-FabricStep "Phase 1c: RDP provisioning (tailnet-scoped)"

    Ensure-LocalAdmin $Cfg

    $tsCtrl = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    $tsPol  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Set-FabricReg $Cfg $tsCtrl "fDenyTSConnections" 0 -Important
    Set-FabricReg $Cfg $tsCtrl "fSingleSessionPerUser" 0
    Set-FabricReg $Cfg $tsPol  "fClientDisableUDP" 0
    Set-FabricReg $Cfg $tsPol  "MaxIdleTime" 0
    Set-FabricReg $Cfg $tsPol  "MaxDisconnectionTime" 0
    Set-FabricReg $Cfg $tsPol  "KeepAliveEnable" 1
    Set-FabricReg $Cfg $tsPol  "KeepAliveInterval" 1
    Set-FabricReg $Cfg $tsPol  "fDisableCdm" 0          # drive mapping on
    Set-FabricReg $Cfg $tsPol  "fDisableClip" 0         # clipboard on
    Set-FabricReg $Cfg $tsPol  "fDisableCpm" 1          # printer redirection off
    Set-FabricReg $Cfg $tsPol  "fDisableLPT" 1
    Set-FabricReg $Cfg $tsPol  "fDisableAudioCapture" 1
    $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    Set-FabricReg $Cfg $rdpTcp "MinEncryptionLevel" 2
    Set-FabricReg $Cfg $rdpTcp "ColorDepth" 5
    # Compression default; Phase 2 finalizes once the Tailscale path is known.
    Set-FabricReg $Cfg $rdpTcp "MaxCompressionLevel" 0

    Set-FabricRdpFirewall $Cfg

    # Contract: the listener must actually be there.
    Start-Sleep -Milliseconds 500
    if (-not (Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)) {
        Restart-Service TermService -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (-not (Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)) {
            throw "RDP listener is not up on 3389."
        }
    }
    Write-FabricLog $Cfg "RDP armed for '$($Cfg.User)' — 3389 accepts tailnet 100.64.0.0/10 only."
    Save-FabricState $Cfg ([ordered]@{ rdp = 'armed-tailnet-only' })
}
