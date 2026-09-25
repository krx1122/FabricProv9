# lib/Config.ps1 — config resolver, logging, merge-only state, shared helpers.
# One $cfg object is built here and passed into every phase.
# v9.3: audit pass — strict input validation (enum/URL/user/hash), version 9.3.
# v9.3.1: firewall create/verify is observable (delete+recreate with real
# errors; verification returns a reason string, not a blind boolean).

function ConvertTo-FabricBool {
    param([string]$v)
    return (@('true','1','yes','on') -contains "$v".Trim().ToLowerInvariant())
}

function Resolve-FabricValue {
    param([string]$EnvName, [string]$ParamValue, [string]$Default)
    $e = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($e))         { return $e.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ParamValue)) { return $ParamValue.Trim() }
    return $Default
}

function Test-FabricUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $u = $Url.Trim()
    if ($u -match '[\x00-\x1F\x7F"''<> ]') { Write-Warning "startup_url rejected (control/space/quote chars)."; return '' }
    $parsed = $null
    try { $parsed = [uri]$u } catch { Write-Warning "startup_url rejected (unparseable)."; return '' }
    if ($parsed.Scheme -ne 'https') { Write-Warning "startup_url rejected (HTTPS only)."; return '' }
    if ($parsed.UserInfo)           { Write-Warning "startup_url rejected (credentials in URL)."; return '' }
    if (-not $parsed.Host)          { Write-Warning "startup_url rejected (no host)."; return '' }
    return $u
}

