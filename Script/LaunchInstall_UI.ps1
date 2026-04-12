$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

function Hide-ConsoleWindow {
    try {
        $hWnd = [NativeMethods]::GetConsoleWindow()
        if ($hWnd -ne [IntPtr]::Zero) {
            [NativeMethods]::ShowWindow($hWnd, 0) | Out-Null
        }
    } catch {}
}

function Get-DisplayScale {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    $baseWidth = 1366
    $baseHeight = 768

    $scaleX = $bounds.Width / $baseWidth
    $scaleY = $bounds.Height / $baseHeight
    $scale = [math]::Min($scaleX, $scaleY)

    if ($scale -lt 0.68) { $scale = 0.68 }
    if ($scale -gt 1.45) { $scale = 1.45 }

    return [pscustomobject]@{
        Scale = $scale
        ScreenWidth = $bounds.Width
        ScreenHeight = $bounds.Height
    }
}

function S {
    param([double]$Value)
    return [int][math]::Round($Value * $script:Display.Scale)
}

function P {
    param([double]$X, [double]$Y)
    return New-Object System.Drawing.Point((S $X), (S $Y))
}

function Z {
    param([double]$W, [double]$H)
    return New-Object System.Drawing.Size((S $W), (S $H))
}

function Fnt {
    param(
        [string]$Name,
        [double]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    return New-Object System.Drawing.Font($Name, ([math]::Max(7, ($Size * $script:Display.Scale))), $Style)
}

function New-RoundedPath {
    param(
        [int]$Width,
        [int]$Height,
        [int]$Radius
    )

    if ($Radius -lt 1) { $Radius = 1 }
    $diameter = $Radius * 2

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
    $path.AddArc($Width - $diameter, 0, $diameter, $diameter, 270, 90)
    $path.AddArc($Width - $diameter, $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc(0, $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedControl {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius
    )

    if (-not $Control) { return }
    if ($Control.Width -le 0 -or $Control.Height -le 0) { return }

    $path = New-RoundedPath -Width $Control.Width -Height $Control.Height -Radius $Radius
    $Control.Region = New-Object System.Drawing.Region($path)
}

function Find-InstallRoot {
    if ($MyInvocation.MyCommand.Path) {
        try {
            $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
            $root = Split-Path -Parent $scriptDir
            if ((Test-Path (Join-Path $root 'Win10')) -and (Test-Path (Join-Path $root 'Win11'))) {
                return $root
            }
        } catch {}
    }

    $letters = 'C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z'
    foreach ($letter in $letters) {
        $root = "$letter`:"
        if ((Test-Path (Join-Path $root 'Win10')) -and (Test-Path (Join-Path $root 'Win11'))) {
            return $root
        }
    }

    return $null
}

function New-BackgroundForm {
    param([string]$InstallRoot)

    try {
        $bgPath = Join-Path $InstallRoot 'Script\winpe-wallpaper.jpg'

        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'
        $form.StartPosition = 'Manual'
        $form.WindowState = 'Maximized'
        $form.TopMost = $false
        $form.ShowInTaskbar = $false
        $form.BackColor = [System.Drawing.Color]::Black

        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Dock = 'Fill'
        $pb.SizeMode = 'Zoom'
        if (Test-Path $bgPath) {
            $pb.Image = [System.Drawing.Image]::FromFile($bgPath)
        }
        $form.Controls.Add($pb)

        $overlay = New-Object System.Windows.Forms.Panel
        $overlay.Dock = 'Fill'
        $overlay.BackColor = [System.Drawing.Color]::FromArgb(120, 0, 0, 0)
        $form.Controls.Add($overlay)

        $form.Show()
        $form.SendToBack()

        return [pscustomobject]@{
            Form = $form
            Picture = $pb
            Overlay = $overlay
        }
    } catch {
        return $null
    }
}

function Apply-InstalledBranding {
    param(
        [string]$InstallRoot,
        [string]$WindowsDrive
    )

    try {
        $scriptDir = Join-Path $InstallRoot 'Script'
        $wallpaperSource = Join-Path $scriptDir 'wallpaper.jpg'
        $lockscreenSource = Join-Path $scriptDir 'lockscreen.jpg'

        $customDir = "$WindowsDrive\Windows\Web\Custom"
        $wallpaperTarget = Join-Path $customDir 'wallpaper.jpg'
        $lockscreenTarget = Join-Path $customDir 'lockscreen.jpg'

        $systemWallpaperDir = "$WindowsDrive\Windows\Web\Wallpaper\Windows"
        $systemWallpaperTarget = Join-Path $systemWallpaperDir 'img0.jpg'
        $system4kWallpaperDir = "$WindowsDrive\Windows\Web\4K\Wallpaper\Windows"
        $systemScreenDir = "$WindowsDrive\Windows\Web\Screen"

        New-Item -Path $customDir -ItemType Directory -Force | Out-Null

        if (Test-Path $wallpaperSource) {
            Copy-Item $wallpaperSource $wallpaperTarget -Force
            New-Item -Path $systemWallpaperDir -ItemType Directory -Force | Out-Null
            Copy-Item $wallpaperSource $systemWallpaperTarget -Force

            if (Test-Path $system4kWallpaperDir) {
                Get-ChildItem -Path $system4kWallpaperDir -Filter '*.jpg' -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item $wallpaperSource $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (Test-Path $lockscreenSource) {
            Copy-Item $lockscreenSource $lockscreenTarget -Force
            if (Test-Path $systemScreenDir) {
                Get-ChildItem -Path $systemScreenDir -Filter '*.jpg' -ErrorAction SilentlyContinue | ForEach-Object {
                    Copy-Item $lockscreenSource $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $softwareHive = "$WindowsDrive\Windows\System32\config\SOFTWARE"
        if (Test-Path $softwareHive) {
            reg load HKLM\OFFSOFT $softwareHive | Out-Null

            reg delete "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v NoChangingWallPaper /f | Out-Null 2>&1
            reg delete "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /f | Out-Null 2>&1
            reg delete "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /f | Out-Null 2>&1
            reg delete "HKLM\OFFSOFT\Policies\Microsoft\Windows\Personalization" /v LockScreenImage /f | Out-Null 2>&1
            reg delete "HKLM\OFFSOFT\Policies\Microsoft\Windows\Personalization" /v NoChangingLockScreen /f | Out-Null 2>&1
            reg delete "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /f | Out-Null 2>&1

            reg unload HKLM\OFFSOFT | Out-Null
        }

        $defaultUserHive = "$WindowsDrive\Users\Default\NTUSER.DAT"
        if (Test-Path $defaultUserHive) {
            reg load HKU\DEFUSER $defaultUserHive | Out-Null

            reg delete "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v NoChangingWallPaper /f | Out-Null 2>&1
            reg delete "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /f | Out-Null 2>&1
            reg delete "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /f | Out-Null 2>&1

            if (Test-Path $wallpaperTarget) {
                reg add "HKU\DEFUSER\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "C:\Windows\Web\Custom\wallpaper.jpg" /f | Out-Null
                reg add "HKU\DEFUSER\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
                reg add "HKU\DEFUSER\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
            }

            reg add "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v PichauApplyBranding /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Setup\Scripts\ApplyUserBranding.ps1" /f | Out-Null

            reg unload HKU\DEFUSER | Out-Null
        }
    } catch {}
}


function New-IndicatorCircle {
    param(
        [string]$Text,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor,
        [int]$X,
        [int]$Y
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = P $X $Y
    $panel.Size = Z 30 24
    $panel.BackColor = $BackColor
    $panel.BorderStyle = 'FixedSingle'

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = $ForeColor
    $label.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $label.Text = $Text
    $panel.Controls.Add($label)

    return $panel
}

function New-InstallerUi {
    param([string]$InstallRoot)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Pichau Retro Installer'
    $form.StartPosition = 'Manual'
    $form.FormBorderStyle = 'None'
    $form.BackColor = [System.Drawing.Color]::FromArgb(5, 5, 7)
    $form.Size = Z 1040 620
    $form.TopMost = $true
    $form.ShowInTaskbar = $true

    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(
        [int](($screenBounds.Width - $form.Width) / 2),
        [int](($screenBounds.Height - $form.Height) / 2)
    )

    $root = New-Object System.Windows.Forms.Panel
    $root.Dock = 'Fill'
    $root.BackColor = [System.Drawing.Color]::FromArgb(5, 5, 7)
    $form.Controls.Add($root)

    $outerFrame = New-Object System.Windows.Forms.Panel
    $outerFrame.Location = P 18 18
    $outerFrame.Size = Z 1004 584
    $outerFrame.BackColor = [System.Drawing.Color]::FromArgb(60, 0, 0)
    $outerFrame.BorderStyle = 'FixedSingle'
    $root.Controls.Add($outerFrame)

    $shell = New-Object System.Windows.Forms.Panel
    $shell.Location = P 6 6
    $shell.Size = Z 992 572
    $shell.BackColor = [System.Drawing.Color]::FromArgb(8, 8, 10)
    $shell.BorderStyle = 'FixedSingle'
    $outerFrame.Controls.Add($shell)

    $left = New-Object System.Windows.Forms.Panel
    $left.Location = P 0 0
    $left.Size = Z 318 572
    $left.BackColor = [System.Drawing.Color]::FromArgb(23, 3, 6)
    $left.BorderStyle = 'FixedSingle'
    $shell.Controls.Add($left)

    $logoFrame = New-Object System.Windows.Forms.Panel
    $logoFrame.Location = P 36 34
    $logoFrame.Size = Z 246 158
    $logoFrame.BackColor = [System.Drawing.Color]::FromArgb(55, 5, 12)
    $logoFrame.BorderStyle = 'FixedSingle'
    $left.Controls.Add($logoFrame)

    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Location = P 22 26
    $logoBox.Size = Z 200 78
    $logoBox.SizeMode = 'Zoom'
    $logoPng = Join-Path $InstallRoot 'Script\logo.png'
    $logoJpg = Join-Path $InstallRoot 'Script\logo.jpg'
    if (Test-Path $logoPng) {
        $logoBox.Image = [System.Drawing.Image]::FromFile($logoPng)
    } elseif (Test-Path $logoJpg) {
        $logoBox.Image = [System.Drawing.Image]::FromFile($logoJpg)
    }
    $logoFrame.Controls.Add($logoBox)

    $logoTag = New-Object System.Windows.Forms.Label
    $logoTag.Location = P 16 120
    $logoTag.Size = Z 212 20
    $logoTag.TextAlign = 'MiddleCenter'
    $logoTag.ForeColor = [System.Drawing.Color]::FromArgb(255, 88, 88)
    $logoTag.Font = Fnt 'Consolas' 8 ([System.Drawing.FontStyle]::Bold)
    $logoTag.Text = 'RETRO DEPLOY INTERFACE'
    $logoFrame.Controls.Add($logoTag)

    $brand = New-Object System.Windows.Forms.Label
    $brand.Location = P 36 214
    $brand.Size = Z 246 30
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(255, 246, 246)
    $brand.Font = Fnt 'Consolas' 18 ([System.Drawing.FontStyle]::Bold)
    $brand.Text = 'DUALBOOT SETUP'
    $left.Controls.Add($brand)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Location = P 36 254
    $desc.Size = Z 246 72
    $desc.ForeColor = [System.Drawing.Color]::FromArgb(235, 214, 214)
    $desc.Font = Fnt 'Consolas' 9
    $desc.Text = "INSTALACAO AUTOMATICA"
    $left.Controls.Add($desc)

    $miniCard = New-Object System.Windows.Forms.Panel
    $miniCard.Location = P 36 392
    $miniCard.Size = Z 246 94
    $miniCard.BackColor = [System.Drawing.Color]::FromArgb(45, 5, 11)
    $miniCard.BorderStyle = 'FixedSingle'
    $left.Controls.Add($miniCard)

    $miniTitle = New-Object System.Windows.Forms.Label
    $miniTitle.Location = P 16 12
    $miniTitle.Size = Z 210 18
    $miniTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 242, 242)
    $miniTitle.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $miniTitle.Text = 'MODO AUTOMATICO'
    $miniCard.Controls.Add($miniTitle)

    $miniText = New-Object System.Windows.Forms.Label
    $miniText.Location = P 16 38
    $miniText.Size = Z 210 38
    $miniText.ForeColor = [System.Drawing.Color]::FromArgb(220, 190, 190)
    $miniText.Font = Fnt 'Consolas' 8
    $miniText.Text = 'BOOT + DISM + DRIVERS'
    $miniCard.Controls.Add($miniText)

    $miniTag = New-Object System.Windows.Forms.Label
    $miniTag.Location = P 16 76
    $miniTag.Size = Z 210 10
    $miniTag.ForeColor = [System.Drawing.Color]::FromArgb(185, 95, 95)
    $miniTag.Font = Fnt 'Consolas' 7 ([System.Drawing.FontStyle]::Bold)
    $miniTag.Text = 'STATUS // ONLINE'
    $miniCard.Controls.Add($miniTag)

    $footerTag = New-Object System.Windows.Forms.Label
    $footerTag.Location = P 36 522
    $footerTag.Size = Z 246 18
    $footerTag.ForeColor = [System.Drawing.Color]::FromArgb(160, 100, 100)
    $footerTag.Font = Fnt 'Consolas' 7
    $footerTag.Text = 'ADNEY CORREA // IA'
    $left.Controls.Add($footerTag)

    $right = New-Object System.Windows.Forms.Panel
    $right.Location = P 318 0
    $right.Size = Z 674 572
    $right.BackColor = [System.Drawing.Color]::FromArgb(7, 7, 9)
    $right.BorderStyle = 'FixedSingle'
    $shell.Controls.Add($right)

    $topAccent = New-Object System.Windows.Forms.Panel
    $topAccent.Location = P 34 28
    $topAccent.Size = Z 88 5
    $topAccent.BackColor = [System.Drawing.Color]::FromArgb(255, 38, 48)
    $right.Controls.Add($topAccent)

    $header = New-Object System.Windows.Forms.Label
    $header.Location = P 34 48
    $header.Size = Z 390 34
    $header.ForeColor = [System.Drawing.Color]::White
    $header.Font = Fnt 'Consolas' 18 ([System.Drawing.FontStyle]::Bold)
    $header.Text = 'PREPARANDO INSTALACAO'
    $right.Controls.Add($header)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = P 34 108
    $status.Size = Z 430 28
    $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 244, 244)
    $status.Font = Fnt 'Consolas' 14 ([System.Drawing.FontStyle]::Bold)
    $status.Text = 'INICIANDO'
    $right.Controls.Add($status)

    $percent = New-Object System.Windows.Forms.Label
    $percent.Location = P 522 90
    $percent.Size = Z 110 56
    $percent.TextAlign = 'MiddleRight'
    $percent.ForeColor = [System.Drawing.Color]::FromArgb(255, 52, 64)
    $percent.Font = Fnt 'Consolas' 28 ([System.Drawing.FontStyle]::Bold)
    $percent.Text = '0%'
    $right.Controls.Add($percent)

    $osBadgeOuter = New-Object System.Windows.Forms.Panel
    $osBadgeOuter.Location = P 454 26
    $osBadgeOuter.Size = Z 176 30
    $osBadgeOuter.BackColor = [System.Drawing.Color]::FromArgb(95, 8, 15)
    $osBadgeOuter.BorderStyle = 'FixedSingle'
    $right.Controls.Add($osBadgeOuter)

    $osBadge = New-Object System.Windows.Forms.Panel
    $osBadge.Location = P 2 2
    $osBadge.Size = Z 170 24
    $osBadge.BackColor = [System.Drawing.Color]::FromArgb(12, 10, 12)
    $osBadge.BorderStyle = 'FixedSingle'
    $osBadgeOuter.Controls.Add($osBadge)

    $osLabel = New-Object System.Windows.Forms.Label
    $osLabel.Dock = 'Fill'
    $osLabel.TextAlign = 'MiddleCenter'
    $osLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 232, 232)
    $osLabel.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $osLabel.Text = 'WINDOWS'
    $osBadge.Controls.Add($osLabel)

    $detailOuter = New-Object System.Windows.Forms.Panel
    $detailOuter.Location = P 34 164
    $detailOuter.Size = Z 596 110
    $detailOuter.BackColor = [System.Drawing.Color]::FromArgb(80, 8, 14)
    $detailOuter.BorderStyle = 'FixedSingle'
    $right.Controls.Add($detailOuter)

    $detailCard = New-Object System.Windows.Forms.Panel
    $detailCard.Location = P 3 3
    $detailCard.Size = Z 588 102
    $detailCard.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 20)
    $detailCard.BorderStyle = 'FixedSingle'
    $detailOuter.Controls.Add($detailCard)

    $detail = New-Object System.Windows.Forms.Label
    $detail.Location = P 16 16
    $detail.Size = Z 554 70
    $detail.ForeColor = [System.Drawing.Color]::FromArgb(224, 224, 230)
    $detail.Font = Fnt 'Consolas' 9
    $detail.Text = 'AGUARDANDO ETAPA INICIAL'
    $detail.AutoEllipsis = $true
    $detailCard.Controls.Add($detail)

    $barOuter = New-Object System.Windows.Forms.Panel
    $barOuter.Location = P 34 298
    $barOuter.Size = Z 596 32
    $barOuter.BackColor = [System.Drawing.Color]::FromArgb(80, 8, 14)
    $barOuter.BorderStyle = 'FixedSingle'
    $right.Controls.Add($barOuter)

    $barBack = New-Object System.Windows.Forms.Panel
    $barBack.Location = P 3 3
    $barBack.Size = Z 588 24
    $barBack.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $barBack.BorderStyle = 'FixedSingle'
    $barOuter.Controls.Add($barBack)

    $barFillGlow = New-Object System.Windows.Forms.Panel
    $barFillGlow.Location = P 0 0
    $barFillGlow.Size = Z 1 24
    $barFillGlow.BackColor = [System.Drawing.Color]::FromArgb(120, 14, 22)
    $barFillGlow.BorderStyle = 'FixedSingle'
    $barBack.Controls.Add($barFillGlow)

    $barFill = New-Object System.Windows.Forms.Panel
    $barFill.Location = P 0 0
    $barFill.Size = Z 1 24
    $barFill.BackColor = [System.Drawing.Color]::FromArgb(220, 24, 38)
    $barFill.BorderStyle = 'FixedSingle'
    $barBack.Controls.Add($barFill)

    $stepsOuter = New-Object System.Windows.Forms.Panel
    $stepsOuter.Location = P 34 350
    $stepsOuter.Size = Z 596 188
    $stepsOuter.BackColor = [System.Drawing.Color]::FromArgb(80, 8, 14)
    $stepsOuter.BorderStyle = 'FixedSingle'
    $right.Controls.Add($stepsOuter)

    $stepsPanel = New-Object System.Windows.Forms.Panel
    $stepsPanel.Location = P 3 3
    $stepsPanel.Size = Z 588 180
    $stepsPanel.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 12)
    $stepsPanel.BorderStyle = 'FixedSingle'
    $stepsOuter.Controls.Add($stepsPanel)

    $stepsTitle = New-Object System.Windows.Forms.Label
    $stepsTitle.Location = P 14 12
    $stepsTitle.Size = Z 220 18
    $stepsTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 240, 240)
    $stepsTitle.Font = Fnt 'Consolas' 10 ([System.Drawing.FontStyle]::Bold)
    $stepsTitle.Text = 'FLUXO DE INSTALACAO'
    $stepsPanel.Controls.Add($stepsTitle)

    $step1Dot = New-IndicatorCircle -Text '1' -BackColor ([System.Drawing.Color]::FromArgb(220, 24, 38)) -ForeColor ([System.Drawing.Color]::White) -X 16 -Y 44
    $step2Dot = New-IndicatorCircle -Text '2' -BackColor ([System.Drawing.Color]::FromArgb(55, 55, 60)) -ForeColor ([System.Drawing.Color]::White) -X 16 -Y 78
    $step3Dot = New-IndicatorCircle -Text '3' -BackColor ([System.Drawing.Color]::FromArgb(55, 55, 60)) -ForeColor ([System.Drawing.Color]::White) -X 16 -Y 112
    $step4Dot = New-IndicatorCircle -Text '4' -BackColor ([System.Drawing.Color]::FromArgb(55, 55, 60)) -ForeColor ([System.Drawing.Color]::White) -X 16 -Y 146
    $stepsPanel.Controls.Add($step1Dot)
    $stepsPanel.Controls.Add($step2Dot)
    $stepsPanel.Controls.Add($step3Dot)
    $stepsPanel.Controls.Add($step4Dot)

    $step1 = New-Object System.Windows.Forms.Label
    $step1.Location = P 58 44
    $step1.Size = Z 494 24
    $step1.ForeColor = [System.Drawing.Color]::White
    $step1.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $step1.Text = 'VALIDACAO DA MIDIA'
    $stepsPanel.Controls.Add($step1)

    $step2 = New-Object System.Windows.Forms.Label
    $step2.Location = P 58 78
    $step2.Size = Z 494 24
    $step2.ForeColor = [System.Drawing.Color]::FromArgb(165, 165, 176)
    $step2.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $step2.Text = 'PREPARACAO DO DISCO'
    $stepsPanel.Controls.Add($step2)

    $step3 = New-Object System.Windows.Forms.Label
    $step3.Location = P 58 112
    $step3.Size = Z 494 24
    $step3.ForeColor = [System.Drawing.Color]::FromArgb(165, 165, 176)
    $step3.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $step3.Text = 'APLICACAO DA IMAGEM'
    $stepsPanel.Controls.Add($step3)

    $step4 = New-Object System.Windows.Forms.Label
    $step4.Location = P 58 146
    $step4.Size = Z 494 24
    $step4.ForeColor = [System.Drawing.Color]::FromArgb(165, 165, 176)
    $step4.Font = Fnt 'Consolas' 9 ([System.Drawing.FontStyle]::Bold)
    $step4.Text = 'BOOT E FINALIZACAO'
    $stepsPanel.Controls.Add($step4)

    return [pscustomobject]@{
        Form = $form
        Header = $header
        Status = $status
        Detail = $detail
        Percent = $percent
        BarBack = $barBack
        BarFill = $barFill
        BarFillGlow = $barFillGlow
        Step1 = $step1
        Step2 = $step2
        Step3 = $step3
        Step4 = $step4
        Step1Dot = $step1Dot
        Step2Dot = $step2Dot
        Step3Dot = $step3Dot
        Step4Dot = $step4Dot
        OsBadge = $osBadge
        OsLabel = $osLabel
    }
}

function Set-StepVisual {
    param(
        $Ui,
        [int]$ActiveStep
    )

    $inactiveText = [System.Drawing.Color]::FromArgb(165, 165, 176)
    $activeText = [System.Drawing.Color]::White
    $doneBack = [System.Drawing.Color]::FromArgb(110, 12, 20)
    $activeBack = [System.Drawing.Color]::FromArgb(220, 24, 38)
    $inactiveBack = [System.Drawing.Color]::FromArgb(55, 55, 60)

    $steps = @(
        @{ N = 1; Label = $Ui.Step1; Dot = $Ui.Step1Dot },
        @{ N = 2; Label = $Ui.Step2; Dot = $Ui.Step2Dot },
        @{ N = 3; Label = $Ui.Step3; Dot = $Ui.Step3Dot },
        @{ N = 4; Label = $Ui.Step4; Dot = $Ui.Step4Dot }
    )

    foreach ($s in $steps) {
        $label = $s.Label
        $dot = $s.Dot

        if ($s.N -lt $ActiveStep) {
            $label.ForeColor = $activeText
            $dot.BackColor = $doneBack
        } elseif ($s.N -eq $ActiveStep) {
            $label.ForeColor = $activeText
            $dot.BackColor = $activeBack
        } else {
            $label.ForeColor = $inactiveText
            $dot.BackColor = $inactiveBack
        }
    }
}

function Update-Ui {
    param(
        $Ui,
        [int]$Percent,
        [string]$Status,
        [string]$Detail,
        [int]$Step = 1
    )

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    if ([string]::IsNullOrWhiteSpace($Status)) { $Status = 'PROCESSANDO' }
    if ([string]::IsNullOrWhiteSpace($Detail)) { $Detail = 'AGUARDANDO ETAPA' }

    $headerText = switch ($Step) {
        1 { 'PREPARANDO INSTALACAO' }
        2 { 'CONFIGURANDO DISCO' }
        3 { 'APLICANDO IMAGEM' }
        4 { 'FINALIZANDO BOOT' }
        default { 'PREPARANDO INSTALACAO' }
    }

    if ($Ui.Header.Text -notlike 'ERRO*') {
        $Ui.Header.Text = $headerText
    }

    $Ui.Status.Text = $Status.ToUpper()
    $Ui.Detail.Text = $Detail
    $Ui.Percent.Text = "$Percent%"

    $maxWidth = [math]::Max(1, $Ui.BarBack.Width)
    $rawWidth = [math]::Round(($maxWidth * $Percent) / 100)
    $pixelUnit = [math]::Max(4, (S 8))
    $newWidth = [math]::Max(1, [int]([math]::Floor($rawWidth / $pixelUnit) * $pixelUnit))
    if ($Percent -gt 0 -and $newWidth -lt $pixelUnit) { $newWidth = $pixelUnit }
    if ($newWidth -gt $maxWidth) { $newWidth = $maxWidth }
    $glowWidth = [math]::Min($maxWidth, $newWidth + (S 8))

    $Ui.BarFillGlow.Width = $glowWidth
    $Ui.BarFill.Width = $newWidth

    Set-StepVisual -Ui $Ui -ActiveStep $Step
    [System.Windows.Forms.Application]::DoEvents()
}

function Stop-WithError {
    param(
        [string]$Message,
        [int]$Seconds = 12,
        [int]$ExitCode = 1
    )

    if ($script:Ui) {
        $script:Ui.Header.Text = 'Erro na instalacao'
        Update-Ui -Ui $script:Ui -Percent 100 -Status 'Falha detectada' -Detail $Message -Step 4
        Start-Sleep -Seconds 8
    }

    Start-Sleep -Seconds $Seconds
    wpeutil reboot
    exit $ExitCode
}

function Get-FreeDriveLetter {
    param([string[]]$PreferredLetters = @('W','V','U','T','S','R','Q','P','O','N','M'))

    $used = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
    foreach ($letter in $PreferredLetters) {
        if ($used -notcontains $letter) { return $letter }
    }
    return $null
}

function Get-ImageFile {
    param([string]$BasePath)
    $wim = Join-Path $BasePath 'sources\install.wim'
    $esd = Join-Path $BasePath 'sources\install.esd'
    if (Test-Path $wim) { return $wim }
    if (Test-Path $esd) { return $esd }
    return $null
}

function Test-BaseFiles {
    param([string]$BasePath)
    return [bool](Get-ImageFile -BasePath $BasePath)
}

function Test-OldIntelCpu {
    param([string]$Name)

    if ($Name -notmatch 'Intel') { return $false }
    if ($Name -match 'Pentium|Celeron|Atom|Xeon') { return $true }

    if ($Name -match 'i[3579]-([0-9]{4,5})') {
        $model = $Matches[1]
        if ($model.Length -eq 4) { $gen = [int]$model.Substring(0, 1) }
        elseif ($model.Length -eq 5) { $gen = [int]$model.Substring(0, 2) }
        else { return $true }
        return ($gen -le 7)
    }

    return $true
}

function Test-OldAmdCpu {
    param([string]$Name)

    if ($Name -notmatch 'AMD') { return $false }
    if ($Name -match 'Ryzen 3|Ryzen 5|Ryzen 7|Ryzen 9|Threadripper|EPYC') { return $false }
    if ($Name -match 'FX|Phenom|Athlon II|Sempron|Opteron|Turion|A-Series|Athlon X2|Athlon 64') { return $true }
    return $true
}

function Get-TpmPresent {
    try {
        $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
        if ($null -ne $tpm) { return $true }
    } catch {}

    try {
        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            $tpm2 = Get-Tpm
            if ($null -ne $tpm2 -and $tpm2.TpmPresent) { return $true }
        }
    } catch {}

    return $false
}

function Get-SafeTargetDisk {
    param([string]$InstallRoot)

    $minBytes = 80GB
    $installDriveLetter = $InstallRoot.TrimEnd(':')
    $usbDiskNumbers = @()

    try {
        $usbPartition = Get-Partition -DriveLetter $installDriveLetter -ErrorAction Stop
        $usbDiskNumbers += $usbPartition.DiskNumber
        $usbDiskNumbers = $usbDiskNumbers | Select-Object -Unique
    } catch {}

    $validBusTypes = @('SATA','NVMe','SCSI','RAID','ATA','SAS')
    $allDisks = Get-Disk | Sort-Object Number

    $safeDisks = $allDisks | Where-Object {
        ($_.Size -ge $minBytes) -and
        ($_.BusType.ToString() -in $validBusTypes) -and
        ($usbDiskNumbers -notcontains $_.Number)
    } | Sort-Object Size -Descending

    return ($safeDisks | Select-Object -First 1)
}

function Get-ImageIndexByName {
    param(
        [string]$ImageFile,
        [string[]]$PreferredNames
    )

    $output = dism /English /Get-WimInfo /WimFile:$ImageFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }

    $blocks = $output -split 'Index : '
    foreach ($block in $blocks) {
        foreach ($name in $PreferredNames) {
            if ($block -match ('Name : ' + [regex]::Escape($name))) {
                if ($block -match '^\s*(\d+)') { return [int]$Matches[1] }
            }
        }
    }

    return 1
}

function Invoke-DiskPartScript {
    param([string]$Content)

    $dpFile = 'X:\diskpart.txt'
    Set-Content -Path $dpFile -Value $Content -Encoding ASCII
    diskpart /s $dpFile | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Falha ao preparar o disco.'
    }
}

