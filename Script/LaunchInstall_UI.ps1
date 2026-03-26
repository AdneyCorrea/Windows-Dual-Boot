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

        $targetDir = "$WindowsDrive\Windows\Web\Custom"
        $wallpaperTarget = Join-Path $targetDir 'wallpaper.jpg'
        $lockscreenTarget = Join-Path $targetDir 'lockscreen.jpg'

        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null

        if (Test-Path $wallpaperSource) {
            Copy-Item $wallpaperSource $wallpaperTarget -Force
        }

        if (Test-Path $lockscreenSource) {
            Copy-Item $lockscreenSource $lockscreenTarget -Force
        }

        $softwareHive = "$WindowsDrive\Windows\System32\config\SOFTWARE"
        if (Test-Path $softwareHive) {
            reg load HKLM\OFFSOFT $softwareHive | Out-Null

            reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /f | Out-Null
            reg add "HKLM\OFFSOFT\Policies\Microsoft\Windows\Personalization" /f | Out-Null
            reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\Policies\System" /f | Out-Null

            if (Test-Path $wallpaperTarget) {
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /v DesktopImageStatus /t REG_DWORD /d 1 /f | Out-Null
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /v DesktopImagePath /t REG_SZ /d "C:\Windows\Web\Custom\wallpaper.jpg" /f | Out-Null
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /v DesktopImageUrl /t REG_SZ /d "C:\Windows\Web\Custom\wallpaper.jpg" /f | Out-Null
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /t REG_SZ /d "C:\Windows\Web\Custom\wallpaper.jpg" /f | Out-Null
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
            }

            if (Test-Path $lockscreenTarget) {
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /v LockScreenImageStatus /t REG_DWORD /d 1 /f | Out-Null
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /v LockScreenImagePath /t REG_SZ /d "C:\Windows\Web\Custom\lockscreen.jpg" /f | Out-Null
                reg add "HKLM\OFFSOFT\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /v LockScreenImageUrl /t REG_SZ /d "C:\Windows\Web\Custom\lockscreen.jpg" /f | Out-Null
                reg add "HKLM\OFFSOFT\Policies\Microsoft\Windows\Personalization" /v LockScreenImage /t REG_SZ /d "C:\Windows\Web\Custom\lockscreen.jpg" /f | Out-Null
            }

            reg unload HKLM\OFFSOFT | Out-Null
        }

        $defaultUserHive = "$WindowsDrive\Users\Default\NTUSER.DAT"
        if (Test-Path $defaultUserHive) {
            reg load HKU\DEFUSER $defaultUserHive | Out-Null
            if (Test-Path $wallpaperTarget) {
                reg add "HKU\DEFUSER\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "C:\Windows\Web\Custom\wallpaper.jpg" /f | Out-Null
                reg add "HKU\DEFUSER\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
                reg add "HKU\DEFUSER\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
            }
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
    $panel.Size = Z 28 28
    $panel.BackColor = $BackColor

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = $ForeColor
    $label.Font = Fnt 'Segoe UI' 9 ([System.Drawing.FontStyle]::Bold)
    $label.Text = $Text
    $panel.Controls.Add($label)

    $panel.Add_Resize({
        Set-RoundedControl -Control $panel -Radius (S 14)
    })

    return $panel
}

