# =============================================================================
# INSTALADOR WINDOWS NO WINPE - INTERFACE, APLICACAO OFFLINE E PRIMEIRO BOOT
# =============================================================================
# Este e o ponto de entrada PowerShell chamado pela midia de instalacao.
# Fluxo: localizar Win10/Win11 -> validar hardware e destino -> escolher Windows
# pelo TPM 2.0 -> particionar -> aplicar imagem -> copiar scripts -> criar boot.
# As funcoes abaixo sao declaradas primeiro; o fluxo automatico fica na secao 8.
# Os comandos de limpeza/formatacao existem apenas nas rotinas Prepare-Disk* e
# so sao chamados depois da selecao e revalidacao do disco pelo fluxo principal.
# Os caminhos WindowsDrive sao temporarios do WinPE (ex.: W:); no primeiro
# boot o Windows assume suas proprias letras, por isso o registro usa C:\Windows.
# Erros principais usam Stop-WithError. Personalizacao e detalhes secundarios
# usam catch de melhor esforco para preservar o fluxo de instalacao.

# Windows Forms/Drawing compoem a interface; NativeMethods importa duas APIs
# nativas apenas para esconder o console enquanto a janela grafica aparece.
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

# =============================================================================
# 1. APOIO NATIVO E ESCALA DA INTERFACE
# =============================================================================

<#
.SYNOPSIS
    Oculta a janela de console que hospedou o PowerShell do instalador.
.DESCRIPTION
    A chamada nativa usa o identificador da propria janela; falhas visuais sao ignoradas.
#>
function Hide-ConsoleWindow {
    try {
        $hWnd = [NativeMethods]::GetConsoleWindow()
        if ($hWnd -ne [IntPtr]::Zero) {
            [NativeMethods]::ShowWindow($hWnd, 0) | Out-Null
        }
    } catch {}
}

<#
.SYNOPSIS
    Calcula a escala visual a partir da tela principal.
.DESCRIPTION
    Usa a area de trabalho efetiva do WinPE, que pode ser menor sem driver de video.
    Janela compacta baseada em 1040x620, com margem para revelar o wallpaper. Fontes
    pequenas continuam legiveis; cards e linhas medem sua altura pela fonte real.
#>
function Get-DisplayScale {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea


    # A janela base mede 1040x620. Reserva margem sem forcar uma escala minima
    # que poderia fazer a janela ultrapassar a tela em modos de video reduzidos.
    $fitScale = [math]::Min([math]::Max(1, $bounds.Width - 16) / 1040, [math]::Max(1, $bounds.Height - 16) / 620)
    # Prefere cerca de 80% da tela e limita o crescimento em Full HD/QHD.
    # Em video basico, usa o espaco necessario para preservar a legibilidade.
    $preferredScale = [math]::Min(($bounds.Width * 0.80) / 1040, ($bounds.Height * 0.82) / 620)
    $scale = [math]::Min($fitScale, [math]::Max(0.8, [math]::Min(1.1, $preferredScale)))

    return [pscustomobject]@{
        Scale = $scale
        ScreenWidth = $bounds.Width
        ScreenHeight = $bounds.Height
    }
}

<#
.SYNOPSIS
    Converte uma medida do layout base em pixels da tela atual.
.PARAMETER Value
    Medida original multiplicada pela escala compartilhada em script:Display.
#>
function S {
    param([double]$Value)
    return [int][math]::Round($Value * $script:Display.Scale)
}

<#
.SYNOPSIS
    Cria uma posicao com coordenadas ajustadas pela escala.
.PARAMETER X
    Coordenada horizontal no layout base.
.PARAMETER Y
    Coordenada vertical no layout base.
#>
function P {
    param([double]$X, [double]$Y)
    return New-Object System.Drawing.Point((S $X), (S $Y))
}

<#
.SYNOPSIS
    Cria um tamanho com largura e altura ajustadas pela escala.
.PARAMETER W
    Largura no layout base.
.PARAMETER H
    Altura no layout base.
#>
function Z {
    param([double]$W, [double]$H)
    return New-Object System.Drawing.Size((S $W), (S $H))
}

<#
.SYNOPSIS
    Cria uma fonte proporcional a tela, com tamanho minimo de sete pontos.
.PARAMETER Name
    Familia de fonte, por exemplo Segoe UI.
.PARAMETER Size
    Tamanho da fonte antes da escala.
.PARAMETER Style
    Estilo da fonte; Regular e o padrao.
