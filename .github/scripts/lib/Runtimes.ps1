# lib/Runtimes.ps1 — Phase 2.5 (best-effort, full only).
# The GHA windows-latest image already ships VC++ 2008-2022, .NET Desktop
# 6/7/8/10, WebView2 and 7-Zip — so on that fingerprint this phase is a log
# line. On generic images it installs ONLY what the Uninstall keys don't show.
# DirectX web setup is deleted in V9 (pointless on Hyper-V video).

function Test-FabricInstalled {
    param([string]$Pattern)
    foreach ($p in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $hit = Get-ItemProperty $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match $Pattern } | Select-Object -First 1
        if ($hit) { return $true }
    }
    return $false
}

function Invoke-FabricRuntimes {
    param([pscustomobject]$Cfg)

    if ($Cfg.Image -eq 'GhaWindowsLatest') {
        Write-FabricLog $Cfg "runtime bootstrap skipped (image already has VC++/.NET/WebView2/7-Zip)."
        Save-FabricState $Cfg ([ordered]@{ runtimes = 'skipped-gha-image' })
        return
    }

    Write-FabricStep "Phase 2.5: runtimes (non-GHA image — only what's missing)"
    $tools = Join-Path $Cfg.DataRoot 'Tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    $log = Join-Path $tools 'runtime-bootstrap.log'
    "runtimes start $(Get-Date -Format o) image=$($Cfg.Image)" | Out-File $log -Encoding utf8

    $pkgs = @(
      @{ n='vc2008_x64.exe';  u='https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'; a=@('/q'); check='Visual C\+\+ 2008 Redistributable' },
      @{ n='vc2008_x86.exe';  u='https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe'; a=@('/q'); check='Visual C\+\+ 2008 Redistributable' },
      @{ n='vc2010_x64.exe';  u='https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'; a=@('/q','/norestart'); check='Visual C\+\+ 2010.*Redistributable' },
      @{ n='vc2010_x86.exe';  u='https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'; a=@('/q','/norestart'); check='Visual C\+\+ 2010.*Redistributable' },
      @{ n='vc2012_x64.exe';  u='https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'; a=@('/install','/quiet','/norestart'); check='Visual C\+\+ 2012 Redistributable' },
      @{ n='vc2012_x86.exe';  u='https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'; a=@('/install','/quiet','/norestart'); check='Visual C\+\+ 2012 Redistributable' },
      @{ n='vc2013_x64.exe';  u='https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x64.exe'; a=@('/install','/quiet','/norestart'); check='Visual C\+\+ 2013 Redistributable' },
      @{ n='vc2013_x86.exe';  u='https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x86.exe'; a=@('/install','/quiet','/norestart'); check='Visual C\+\+ 2013 Redistributable' },
      @{ n='vc2015_2022_x64.exe'; u='https://aka.ms/vs/17/release/vc_redist.x64.exe'; a=@('/install','/quiet','/norestart'); check='Visual C\+\+ (2015|2019|2022)|Visual C\+\+ v14' },
      @{ n='vc2015_2022_x86.exe'; u='https://aka.ms/vs/17/release/vc_redist.x86.exe'; a=@('/install','/quiet','/norestart'); check='Visual C\+\+ (2015|2019|2022)|Visual C\+\+ v14' },
      @{ n='dotnet-desktop-8.0-x64.exe'; u='https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'; a=@('/install','/quiet','/norestart'); check='Windows Desktop Runtime - 8\.' },
      @{ n='dotnet-desktop-9.0-x64.exe'; u='https://aka.ms/dotnet/9.0/windowsdesktop-runtime-win-x64.exe'; a=@('/install','/quiet','/norestart'); check='Windows Desktop Runtime - 9\.' },
      @{ n='MicrosoftEdgeWebview2Setup.exe'; u='https://go.microsoft.com/fwlink/p/?LinkId=2124703'; a=@('/silent','/install'); check='WebView2' }
    )

    $todo = @($pkgs | Where-Object { -not (Test-FabricInstalled $_.check) })
    "[skip] already present: $($pkgs.Count - $todo.Count)/$($pkgs.Count)" | Out-File $log -Append -Encoding utf8
    if (-not $todo.Count) {
        Write-FabricLog $Cfg "All runtimes already present — nothing to do."
        Save-FabricState $Cfg ([ordered]@{ runtimes = 'all-present' })
        return
    }

    # Parallel fetch, serialized install.
    $pending = @()
    foreach ($p in $todo) {
        $dst = Join-Path $tools $p.n
        Remove-Item -LiteralPath $dst, "$dst.part" -Force -ErrorAction SilentlyContinue
        $proc = Start-Process -FilePath 'curl.exe' -ArgumentList @('-sS','-L','--retry','2','--retry-all-errors','-m','300','-o',"`"$dst.part`"",$p.u) -WindowStyle Hidden -PassThru
        $pending += [pscustomobject]@{ Proc = $proc; Dst = $dst }
    }
    foreach ($h in $pending) {
        try { $h.Proc.WaitForExit() } catch {}
        $part = $h.Dst + '.part'
        if ((Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -gt 100KB) {
            Move-Item -LiteralPath $part -Destination $h.Dst -Force
            "[dl  ] $(Split-Path $h.Dst -Leaf)" | Out-File $log -Append -Encoding utf8
        } else {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            "[dlfail] $(Split-Path $h.Dst -Leaf)" | Out-File $log -Append -Encoding utf8
        }
    }
    foreach ($p in $todo) {
        $dst = Join-Path $tools $p.n
        if (Test-Path -LiteralPath $dst) {
            Start-Process -FilePath $dst -ArgumentList $p.a -Wait -WindowStyle Hidden
            "[ok  ] $($p.n)" | Out-File $log -Append -Encoding utf8
        } else {
            "[fail] $($p.n)" | Out-File $log -Append -Encoding utf8
        }
    }

    if (Test-FabricInstalled '7-Zip') {
        "[skip] 7-Zip" | Out-File $log -Append -Encoding utf8
    } else {
        try {
            winget source update --disable-interactivity 2>$null | Out-Null
            winget install -e --id 7zip.7zip --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>$null | Out-Null
            "[ok  ] 7-Zip" | Out-File $log -Append -Encoding utf8
        } catch { "[fail] 7-Zip" | Out-File $log -Append -Encoding utf8 }
    }

    "runtimes done $(Get-Date -Format o)" | Out-File $log -Append -Encoding utf8
    Save-FabricState $Cfg ([ordered]@{ runtimes = "installed-$($todo.Count)-missing" })
    Write-FabricLog $Cfg "Runtimes done — see $log"
}