function Prepare-DiskUefi {
    param(
        [int]$DiskNumber,
        [string]$SystemLetter,
        [string]$WindowsLetter
    )

    $dp = @"
select disk $DiskNumber
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=$SystemLetter
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=$WindowsLetter
exit
"@
    Invoke-DiskPartScript -Content $dp
}

function Prepare-DiskBios {
    param(
        [int]$DiskNumber,
        [string]$SystemLetter,
        [string]$WindowsLetter
    )

    $dp = @"
select disk $DiskNumber
clean
convert mbr
create partition primary size=500
format quick fs=ntfs label="System"
active
assign letter=$SystemLetter
create partition primary
format quick fs=ntfs label="Windows"
assign letter=$WindowsLetter
exit
"@
    Invoke-DiskPartScript -Content $dp
}

function Invoke-DismApplyImageWithUi {
    param(
        [string]$ImageFile,
        [int]$Index,
        [string]$WindowsDrive,
        $Ui
    )

    $arguments = "/Apply-Image /ImageFile:`"$ImageFile`" /Index:$Index /ApplyDir:$WindowsDrive\"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'dism.exe'
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    while (-not $proc.HasExited) {
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()

            if ($line -match '(\d+(?:[\,\.]\d+)?)%') {
                $raw = $Matches[1].Replace(',', '.')
                $dismPercent = [double]$raw
                $mapped = [math]::Round(25 + (($dismPercent / 100) * 60))
                Update-Ui -Ui $Ui -Percent $mapped -Status 'Aplicando imagem do Windows' -Detail $line -Step 3
            } elseif ($line) {
                Update-Ui -Ui $Ui -Percent 30 -Status 'Aplicando imagem do Windows' -Detail $line -Step 3
            }
        }

        Start-Sleep -Milliseconds 120
        [System.Windows.Forms.Application]::DoEvents()
    }

    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($line -match '(\d+(?:[\,\.]\d+)?)%') {
            $raw = $Matches[1].Replace(',', '.')
            $dismPercent = [double]$raw
            $mapped = [math]::Round(25 + (($dismPercent / 100) * 60))
            Update-Ui -Ui $Ui -Percent $mapped -Status 'Aplicando imagem do Windows' -Detail $line -Step 3
        }
    }

    $stderr = $proc.StandardError.ReadToEnd()
    if ($proc.ExitCode -ne 0) {
        if (-not $stderr) { $stderr = 'DISM retornou erro na aplicacao da imagem.' }
        Stop-WithError $stderr
    }
}

function Copy-UnattendToInstalledWindows {
    param(
        [string]$XmlPath,
        [string]$WindowsDrive
    )

    $pantherDir = "$WindowsDrive\Windows\Panther"
    if (-not (Test-Path $pantherDir)) {
        New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $XmlPath -Destination (Join-Path $pantherDir 'unattend.xml') -Force
}

function Copy-SetupComplete {
    param(
        [string]$InstallRoot,
        [string]$WindowsDrive
    )

    $destDir = "$WindowsDrive\Windows\Setup\Scripts"
    if (-not (Test-Path $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    $filesToCopy = @(
        @{ Source = (Join-Path $InstallRoot 'SetupComplete.cmd'); Destination = 'SetupComplete.cmd' },
        @{ Source = (Join-Path $InstallRoot 'Script\Instalar_Drivers_Offline.cmd'); Destination = 'Instalar_Drivers_Offline.cmd' },
        @{ Source = (Join-Path $InstallRoot 'Script\Instalar_Drivers_Offline.ps1'); Destination = 'Instalar_Drivers_Offline.ps1' }
    )

    foreach ($file in $filesToCopy) {
        if (Test-Path $file.Source) {
            Copy-Item -Path $file.Source -Destination (Join-Path $destDir $file.Destination) -Force
        }
    }
}

function Create-BootFiles {
    param(
        [bool]$IsUefi,
        [string]$SystemDrive,
        [string]$WindowsDrive
    )

    if ($IsUefi) {
        bcdboot "$WindowsDrive\Windows" /s "$SystemDrive`:" /f UEFI | Out-Null
    } else {
        bcdboot "$WindowsDrive\Windows" /s "$SystemDrive`:" /f BIOS | Out-Null
        bootsect /nt60 "$SystemDrive`:" /mbr | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Falha ao criar o boot do Windows.'
    }
}

