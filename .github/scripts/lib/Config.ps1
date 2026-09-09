# lib/Config.ps1 — config resolver, logging, merge-only state, shared helpers.
# One $cfg object is built here and passed into every phase.
# v9.1: Version bump, state JSON depth 6 (S6).

function ConvertTo-FabricBool {
    param([string]$v)
    return (@('true','1','yes','on') -contains "$v".Trim().ToLowerInvariant())
}

# Resolver rule: FAB_* env (non-empty) → CLI -Param (non-empty) → hard default.
function Resolve-FabricValue {
    param([string]$EnvName, [string]$ParamValue, [string]$Default)
    $e = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($e))         { return $e.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ParamValue)) { return $ParamValue.Trim() }
    return $Default
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
    $root = Resolve-FabricValue 'FABRIC_ROOT' '' 'C:\ProgramData\RDPFabric'

    [pscustomobject]@{
        # ── contract ──
        Version         = '9.1'
        Mode            = $modeRaw
        RuntimeMinutes  = $rt
        JobTimeoutMin   = [math]::Min(360, $rt + 15)
        Profile         = $profile          # 'auto' is resolved in Inventory
        Ramdisk         = $false            # finalized in Inventory (needs RAM)
        RamdiskRequested= (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_RAMDISK' $EnableRamdisk 'false'))
        RdpCompression  = $comp
        ReclaimDisk     = (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_RECLAIM' $ReclaimDisk 'true'))
        StartupUrl      = (Resolve-FabricValue 'FAB_STARTUP_URL' $StartupUrl '')
        Notify          = (ConvertTo-FabricBool (Resolve-FabricValue 'FAB_NOTIFY' $Notify 'false'))
        User            = (Resolve-FabricValue 'RDP_USER' '' 'FabricAdmin')
        FabricRoot      = $root
        DataRoot        = $null
        Image           = $null
        # ── measured in Inventory ──
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
        # ── Tailscale ──
        TsVersion       = $tsv
        TsSha256        = [Environment]::GetEnvironmentVariable('FAB_TS_SHA256')
        TsMsiUrl        = "https://pkgs.tailscale.com/stable/tailscale-setup-$tsv-amd64.msi"
        TsMsiPath       = (Join-Path $root 'cache\tailscale.msi')
        TsPartPath      = (Join-Path $root 'cache\tailscale.msi.part')
        TsDlProc        = $null
        TsExe           = 'C:\Program Files\Tailscale\tailscale.exe'
        TsHostname      = $null
        TsIp            = ''
        TsDirect        = $false
        # ── bookkeeping ──
        FailCount       = 0
        LogReady        = $false
    }
}

# ── logging ──────────────────────────────────────────────────────────────────
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

# ── state (merge-only — a save never drops another phase's fields) ───────────
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

# ── registry helper (ensures key, consistent error accounting) ───────────────
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

# ── phase runner (fatal vs best-effort declared in Fabric.ps1) ───────────────
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

# ── misc shared ──────────────────────────────────────────────────────────────
function Get-FreeMemMB {
    return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
}

function Test-FabricFile {
    param([string]$Path, [long]$MinBytes = 1MB)
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    return ($fi -and $fi.Length -ge $MinBytes)
}

# Idempotent firewall rule; re-asserts scope on an existing rule.
function Ensure-FabricFirewallRule {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Direction = 'Inbound',
        [string]$Protocol = 'TCP',
        [int]$Port,
        [string[]]$RemoteAddress,
        [switch]$Remote
    )
    $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if ($rule) {
        if ($RemoteAddress) {
            try { $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue |
                    Set-NetFirewallAddressFilter -RemoteAddress $RemoteAddress -ErrorAction SilentlyContinue } catch {}
        }
        if (-not $rule.Enabled) { Enable-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue }
        return
    }
    $p = @{ DisplayName=$DisplayName; Direction=$Direction; Protocol=$Protocol; Action='Allow'; ErrorAction='SilentlyContinue' }
    if ($Remote) { $p['RemotePort'] = $Port } else { $p['LocalPort'] = $Port }
    if ($RemoteAddress) { $p['RemoteAddress'] = $RemoteAddress }
    New-NetFirewallRule @p | Out-Null
}

# Telegram is opt-in (notify input). Never sends when disabled.
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