#>
function Fnt {
    param(
        [string]$Name,
        [double]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    return New-Object System.Drawing.Font($Name, ([math]::Max(7, ($Size * $script:Display.Scale))), $Style)
}

<#
.SYNOPSIS
    Cria o contorno grafico de um retangulo com quatro cantos arredondados.
.PARAMETER Width
    Largura total do contorno em pixels.
.PARAMETER Height
    Altura total do contorno em pixels.
.PARAMETER Radius
    Raio dos cantos; valores abaixo de um sao ajustados para um.
#>
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

<#
.SYNOPSIS
    Aplica uma regiao arredondada a um controle que ja tem tamanho definido.
.PARAMETER Control
    Controle Windows Forms que recebera o recorte visual.
.PARAMETER Radius
    Raio dos cantos, em pixels ja ajustados pela escala.
#>
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

# =============================================================================
# 2. LOCALIZACAO DA MIDIA E IDENTIDADE VISUAL
# =============================================================================

<#
.SYNOPSIS
    Localiza a raiz da midia que contem as duas pastas Win10 e Win11.
.DESCRIPTION
    Tenta o caminho obtido da invocacao e depois percorre as letras de C a Z.
    Retorna null quando nenhuma raiz atende ao criterio.
#>
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

<#
.SYNOPSIS
    Cria a janela de fundo com a imagem da midia, atras do instalador.
.DESCRIPTION
    Retorna formulario, imagem e sobreposicao; retorna null se a preparacao falhar.
.PARAMETER InstallRoot
    Raiz da midia, usada para buscar Branding e os caminhos alternativos.
#>
function New-BackgroundForm {
    param([string]$InstallRoot)

    try {
        $bgPath = Join-Path $InstallRoot 'Script\Branding\winpe-pichau-red.png'
        if (-not (Test-Path $bgPath)) { $bgPath = Join-Path $InstallRoot 'Script\Instalador\winpe-wallpaper.jpg' }
        if (-not (Test-Path $bgPath)) { $bgPath = Join-Path $InstallRoot 'Script\winpe-wallpaper.jpg' }

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
        $overlay.BackColor = [System.Drawing.Color]::FromArgb(48, 0, 0, 0)
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

<#
.SYNOPSIS
    Copia as imagens de marca para o Windows offline e prepara o perfil padrao.
.DESCRIPTION
    Atualiza wallpapers, tela de bloqueio e hives offline SOFTWARE/NTUSER.DAT.
    As operacoes de branding ficam em melhor esforco e nao interrompem a instalacao.
.PARAMETER InstallRoot
    Raiz da midia com os arquivos em Script\Branding ou caminhos alternativos.
.PARAMETER WindowsDrive
    Unidade do Windows aplicado, incluindo dois-pontos, por exemplo W:.
#>
function Apply-InstalledBranding {
    param(
        [string]$InstallRoot,
        [string]$WindowsDrive
    )

    try {
        $scriptDir = Join-Path $InstallRoot 'Script'
        # Prioriza Branding e aceita a disposicao antiga como alternativa.
        $wallpaperSource = Join-Path $scriptDir 'Branding\wallpaper.jpg'
        $lockscreenSource = Join-Path $scriptDir 'Branding\lockscreen.jpg'
        if (-not (Test-Path $wallpaperSource)) { $wallpaperSource = Join-Path $scriptDir 'wallpaper.jpg' }
        if (-not (Test-Path $lockscreenSource)) { $lockscreenSource = Join-Path $scriptDir 'lockscreen.jpg' }

        # Mantem copias personalizadas e atualiza as imagens padrao offline.
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

        # Carrega o SOFTWARE do Windows de destino, remove politicas que fixavam
        # as imagens e descarrega o hive; o registro do WinPE nao e o alvo.
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

        # O perfil Default fornece as configuracoes iniciais aos novos usuarios.
        # A imagem e configurada diretamente, sem RunOnce para script externo.
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


            reg unload HKU\DEFUSER | Out-Null
        }
    } catch {}
}


# =============================================================================
# 3. CONSTRUCAO E ATUALIZACAO DO FORMULARIO
# =============================================================================

<#
.SYNOPSIS
    Monta o indicador numerado de uma etapa do fluxo.
.DESCRIPTION
    Retorna um Panel com Label centralizado e regiao arredondada.
.PARAMETER Text
    Numero ou texto mostrado no centro do indicador.
.PARAMETER BackColor
    Cor do fundo do painel.
.PARAMETER ForeColor
    Cor do texto.
.PARAMETER X
    Posicao horizontal no layout base.
.PARAMETER Y
    Posicao vertical no layout base.
#>
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
    $panel.BorderStyle = 'FixedSingle'

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = $ForeColor
    $label.Font = Fnt 'Segoe UI' 9 ([System.Drawing.FontStyle]::Bold)
    $label.Text = $Text
    $panel.Controls.Add($label)
    Set-RoundedControl -Control $panel -Radius (S 14)

    return $panel
}

<#
.SYNOPSIS
    Monta a janela principal e devolve referencias aos controles atualizados depois.
.DESCRIPTION
    O hardware ocupa uma grade central de seis cards; abaixo ficam status, percentual,
    uma unica barra de progresso, detalhes e quatro etapas na horizontal.
.PARAMETER InstallRoot
    Raiz da midia para localizar a logo e suas alternativas.
#>
function New-InstallerUi {
    param([string]$InstallRoot)

    # Tela compacta: cabecalho, progresso no topo, hardware central em grade
    # e quatro etapas abaixo. Margens revelam o wallpaper, sem barra textual do DISM.
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Pichau Windows Setup'
    $form.StartPosition = 'Manual'
    $form.FormBorderStyle = 'None'
    $form.AutoScaleMode = 'None'
    $form.BackColor = [System.Drawing.Color]::FromArgb(14, 17, 24)
    $form.Size = Z 1040 620
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($screenBounds.Left + [int](($screenBounds.Width - $form.Width) / 2)), ($screenBounds.Top + [int](($screenBounds.Height - $form.Height) / 2)))

    # Alturas de texto usam a fonte real; em baixa resolucao nao ha rolagem.
    function New-SetupText {
        param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [double]$FontSize = 9, [bool]$Bold = $false)
        $label = New-Object System.Windows.Forms.Label
        $label.Location = P $X $Y
        $label.Size = Z $Width $Height
        $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $label.Font = Fnt 'Segoe UI' $FontSize $style
        $label.Height = [math]::Max($label.Height, $label.Font.Height + 3)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(231, 234, 241)
        $label.AutoEllipsis = $true
        $label.UseMnemonic = $false
        $Parent.Controls.Add($label)
        $label.Text = $Text
        return $label
    }
    $accent = New-Object System.Windows.Forms.Panel
    $accent.BackColor = [System.Drawing.Color]::FromArgb(237, 43, 65)
    $accent.Location = P 0 0
    $accent.Size = Z 1040 4
    $form.Controls.Add($accent)

    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Location = P 28 22
    $logoBox.Size = Z 54 54
    $logoBox.SizeMode = 'Zoom'
    foreach ($relative in @('Script\Branding\logo-pichau.png','Script\Branding\logo.png','Script\logo.png','Script\logo.jpg')) {
        $logoPath = Join-Path $InstallRoot $relative
        if (Test-Path -LiteralPath $logoPath) { $logoBox.Image = [System.Drawing.Image]::FromFile($logoPath); break }
    }
    $form.Controls.Add($logoBox)
    $brand = New-SetupText $form 'PICHAU DUALBOOT' 96 22 640 32 20 $true
    $subtitle = New-SetupText $form 'FEITO POR ADNEY CORREA' 98 59 640 20 8
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(138, 148, 168)
    $osBadge = New-Object System.Windows.Forms.Panel
    $osBadge.Location = P 824 28
    $osBadge.Size = Z 188 38
    $osBadge.BackColor = [System.Drawing.Color]::FromArgb(41, 22, 27)
    $form.Controls.Add($osBadge)
    $osLabel = New-SetupText $osBadge 'WINDOWS' 0 0 188 38 10 $true
    $osLabel.Dock = 'Fill'
    $osLabel.TextAlign = 'MiddleCenter'
    Set-RoundedControl -Control $osBadge -Radius (S 10)

    $equipmentTitle = New-SetupText $form 'EQUIPAMENTO IDENTIFICADO' 28 92 700 20 8 $true
    $equipmentTitle.ForeColor = [System.Drawing.Color]::FromArgb(146, 157, 180)
    $hardwareTooltip = New-Object System.Windows.Forms.ToolTip
    $hardwareTooltip.AutoPopDelay = 20000
    $hardwareRows = @{}
    $hardwareIcons = @{}
    $iconPaint = {
        param($sender, $paintArgs)
        $graphics = $paintArgs.Graphics
        $saved = $graphics.Save()
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 112, 118), 1.2)
        try {
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.ScaleTransform([single]($sender.Width / 18.0), [single]($sender.Height / 18.0))
            switch ([string]$sender.Tag) {
                'CPU' {
                    $graphics.DrawRectangle($pen, 5, 5, 8, 8)
                    $graphics.DrawRectangle($pen, 7, 7, 4, 4)
                    foreach ($pin in @(6, 9, 12)) {
                        $graphics.DrawLine($pen, $pin, 2, $pin, 5); $graphics.DrawLine($pen, $pin, 13, $pin, 16)
                        $graphics.DrawLine($pen, 2, $pin, 5, $pin); $graphics.DrawLine($pen, 13, $pin, 16, $pin)
                    }
                }
                'RAM' {
                    $graphics.DrawRectangle($pen, 2, 5, 14, 7)
                    foreach ($chip in @(4, 8, 12)) { $graphics.DrawRectangle($pen, $chip, 7, 2, 3) }
                    foreach ($pin in @(3, 6, 9, 12, 15)) { $graphics.DrawLine($pen, $pin, 12, $pin, 15) }
                }
                'GPU' {
                    $graphics.DrawRectangle($pen, 3, 4, 13, 9)
                    $graphics.DrawEllipse($pen, 5, 6, 5, 5); $graphics.DrawEllipse($pen, 11, 7, 3, 3)
                    $graphics.DrawLine($pen, 1, 3, 1, 15); $graphics.DrawLine($pen, 5, 15, 12, 15)
                }
                'PLACA' {
                    $graphics.DrawRectangle($pen, 3, 2, 12, 14)
                    $graphics.DrawRectangle($pen, 5, 5, 5, 5)
                    $graphics.DrawLine($pen, 12, 4, 12, 11); $graphics.DrawLine($pen, 5, 13, 12, 13)
                }
                'DISCO' {
                    $graphics.DrawRectangle($pen, 3, 2, 12, 14)
                    $graphics.DrawEllipse($pen, 5, 4, 8, 8)
                    $graphics.DrawLine($pen, 9, 8, 13, 13)
                }
            }
        } finally { $pen.Dispose(); $graphics.Restore($saved) }
    }
    # Seis cards distribuem o hardware em toda a largura. O nome comercial da GPU
    # permanece integral nos dados/tooltip, com reticencias apenas no texto visivel.
    $tileKeys = @('CPU','RAM','GPU','PLACA','DISCO','EQUIPAMENTO')
    $tiles = @()
    $tileGap = [math]::Max(5, (S 10))
    $margin = S 28
    $tileWidth = [int][math]::Floor(($form.ClientSize.Width - 2 * $margin - 2 * $tileGap) / 3)
    $tileTop = [math]::Max((S 120), $equipmentTitle.Bottom + (S 8))
    $tileHeight = 0
    foreach ($key in $tileKeys) {
        $tile = New-Object System.Windows.Forms.Panel
        $tile.BackColor = [System.Drawing.Color]::FromArgb(24, 30, 41)
        $tile.Width = $tileWidth
        $caption = New-SetupText $tile $key 14 8 270 16 7 $true
        $caption.ForeColor = [System.Drawing.Color]::FromArgb(139, 151, 173)
        $caption.Width = $tileWidth - (S 28)
        $value = New-SetupText $tile 'Detectando...' 14 30 270 25 9 $true
        $value.Top = $caption.Bottom + 1
        $value.Width = $caption.Width
        $tile.Height = [math]::Max((S 66), $value.Bottom + [math]::Max(4, (S 8)))
        if ($key -ne 'EQUIPAMENTO') {
            $icon = New-Object System.Windows.Forms.PictureBox
            $icon.Tag = $key
            $iconSide = [math]::Max(12, (S 16))
            $icon.Size = New-Object System.Drawing.Size($iconSide, $iconSide)
            $icon.Location = New-Object System.Drawing.Point((S 14), $caption.Top)
            $icon.Add_Paint($iconPaint)
            $tile.Controls.Add($icon)
            $caption.Left = $icon.Right + 4
            $caption.Width = $tileWidth - $caption.Left - (S 12)
            $hardwareIcons[$key] = $icon
        }
        $hardwareRows[$key] = $value
        $form.Controls.Add($tile)
        $tiles += $tile
        $tileHeight = [math]::Max($tileHeight, $tile.Height)
    }
    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $tiles[$i].Location = New-Object System.Drawing.Point(($margin + ($i % 3) * ($tileWidth + $tileGap)), ($tileTop + [int][math]::Floor($i / 3) * ($tileHeight + $tileGap)))
        $tiles[$i].Height = $tileHeight
        Set-RoundedControl -Control $tiles[$i] -Radius (S 9)
    }

    # Uma unica barra representa o progresso global; percentual ao lado do titulo.
    $progress = New-Object System.Windows.Forms.Panel
    $progress.Location = New-Object System.Drawing.Point($margin, ($tiles[5].Bottom + (S 12)))
    $progress.Width = $form.ClientSize.Width - 2 * $margin
    $progress.BackColor = [System.Drawing.Color]::FromArgb(19, 24, 34)
    $form.Controls.Add($progress)
    $header = New-SetupText $progress 'PREPARANDO INSTALACAO' 18 14 760 28 17 $true
    $percent = New-SetupText $progress '0%' 824 10 140 40 25 $true
    $percent.ForeColor = [System.Drawing.Color]::FromArgb(255, 67, 87)
    $percent.TextAlign = 'MiddleRight'
    $percent.Left = $progress.Width - $percent.Width - (S 18)
    $header.Width = $percent.Left - $header.Left - (S 14)
    $status = New-SetupText $progress 'Iniciando' 18 48 940 22 9
    $status.Top = [math]::Max($header.Bottom, $percent.Bottom) + (S 3)
    $status.Width = $progress.Width - (S 36)
    $status.ForeColor = [System.Drawing.Color]::FromArgb(173, 184, 204)
    $barBack = New-Object System.Windows.Forms.Panel
    $barBack.Location = New-Object System.Drawing.Point((S 18), ($status.Bottom + (S 12)))
    $barBack.Size = New-Object System.Drawing.Size(($progress.Width - (S 36)), ([math]::Max(6, (S 10))))
    $barBack.BackColor = [System.Drawing.Color]::FromArgb(43, 51, 67)
    $progress.Controls.Add($barBack)
    $barFillGlow = New-Object System.Windows.Forms.Panel
    $barFillGlow.Size = New-Object System.Drawing.Size(1, $barBack.Height)
    $barFillGlow.BackColor = [System.Drawing.Color]::FromArgb(156, 39, 57)
    $barBack.Controls.Add($barFillGlow)
    $barFill = New-Object System.Windows.Forms.Panel
    $barFill.Size = New-Object System.Drawing.Size(1, $barBack.Height)
    $barFill.BackColor = [System.Drawing.Color]::FromArgb(240, 45, 68)
    $barBack.Controls.Add($barFill)
    $detail = New-SetupText $progress 'Validando a midia de instalacao.' 18 108 940 42 8
    $detail.Top = $barBack.Bottom + (S 10)
    $detail.Width = $barBack.Width
    $detail.Height = [math]::Max((S 42), 2 * $detail.Font.Height + 2)
    $detail.ForeColor = [System.Drawing.Color]::FromArgb(138, 150, 173)
    $progress.Height = $detail.Bottom + (S 12)
    Set-RoundedControl -Control $progress -Radius (S 10)

    # Ordem visual: progresso logo abaixo do cabecalho; hardware no meio da janela.
    # Reposiciona pelos limites reais dos controles para preservar o ajuste em baixa resolucao.
    $progress.Top = $equipmentTitle.Top
    $equipmentTitle.Top = $progress.Bottom + (S 12)
    $tileTop = $equipmentTitle.Bottom + (S 8)
    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $tiles[$i].Top = $tileTop + [int][math]::Floor($i / 3) * ($tileHeight + $tileGap)
    }

    # Quatro etapas na horizontal, sem repetir o bloco principal de andamento.
    $stepLabels = @(); $stepDots = @(); $stepCards = @()
    $stepGap = [math]::Max(4, (S 8))
    $stepWidth = [int][math]::Floor(($progress.Width - 3 * $stepGap) / 4)
    $stepNames = @("VALIDACAO`r`nDA MIDIA", "PREPARACAO`r`nDO DISCO", "APLICACAO`r`nDO WINDOWS", "BOOT E`r`nFINALIZACAO")
    for ($i = 0; $i -lt 4; $i++) {
        $stepCard = New-Object System.Windows.Forms.Panel
        $stepCard.Location = New-Object System.Drawing.Point(($margin + $i * ($stepWidth + $stepGap)), ($tiles[5].Bottom + (S 12)))
        $stepCard.Width = $stepWidth
        $stepCard.BackColor = [System.Drawing.Color]::FromArgb(24, 30, 41)
        $form.Controls.Add($stepCard)
        $dot = New-IndicatorCircle -Text ([string]($i + 1)) -BackColor ([System.Drawing.Color]::FromArgb(55,55,60)) -ForeColor ([System.Drawing.Color]::White) -X 12 -Y 14
        $dot.Size = New-Object System.Drawing.Size(([math]::Max(19,(S 28))), ([math]::Max(19,(S 28))))
        Set-RoundedControl -Control $dot -Radius ([int]($dot.Width / 2))
        $stepCard.Controls.Add($dot)
        $stepLabel = New-SetupText $stepCard $stepNames[$i] 52 10 180 42 8 $true
        $stepLabel.Left = $dot.Right + [math]::Max(4,(S 8))
        $stepLabel.Width = $stepWidth - $stepLabel.Left - (S 8)
        $stepLabel.Height = [math]::Max((S 42), 2 * $stepLabel.Font.Height + 2)
        $stepCard.Height = [math]::Max($dot.Bottom, $stepLabel.Bottom) + (S 10)
        Set-RoundedControl -Control $stepCard -Radius (S 8)
        $stepLabels += $stepLabel; $stepDots += $dot; $stepCards += $stepCard
    }
    $safety = New-SetupText $form 'ATENCAO: todos os dados do disco de destino serao apagados.' 28 564 984 22 8
    $safety.Top = $stepCards[0].Bottom + (S 10)
    $safety.ForeColor = [System.Drawing.Color]::FromArgb(237, 169, 91)
    $safety.TextAlign = 'MiddleCenter'
    $footer = New-SetupText $form 'DUALBOOT  /  Adney Correa' 28 592 984 18 7
    $footer.Top = $safety.Bottom + (S 4)
    $footer.ForeColor = [System.Drawing.Color]::FromArgb(93, 106, 128)
    $footer.TextAlign = 'MiddleCenter'

    return [pscustomobject]@{
        Form = $form; Header = $header; Status = $status; Detail = $detail; Percent = $percent
        BarBack = $barBack; BarFill = $barFill; BarFillGlow = $barFillGlow
        Step1 = $stepLabels[0]; Step2 = $stepLabels[1]; Step3 = $stepLabels[2]; Step4 = $stepLabels[3]
        Step1Dot = $stepDots[0]; Step2Dot = $stepDots[1]; Step3Dot = $stepDots[2]; Step4Dot = $stepDots[3]
        OsBadge = $osBadge; OsLabel = $osLabel; MachineInfo = $hardwareRows['EQUIPAMENTO']
        HardwareInfo = $hardwareRows['CPU']; RamInfo = $hardwareRows['RAM']; GpuInfo = $hardwareRows['GPU']
        BoardInfo = $hardwareRows['PLACA']; DiskInfo = $hardwareRows['DISCO']
        HardwareTooltip = $hardwareTooltip; HardwareIcons = $hardwareIcons
        HardwareCards = $tiles; ProgressCard = $progress; StepCards = $stepCards; SafetyInfo = $safety; Footer = $footer
    }
}