function Get-FirmwareBootEntries {
    $text = bcdedit /enum firmware 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return @() }

    $entries = @()
    $current = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^Firmware Application \((.+)\)$') {
            if ($current) { $entries += [pscustomobject]$current }
            $current = @{ Type = $Matches[1]; Identifier = ''; Description = '' }
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^identifier\s+(\{.+\})$') { $current.Identifier = $Matches[1]; continue }
        if ($line -match '^description\s+(.+)$') { $current.Description = $Matches[1].Trim(); continue }
    }
    if ($current) { $entries += [pscustomobject]$current }
    return $entries
}

function Set-NextBootToInternalWindows {
    param(
        [bool]$IsUefi,
        [string]$SystemDrive
    )

    if (-not $IsUefi) { return }

    try {
        $efiBcd = "$SystemDrive`:\EFI\Microsoft\Boot\BCD"
        if (-not (Test-Path $efiBcd)) { return }

        $fwText = bcdedit /enum firmware 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return }

        $entries = @()
        $current = $null

        foreach ($line in ($fwText -split "`r?`n")) {
            if ($line -match '^Firmware Application \((.+)\)$') {
                if ($current) { $entries += [pscustomobject]$current }
                $current = @{
                    Type = $Matches[1]
                    Identifier = ''
                    Description = ''
                }
                continue
            }

            if (-not $current) { continue }

            if ($line -match '^identifier\s+(\{.+\})$') {
                $current.Identifier = $Matches[1]
                continue
            }

            if ($line -match '^description\s+(.+)$') {
                $current.Description = $Matches[1].Trim()
                continue
            }
        }

        if ($current) { $entries += [pscustomobject]$current }

        $candidate = $entries | Where-Object {
            $_.Description -eq 'Windows Boot Manager'
        } | Select-Object -First 1

        if (-not $candidate) {
            $candidate = $entries | Where-Object {
                $_.Description -match 'Windows Boot Manager'
            } | Where-Object {
                $_.Description -notmatch 'USB|Removable|Pendrive'
            } | Select-Object -First 1
        }

        if ($candidate -and $candidate.Identifier) {
            bcdedit /store $efiBcd /set '{bootmgr}' device partition="$SystemDrive`:" | Out-Null
            bcdedit /store $efiBcd /set '{bootmgr}' path \EFI\Microsoft\Boot\bootmgfw.efi | Out-Null
            bcdedit /set '{fwbootmgr}' bootsequence $candidate.Identifier | Out-Null
        }
    } catch {}
}