function New-InstallerUi {
    param([string]$InstallRoot)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Premium DualBoot Installer'
    $form.StartPosition = 'Manual'
    $form.FormBorderStyle = 'None'
    $form.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 12)
    $form.Size = Z 1040 620
    $form.TopMost = $true
    $form.ShowInTaskbar = $true

    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(
        [int](($screenBounds.Width - $form.Width) / 2),
        [int](($screenBounds.Height - $form.Height) / 2)
    )

    $form.Add_Shown({
        Set-RoundedControl -Control $form -Radius (S 24)
    })

    $root = New-Object System.Windows.Forms.Panel
    $root.Dock = 'Fill'
    $root.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 12)
    $form.Controls.Add($root)

    $glow = New-Object System.Windows.Forms.Panel
    $glow.Location = P 18 18
    $glow.Size = Z 1004 584
    $glow.BackColor = [System.Drawing.Color]::FromArgb(28, 0, 0)
    $root.Controls.Add($glow)
    $glow.Add_Resize({
        Set-RoundedControl -Control $glow -Radius (S 26)
    })

    $shell = New-Object System.Windows.Forms.Panel
    $shell.Location = P 10 10
    $shell.Size = Z 984 564
    $shell.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 18)
    $glow.Controls.Add($shell)
    $shell.Add_Resize({
        Set-RoundedControl -Control $shell -Radius (S 24)
    })

    $left = New-Object System.Windows.Forms.Panel
    $left.Location = P 0 0
    $left.Size = Z 340 564
    $left.BackColor = [System.Drawing.Color]::FromArgb(24, 7, 9)
    $shell.Controls.Add($left)
    $left.Add_Resize({
        Set-RoundedControl -Control $left -Radius (S 24)
    })

    $logoFrame = New-Object System.Windows.Forms.Panel
    $logoFrame.Location = P 40 34
    $logoFrame.Size = Z 260 170
    $logoFrame.BackColor = [System.Drawing.Color]::FromArgb(34, 12, 15)
    $left.Controls.Add($logoFrame)
    $logoFrame.Add_Resize({
        Set-RoundedControl -Control $logoFrame -Radius (S 20)
    })

    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Location = P 18 18
    $logoBox.Size = Z 224 134
    $logoBox.SizeMode = 'Zoom'
    $logoPng = Join-Path $InstallRoot 'Script\logo.png'
    $logoJpg = Join-Path $InstallRoot 'Script\logo.jpg'
    if (Test-Path $logoPng) {
        $logoBox.Image = [System.Drawing.Image]::FromFile($logoPng)
    } elseif (Test-Path $logoJpg) {
        $logoBox.Image = [System.Drawing.Image]::FromFile($logoJpg)
    }
    $logoFrame.Controls.Add($logoBox)

    $brand = New-Object System.Windows.Forms.Label
    $brand.Location = P 40 224
    $brand.Size = Z 260 34
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $brand.Font = Fnt 'Segoe UI' 20 ([System.Drawing.FontStyle]::Bold)
    $brand.Text = 'DualBoot Setup'
    $left.Controls.Add($brand)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Location = P 40 268
    $desc.Size = Z 260 90
    $desc.ForeColor = [System.Drawing.Color]::FromArgb(210, 180, 180)
    $desc.Font = Fnt 'Segoe UI' 10
    $desc.Text = "Instalacao premium`r`ncom visual moderno`r`ne progresso em tempo real"
    $left.Controls.Add($desc)

    $miniCard = New-Object System.Windows.Forms.Panel
    $miniCard.Location = P 40 390
    $miniCard.Size = Z 260 90
    $miniCard.BackColor = [System.Drawing.Color]::FromArgb(32, 11, 14)
    $left.Controls.Add($miniCard)
    $miniCard.Add_Resize({
        Set-RoundedControl -Control $miniCard -Radius (S 18)
    })

    $miniTitle = New-Object System.Windows.Forms.Label
    $miniTitle.Location = P 18 14
    $miniTitle.Size = Z 220 22
    $miniTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
    $miniTitle.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $miniTitle.Text = 'Modo automatico'
    $miniCard.Controls.Add($miniTitle)

    $miniText = New-Object System.Windows.Forms.Label
    $miniText.Location = P 18 40
    $miniText.Size = Z 220 34
    $miniText.ForeColor = [System.Drawing.Color]::FromArgb(205, 178, 178)
    $miniText.Font = Fnt 'Segoe UI' 9
    $miniText.Text = 'Boot, imagem e branding sem intervencao manual'
    $miniCard.Controls.Add($miniText)

    $footerTag = New-Object System.Windows.Forms.Label
    $footerTag.Location = P 40 512
    $footerTag.Size = Z 260 20
    $footerTag.ForeColor = [System.Drawing.Color]::FromArgb(150, 120, 120)
    $footerTag.Font = Fnt 'Segoe UI' 8
    $footerTag.Text = 'Script feito por Adney Correa com auxilio da IA'
    $left.Controls.Add($footerTag)

    $right = New-Object System.Windows.Forms.Panel
    $right.Location = P 340 0
    $right.Size = Z 644 564
    $right.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 18)
    $shell.Controls.Add($right)

    $topAccent = New-Object System.Windows.Forms.Panel
    $topAccent.Location = P 40 30
    $topAccent.Size = Z 72 6
    $topAccent.BackColor = [System.Drawing.Color]::FromArgb(200, 20, 35)
    $right.Controls.Add($topAccent)
    $topAccent.Add_Resize({
        Set-RoundedControl -Control $topAccent -Radius (S 3)
    })

    $header = New-Object System.Windows.Forms.Label
    $header.Location = P 40 54
    $header.Size = Z 360 40
    $header.ForeColor = [System.Drawing.Color]::White
    $header.Font = Fnt 'Segoe UI' 20 ([System.Drawing.FontStyle]::Bold)
    $header.Text = 'Preparando instalacao'
    $right.Controls.Add($header)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = P 40 116
    $status.Size = Z 420 34
    $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 245, 245)
    $status.Font = Fnt 'Segoe UI' 15 ([System.Drawing.FontStyle]::Bold)
    $status.Text = 'Iniciando'
    $right.Controls.Add($status)

    $percent = New-Object System.Windows.Forms.Label
    $percent.Location = P 500 96
    $percent.Size = Z 100 62
    $percent.TextAlign = 'MiddleRight'
    $percent.ForeColor = [System.Drawing.Color]::FromArgb(235, 40, 55)
    $percent.Font = Fnt 'Segoe UI' 30 ([System.Drawing.FontStyle]::Bold)
    $percent.Text = '0%'
    $right.Controls.Add($percent)

    $osBadge = New-Object System.Windows.Forms.Panel
    $osBadge.Location = P 430 28
    $osBadge.Size = Z 170 34
    $osBadge.BackColor = [System.Drawing.Color]::FromArgb(32, 11, 14)
    $right.Controls.Add($osBadge)
    $osBadge.Add_Resize({
        Set-RoundedControl -Control $osBadge -Radius (S 17)
    })

    $osLabel = New-Object System.Windows.Forms.Label
    $osLabel.Dock = 'Fill'
    $osLabel.TextAlign = 'MiddleCenter'
    $osLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
    $osLabel.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $osLabel.Text = 'Windows'
    $osBadge.Controls.Add($osLabel)

    $detailCard = New-Object System.Windows.Forms.Panel
    $detailCard.Location = P 40 170
    $detailCard.Size = Z 564 108
    $detailCard.BackColor = [System.Drawing.Color]::FromArgb(22, 22, 26)
    $right.Controls.Add($detailCard)
    $detailCard.Add_Resize({
        Set-RoundedControl -Control $detailCard -Radius (S 18)
    })

    $detail = New-Object System.Windows.Forms.Label
    $detail.Location = P 18 18
    $detail.Size = Z 528 72
    $detail.ForeColor = [System.Drawing.Color]::FromArgb(205, 205, 210)
    $detail.Font = Fnt 'Segoe UI' 10
    $detail.Text = 'Aguardando etapa inicial'
    $detailCard.Controls.Add($detail)

    $barBack = New-Object System.Windows.Forms.Panel
    $barBack.Location = P 40 304
    $barBack.Size = Z 564 28
    $barBack.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 40)
    $right.Controls.Add($barBack)
    $barBack.Add_Resize({
        Set-RoundedControl -Control $barBack -Radius (S 14)
    })

    $barFillGlow = New-Object System.Windows.Forms.Panel
    $barFillGlow.Location = P 0 0
    $barFillGlow.Size = Z 1 28
    $barFillGlow.BackColor = [System.Drawing.Color]::FromArgb(120, 20, 28)
    $barBack.Controls.Add($barFillGlow)

    $barFill = New-Object System.Windows.Forms.Panel
    $barFill.Location = P 0 0
    $barFill.Size = Z 1 28
    $barFill.BackColor = [System.Drawing.Color]::FromArgb(215, 24, 38)
    $barBack.Controls.Add($barFill)

    $barFillGlow.Add_Resize({
        Set-RoundedControl -Control $barFillGlow -Radius (S 14)
    })
    $barFill.Add_Resize({
        Set-RoundedControl -Control $barFill -Radius (S 14)
    })

    $stepsTitle = New-Object System.Windows.Forms.Label
    $stepsTitle.Location = P 40 360
    $stepsTitle.Size = Z 200 24
    $stepsTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 240, 240)
    $stepsTitle.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $stepsTitle.Text = 'Fluxo de instalacao'
    $right.Controls.Add($stepsTitle)

    $step1Dot = New-IndicatorCircle -Text '1' -BackColor ([System.Drawing.Color]::FromArgb(215, 24, 38)) -ForeColor ([System.Drawing.Color]::White) -X 40 -Y 402
    $step2Dot = New-IndicatorCircle -Text '2' -BackColor ([System.Drawing.Color]::FromArgb(55, 55, 60)) -ForeColor ([System.Drawing.Color]::White) -X 40 -Y 444
    $step3Dot = New-IndicatorCircle -Text '3' -BackColor ([System.Drawing.Color]::FromArgb(55, 55, 60)) -ForeColor ([System.Drawing.Color]::White) -X 40 -Y 486
    $step4Dot = New-IndicatorCircle -Text '4' -BackColor ([System.Drawing.Color]::FromArgb(55, 55, 60)) -ForeColor ([System.Drawing.Color]::White) -X 40 -Y 528
    $right.Controls.Add($step1Dot)
    $right.Controls.Add($step2Dot)
    $right.Controls.Add($step3Dot)
    $right.Controls.Add($step4Dot)

    $step1 = New-Object System.Windows.Forms.Label
    $step1.Location = P 80 404
    $step1.Size = Z 480 24
    $step1.ForeColor = [System.Drawing.Color]::White
    $step1.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $step1.Text = 'Validacao da midia'
    $right.Controls.Add($step1)

    $step2 = New-Object System.Windows.Forms.Label
    $step2.Location = P 80 446
    $step2.Size = Z 480 24
    $step2.ForeColor = [System.Drawing.Color]::FromArgb(155, 155, 165)
    $step2.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $step2.Text = 'Preparacao do disco'
    $right.Controls.Add($step2)

    $step3 = New-Object System.Windows.Forms.Label
    $step3.Location = P 80 488
    $step3.Size = Z 480 24
    $step3.ForeColor = [System.Drawing.Color]::FromArgb(155, 155, 165)
    $step3.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $step3.Text = 'Aplicacao da imagem'
    $right.Controls.Add($step3)

    $step4 = New-Object System.Windows.Forms.Label
    $step4.Location = P 80 530
    $step4.Size = Z 480 24
    $step4.ForeColor = [System.Drawing.Color]::FromArgb(155, 155, 165)
    $step4.Font = Fnt 'Segoe UI' 10 ([System.Drawing.FontStyle]::Bold)
    $step4.Text = 'Boot e finalizacao'
    $right.Controls.Add($step4)

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

    $inactiveText = [System.Drawing.Color]::FromArgb(155, 155, 165)
    $activeText = [System.Drawing.Color]::White
    $doneBack = [System.Drawing.Color]::FromArgb(130, 18, 28)
    $activeBack = [System.Drawing.Color]::FromArgb(215, 24, 38)
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

        Set-RoundedControl -Control $dot -Radius (S 14)
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

    $Ui.Status.Text = $Status
    $Ui.Detail.Text = $Detail
    $Ui.Percent.Text = "$Percent%"

    $maxWidth = $Ui.BarBack.Width
    $newWidth = [math]::Max(1, [math]::Round(($maxWidth * $Percent) / 100))
    $glowWidth = [math]::Min($maxWidth, $newWidth + (S 12))

    $Ui.BarFillGlow.Width = $glowWidth
    $Ui.BarFill.Width = $newWidth

    Set-RoundedControl -Control $Ui.BarFillGlow -Radius (S 14)
    Set-RoundedControl -Control $Ui.BarFill -Radius (S 14)

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

    $source = Join-Path $InstallRoot 'SetupComplete.cmd'
    if (-not (Test-Path $source)) { return }

    $destDir = "$WindowsDrive\Windows\Setup\Scripts"
    if (-not (Test-Path $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $source -Destination (Join-Path $destDir 'SetupComplete.cmd') -Force
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
    param([bool]$IsUefi)

    if (-not $IsUefi) { return }

    try {
        $entries = Get-FirmwareBootEntries
        $candidate = $entries | Where-Object {
            $_.Description -match 'Windows Boot Manager' -or
            $_.Description -match 'SSD' -or
            $_.Description -match 'NVMe' -or
            $_.Description -match 'Hard Drive'
        } | Where-Object {
            $_.Description -notmatch 'USB|UEFI: USB|Removable|Pendrive'
        } | Select-Object -First 1

        if ($candidate -and $candidate.Identifier) {
            bcdedit /set '{fwbootmgr}' bootsequence $candidate.Identifier | Out-Null
        }
    } catch {}
}

function Test-ExistingAppliedWindows {
    param([int]$DiskNumber)

    $parts = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    foreach ($part in $parts) {
        try {
            if (-not $part.DriveLetter) { continue }
            $drive = "$($part.DriveLetter):"
            if (Test-Path "$drive\Windows\System32\winload.efi" -or Test-Path "$drive\Windows\System32\winload.exe") {
                return $drive
            }
        } catch {}
    }
    return $null
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

$existingWindows = Test-ExistingAppliedWindows -DiskNumber $targetDisk.Number
if ($existingWindows) {
    Update-Ui -Ui $script:Ui -Percent 96 -Status 'Windows ja aplicado' -Detail "Foi encontrada uma instalacao em $existingWindows. Reiniciando pelo disco interno." -Step 4
    Set-NextBootToInternalWindows -IsUefi $isUefi
    Start-Sleep -Seconds 5
    wpeutil reboot
    exit 0
}

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
Set-NextBootToInternalWindows -IsUefi $isUefi

Update-Ui -Ui $script:Ui -Percent 100 -Status 'Instalacao concluida' -Detail 'O computador sera reiniciado para continuar no disco interno.' -Step 4
Start-Sleep -Seconds 4
wpeutil reboot
exit 0