<#
.SYNOPSIS
    Destaca a etapa atual e diferencia etapas concluidas e futuras.
.PARAMETER Ui
    Objeto de controles retornado por New-InstallerUi.
.PARAMETER ActiveStep
    Numero de 1 a 4 correspondente a etapa atual.
#>
function Set-StepVisual {
    param(
        $Ui,
        [int]$ActiveStep
    )

    $inactiveText = [System.Drawing.Color]::FromArgb(165, 165, 176)
    $activeText = [System.Drawing.Color]::White
    $doneBack = [System.Drawing.Color]::FromArgb(123, 35, 46)
    $activeBack = [System.Drawing.Color]::FromArgb(232, 35, 52)
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

<#
.SYNOPSIS
    Atualiza textos, percentual, barra e etapa, processando os eventos da janela.
.PARAMETER Ui
    Objeto de controles da interface principal.
.PARAMETER Percent
    Progresso global, limitado ao intervalo de zero a cem.
.PARAMETER Status
    Nome curto da operacao atual, mostrado em maiusculas.
.PARAMETER Detail
    Descricao detalhada da operacao ou da mensagem recebida do DISM.
.PARAMETER Step
    Etapa do fluxo de 1 a 4; o padrao e a validacao inicial.
#>
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

    # O cabecalho acompanha a etapa numerica; o conteudo de erro e preservado.
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
    # O DISM fornece uma barra ASCII e percentual local; manter apenas o progresso
    # global na tela para nao apresentar dois indicadores concorrentes.
    if ($Step -eq 3 -and $Detail -match '(?m)^\s*\[[=\s.>\-]*\d+(?:[.,]\d+)?%[=\s.>\-]*\]\s*$') {
        $Detail = 'Transferindo os arquivos do Windows para o disco. Aguarde a conclusao.'
    }
    $Ui.Detail.Text = $Detail
    $Ui.Percent.Text = "$Percent%"

    # Converte o percentual em pixels, mantendo preenchimento minimo e sem
    # ultrapassar a barra; o brilho avanca alguns pixels a frente.
    $maxWidth = [math]::Max(1, $Ui.BarBack.Width)
    $rawWidth = [math]::Round(($maxWidth * $Percent) / 100)
    $newWidth = [math]::Max(1, [int]$rawWidth)
    if ($newWidth -gt $maxWidth) { $newWidth = $maxWidth }
    $glowWidth = [math]::Min($maxWidth, $newWidth + (S 8))

    $Ui.BarFillGlow.Width = $glowWidth
    $Ui.BarFill.Width = $newWidth
    if ($Ui.BarBack.Width -gt 0) { Set-RoundedControl -Control $Ui.BarBack -Radius (S 8) }
    if ($newWidth -ge (S 16)) { Set-RoundedControl -Control $Ui.BarFill -Radius (S 8) }

    Set-StepVisual -Ui $Ui -ActiveStep $Step
    [System.Windows.Forms.Application]::DoEvents()
}

# =============================================================================
# 4. VALIDACAO DA MIDIA E INFORMACOES DE HARDWARE
# =============================================================================

<#
.SYNOPSIS
    Mostra uma falha, aguarda a leitura e reinicia o ambiente WinPE.
.DESCRIPTION
    Quando a janela ja existe, ha tambem uma espera visual de oito segundos.
    Esta e uma rotina de encerramento do instalador, nao apenas de notificacao.
.PARAMETER Message
    Descricao do erro ou bloqueio que sera apresentada na interface.
.PARAMETER Seconds
    Espera adicional antes do reinicio; o padrao e 12 segundos.
.PARAMETER ExitCode
    Codigo usado ao sair do script depois da chamada ao reboot; padrao 1.
#>
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

<#
.SYNOPSIS
    Encontra a primeira letra preferida que ainda nao existe como unidade.
.DESCRIPTION
    Retorna null se todas as candidatas estiverem ocupadas.
.PARAMETER PreferredLetters
    Lista ordenada de letras candidatas, informadas sem dois-pontos.
#>
function Get-FreeDriveLetter {
    param([string[]]$PreferredLetters = @('W','V','U','T','S','R','Q','P','O','N','M'))

    $used = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
    foreach ($letter in $PreferredLetters) {
        if ($used -notcontains $letter) { return $letter }
    }
    return $null
}

<#
.SYNOPSIS
    Busca a imagem de instalacao, dando preferencia a WIM antes de ESD.
.DESCRIPTION
    Retorna o caminho de install.wim/install.esd ou null se nenhum existir.
.PARAMETER BasePath
    Pasta Win10 ou Win11 que contem a subpasta sources.
#>
function Get-ImageFile {
    param([string]$BasePath)
    $wim = Join-Path $BasePath 'sources\install.wim'
    $esd = Join-Path $BasePath 'sources\install.esd'
    if (Test-Path $wim) { return $wim }
    if (Test-Path $esd) { return $esd }
    return $null
}

<#
.SYNOPSIS
    Confirma se a base selecionada oferece uma imagem WIM ou ESD.
.PARAMETER BasePath
    Pasta do sistema operacional a ser validada.
#>
function Test-BaseFiles {
    param([string]$BasePath)
    return [bool](Get-ImageFile -BasePath $BasePath)
}

<#
.SYNOPSIS
    Confirma TPM 2.0 pela versao de especificacao informada pelo Windows.
.DESCRIPTION
    Tenta primeiro Win32_Tpm via CIM e depois Get-Tpm, quando disponivel.
    TPM apenas presente, sem versao 2.0 comprovada, nao basta para retornar true.
#>
function Get-Tpm20Present {
    try {
        $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
        if ($null -ne $tpm) {
            $specVersion = [string]$tpm.SpecVersion
            if ($specVersion -match '(^|,)\s*2\.0(\s|,|$)') { return $true }
        }
    } catch {}

    try {
        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            $tpm2 = Get-Tpm
            if ($null -ne $tpm2 -and $tpm2.TpmPresent) {
                $specVersion = ''
                if ($tpm2.PSObject.Properties.Name -contains 'SpecVersion') {
                    $specVersion = [string]$tpm2.SpecVersion
                }
                if ($specVersion -and $specVersion -match '(^|,)\s*2\.0(\s|,|$)') { return $true }
            }
        }
    } catch {}

    return $false
}

# =============================================================================
# 5. SELECAO DO DESTINO E BLOQUEIOS DE DISCO
# =============================================================================

<#
.SYNOPSIS
    Normaliza identificadores para comparar nomes, rotulos e seriais de disco.
.PARAMETER Value
    Texto ou outro valor convertido para maiusculas, mantendo somente letras e numeros.
#>
function Normalize-DiskGuardText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return (([string]$Value).ToUpperInvariant() -replace '[^A-Z0-9]', '')
}

<#
.SYNOPSIS
    Reune nomes, seriais e rotulos de um disco por fontes independentes.
.DESCRIPTION
    Retorna listas sem duplicacoes; falhas parciais nao impedem consultar as demais fontes.
.PARAMETER DiskNumber
    Numero fisico do disco consultado por Get-Disk, CIM e particoes/volumes.