Hide-ConsoleWindow
wpeutil UpdateBootInfo | Out-Null
wpeutil InitializeNetwork | Out-Null

$installRoot = Find-InstallRoot
if (-not $installRoot) {
    Stop-WithError 'Midia dual boot nao encontrada. Verifique as pastas Win10 e Win11.'
}

$script:Display = Get-DisplayScale
$script:Bg = New-BackgroundForm -InstallRoot $installRoot
$script:Ui = New-InstallerUi -InstallRoot $installRoot
$script:Ui.Form.Show()
[System.Windows.Forms.Application]::DoEvents()

Update-Ui -Ui $script:Ui -Percent 3 -Status 'Validando midia' -Detail "Midia encontrada em $installRoot" -Step 1

$win10Base = Join-Path $installRoot 'Win10'
$win11Base = Join-Path $installRoot 'Win11'
$xml10 = Join-Path $installRoot 'autounattend-win10.xml'
$xml11 = Join-Path $installRoot 'autounattend-win11.xml'

if (-not (Test-BaseFiles -BasePath $win10Base)) {
    Stop-WithError "Arquivos do Windows 10 incompletos em $win10Base"
}

if (-not (Test-BaseFiles -BasePath $win11Base)) {
    Stop-WithError "Arquivos do Windows 11 incompletos em $win11Base"
}

