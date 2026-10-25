Add-Type -AssemblyName System.Drawing

$size = 1024
$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'iOS\MaisonZen\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$graphics.Clear([System.Drawing.Color]::FromArgb(67, 143, 142))

$backgroundBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.Rectangle]::new(0, 0, $size, $size),
    [System.Drawing.Color]::FromArgb(67, 143, 142),
    [System.Drawing.Color]::FromArgb(124, 191, 159),
    45
)
$graphics.FillRectangle($backgroundBrush, 0, 0, $size, $size)

$housePath = [System.Drawing.Drawing2D.GraphicsPath]::new()
$housePath.AddPolygon([System.Drawing.Point[]]@(
    [System.Drawing.Point]::new(128, 450),
    [System.Drawing.Point]::new(512, 130),
    [System.Drawing.Point]::new(896, 450),
    [System.Drawing.Point]::new(840, 450),
    [System.Drawing.Point]::new(840, 820),
    [System.Drawing.Point]::new(184, 820),
    [System.Drawing.Point]::new(184, 450)
))
$graphics.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(248, 250, 247)), $housePath)

$checkPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(93, 166, 119), 76)
$checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$graphics.DrawLines($checkPen, [System.Drawing.Point[]]@(
    [System.Drawing.Point]::new(292, 515),
    [System.Drawing.Point]::new(438, 653),
    [System.Drawing.Point]::new(733, 342)
))

$sparkleBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(242, 198, 109))
$graphics.FillEllipse($sparkleBrush, 782, 157, 42, 42)
$bitmap.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose(); $backgroundBrush.Dispose(); $housePath.Dispose(); $checkPen.Dispose(); $sparkleBrush.Dispose()
Write-Output $target