function Resolve-FabricConfig {
    param(
        [string]$Mode, [string]$WorkloadProfile, [string]$RdpCompression,
        [string]$QuickTest, [string]$EnableRamdisk, [string]$ReclaimDisk,
        [string]$StartupUrl, [string]$Notify, [string]$TailscaleVersion
    )
    $modeRaw = Resolve-FabricValue 'FAB_MODE' $Mode 'full'
    if ($modeRaw -notin @('full','mvp')) { throw "Unknown mode '$modeRaw' (expected full|mvp)." }

    $qt    = ConvertTo-FabricBool (Resolve-FabricValue 'FAB_QUICKTEST' $QuickTest 'false')
    $rtStr = Resolve-FabricValue 'FAB_RUNTIME' '' '345'
    $rt = 0
    if (-not [int]::TryParse($rtStr, [ref]$rt)) { $rt = 345 }
    if ($rt -lt 1)   { $rt = 1 }
    if ($rt -gt 345) { $rt = 345 }
    if ($qt) { $rt = 5 }

    $profile = (Resolve-FabricValue 'FAB_PROFILE_INPUT' $WorkloadProfile 'auto').ToLowerInvariant()
    if ($profile -notin @('auto','interactive','memory','network','compute')) {
        Write-Warning "Unknown workload_profile '$profile' — using auto."
        $profile = 'auto'
    }
    $comp = (Resolve-FabricValue 'FAB_RDPCOMP' $RdpCompression 'auto').ToLowerInvariant()
    if ($comp -notin @('auto','on','off')) { $comp = 'auto' }

    $tsv = Resolve-FabricValue 'FAB_TS_VERSION' $TailscaleVersion '1.102.3'
    if ($tsv -notmatch '^\d+\.\d+\.\d+$') { Write-Warning "FAB_TS_VERSION malformed — using 1.102.3."; $tsv = '1.102.3' }
    $root = Resolve-FabricValue 'FABRIC_ROOT' '' 'C:\ProgramData\RDPFabric'

    $sha = [Environment]::GetEnvironmentVariable('FAB_TS_SHA256')
    if ($sha) { $sha = $sha.Trim(); if ($sha -notmatch '^[0-9a-fA-F]{64}$') { Write-Warning "FAB_TS_SHA256 malformed — ignored."; $sha = $null } }

    $url = Test-FabricUrl (Resolve-FabricValue 'FAB_STARTUP_URL' $StartupUrl '')

    $user = Resolve-FabricValue 'RDP_USER' '' 'FabricAdmin'
    if ($user -notmatch '^[A-Za-z0-9_.-]{1,20}$') { Write-Warning "RDP_USER malformed — using FabricAdmin."; $user = 'FabricAdmin' }

    [pscustomobject]@{
        Version         = '9.3'
        Mode            = $modeRaw
        RuntimeMinutes  = $rt
        JobTimeoutMin   = [math]::Min(360, $rt + 15)
        Profile         = $profile
        Ramdisk         = $false
        RamdiskRequested= (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_RAMDISK' $EnableRamdisk 'false'))
        RdpCompression  = $comp
        ReclaimDisk     = (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_RECLAIM' $ReclaimDisk 'true'))
        StartupUrl      = $url
        Notify          = (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_NOTIFY' $Notify 'false'))
        Lockdown        = (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_LOCKDOWN' '' 'false'))
        User            = $user
        FabricRoot      = $root
        DataRoot        = $null
        Image           = $null
        QuickTest       = $qt
        Deadline        = $null
        RamGB           = 0.0
        FreeRamGB       = 0.0
        Cpu             = 0
        CpuCores        = 0
        CpuName         = ''
        OsCaption       = ''
        NodeName        = $env:COMPUTERNAME
        IsGHA           = ($env:GITHUB_ACTIONS -eq 'true')
        BestLetter      = $null
        CFreeGB         = 0.0
        DFreeGB         = 0.0
        HasRealGpu      = $false
        TsVersion       = $tsv
        TsSha256        = $sha
        TsMsiUrl        = "https://pkgs.tailscale.com/stable/tailscale-setup-$tsv-amd64.msi"
        TsMsiPath       = (Join-Path $root 'cache\tailscale.msi')
        TsPartPath      = (Join-Path $root 'cache\tailscale.msi.part')
        TsDlProc        = $null
        TsExe           = 'C:\Program Files\Tailscale\tailscale.exe'
        TsHostname      = $null
        TsIp            = ''
        TsDirect        = $false
        FailCount       = 0
        LogReady        = $false
    }
}

function Write-FabricStep { param([string]$m) Write-Host "── $m" -ForegroundColor Cyan }

function Write-FabricLog {
    param([pscustomobject]$Cfg, [string]$m)
    if (-not $Cfg.LogReady) {
        New-Item -ItemType Directory -Path $Cfg.FabricRoot -Force -ErrorAction SilentlyContinue | Out-Null
        $Cfg.LogReady = $true
    }
    $line = '{0:o}  {1}' -f (Get-Date), $m
    Add-Content -Path (Join-Path $Cfg.FabricRoot 'launch.log') -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $m
}

function Get-FabricState {
    param([pscustomobject]$Cfg)
    $f = Join-Path $Cfg.FabricRoot 'state.json'
    if (Test-Path -LiteralPath $f) {
        try { return Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-FabricState {
    param([pscustomobject]$Cfg, [System.Collections.IDictionary]$Fields)
    New-Item -ItemType Directory -Path $Cfg.FabricRoot -Force | Out-Null
    $merged = [ordered]@{}
    $existing = Get-FabricState $Cfg
    if ($existing) { foreach ($p in $existing.PSObject.Properties) { $merged[$p.Name] = $p.Value } }
    foreach ($k in $Fields.Keys) { $merged[$k] = $Fields[$k] }
    ($merged | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $Cfg.FabricRoot 'state.json') -Encoding UTF8
}

function Set-FabricReg {
    param(
        [pscustomobject]$Cfg,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        $Value,
        [string]$Type = 'DWord',
        [switch]$Important
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
    } catch {
        $Cfg.FailCount++
        if ($Important) { Write-FabricLog $Cfg "registry set failed [$Path -> $Name]: $($_.Exception.Message)" }
    }
}

function Invoke-FabricPhase {
    param([pscustomobject]$Cfg, [string]$Name, [scriptblock]$Block, [switch]$Fatal)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Block
        $sw.Stop()
        Write-FabricLog $Cfg ("{0} ok in {1:n1}s (warnings: {2})" -f $Name, $sw.Elapsed.TotalSeconds, $Cfg.FailCount)
    } catch {
        $sw.Stop()
        $Cfg.FailCount++
        Write-FabricLog $Cfg ("{0} FAILED{1}: {2}" -f $Name, $(if ($Fatal) { ' (FATAL)' } else { ' (best-effort)' }), $_.Exception.Message)
        if ($Fatal) { throw }
    }
}

function Get-FreeMemMB {
    return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
}

function Test-FabricFile {
    param([string]$Path, [long]$MinBytes = 1MB)
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    return ($fi -and $fi.Length -ge $MinBytes)
}

# ── Firewall (v9.3.1): delete-then-create (idempotent) with REAL errors ──────
function Set-FabricFirewallRule {
    param(
        [pscustomobject]$Cfg,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Direction = 'Inbound',
        [string]$Protocol = 'TCP',
        [int]$Port,
        [string[]]$RemoteAddress,
        [switch]$Remote
    )
    Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    $p = @{ DisplayName=$DisplayName; Direction=$Direction; Protocol=$Protocol; Action='Allow' }
    if ($Remote) { $p['RemotePort'] = $Port } else { $p['LocalPort'] = $Port }
    if ($RemoteAddress) { $p['RemoteAddress'] = $RemoteAddress }
    try {
        New-NetFirewallRule @p -ErrorAction Stop | Out-Null
    } catch {
        $Cfg.FailCount++
        throw "Failed to create firewall rule '$DisplayName' ($Direction/$Protocol/$Port): $($_.Exception.Message)"
    }
}

# Verification that tells you WHY it failed (logged, not just thrown blind).
function Test-FabricRdpFirewall {
    param([pscustomobject]$Cfg, [ref]$Reason)
    $Reason.Value = 'ok'
    $expected = @('100.64.0.0/10','fd7a:115c:a1e0::/48')
    foreach ($name in @('RDP-TCP-In-Tailscale','RDP-UDP-In-Tailscale')) {
        $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        if (-not $rule) { $Reason.Value = "missing rule '$name'"; return $false }
        if (-not $rule.Enabled) { $Reason.Value = "rule '$name' disabled"; return $false }
        $addr = @($rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty RemoteAddress)
        foreach ($cidr in $expected) {
            if (-not ($addr | Where-Object { $_.Trim() -ieq $cidr })) {
                $Reason.Value = "rule '$name' missing scope $cidr (has: $($addr -join ', '))"
                return $false
            }
        }
    }
    # The built-in any/any group must stay disabled.
    $group = @(Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Where-Object Enabled -eq $true)
    if ($group.Count -gt 0) {
        $Reason.Value = "built-in 'Remote Desktop' group re-enabled ($($group[0].DisplayName))"
        return $false
    }
    return $true
}

function Send-FabricNotify {
    param([pscustomobject]$Cfg, [string]$Html)
    if (-not $Cfg.Notify) { return }
    if (-not $env:TG_TOKEN -or -not $env:TG_CHAT) {
        Write-FabricLog $Cfg "notify on but TG_TOKEN/TG_CHAT missing — skipped."
        return
    }
    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TG_TOKEN)/sendMessage" -Method Post `
            -Body @{chat_id=$env:TG_CHAT; text=$Html; parse_mode='HTML'} -TimeoutSec 15 | Out-Null
        Write-FabricLog $Cfg "Telegram ping sent."
    } catch { Write-FabricLog $Cfg "Telegram send failed (non-fatal)." }
}