if (-not (Test-Path $xml10)) {
    Stop-WithError "Arquivo nao encontrado: $xml10"
}

if (-not (Test-Path $xml11)) {
    Stop-WithError "Arquivo nao encontrado: $xml11"
}

Update-Ui -Ui $script:Ui -Percent 8 -Status 'Detectando hardware' -Detail 'Buscando disco seguro e validando compatibilidade' -Step 1

$targetDisk = Get-SafeTargetDisk -InstallRoot $installRoot
if (-not $targetDisk) {
    Stop-WithError 'Nenhum disco interno seguro foi encontrado. A instalacao foi cancelada.'
}

$ramGB = [math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB), 2)
$cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
$tpmPresent = Get-TpmPresent

$useWin10 = $false
$reasons = @()

if (-not $tpmPresent) {
    $useWin10 = $true
    $reasons += 'sem TPM'
}

if ($ramGB -lt 8) {
    $useWin10 = $true
    $reasons += 'menos de 8 GB de RAM'
}

if (Test-OldIntelCpu -Name $cpuName) {
    $useWin10 = $true
    $reasons += 'Intel antigo'
}

if (Test-OldAmdCpu -Name $cpuName) {
    $useWin10 = $true
    $reasons += 'AMD antigo'
}

if ($useWin10) {
    $selectedBase = $win10Base
    $selectedXml = $xml10
    $preferredNames = @('Windows 10 Pro','Windows 10 Pro N','Windows 10 Professional')
    $chosenName = 'Windows 10'
    $chosenReason = $reasons -join ', '
} else {
    $selectedBase = $win11Base
    $selectedXml = $xml11
    $preferredNames = @('Windows 11 Pro','Windows 11 Pro N','Windows 11 Professional')
    $chosenName = 'Windows 11'
    $chosenReason = 'hardware compativel'
}