#>
function Get-BenchmarkDiskGuardInfo {
    param([int]$DiskNumber)

    $names = @()
    $serials = @()
    $labels = @()

    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        $names += [string]$disk.FriendlyName
        $serials += [string]$disk.SerialNumber
    } catch {}

    try {
        Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object {
            $_.Index -eq $DiskNumber
        } | ForEach-Object {
            $names += [string]$_.Model
            $names += [string]$_.Caption
            $serials += [string]$_.SerialNumber
        }
    } catch {}

    try {
        Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
            Get-Volume -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.FileSystemLabel) { $labels += [string]$_.FileSystemLabel }
            }
    } catch {}

    return [pscustomobject]@{
        Names = @($names | Where-Object { $_ } | Select-Object -Unique)
        Serials = @($serials | Where-Object { $_ } | Select-Object -Unique)
        Labels = @($labels | Where-Object { $_ } | Select-Object -Unique)
    }
}

<#
.SYNOPSIS
    Identifica o SSD de teste que nunca pode ser usado como destino.
.DESCRIPTION
    Compara o nome/rotulo BENCHMARK e o serial configurado. Devolve Protected,
    Reason e as evidencias coletadas para as mensagens dos bloqueios.
.PARAMETER Disk
    Objeto de Get-Disk, usado como fonte adicional de numero, nome e serial.
.PARAMETER DiskNumber
    Numero fisico explicito; -1 permite obte-lo a partir do objeto Disk.
#>
function Test-BenchmarkProtectedDisk {
    param(
        $Disk,
        [int]$DiskNumber = -1
    )

    if ($DiskNumber -lt 0 -and $Disk) {
        try { $DiskNumber = [int]$Disk.Number } catch {}
    }

    # Cruza fontes para proteger o SSD mesmo quando o modelo ou serial aparecem
    # em campos diferentes no WinPE.
    $info = Get-BenchmarkDiskGuardInfo -DiskNumber $DiskNumber

    if ($Disk) {
        try { $info.Names += [string]$Disk.FriendlyName } catch {}
        try { $info.Serials += [string]$Disk.SerialNumber } catch {}
    }

    # Identificadores protegidos: usados na selecao e na revalidacao do destino.
    $protectedSerial = Normalize-DiskGuardText 'MRF1OE217t1096'
    $protectedName = Normalize-DiskGuardText 'BENCHMARK'

    $nameHits = @($info.Names + $info.Labels | ForEach-Object { Normalize-DiskGuardText $_ } | Where-Object { $_ })
    $serialHits = @($info.Serials | ForEach-Object { Normalize-DiskGuardText $_ } | Where-Object { $_ })

    $hasProtectedName = @($nameHits | Where-Object { $_ -eq $protectedName -or $_ -like "*$protectedName*" }).Count -gt 0
    $hasProtectedSerial = @($serialHits | Where-Object { $_ -eq $protectedSerial }).Count -gt 0

    $reason = ''
    if ($hasProtectedName) { $reason = 'nome/label BENCHMARK' }
    if ($hasProtectedSerial) {
        if ($reason) { $reason += ' + ' }
        $reason += 'serial MRF1OE217t1096'
    }

    return [pscustomobject]@{
        Protected = ($hasProtectedName -or $hasProtectedSerial)
        Reason = $reason
        Names = @($info.Names | Select-Object -Unique)
        Serials = @($info.Serials | Select-Object -Unique)
        Labels = @($info.Labels | Select-Object -Unique)
    }
}

<#
.SYNOPSIS
    Interrompe a instalacao se o numero informado corresponder ao SSD protegido.
.PARAMETER DiskNumber
    Numero fisico do destino a conferir novamente.
#>
function Assert-NotProtectedBenchmarkDisk {
    param([int]$DiskNumber)

    $disk = $null
    try { $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop } catch {}

    $guard = Test-BenchmarkProtectedDisk -Disk $disk -DiskNumber $DiskNumber
    if ($guard.Protected) {
        Stop-WithError ("BLOQUEIO DE SEGURANCA: o disco {0} nao sera formatado porque corresponde ao SSD de teste ({1}). Remova esse SSD ou escolha outro disco." -f $DiskNumber, $guard.Reason) 20 10
    }
}

<#
.SYNOPSIS
    Relaciona a letra da midia aos discos fisicos que devem ser preservados.
.DESCRIPTION
    Exige conseguir mapear a unidade por Get-Partition. Sem esse mapeamento,
    lanca excecao para que nenhum destino seja liberado por suposicao.
.PARAMETER InstallRoot
    Unidade raiz da midia, por exemplo E:.
#>
function Get-InstallMediaDiskNumbers {
    param([string]$InstallRoot)

    # Sem comprovar o disco da midia, nenhum destino pode ser liberado.
    $driveLetter = $InstallRoot.TrimEnd(':').TrimEnd('\')
    if ($driveLetter -notmatch '^[A-Za-z]$') {
        throw "Nao foi possivel identificar a unidade da midia de instalacao: $InstallRoot"
    }

    try {
        $partitions = @(Get-Partition -DriveLetter $driveLetter -ErrorAction Stop)
        $numbers = @($partitions | ForEach-Object { [int]$_.DiskNumber } | Select-Object -Unique)
        if ($numbers.Count -gt 0) { return $numbers }
    } catch {}

    # Se nao conseguirmos provar em qual disco esta o instalador, nao liberar nenhum alvo.
    throw "Nao consegui mapear a unidade $driveLetter`: da midia para um disco fisico. Instalacao cancelada por seguranca."
}

<#
.SYNOPSIS
    Indica se o disco deve ser tratado como removivel ou externo.
.DESCRIPTION
    Combina BusType com interface, identificador PNP e tipo de midia via CIM.
.PARAMETER Disk
    Objeto de Get-Disk; ausencia do objeto e tratada como bloqueio.
#>
function Test-IsRemovableOrUsbDisk {
    param($Disk)

    if (-not $Disk) { return $true }
    $bus = ''
    try { $bus = [string]$Disk.BusType } catch {}
    if ($bus -match '^(USB|SD|MMC|1394|iSCSI)$') { return $true }

    try {
        $drive = Get-CimInstance Win32_DiskDrive -Filter "Index=$($Disk.Number)" -ErrorAction Stop
        if ($drive.InterfaceType -match 'USB|1394') { return $true }
        if ($drive.PNPDeviceID -match '^(USBSTOR|USB)\\') { return $true }
        if ($drive.MediaType -match 'Removable') { return $true }
    } catch {
        # BusType do Get-Disk continua sendo uma verificacao independente.
    }

    return $false
}

<#
.SYNOPSIS
    Revalida o destino imediatamente antes de qualquer diskpart destrutivo.
.DESCRIPTION
    Bloqueia removiveis, discos/particoes de boot ou sistema, a propria midia e
    os identificadores do SSD de teste. Retorna o disco se passar pelas verificacoes.
.PARAMETER DiskNumber
    Numero do disco escolhido na selecao inicial.
#>
function Assert-SafeTargetDisk {
    param([int]$DiskNumber)

    $disk = $null
    try { $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop } catch {
        Stop-WithError "BLOQUEIO DE SEGURANCA: nao foi possivel revalidar o disco $DiskNumber. Nenhum disco sera alterado." 20 10
    }

    if (Test-IsRemovableOrUsbDisk -Disk $disk) {
        Stop-WithError "BLOQUEIO DE SEGURANCA: o disco $DiskNumber e USB/removivel. Pendrives nunca podem ser usados como destino." 20 10
    }

    if ($disk.IsBoot -or $disk.IsSystem) {
        Stop-WithError "BLOQUEIO DE SEGURANCA: o disco $DiskNumber esta marcado como disco de boot/sistema e nao sera apagado." 20 10
    }

    # A unidade que forneceu Win10/Win11 nunca pode ser apagada.
    if ($script:InstallMediaDiskNumbers -contains $DiskNumber) {
        Stop-WithError "BLOQUEIO DE SEGURANCA: o disco $DiskNumber contem a midia de instalacao. Ele nunca sera limpo ou particionado." 20 10
    }

    foreach ($partition in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)) {
        if ($partition.IsBoot -or $partition.IsSystem) {
            Stop-WithError "BLOQUEIO DE SEGURANCA: o disco $DiskNumber contem uma particao de boot/sistema ativa e nao sera apagado." 20 10
        }
    }

    Assert-NotProtectedBenchmarkDisk -DiskNumber $DiskNumber
    return $disk
}

<#
.SYNOPSIS
    Escolhe o disco interno por prioridade de midia e pelos bloqueios do instalador.
.DESCRIPTION
    Considera apenas discos elegiveis com ao menos 80 GB e barramento permitido.
    Prioridade de selecao:
    1. NVMe: tem preferencia sobre os demais discos.
    2. SSD: sem NVMe elegivel, escolhe o SSD de menor capacidade de armazenamento.
       Havendo SSD e HD, o SSD tem prioridade, mesmo que o HD seja menor.
    3. HD (HDD) ou midia desconhecida: usados como ultima alternativa.
    Entre NVMe, entre HDs e em empates de capacidade dos SSDs, usa o menor numero
    de disco. Se a consulta do tipo de midia falhar, apenas NVMe tem prioridade;
    os demais discos sao ordenados pelo numero, sem presumir que sejam SSDs.
    Exclui pendrives/USB, removiveis, a propria midia de instalacao, discos ou
    particoes de boot/sistema e discos protegidos pelos bloqueios do instalador.
    Guarda os numeros da midia para revalidar o destino antes do particionamento.
.PARAMETER InstallRoot
    Raiz da midia, necessaria para excluir seu disco fisico.
