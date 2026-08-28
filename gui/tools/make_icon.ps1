# Generates a scarlet neon "diamond" (gem) app icon: rpgm-decrypt.ico + .png
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_icon.ps1
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$size = 256
$bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# Gem silhouette: flat table on top, point at the bottom (brilliant cut).
$pts = @(
  (New-Object System.Drawing.PointF(88, 64)),
  (New-Object System.Drawing.PointF(168, 64)),
  (New-Object System.Drawing.PointF(216, 104)),
  (New-Object System.Drawing.PointF(128, 224)),
  (New-Object System.Drawing.PointF(40, 104))
)

# --- neon outer glow: stroke the outline several times, wide+faint -> tight+bright
$glow = @(
  @{ w = 22; a = 40 },
  @{ w = 14; a = 70 },
  @{ w = 8;  a = 120 }
)
foreach ($layer in $glow) {
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($layer.a, 255, 31, 75), [float]$layer.w)
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $g.DrawPolygon($pen, $pts)
  $pen.Dispose()
}

# --- gem body: vertical scarlet gradient
$rect = New-Object System.Drawing.RectangleF(40, 64, 176, 160)
$grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  $rect,
  [System.Drawing.Color]::FromArgb(255, 255, 90, 120),
  [System.Drawing.Color]::FromArgb(255, 193, 0, 46),
  [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$g.FillPolygon($grad, $pts)

# --- bright neon rim
$rim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 255, 31, 75), 5)
$rim.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawPolygon($rim, $pts)

# --- facet lines (light, semi-transparent) for the diamond look
$facet = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(190, 255, 235, 240), 2)
$lines = @(
  @(88,64, 40,104), @(168,64, 216,104),      # crown sides
  @(40,104, 216,104),                          # girdle
  @(40,104, 128,224), @(216,104, 128,224),    # pavilion sides
  @(128,64, 128,104),                          # table split
  @(128,104, 40,104), @(128,104, 216,104),    # crown to girdle
  @(128,104, 128,224)                          # centre to point
)
foreach ($l in $lines) { $g.DrawLine($facet, $l[0], $l[1], $l[2], $l[3]) }

# --- a small white sparkle highlight on the table
$hl = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160, 255, 255, 255))
$g.FillPolygon($hl, @(
  (New-Object System.Drawing.PointF(100, 72)),
  (New-Object System.Drawing.PointF(124, 72)),
  (New-Object System.Drawing.PointF(112, 96))
))

$g.Dispose()

$outDir = Split-Path -Parent $PSScriptRoot   # gui\
$png = Join-Path $outDir 'rpgm-decrypt.png'
$ico = Join-Path $outDir 'rpgm-decrypt.ico'
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)

# Save a real .ico (with alpha) via GetHicon -> Icon.Save
$hicon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hicon)
$fs = [System.IO.File]::Create($ico)
$icon.Save($fs)
$fs.Close()
$icon.Dispose()
$bmp.Dispose()

Write-Output "Wrote $png"
Write-Output "Wrote $ico"