$script:Ui.OsLabel.Text = $chosenName
if ($chosenName -eq 'Windows 11') {
    $script:Ui.OsBadge.BackColor = [System.Drawing.Color]::FromArgb(40, 14, 18)
} else {
    $script:Ui.OsBadge.BackColor = [System.Drawing.Color]::FromArgb(34, 24, 10)
}
Set-RoundedControl -Control $script:Ui.OsBadge -Radius (S 17)
[System.Windows.Forms.Application]::DoEvents()

$imageFile = Get-ImageFile -BasePath $selectedBase
if (-not $imageFile) {
    Stop-WithError "Imagem de instalacao nao encontrada em $selectedBase\sources"
}

$imageIndex = Get-ImageIndexByName -ImageFile $imageFile -PreferredNames $preferredNames
if (-not $imageIndex) {
    Stop-WithError 'Nao foi possivel identificar o indice da imagem.'
}

$firmwareType = $env:FIRMWARE_TYPE
$isUefi = $true
if ($firmwareType) {
    if ($firmwareType -match 'BIOS') { $isUefi = $false }
    elseif ($firmwareType -match 'UEFI') { $isUefi = $true }
}

$systemLetter = Get-FreeDriveLetter -PreferredLetters @('S','R','Q','P','O')
if (-not $systemLetter) {
    Stop-WithError 'Nao foi possivel encontrar uma letra livre para a particao de sistema.'
}