#>
function Get-SafeTargetDisk {
    param([string]$InstallRoot)

    # O filtro combina tamanho, barramento, protecoes e origem da midia.
    # A prioridade e NVMe, menor SSD e, por ultimo, HDD/midia desconhecida.
    $minBytes = 80GB
    $usbDiskNumbers = @(Get-InstallMediaDiskNumbers -InstallRoot $InstallRoot)
    $script:InstallMediaDiskNumbers = $usbDiskNumbers

    $validBusTypes = @('SATA','NVMe','SCSI','RAID','ATA','SAS')
    $allDisks = Get-Disk | Sort-Object Number

    # Get-Disk informa o barramento; Get-PhysicalDisk distingue SSD de HDD.
    # Se o provedor nao informar o tipo, nao presumir que um disco SATA e SSD.
    $ssdDiskNumbers = @{}
    try {
        foreach ($physicalDisk in @(Get-PhysicalDisk -ErrorAction Stop)) {
            if ([string]$physicalDisk.MediaType -in @('SSD', '4')) {
                $ssdDiskNumbers[[string]$physicalDisk.DeviceId] = $true
            }
        }
    } catch {
        Write-Warning 'Nao foi possivel consultar o tipo de midia. Apenas NVMe tera prioridade; os demais discos serao ordenados pelo numero.'
    }

    $safeDisks = $allDisks | Where-Object {
        $guard = Test-BenchmarkProtectedDisk -Disk $_
        (-not $guard.Protected) -and
        ($_.Size -ge $minBytes) -and
        ($_.BusType.ToString() -in $validBusTypes) -and
        (-not $_.IsBoot) -and
        (-not $_.IsSystem) -and
        ($usbDiskNumbers -notcontains $_.Number) -and
        (-not (Test-IsRemovableOrUsbDisk -Disk $_)) -and
        (-not (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object { $_.IsBoot -or $_.IsSystem }))
    } | Sort-Object @{ Expression = {
        if ($_.BusType.ToString() -eq 'NVMe') { 0 }
        elseif ($ssdDiskNumbers.ContainsKey([string]$_.Number)) { 1 }
        else { 2 }
    } }, @{ Expression = {
        # Apenas SSDs nao NVMe usam capacidade como criterio de desempate.
        if ($_.BusType.ToString() -ne 'NVMe' -and $ssdDiskNumbers.ContainsKey([string]$_.Number)) { $_.Size }
        else { 0 }
    } }, @{ Expression = { $_.Number } }

    return ($safeDisks | Select-Object -First 1)
}

# =============================================================================
# 6. PARTICIONAMENTO E APLICACAO DA IMAGEM
# =============================================================================

<#
.SYNOPSIS
    Le os indices e nomes no XML interno de uma imagem WIM ou ESD.
.DESCRIPTION
    Abre somente para leitura, valida o cabecalho e busca o recurso XML por offset.
    Nao monta nem aplica a imagem e nao depende do modulo DISM do WinPE.
    XML comprimido ou formato desconhecido e recusado para permitir a alternativa DISM.
.PARAMETER ImageFile
    Caminho completo de install.wim ou install.esd.
