# lib/Rdp.ps1 — Phase 1c (fatal).
# Verified local admin + tailnet-scoped firewall + RDP picture-quality keys.
# v9.3 (audit): NLA explicitly required, SecurityLayer=TLS, MinEncryptionLevel=3
# (High), and the listener AND firewall scope are both verified before the
# phase reports success.

function Ensure-LocalAdmin {
    param([pscustomobject]$Cfg)
    $secPass = ConvertTo-SecureString $env:RDP_PASS -AsPlainText -Force
    $existing = Get-LocalUser -Name $Cfg.User -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-LocalUser -Name $Cfg.User -Password $secPass -Description "Fabric RDP User" `
            -AccountNeverExpires -PasswordNeverExpires -ErrorAction Stop | Out-Null
    } else {
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

# Picture quality + compression in one place, callable any time.
# Compression OFF unless the path is DERP-relayed (the #1 progressive-blur
# cause, and it burns a full thread on a 4t box).
function Set-FabricRdpPictureQuality {
    param([pscustomobject]$Cfg, [bool]$Relayed)
    $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    $tsPol  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"

    $cfgComp = ("$($Cfg.RdpCompression)").ToLowerInvariant()
    $wantComp = switch ($cfgComp) {
        'on'  { $true }
        'off' { $false }
        default { $Relayed }
    }
    Set-FabricReg $Cfg $rdpTcp "fDisableCompression" $(if ($wantComp) {0} else {1}) -Important
    Set-FabricReg $Cfg $rdpTcp "MaxCompressionLevel" $(if ($wantComp) {2} else {0})

    Set-FabricReg $Cfg $tsPol  "fEnableH264" 1
    Set-FabricReg $Cfg $rdpTcp "DisableDynamicColorDepth" 0
    Set-FabricReg $Cfg $rdpTcp "MaxMonitors" 4
    Set-FabricReg $Cfg $rdpTcp "fDisableRemoteFXAdaptiveGraphics" 0
    return $wantComp
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
    # Audit fix 3: NLA required, TLS security layer, High (128-bit) encryption.
    Set-FabricReg $Cfg $tsPol  "UserAuthentication" 1 -Important   # NLA
    Set-FabricReg $Cfg $rdpTcp "UserAuthentication" 1 -Important
    Set-FabricReg $Cfg $rdpTcp "SecurityLayer" 2 -Important        # TLS (SSL)
    Set-FabricReg $Cfg $rdpTcp "MinEncryptionLevel" 3 -Important   # High
    Set-FabricReg $Cfg $rdpTcp "ColorDepth" 5
    [void](Set-FabricRdpPictureQuality $Cfg $true)

    Set-FabricRdpFirewall $Cfg

    # Contract: listener must exist AND the firewall must be verifiably scoped.
    Start-Sleep -Milliseconds 500
    if (-not (Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)) {
        Restart-Service TermService -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (-not (Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)) {
            throw "RDP listener is not up on 3389."
        }
    }
    if (-not (Test-FabricRdpFirewall $Cfg)) {
        throw "RDP firewall verification failed — 3389 rules are missing, disabled, or not tailnet-scoped."
    }

    $nla = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication
    Write-FabricLog $Cfg "RDP armed for '$($Cfg.User)' — tailnet-only, NLA=on, TLS, High encryption (NLA readback=$nla)."
    Save-FabricState $Cfg ([ordered]@{ rdp='armed-tailnet-only'; nla=($nla -eq 1); security_layer='tls'; firewall_verified=$true })
}