$windowsLetter = Get-FreeDriveLetter -PreferredLetters @('W','V','U','T','N','M')
if (-not $windowsLetter) {
    Stop-WithError 'Nao foi possivel encontrar uma letra livre para a particao do Windows.'
}

if ($windowsLetter -eq $systemLetter) {
    Stop-WithError 'Conflito interno ao selecionar letras temporarias.'
}

# Bloco removido: sempre reinstalar quando iniciar pelo pendrive.

Update-Ui -Ui $script:Ui -Percent 14 -Status 'Hardware validado' -Detail ("Sistema selecionado: {0}`r`nCPU: {1}`r`nRAM: {2} GB`r`nTPM: {3}`r`nMotivo: {4}" -f $chosenName, $cpuName, $ramGB, $tpmPresent, $chosenReason) -Step 1
Start-Sleep -Milliseconds 700

Update-Ui -Ui $script:Ui -Percent 18 -Status 'Preparando disco' -Detail ("Disco alvo: {0}`r`nModo de boot: {1}" -f $targetDisk.Number, ($(if($isUefi){'UEFI'}else{'BIOS'}))) -Step 2

if ($isUefi) {
    Prepare-DiskUefi -DiskNumber $targetDisk.Number -SystemLetter $systemLetter -WindowsLetter $windowsLetter
} else {
    Prepare-DiskBios -DiskNumber $targetDisk.Number -SystemLetter $systemLetter -WindowsLetter $windowsLetter
}

