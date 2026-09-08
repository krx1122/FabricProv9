# session/FabricTimer.ps1 — time-only countdown overlay, topmost, draggable.
# Reads deadline.txt (written once in Phase 0) — nothing else.
param(
  [string]$DeadlineFile = 'C:\ProgramData\RDPFabric\deadline.txt',
  [int]$FallbackMinutes = 345
)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$mtx = New-Object System.Threading.Mutex($false, 'Local\RDPFabricTimerOverlay')
if (-not $mtx.WaitOne(0)) { exit }
$deadline = $null
if (Test-Path -LiteralPath $DeadlineFile) {
  $raw = Get-Content -LiteralPath $DeadlineFile -Raw -ErrorAction SilentlyContinue
  if ($raw) {
    try {
      $deadline = [datetime]::Parse($raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch { $deadline = $null }
  }
}
if (-not $deadline) { $deadline = (Get-Date).AddMinutes($FallbackMinutes) }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Fabric Timer'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(10, 10)
$form.ClientSize = New-Object System.Drawing.Size(120, 34)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 18)
$form.Opacity = 0.88

$lbl = New-Object System.Windows.Forms.Label
$lbl.Dock = [System.Windows.Forms.DockStyle]::Fill
$lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lbl.Font = New-Object System.Drawing.Font('Consolas', 13, [System.Drawing.FontStyle]::Bold)
$lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 230, 140)
$lbl.Text = '--:--:--'
$form.Controls.Add($lbl)

$dragging = $false
$origin = New-Object System.Drawing.Point(0, 0)
$onDown = { param($s,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:dragging = $true; $script:origin = $e.Location } }
$onMove = { param($s,$e) if ($script:dragging) { $form.Location = New-Object System.Drawing.Point(($form.Location.X + $e.X - $script:origin.X), ($form.Location.Y + $e.Y - $script:origin.Y)) } }
$onUp   = { $script:dragging = $false }
$lbl.Add_MouseDown($onDown);  $lbl.Add_MouseMove($onMove);  $lbl.Add_MouseUp($onUp)
$form.Add_MouseDown($onDown); $form.Add_MouseMove($onMove); $form.Add_MouseUp($onUp)
$lbl.Add_DoubleClick({ $form.Location = New-Object System.Drawing.Point(10, 10) })

$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 1000
$tick.Add_Tick({
  $remain = $deadline - (Get-Date)
  $total = [math]::Ceiling($remain.TotalSeconds)
  if ($total -le 0) {
    $lbl.Text = '00:00:00'
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80)
    return
  }
  $h  = [math]::Floor($total / 3600)
  $mm = [math]::Floor(($total % 3600) / 60)
  $ss = $total % 60
  $lbl.Text = ('{0:00}:{1:00}:{2:00}' -f $h, $mm, $ss)
  if ($total -le 300)      { $lbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 80, 80) }
  elseif ($total -le 900)  { $lbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 176, 32) }
  else                     { $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 230, 140) }
  if (-not $form.TopMost)  { $form.TopMost = $true }
})
$tick.Start()

$keepTop = New-Object System.Windows.Forms.Timer
$keepTop.Interval = 30000
$keepTop.Add_Tick({ $form.TopMost = $false; $form.TopMost = $true })
$keepTop.Start()

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
