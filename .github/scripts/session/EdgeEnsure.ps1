# session/EdgeEnsure.ps1 — open the startup URL once, single-instance via mutex.
# -Match is the regex used to detect an already-running window (the caller
# passes the regex-escaped URL host, so changing the URL never breaks detection).
# -SoftwareGpu (v9.1): no real GPU on this node — force software rendering
# instead of GPU flags that blank/crash on a 0 MB Hyper-V adapter.
param(
  [string]$Url,
  [string]$Match,
  [switch]$SoftwareGpu
)
$ErrorActionPreference = 'SilentlyContinue'
if (-not $Url) { exit }
if (-not $Match) { $Match = [regex]::Escape($Url) }
$mutex = New-Object System.Threading.Mutex($false, 'Local\RDPFabricEdge')
if (-not $mutex.WaitOne(1000)) { exit }
try {
  $edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  $edge64 = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
  if (-not (Test-Path -LiteralPath $edge) -and (Test-Path -LiteralPath $edge64)) { $edge = $edge64 }
  if (-not (Test-Path -LiteralPath $edge)) { exit }
  $running = Get-CimInstance Win32_Process -Filter "name='msedge.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match $Match }
  if (-not $running) {
    $flags = '--no-first-run --no-default-browser-check --disable-sync --disable-background-networking --disable-features=Translate,MediaRouter --disable-pinch'
    if ($SoftwareGpu) { $flags += ' --disable-gpu --disable-gpu-compositing --in-process-gpu' }
    Start-Process -FilePath $edge -ArgumentList "--new-window $Url $flags"
  }
} finally { $mutex.ReleaseMutex() }