Update-Ui -Ui $script:Ui -Percent 25 -Status 'Disco preparado' -Detail ("Sistema: {0}:`r`nWindows: {1}:" -f $systemLetter, $windowsLetter) -Step 2
Start-Sleep -Milliseconds 700

Invoke-DismApplyImageWithUi -ImageFile $imageFile -Index $imageIndex -WindowsDrive "$windowsLetter`:" -Ui $script:Ui

Update-Ui -Ui $script:Ui -Percent 86 -Status 'Aplicando branding' -Detail 'Copiando wallpaper e lockscreen para o Windows instalado' -Step 3
Apply-InstalledBranding -InstallRoot $installRoot -WindowsDrive "$windowsLetter`:"

Update-Ui -Ui $script:Ui -Percent 90 -Status 'Copiando configuracoes' -Detail 'Aplicando unattend e SetupComplete' -Step 3
Copy-UnattendToInstalledWindows -XmlPath $selectedXml -WindowsDrive "$windowsLetter`:"
Copy-SetupComplete -InstallRoot $installRoot -WindowsDrive "$windowsLetter`:"

Update-Ui -Ui $script:Ui -Percent 94 -Status 'Criando boot' -Detail 'Configurando arquivos de boot do Windows' -Step 4
Create-BootFiles -IsUefi $isUefi -SystemDrive $systemLetter -WindowsDrive "$windowsLetter`:"
Set-NextBootToInternalWindows -IsUefi $isUefi -SystemDrive $systemLetter

Update-Ui -Ui $script:Ui -Percent 100 -Status 'Instalacao concluida' -Detail 'Reiniciando para continuar no disco interno.' -Step 4

try {
    [System.Windows.Forms.Application]::DoEvents()
} catch {}

Start-Sleep -Seconds 3

try {
    wpeutil UpdateBootInfo | Out-Null
} catch {}

try {
    $null = mountvol "$systemLetter`:" /L 2>$null
} catch {}

try {
    shutdown.exe /r /t 0 /f
} catch {
    wpeutil reboot
}

exit 0