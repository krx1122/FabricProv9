# session/Governor.ps1 — working-set trim under memory pressure.
# V9: invoked by the hold loop ONLY on nodes with >= 24 GB RAM — on the 16 GB
# GHA image it never runs (12 GB free is the norm; trimming user apps hurts
# more than it helps). Keep-list covers interactive apps regardless.
param([int]$PressureMb = 1536)
$ErrorActionPreference = 'SilentlyContinue'
$os = Get-CimInstance Win32_OperatingSystem
$freeMb = [int]($os.FreePhysicalMemory / 1KB)
if ($freeMb -gt $PressureMb) { return $freeMb }
$code = @"
using System;
using System.Runtime.InteropServices;
public class FabricMem {
  [DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hProcess);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool i, int p);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@
try { Add-Type $code -ErrorAction SilentlyContinue } catch {}
$keep = @('csrss','wininit','winlogon','services','lsass','smss','system','idle','svchost',
          'explorer','dwm','rdpclip','rdpinput','termsrv','tailscale','tailscaled','tailscale-ipn',
          'powershell','pwsh','msiexec','winget','vcredist','wmiadap','runner.worker','runner.listener',
          'msedge','msedgewebview2','chrome','devenv','code','node','java','docker','dockerd',
          'ayugram','telegram','windowsterminal')
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 80MB -and ($keep -notcontains $_.ProcessName.ToLower()) } | ForEach-Object {
  try {
    $h = [FabricMem]::OpenProcess(0x1F0FFF, $false, $_.Id)
    if ($h -ne [IntPtr]::Zero) { [FabricMem]::EmptyWorkingSet($h) | Out-Null; [FabricMem]::CloseHandle($h) | Out-Null }
  } catch {}
}
[gc]::Collect(); [gc]::WaitForPendingFinalizers()
return [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