#>
function Get-WimMetadataImages {
    param([string]$ImageFile)

    $stream = $null
    $reader = $null
    $xmlStream = $null
    $xmlReader = $null
    try {
        $stream = [IO.File]::Open($ImageFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $reader = [IO.BinaryReader]::new($stream)
        $header = $reader.ReadBytes(96)
        if ($header.Length -ne 96 -or [Text.Encoding]::ASCII.GetString($header, 0, 8) -cne "MSWIM`0`0`0") {
            throw 'Cabecalho WIM/ESD ausente ou incompleto.'
        }
        $headerSize = [BitConverter]::ToUInt32($header, 8)
        $imageCount = [BitConverter]::ToUInt32($header, 44)
        if ($headerSize -lt 96 -or $headerSize -gt $stream.Length -or $imageCount -eq 0) {
            throw 'Cabecalho da imagem invalido ou sem edicoes.'
        }

        # O descritor XML ocupa 24 bytes a partir do offset 72 do cabecalho.
        # Os 56 bits inferiores guardam o tamanho; os oito superiores, as flags.
        $sizeAndFlags = [BitConverter]::ToUInt64($header, 72)
        $xmlSize = $sizeAndFlags -band [uint64]72057594037927935
        $xmlFlags = $header[79]
        $xmlOffset = [BitConverter]::ToUInt64($header, 80)
        $xmlOriginalSize = [BitConverter]::ToUInt64($header, 88)
        if (($xmlFlags -band 4) -ne 0 -or $xmlOriginalSize -ne $xmlSize) {
            throw 'Metadados XML comprimidos exigem consulta pelo DISM.'
        }
        # Limita a leitura e verifica limites antes de converter offsets de 64 bits.
        if ($xmlSize -eq 0 -or $xmlSize -gt 16MB -or $xmlOffset -lt $headerSize -or
            $xmlOffset -gt [uint64]$stream.Length -or $xmlSize -gt ([uint64]$stream.Length - $xmlOffset)) {
            throw 'Metadados XML ausentes, truncados ou fora dos limites da imagem.'
        }
        $null = $stream.Seek([long]$xmlOffset, [IO.SeekOrigin]::Begin)
        $xmlBytes = $reader.ReadBytes([int]$xmlSize)
        if ($xmlBytes.Length -ne $xmlSize) { throw 'Leitura incompleta dos metadados XML.' }

        # XmlReader identifica a codificacao pelo BOM e nao carrega DTD/recursos externos.
        $xmlStream = [IO.MemoryStream]::new($xmlBytes, $false)
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $xmlReader = [Xml.XmlReader]::Create($xmlStream, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($xmlReader)
        $nodes = @($document.SelectNodes('/WIM/IMAGE'))
        if ($nodes.Count -ne $imageCount) { throw 'Quantidade de edicoes inconsistente nos metadados.' }

        $seen = [Collections.Generic.HashSet[int]]::new()
        foreach ($node in $nodes) {
            $index = 0
            if (-not [int]::TryParse($node.GetAttribute('INDEX'), [ref]$index) -or
                $index -lt 1 -or $index -gt $imageCount -or -not $seen.Add($index)) {
                throw 'Indice de edicao invalido ou duplicado nos metadados.'
            }
        }
        foreach ($node in $nodes) {
            $nameNode = $node.SelectSingleNode('NAME')
            [pscustomobject]@{
                Index = [int]$node.GetAttribute('INDEX')
                Name = if ($nameNode) { $nameNode.InnerText.Trim() } else { '' }
            }
        }
    }
    finally {
        if ($xmlReader) { $xmlReader.Dispose() }
        if ($xmlStream) { $xmlStream.Dispose() }
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

<#
.SYNOPSIS
    Identifica um indice comprovadamente existente antes de preparar o disco.
.DESCRIPTION
    Prefere os metadados da propria imagem. DISM e a alternativa para formatos
    nao lidos diretamente. Falhas mantem o disco intacto e registram diagnostico.
.PARAMETER ImageFile
    Caminho completo da imagem WIM ou ESD.
.PARAMETER PreferredNames
    Nomes exatos das edicoes preferidas; sem correspondencia usa a primeira existente.
#>
function Get-ImageIndexByName {
    param(
        [string]$ImageFile,
        [string[]]$PreferredNames
    )

    $script:ImageIndexDiagnostic = ''
    $script:ImageIndexLogPath = $null
    $details = [Collections.Generic.List[string]]::new()
    $images = @()
    $selectedIndex = $null
    try {
        $images = @(Get-WimMetadataImages -ImageFile $ImageFile)
        $details.Add('Indices lidos diretamente dos metadados WIM/ESD.')
    } catch {
        $details.Add('Leitura dos metadados: ' + $_.Exception.Message)
    }

    if ($images.Count -eq 0) {
        try {
            # Cada argumento e separado para preservar caminhos com espacos.
            # Continue permite capturar stderr de comandos nativos no PowerShell 5.1.
            $arguments = @('/English', '/Get-WimInfo', ('/WimFile:' + $ImageFile))
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $lines = & dism.exe @arguments 2>&1
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            $output = $lines | Out-String
            $details.Add(('DISM codigo {0}: {1}' -f $exitCode, $output.Trim()))
            if ($exitCode -eq 0) {
                # Tolera alinhamento e idioma; nunca presume indice 1 sem uma listagem.
                $pattern = '(?ims)^\s*(?:Index|Indice|Índice)\s*:\s*(?<index>\d+)[^\r\n]*\r?\n(?<fields>.*?)(?=^\s*(?:Index|Indice|Índice)\s*:|\z)'
                $images = @([regex]::Matches($output, $pattern) | ForEach-Object {
                    $index = 0
                    if ([int]::TryParse($_.Groups['index'].Value, [ref]$index) -and $index -gt 0) {
                        $nameMatch = [regex]::Match($_.Groups['fields'].Value, '(?im)^\s*(?:Name|Nome)\s*:\s*([^\r\n]+)')
                        [pscustomobject]@{ Index = $index; Name = $nameMatch.Groups[1].Value.Trim() }
                    }
                })
            }
        } catch {
            $details.Add('Consulta DISM: ' + $_.Exception.Message)
        }
    }

    # Compara nomes completos para nao confundir Pro com Pro N em imagens multiplas.
    foreach ($image in $images) {
        if ($PreferredNames -contains $image.Name) { $selectedIndex = $image.Index; break }
    }
    if (-not $selectedIndex -and $images.Count -gt 0) { $selectedIndex = $images[0].Index }
    if ($selectedIndex) { $details.Add('Indice selecionado: ' + $selectedIndex) }
    else { $details.Add('Nenhum indice existente foi identificado. Nenhum disco foi preparado.') }
    $script:ImageIndexDiagnostic = $details -join [Environment]::NewLine

    # O log fica no TEMP do WinPE, normalmente X:\Windows\Temp; falha no log nao
    # impede selecionar uma imagem valida nem oculta o diagnostico na mensagem.
    try {
        $logPath = Join-Path ([IO.Path]::GetTempPath()) 'Pichau-ImageIndex.log'
        $record = '[{0}] Imagem: {1}{2}{3}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ImageFile, [Environment]::NewLine, $script:ImageIndexDiagnostic
        [IO.File]::AppendAllText($logPath, $record, [Text.Encoding]::UTF8)
        $script:ImageIndexLogPath = $logPath
    } catch {}
    return $selectedIndex
}

<#
.SYNOPSIS
    Grava os comandos no RAM drive do WinPE e executa o diskpart.
.DESCRIPTION
    Falha de diskpart chama Stop-WithError. Esta funcao efetivamente altera o disco.
.PARAMETER Content
    Conteudo completo do script diskpart ja montado para o disco escolhido.
#>
function Invoke-DiskPartScript {
    param([string]$Content)

    # X: e o RAM drive do WinPE; o arquivo contem a operacao prestes a executar.
    $dpFile = 'X:\diskpart.txt'
    Set-Content -Path $dpFile -Value $Content -Encoding ASCII
    diskpart /s $dpFile | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Falha ao preparar o disco.'
    }
}

<#
.SYNOPSIS
    Limpa o destino e cria o particionamento GPT para inicializacao UEFI.
.DESCRIPTION
    Cria EFI FAT32 de 260 MB, MSR de 16 MB e o restante como Windows NTFS.
.PARAMETER DiskNumber
    Numero do disco fisico que sera revalidado e apagado.
.PARAMETER SystemLetter
    Letra livre, sem dois-pontos, para a particao EFI.
.PARAMETER WindowsLetter
    Letra livre, sem dois-pontos, para a particao principal do Windows.
#>
function Prepare-DiskUefi {
    param(
        [int]$DiskNumber,
        [string]$SystemLetter,
        [string]$WindowsLetter
    )

    Assert-SafeTargetDisk -DiskNumber $DiskNumber | Out-Null

    # Os comandos abaixo sao texto enviado ao diskpart apos a revalidacao.
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

<#
.SYNOPSIS
    Limpa o destino e cria o particionamento MBR para inicializacao BIOS.
.DESCRIPTION
    Cria uma particao NTFS ativa de 500 MB e o restante como Windows NTFS.
.PARAMETER DiskNumber
    Numero do disco fisico que sera revalidado e apagado.
.PARAMETER SystemLetter
    Letra livre, sem dois-pontos, para a particao de sistema.
.PARAMETER WindowsLetter
    Letra livre, sem dois-pontos, para a particao principal do Windows.
#>
function Prepare-DiskBios {
    param(
        [int]$DiskNumber,
        [string]$SystemLetter,
        [string]$WindowsLetter
    )

    Assert-SafeTargetDisk -DiskNumber $DiskNumber | Out-Null

    # Os comandos abaixo sao texto enviado ao diskpart apos a revalidacao.
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

<#
.SYNOPSIS
    Aplica a imagem ao destino e traduz o progresso do DISM para o painel.
.DESCRIPTION
    O percentual local do DISM ocupa a faixa global de 25% a 85%.
    Saida de erro e codigo diferente de zero interrompem a instalacao.
.PARAMETER ImageFile
    Caminho da imagem WIM ou ESD selecionada.
.PARAMETER Index
    Indice da edicao a extrair da imagem.
.PARAMETER WindowsDrive
    Letra do volume de destino com dois-pontos, por exemplo W:.
.PARAMETER Ui
    Objeto de controles atualizado durante a aplicacao.
#>
function Invoke-DismApplyImageWithUi {
    param(
        [string]$ImageFile,
        [int]$Index,
        [string]$WindowsDrive,
        $Ui
    )

    # Processo separado permite capturar a saida e atualizar o formulario.
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

    # Aceita percentual com ponto ou virgula. DISM ocupa a faixa global 25-85%;
    # copia de configuracoes e boot usam as etapas posteriores da barra.
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

    # O codigo de saida decide sucesso; stderr fornece os detalhes da falha.
    $stderr = $proc.StandardError.ReadToEnd()
    if ($proc.ExitCode -ne 0) {
        if (-not $stderr) { $stderr = 'DISM retornou erro na aplicacao da imagem.' }
        Stop-WithError $stderr
    }
}

# =============================================================================
# 7. PREPARACAO DO PRIMEIRO BOOT E DOS UTILITARIOS
# =============================================================================

<#
.SYNOPSIS
    Instala o arquivo de respostas no Panther do Windows offline.
.PARAMETER XmlPath
    Arquivo autounattend correspondente ao Windows selecionado.
.PARAMETER WindowsDrive
    Unidade do Windows aplicado, incluindo dois-pontos.
#>
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

<#
.SYNOPSIS
    Confere os arquivos obrigatorios antes de particionar e antes da copia.
.DESCRIPTION
    O controlador de primeiro logon deve acompanhar os dois arquivos do atualizador.
    Ausencia de qualquer componente interrompe a preparacao com erro explicito.
#>
function Get-FirstLogonRequiredFiles {
    param([string]$InstallRoot)
    $files = @(@{ Source = (Join-Path $InstallRoot 'SetupComplete.cmd'); Destination = 'SetupComplete.cmd' })
    foreach ($name in @('Atualizar Drivers.cmd', 'Atualizar Drivers.ps1', 'Iniciar-PrimeiroLogon.ps1')) {
        $source = Join-Path $InstallRoot ('Script\Drivers\' + $name)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $source = Join-Path $InstallRoot $name }
        $files += @{ Source = $source; Destination = $name }
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
            throw ('Arquivo obrigatorio ausente na midia: ' + $file.Source + '. Atualize a pasta Script inteira e SetupComplete.cmd.')
        }
    }
    return $files
}

<#
.SYNOPSIS
    Prepara os scripts e utilitarios executados apos a instalacao do Windows.
.DESCRIPTION
    Copia atualizador de drivers, Visual C++, utilitarios, painel de qualidade e
    recursos do slideshow para Windows\Setup\Scripts, usando caminhos alternativos.
.PARAMETER InstallRoot
    Raiz da midia com SetupComplete.cmd e a pasta Script.
.PARAMETER WindowsDrive
    Unidade do Windows aplicado, incluindo dois-pontos.
#>
function Copy-SetupComplete {
    param(
        [string]$InstallRoot,
        [string]$WindowsDrive
    )

    $filesToCopy = @(Get-FirstLogonRequiredFiles -InstallRoot $InstallRoot)

    # Os recursos pos-instalacao ficam no disco instalado porque a midia
    # removivel pode nao estar disponivel depois do reboot.
    $destDir = "$WindowsDrive\Windows\Setup\Scripts"
    if (-not (Test-Path $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    # Remove scripts antigos de driver para evitar conflito/crash.
    $oldDriverFiles = @(
        'Instalar_Drivers_Offline.cmd',
        'Instalar_Drivers_Offline.ps1',
        'Instalar_Drivers_Offline_Rapido.cmd',
        'Instalar_Drivers_Offline_Rapido.ps1',
        'Instalar_Drivers_Offline - RAPIDO.cmd',
        'Instalar_Drivers_Offline - RAPIDO.ps1'
    )
    foreach ($old in $oldDriverFiles) {
        $oldPath = Join-Path $destDir $old
        if (Test-Path $oldPath) {
            Remove-Item -Path $oldPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Copia o controlador de primeiro logon e os dois arquivos do atualizador.
    foreach ($file in $filesToCopy) {
        Copy-Item -LiteralPath $file.Source -Destination (Join-Path $destDir $file.Destination) -Force -ErrorAction Stop
    }

    # Cada nova instalacao recebe uma reserva nova. Remove somente arquivos
    # conhecidos dentro do Windows aplicado, sem alterar o computador do WinPE.
    # Nao cria Startup: o XML e o unico gatilho automatico.
    foreach ($relative in @(
        # Limpa tambem marcadores legados do fluxo antecipado, somente no destino.
        'Windows\Temp\PichauDrivers-specialize.once',
        'Windows\Temp\PichauDrivers-specialize.json',
        'Windows\Temp\PichauDrivers-logon.once',
        'Windows\Temp\PichauDrivers-logon.json',
        'Windows\Temp\PichauPosLogon.once',
        'Windows\Temp\PichauPosLogon.json',
        'Windows\Temp\Pichau-Preparacao.log',
        'Windows\Temp\PichauAtualizarDrivers.once',
        'Windows\Temp\PichauAtualizarDrivers.result.json',
        'Windows\Setup\Scripts\Pichau_FirstLogon_AtualizarDrivers.cmd',
        'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Pichau_FirstLogon_AtualizarDrivers.cmd',
        'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Pichau_FirstLogon_Drivers.cmd'
    )) {
        $legacyPath = Join-Path $WindowsDrive $relative
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) { Remove-Item -LiteralPath $legacyPath -Force -ErrorAction Stop }
    }

    # Copia o instalador dedicado do Proxy de Hub para o mesmo layout usado pelo atualizador.
    $proxyHubSources = @(
        (Join-Path $InstallRoot 'Script\Drivers\ProxyHub\DISPOSITIVO DE PROXY HUB.EXE'),
        (Join-Path $InstallRoot 'Outros\DISPOSITIVO DE PROXY HUB.EXE'),
        (Join-Path $InstallRoot 'ProxyHub\DISPOSITIVO DE PROXY HUB.EXE')
    )
    foreach ($proxyHubSource in $proxyHubSources) {
        if (Test-Path -LiteralPath $proxyHubSource -PathType Leaf) {
            $proxyHubDest = Join-Path $destDir 'ProxyHub'
            New-Item -ItemType Directory -Path $proxyHubDest -Force | Out-Null
            Copy-Item -LiteralPath $proxyHubSource -Destination (Join-Path $proxyHubDest 'DISPOSITIVO DE PROXY HUB.EXE') -Force
            break
        }
    }

    # Copia o instalador Visual C++ para executar depois dos drivers e antes do Controle de Qualidade.
    $visualCppDest = Join-Path $destDir '[AquaX]Visual C++.exe'
    $visualCppSources = @(
        (Join-Path $InstallRoot 'Script\Utilitarios\[AquaX]Visual C++.exe'),
        (Join-Path $InstallRoot '[AquaX]Visual C++.exe'),
        (Join-Path $InstallRoot 'Script\Visual C++.exe'),
        (Join-Path $InstallRoot 'Visual C++.exe'),
        (Join-Path $InstallRoot 'Script\AquaX Visual C++.exe'),
        (Join-Path $InstallRoot 'AquaX Visual C++.exe')
    )
    # Os colchetes de [AquaX] fazem parte do nome; LiteralPath evita wildcards.
    foreach ($visualCppSource in $visualCppSources) {
        if (Test-Path -LiteralPath $visualCppSource) {
            Copy-Item -LiteralPath $visualCppSource -Destination $visualCppDest -Force
            break
        }
    }

    # A midia atual mantem OCCT.exe na raiz; aceita tambem o caminho organizado.
    $occtSource = Join-Path $InstallRoot 'Script\Utilitarios\OCCT.exe'
    if (-not (Test-Path -LiteralPath $occtSource)) { $occtSource = Join-Path $InstallRoot 'OCCT.exe' }

    foreach ($utility in @(
        @{ Source = $occtSource; Destination = 'OCCT.exe' },
        @{ Source = (Join-Path $InstallRoot 'Script\Utilitarios\OCCT.config.json'); Destination = 'OCCT.config.json' },
        @{ Source = (Join-Path $InstallRoot 'Script\Utilitarios\BIOS.cmd'); Destination = 'BIOS.cmd' }
    )) {
        if (Test-Path $utility.Source) {
            Copy-Item -LiteralPath $utility.Source -Destination (Join-Path $destDir $utility.Destination) -Force
        }
    }

    # Copia o Controle de Qualidade junto com os scripts, para abrir automaticamente ao final dos drivers.
    $qualityDest = Join-Path $destDir 'Controle de Qualidade'
    $qualitySources = @(
        (Join-Path $InstallRoot 'Script\Controle de Qualidade'),
        (Join-Path $InstallRoot 'Controle de Qualidade')
    )
    foreach ($qualitySource in $qualitySources) {
        if (Test-Path (Join-Path $qualitySource 'Controle de Qualidade.exe')) {
            if (Test-Path $qualityDest) {
                Remove-Item -Path $qualityDest -Recurse -Force -ErrorAction SilentlyContinue
            }
            Copy-Item -Path $qualitySource -Destination $qualityDest -Recurse -Force
            break
        }
    }

    # Copia a pasta Wallpaper inteira (uma unica vez) para o disco local.
    # Ela sera usada como apresentacao de slides (papel de parede) ao final da atualizacao de drivers.
    $wallpaperDest = Join-Path $destDir 'Wallpaper'
    $wallpaperSources = @(
        (Join-Path $InstallRoot 'Script\Wallpaper\Wallpaper'),
        (Join-Path $InstallRoot 'Script\Wallpaper'),
        (Join-Path $InstallRoot 'Wallpaper')
    )
    foreach ($wallpaperSource in $wallpaperSources) {
        if ((Test-Path $wallpaperSource) -and (Get-ChildItem -LiteralPath $wallpaperSource -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp|gif|tif|tiff|webp)$' } | Select-Object -First 1)) {
            if (Test-Path $wallpaperDest) {
                Remove-Item -Path $wallpaperDest -Recurse -Force -ErrorAction SilentlyContinue
            }
            Copy-Item -Path $wallpaperSource -Destination $wallpaperDest -Recurse -Force
            break
        }
    }

    # Copia o script/executavel que aplica a pasta como slideshow nativo do Windows.
    foreach ($slideshowSource in @(
        (Join-Path $InstallRoot 'Script\Wallpaper\AplicarSlideshow.ps1'),
        (Join-Path $InstallRoot 'AplicarSlideshow.ps1')
    )) {
        if (Test-Path $slideshowSource) {
            Copy-Item -Path $slideshowSource -Destination (Join-Path $destDir 'AplicarSlideshow.ps1') -Force
            break
        }
    }
    foreach ($slideshowExeSource in @(
        (Join-Path $InstallRoot 'Script\Wallpaper\AplicarSlideshow.exe'),
        (Join-Path $InstallRoot 'AplicarSlideshow.exe')
    )) {
        if (Test-Path $slideshowExeSource) {
            Copy-Item -Path $slideshowExeSource -Destination (Join-Path $destDir 'AplicarSlideshow.exe') -Force
            break
        }
    }
}

<#
.SYNOPSIS
    Cria os arquivos de inicializacao de acordo com o firmware.
.DESCRIPTION
    Usa bcdboot em ambos os modos e bootsect adicionalmente no modo BIOS.
.PARAMETER IsUefi
    True para UEFI/GPT; false para BIOS/MBR.
.PARAMETER SystemDrive
    Letra da particao de sistema sem dois-pontos.
.PARAMETER WindowsDrive
    Unidade do Windows aplicado, incluindo dois-pontos.
#>
function Create-BootFiles {
    param(
        [bool]$IsUefi,
        [string]$SystemDrive,
        [string]$WindowsDrive
    )

    # UEFI usa EFI; BIOS tambem requer codigo de boot no volume/MBR.
    if ($IsUefi) {
        bcdboot "$WindowsDrive\Windows" /s "$SystemDrive`:" /f UEFI | Out-Null
    } else {
        bcdboot "$WindowsDrive\Windows" /s "$SystemDrive`:" /f BIOS | Out-Null
        # Valida BCDBoot antes de Bootsect sobrescrever o codigo de saida.
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError 'Falha ao criar o boot do Windows.'
        }
        bootsect /nt60 "$SystemDrive`:" /mbr | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Falha ao criar o boot do Windows.'
    }
}

<#
.SYNOPSIS
    Tenta direcionar o proximo boot UEFI ao Windows Boot Manager interno.
.DESCRIPTION
    Consulta as entradas de firmware, evita candidatos USB e ajusta o BCD da EFI.
    Falhas sao ignoradas para manter o fluxo de finalizacao existente.
.PARAMETER IsUefi
    Somente true habilita essa configuracao; BIOS retorna sem alteracoes.
.PARAMETER SystemDrive
    Letra da particao EFI sem dois-pontos.
#>
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

        # Primeiro tenta o nome exato; a alternativa aceita variacoes e exclui
        # descricoes que apontem explicitamente para midia removivel.
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

<#
.SYNOPSIS
    Resolve VEN/DEV e, quando disponivel, SUBSYS usando a base local pci.ids.
.DESCRIPTION
    Le o formato oficial: fabricante sem recuo, dispositivo com uma tabulacao e
    subsistema com duas. SUBSYS do Windows usa dispositivo antes do fabricante;
    pci.ids usa fabricante antes do dispositivo. Prefere a correspondencia mais
    especifica e retorna o nome do dispositivo se nao houver subsistema cadastrado.
    IDs compartilhados podem identificar uma familia, sem garantir o modelo exato.
    Base ausente, ilegivel ou sem correspondencia retorna vazio para a alternativa.
    Atualizacao: substituir Script\pci.ids pela base do https://pci-ids.ucw.cz/ ou
    https://raw.githubusercontent.com/pciutils/pciids/master/pci.ids, preservando
    cabecalho e licenca. Nenhum download e feito durante a instalacao no WinPE.
#>
function Resolve-PciDeviceName {
    param(
        [string]$DatabasePath,
        [string]$VendorId,
        [string]$DeviceId,
        [string]$SubsystemId
    )
    if ($VendorId -notmatch '^[0-9A-Fa-f]{4}$' -or $DeviceId -notmatch '^[0-9A-Fa-f]{4}$') { return '' }
    $inVendor = $false
    $inDevice = $false
    $deviceName = ''
    $subVendor = ''
    $subDevice = ''
    if ($SubsystemId -match '^[0-9A-Fa-f]{8}$') {
        $subDevice = $SubsystemId.Substring(0, 4)
        $subVendor = $SubsystemId.Substring(4, 4)
    }
    try {
        # Le em fluxo e para ao sair do bloco solicitado, sem carregar toda a base.
        foreach ($line in [IO.File]::ReadLines($DatabasePath, [Text.Encoding]::UTF8)) {
            if ($line -match '^([0-9A-Fa-f]{4})\s+(.+)$') {
                if ($inVendor) { break }
                $inVendor = $Matches[1] -eq $VendorId
            } elseif ($line -match '^\t([0-9A-Fa-f]{4})\s+(.+)$') {
                if (-not $inVendor) { continue }
                if ($inDevice) { break }
                $inDevice = $Matches[1] -eq $DeviceId
                if ($inDevice) { $deviceName = $Matches[2].Trim() }
            } elseif ($inDevice -and $subVendor -and $line -match '^\t\t([0-9A-Fa-f]{4})\s+([0-9A-Fa-f]{4})\s+(.+)$') {
                if ($Matches[1] -eq $subVendor -and $Matches[2] -eq $subDevice) {
                    return $Matches[3].Trim()
                }
            } elseif ($line -match '^C\s') { break }
        }
    } catch { return '' }
    return $deviceName
}
<#
.SYNOPSIS
    Identifica video no WinPE mesmo sem o driver do fabricante.
.DESCRIPTION
    Preserva nomes especificos retornados por Win32_VideoController. Como alternativa,
    le HardwareID/CompatibleIDs do barramento PCI no Registro do ambiente em execucao.
    A classe PCI 03 identifica controladores de video, inclusive sem driver instalado;
    nao basta encontrar VEN de uma marca, pois outros componentes usam o mesmo VEN.
    Sem nome especifico do controlador, consulta VEN/DEV/SUBSYS em Script\pci.ids
    na midia de instalacao. Se a base estiver ausente ou o ID nao estiver cadastrado,
    mostra fabricante e VEN/DEV. Nao presume modelo comercial para IDs compartilhados.
    A leitura e local, somente leitura e nao exige rede, driver de video ou modulo PnpDevice.
#>
function Get-WinPeGpuName {
    param([string]$DatabasePath = (Join-Path $PSScriptRoot 'pci.ids'))
    $genericName = '(?i)Microsoft|Basic|Basico|Básico|Standard|Padrao|Padrão|Unknown|Desconhecido|Video Controller|Controlador de video|Controlador de vídeo|^Display$'
    $controllers = @()
    try { $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch {}

    $vendors = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel'; '102B' = 'Matrox'; '1A03' = 'ASPEED' }
    $names = @()
    try {
        $pciDevices = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction Stop)
        foreach ($device in $pciDevices) {
            foreach ($instance in @(Get-ChildItem -LiteralPath $device.PSPath -ErrorAction SilentlyContinue)) {
                $properties = Get-ItemProperty -LiteralPath $instance.PSPath -ErrorAction SilentlyContinue
                if (-not $properties) { continue }
                $ids = @($properties.HardwareID) + @($properties.CompatibleIDs)
                $isDisplay = @($ids | Where-Object { $_ -match '(?i)^PCI\\.*CC_03[0-9A-F]{2}(?:[0-9A-F]{2})?$' }).Count -gt 0
                if (-not $isDisplay) { continue }
                $identity = @($ids | Where-Object { $_ -match '(?i)^PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}' } | Select-Object -First 1)
                if ($identity.Count -eq 0) { continue }
                $null = $identity[0] -match '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})'
                $vendorId = $Matches[1].ToUpperInvariant()
                $deviceId = $Matches[2].ToUpperInvariant()
                $vendorName = $vendors[$vendorId]
                if (-not $vendorName) { $vendorName = 'GPU PCI' }
                $name = '{0} [VEN_{1} DEV_{2}]' -f $vendorName, $vendorId, $deviceId
                $subsystemId = ''
                foreach ($hardwareId in $ids) {
                    if ($hardwareId -match '(?i)SUBSYS_([0-9A-F]{8})') {
                        $subsystemId = $Matches[1]
                        break
                    }
                }
                $databaseName = Resolve-PciDeviceName -DatabasePath $DatabasePath -VendorId $vendorId -DeviceId $deviceId -SubsystemId $subsystemId
                if ($databaseName) {
                    # pci.ids pode incluir o chip antes do modelo: GB203 [GeForce RTX 5080].
                    # Exibe apenas o nome entre colchetes; sem colchetes, preserva o nome.
                    # Aplica somente ao resultado da base, nunca aos codigos VEN/DEV da alternativa.
                    if ($databaseName -match '\[([^\[\]]+)\]') {
                        $name = $Matches[1].Trim()
                    } else {
                        $name = $databaseName
                    }
                }

                # Usa o modelo somente quando o controlador corresponde a esta instancia PCI.
                $instanceId = 'PCI\{0}\{1}' -f $device.PSChildName, $instance.PSChildName
                $matched = $controllers | Where-Object {
                    $_.PNPDeviceID -eq $instanceId -and $_.Name -and $_.Name -notmatch $genericName
                } | Select-Object -First 1
                if ($matched) { $name = [string]$matched.Name }
                $names += $name
            }
        }
    } catch {
        # A consulta CIM ainda pode fornecer um nome se a enumeracao PCI nao estiver acessivel.
    }
    if ($names.Count -gt 0) { return (($names | Select-Object -Unique) -join ' + ') }
    $namedControllers = @($controllers | Where-Object { $_.Name -and $_.Name -notmatch $genericName } | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
    if ($namedControllers.Count -gt 0) { return ($namedControllers -join ' + ') }
    return 'Nao identificado'
}

# =============================================================================
# 8. FLUXO AUTOMATICO DO WINPE
# =============================================================================

# 8.1 Atualiza boot/rede, encontra a midia e abre a interface.
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

# 8.2 Exige imagem e respostas dos dois sistemas antes do particionamento.
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

# 8.3 Escolhe um destino permitido e repete o bloqueio do SSD de teste.
$targetDisk = Get-SafeTargetDisk -InstallRoot $installRoot
if (-not $targetDisk) {
    Stop-WithError 'Nenhum disco interno seguro foi encontrado. A instalacao foi cancelada.'
}

$targetGuard = Test-BenchmarkProtectedDisk -Disk $targetDisk
if ($targetGuard.Protected) {
    Stop-WithError ("BLOQUEIO DE SEGURANCA: o disco alvo {0} corresponde ao SSD de teste ({1}). A instalacao foi cancelada antes do diskpart." -f $targetDisk.Number, $targetGuard.Reason) 20 10
}

# 8.4 RAM/CPU sao informacoes visuais; TPM 2.0 determina Win10 ou Win11.
# GPU, placa-mae e fabricante sao consultados em melhor esforco para o resumo.
$ramGB = [math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB), 2)
$cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
$tpmPresent = Get-Tpm20Present
$computerInfo = $null
$gpuName = 'Nao identificado'
$boardName = 'Nao identificado'
try { $computerInfo = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
$gpuName = Get-WinPeGpuName -DatabasePath (Join-Path $installRoot 'Script\pci.ids')
# O campo GPU permanece visivel mesmo se nenhum nome valido for retornado.
if ([string]::IsNullOrWhiteSpace([string]$gpuName)) { $gpuName = 'Nao identificado' }
try {
    $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    if ($board) {
        $boardName = (@([string]$board.Manufacturer, [string]$board.Product) | Where-Object { $_.Trim() }) -join ' '
    }
} catch {}

# Reduz textos longos somente na exibicao, preservando os dados completos.
$machineModel = 'Computador nao identificado'
if ($computerInfo) {
    $maker = ([string]$computerInfo.Manufacturer).Trim()
    $model = ([string]$computerInfo.Model).Trim()
    $machineParts = @($maker, $model) | Where-Object { $_ }
    $machineModel = ($machineParts -join ' ').Trim()
    if (-not $machineModel) { $machineModel = 'Computador nao identificado' }
}
if ($machineModel.Length -gt 34) { $machineModel = $machineModel.Substring(0, 31) + '...' }
# Os controles individuais aplicam reticencias sem quebrar linhas. Nao truncar
# os dados antes do tooltip: ele deve mostrar o nome integral retornado por pci.ids.
$script:Ui.MachineInfo.Text = $machineModel
$script:Ui.HardwareInfo.Text = [string]$cpuName
$script:Ui.RamInfo.Text = "$ramGB GB | TPM 2.0: $(if($tpmPresent){'SIM'}else{'NAO'})"
$script:Ui.GpuInfo.Text = [string]$gpuName
$script:Ui.BoardInfo.Text = [string]$boardName
foreach ($infoControl in @($script:Ui.HardwareInfo, $script:Ui.RamInfo, $script:Ui.GpuInfo, $script:Ui.BoardInfo)) {
    $script:Ui.HardwareTooltip.SetToolTip($infoControl, $infoControl.Text)
}
$script:Ui.DiskInfo.Text = '#{0} {1} | {2:N0} GB' -f $targetDisk.Number, $targetDisk.BusType, ($targetDisk.Size / 1GB)
$script:Ui.HardwareTooltip.SetToolTip($script:Ui.DiskInfo, $script:Ui.DiskInfo.Text)
foreach ($iconKey in @('CPU', 'RAM', 'GPU', 'PLACA', 'DISCO')) {
    $iconLabel = switch ($iconKey) {
        'CPU' { $script:Ui.HardwareInfo }; 'RAM' { $script:Ui.RamInfo }; 'GPU' { $script:Ui.GpuInfo }
        'PLACA' { $script:Ui.BoardInfo }; 'DISCO' { $script:Ui.DiskInfo }
    }
    $script:Ui.HardwareTooltip.SetToolTip($script:Ui.HardwareIcons[$iconKey], $iconLabel.Text)
}
# Politica existente: sem TPM 2.0 comprovado usa Win10; com TPM 2.0 usa Win11.
# As antigas heuristicas de idade de CPU nao participam mais deste fluxo.
$useWin10 = -not $tpmPresent
$reasons = @()

if ($useWin10) {
    $reasons += 'sem TPM 2.0'
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
    $chosenReason = 'TPM 2.0 detectado'
}

$script:Ui.OsLabel.Text = $chosenName
if ($chosenName -eq 'Windows 11') {
    $script:Ui.OsBadge.BackColor = [System.Drawing.Color]::FromArgb(41, 22, 27)
} else {
    $script:Ui.OsBadge.BackColor = [System.Drawing.Color]::FromArgb(34, 21, 25)
}
Set-RoundedControl -Control $script:Ui.OsBadge -Radius (S 17)
[System.Windows.Forms.Application]::DoEvents()

# Valida a entrada automatica antes de permitir a limpeza do disco.
try { $null = Get-FirstLogonRequiredFiles -InstallRoot $installRoot }
catch { Stop-WithError $_.Exception.Message }

# 8.5 Resolve arquivo/indice, firmware e letras livres antes da limpeza.
$imageFile = Get-ImageFile -BasePath $selectedBase
if (-not $imageFile) {
    Stop-WithError "Imagem de instalacao nao encontrada em $selectedBase\sources"
}

$imageIndex = Get-ImageIndexByName -ImageFile $imageFile -PreferredNames $preferredNames
if (-not $imageIndex) {
    $imageDetail = $script:ImageIndexDiagnostic
    if ($imageDetail.Length -gt 700) { $imageDetail = $imageDetail.Substring(0, 700) + '...' }
    $imageError = "Nao foi possivel identificar o indice da imagem.`r`nArquivo: $imageFile`r`n$imageDetail"
    if ($script:ImageIndexLogPath) { $imageError += "`r`nLog: $script:ImageIndexLogPath" }
    Stop-WithError $imageError
}

# UEFI e o padrao sem modo informado; BIOS explicito usa MBR.
$firmwareType = $env:FIRMWARE_TYPE
$isUefi = $true
if ($firmwareType) {
    if ($firmwareType -match 'BIOS') { $isUefi = $false }
    elseif ($firmwareType -match 'UEFI') { $isUefi = $true }
}

# Listas distintas evitam colidir as letras de sistema/Windows e as ja ocupadas.
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

# 8.6 A inicializacao pela midia segue a reinstalacao. Prepare-Disk* revalida o
# destino imediatamente antes de diskpart executar clean.
# Bloco removido: sempre reinstalar quando iniciar pelo pendrive.

Update-Ui -Ui $script:Ui -Percent 14 -Status 'Hardware validado' -Detail ("Sistema selecionado: {0}`r`nCPU: {1}`r`nRAM: {2} GB`r`nTPM: {3}`r`nMotivo: {4}" -f $chosenName, $cpuName, $ramGB, $tpmPresent, $chosenReason) -Step 1
Start-Sleep -Milliseconds 700

Update-Ui -Ui $script:Ui -Percent 18 -Status 'Preparando disco' -Detail ("Disco alvo: {0} - {1}`r`nTipo: {2} | Tamanho: {3:N0} GB`r`nNVMe --> SSD --> HDD`r`nModo de boot: {4}" -f $targetDisk.Number, $targetDisk.FriendlyName, $targetDisk.BusType, ($targetDisk.Size / 1GB), ($(if($isUefi){'UEFI'}else{'BIOS'}))) -Step 2

if ($isUefi) {
    Prepare-DiskUefi -DiskNumber $targetDisk.Number -SystemLetter $systemLetter -WindowsLetter $windowsLetter
} else {
    Prepare-DiskBios -DiskNumber $targetDisk.Number -SystemLetter $systemLetter -WindowsLetter $windowsLetter
}

Update-Ui -Ui $script:Ui -Percent 25 -Status 'Disco preparado' -Detail ("Sistema: {0}:`r`nWindows: {1}:" -f $systemLetter, $windowsLetter) -Step 2
Start-Sleep -Milliseconds 700

# 8.7 Aplica a imagem e prepara personalizacao, respostas e scripts do primeiro boot.
Invoke-DismApplyImageWithUi -ImageFile $imageFile -Index $imageIndex -WindowsDrive "$windowsLetter`:" -Ui $script:Ui

Update-Ui -Ui $script:Ui -Percent 86 -Status 'Aplicando branding' -Detail 'Copiando wallpaper e lockscreen para o Windows instalado' -Step 3
Apply-InstalledBranding -InstallRoot $installRoot -WindowsDrive "$windowsLetter`:"

Update-Ui -Ui $script:Ui -Percent 90 -Status 'Copiando configuracoes' -Detail 'Aplicando unattend e SetupComplete' -Step 3
Copy-UnattendToInstalledWindows -XmlPath $selectedXml -WindowsDrive "$windowsLetter`:"
Copy-SetupComplete -InstallRoot $installRoot -WindowsDrive "$windowsLetter`:"

Update-Ui -Ui $script:Ui -Percent 94 -Status 'Criando boot' -Detail 'Configurando arquivos de boot do Windows' -Step 4
# 8.8 Cria os arquivos de boot e tenta priorizar o Windows interno em UEFI.
Create-BootFiles -IsUefi $isUefi -SystemDrive $systemLetter -WindowsDrive "$windowsLetter`:"
Set-NextBootToInternalWindows -IsUefi $isUefi -SystemDrive $systemLetter

Update-Ui -Ui $script:Ui -Percent 100 -Status 'Instalacao concluida' -Detail ("{0} preparado com sucesso`r`nComputador: {1}`r`nDestino: disco {2} ({3}) - reiniciando" -f $chosenName, $machineModel, $targetDisk.Number, $targetDisk.BusType) -Step 4

try {
    [System.Windows.Forms.Application]::DoEvents()
} catch {}

# 8.9 Mostra a conclusao, atualiza boot e reinicia; wpeutil e o fallback do shutdown.
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
