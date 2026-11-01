<#
AplicarSlideshow.ps1
--------------------------------------------------------------------------
Aplica a pasta de imagens (Script\Wallpaper) como APRESENTACAO DE SLIDES
(papel de parede do Windows), trocando a imagem a cada 1 MINUTO, usando
a ferramenta NATIVA do Windows (Personalizacao > Plano de fundo > Slideshow).

- Nao instala nada e nao depende de programa externo.
- Copia a pasta INTEIRA para o disco local (C:\Windows\Setup\Scripts\Wallpaper)
  e aponta o slideshow para essa pasta.
- Usa as chaves nativas:
    HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers
        BackgroundType = 2  (Slideshow)
        SlideshowPath  = <pasta>
    HKCU\Control Panel\Personalization\Desktop Slideshow
        Interval = 60000    (1 minuto, em milissegundos)
        Shuffle  = 0/1
    HKCU\Control Panel\Desktop
        WallpaperStyle = 10  (Preencher/Fill)
        TileWallpaper  = 0

Uso:
    powershell -NoProfile -ExecutionPolicy Bypass -File AplicarSlideshow.ps1
    Parametros opcionais:
      -Pasta       (pasta de origem das imagens; se omitido, procura no pendrive)
      -Destino     (pasta no disco local; padrao C:\Windows\Setup\Scripts\Wallpaper)
      -IntervaloMs (intervalo entre imagens; padrao 60000 = 1 minuto)
      -Aleatorio   (embaralha a ordem das imagens)
#>

param(
    [string]$Pasta = '',
    [string]$Destino = 'C:\Windows\Setup\Scripts\Wallpaper',
    [int]$IntervaloMs = 60000,
    [switch]$Aleatorio
)

# O aplicador é um utilitário separado do painel. As etapas opcionais registram
# avisos e permitem que as alternativas de aplicação continuem sendo tentadas.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# Mostra o andamento no console e tenta gravar o mesmo texto no log do Windows.
# A indisponibilidade do log não impede a aplicação do plano de fundo.
function Log([string]$m) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $m
    Write-Host $line
    try { Add-Content -Path 'C:\Windows\Temp\AplicarSlideshow.log' -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# ---------------------------------------------------------------------------
# 1) Descobrir a pasta de origem das imagens (Wallpaper).
#    Prioridade: parametro -Pasta, pasta local ja copiada, e por fim pendrive.
# ---------------------------------------------------------------------------
function LocalizarPastaOrigem {
    param([string]$Preferida)

    # Os candidatos são avaliados em ordem, evitando consultas repetidas por nome.
    # Uma pasta só serve como origem se tiver imagens diretamente nela.
    $candidatos = New-Object System.Collections.Generic.List[string]
    if ($Preferida -and (Test-Path -LiteralPath $Preferida)) { $candidatos.Add($Preferida) }
    if ($Destino -and (Test-Path -LiteralPath $Destino)) { $candidatos.Add($Destino) }

    # Procura "Script\Wallpaper" em todas as unidades (pendrive / midia).
    foreach ($letra in @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z','C')) {
        $candidatos.Add(($letra + ':\Script\Wallpaper'))
        $candidatos.Add(($letra + ':\Script\Wallpaper\Wallpaper'))
        $candidatos.Add(($letra + ':\Wallpaper'))
    }

    # A expressão aceita as extensões listadas sem diferenciar maiúsculas.
    foreach ($c in ($candidatos | Select-Object -Unique)) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $imgs = @(Get-ChildItem -LiteralPath $c -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -match '(?i)\.(jpg|jpeg|png|bmp|gif|tif|tiff|webp)$'
            })
            if ($imgs.Count -gt 0) { return $c }
        }
    }
    return $null
}

# Helpers de segurança da etapa de cópia; não alteram o sistema por conta própria.
function Get-CaminhoComparavel {
    param([string]$Caminho)

    # Normaliza aliases como "." e ".." antes de comparar ou remover pastas.
    return [IO.Path]::GetFullPath($Caminho).TrimEnd('\', '/')
}

function Test-CopiaSegura {
    param([string]$Origem, [string]$Destino)

    try {
        $a = Get-CaminhoComparavel $Origem
        $b = Get-CaminhoComparavel $Destino
        # Caminhos equivalentes serão reutilizados, sem remoção ou cópia.
        if ($a -ieq $b) { return $true }

        $raiz = Get-CaminhoComparavel ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destino)))
        if ($b -ieq $raiz) { return $false }

        # Rejeita tanto destino ancestral (apagaria a origem) como destino
        # descendente (criaria uma cópia recursiva dentro da própria origem).
        return (-not $a.StartsWith($b + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
                -not $b.StartsWith($a + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))
    } catch {
        return $false
    }
}

# A origem pode continuar vazia quando não há mídia disponível. Mais abaixo,
# a validação ainda permite utilizar uma pasta de destino local já existente.
$origem = LocalizarPastaOrigem -Preferida $Pasta

# ---------------------------------------------------------------------------
# 2) Copiar a pasta INTEIRA para o disco local (uma unica vez), se necessario.
#    O slideshow nativo le a pasta local, entao o pendrive pode ser removido.
# ---------------------------------------------------------------------------
if ($origem) {
    # A validação acontece antes da remoção e fora do catch de cópia, para que
    # uma rejeição de caminho também não alcance a alternativa Copy-Item.
    if (-not (Test-CopiaSegura -Origem $origem -Destino $Destino)) {
        Log 'ERRO: copia recusada. O destino deve ser uma pasta separada da origem e nao pode ser a raiz de uma unidade.'
        exit 1
    }

    if ((Get-CaminhoComparavel $origem) -ieq (Get-CaminhoComparavel $Destino)) {
        Log "Pasta de origem e destino iguais (ja local): $Destino"
    } else {
        Log "Copiando pasta inteira de '$origem' para '$Destino'..."
        try {
            if (Test-Path -LiteralPath $Destino) { Remove-Item -LiteralPath $Destino -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $Destino -Force | Out-Null

            # Prefere o utilitário do próprio Windows. A cópia inclui todos os
            # arquivos e subpastas, não apenas as extensões de imagem aceitas.
            $robocopy = Join-Path $env:SystemRoot 'System32\Robocopy.exe'
            $copiou = $false
            if (Test-Path -LiteralPath $robocopy) {
                # /E copia subpastas (inclusive vazias); traz a pasta completa de uma vez.
                & $robocopy $origem $Destino /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                # Robocopy usa 0 a 7 para resultados sem falha; 8 ou mais
                # exigem a cópia alternativa. Não repete transferências válidas.
                $copiou = ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -lt 8)
            }

            if (-not $copiou) {
                # Fallback: copia o conteudo da pasta (nao a pasta em si) para o destino.
                Copy-Item -Path (Join-Path $origem '*') -Destination $Destino -Recurse -Force -ErrorAction Stop
            }
            Log 'Copia concluida.'
        } catch {
            Log ('Aviso: falha ao copiar a pasta (' + $_.Exception.Message + '). Tentando copia simples.')
            try { Copy-Item -Path (Join-Path $origem '*') -Destination $Destino -Recurse -Force -ErrorAction Stop } catch { Log ('Erro ao copiar pasta: ' + $_.Exception.Message) }
        }
    }
}

# Valida o conteúdo final antes de alterar as preferências de plano de fundo.
# A contagem usa somente os arquivos diretamente dentro da pasta de destino.
if (-not (Test-Path -LiteralPath $Destino)) {
    Log "ERRO: pasta de imagens nao encontrada (origem='$origem', destino='$Destino'). Slideshow nao aplicado."
    exit 1
}

$imagens = @(Get-ChildItem -LiteralPath $Destino -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -match '(?i)\.(jpg|jpeg|png|bmp|gif|tif|tiff|webp)$'
})
if ($imagens.Count -eq 0) {
    Log "ERRO: nenhuma imagem valida encontrada em '$Destino'. Slideshow nao aplicado."
    exit 1
}
Log ("Imagens encontradas: {0}" -f $imagens.Count)

# ---------------------------------------------------------------------------
# 3) Aplicar o slideshow NATIVO do Windows via registro (HKCU).
# ---------------------------------------------------------------------------
try {
    $keyWallpapers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    $keySlideshow  = 'HKCU:\Control Panel\Personalization\Desktop Slideshow'
    $keyDesktop    = 'HKCU:\Control Panel\Desktop'

    # Cria somente as chaves ausentes; os valores são atualizados logo depois.
    foreach ($k in @($keyWallpapers, $keySlideshow, $keyDesktop)) {
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    }

    # Tipo de plano de fundo = Slideshow (2) e a pasta selecionada.
    New-ItemProperty -Path $keyWallpapers -Name 'BackgroundType' -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $keyWallpapers -Name 'SlideshowPath'  -Value $Destino -PropertyType String -Force | Out-Null

    # Intervalo de troca (ms) e embaralhar.
    New-ItemProperty -Path $keySlideshow -Name 'Interval' -Value $IntervaloMs -PropertyType DWord -Force | Out-Null
    $shuffle = if ($Aleatorio) { 1 } else { 0 }
    New-ItemProperty -Path $keySlideshow -Name 'Shuffle'  -Value $shuffle -PropertyType DWord -Force | Out-Null

    # Estilo de ajuste da imagem: Preencher (Fill) = 10.
    New-ItemProperty -Path $keyDesktop -Name 'WallpaperStyle' -Value '10' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyDesktop -Name 'TileWallpaper'  -Value '0'  -PropertyType String -Force | Out-Null

    Log 'Registro do slideshow nativo configurado com sucesso.'
} catch {
    Log ('Erro ao configurar o registro do slideshow: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# 4) Registrar a pasta como album conhecido do Windows (para ela aparecer em
#    Personalizacao > Plano de fundo) - nao obrigatorio, mas ajuda o usuario.
# ---------------------------------------------------------------------------
try {
    # HKLM exige permissão administrativa. Falhas nesta etapa são opcionais e
    # não impedem a tentativa seguinte pela API de slideshow do usuário.
    $mergeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers\knownfolders\0\Windows Wallpapers\MergeFolders'
    if (-not (Test-Path $mergeKey)) { New-Item -Path $mergeKey -Force | Out-Null }
    $nome = 'PichauWallpaper_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8))
    New-ItemProperty -Path $mergeKey -Name $nome -Value $Destino -PropertyType ExpandString -Force | Out-Null
    Log "Pasta registrada como album conhecido: $Destino"
} catch {
    Log ('Aviso: nao foi possivel registrar a pasta como album (opcional): ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# 5) Aplicar a PASTA como slideshow NATIVO do Windows, sem reiniciar.
#    Usa a API oficial IDesktopWallpaper (a mesma que a tela de Personalizacao usa).
#    IMPORTANTE: SetSlideshow recebe a PASTA INTEIRA (nao uma imagem), portanto o
#    Windows roda o slideshow com todas as imagens, trocando a cada IntervaloMs.
# ---------------------------------------------------------------------------
try {
    # O bloco C# declara os contratos COM/P/Invoke e efetiva a pasta no Windows.
    # A ordem dos métodos de IDesktopWallpaper acompanha a interface nativa,
    # inclusive métodos não chamados, pois determina sua posição na vtable.
    # Os enums representam os valores esperados pela API, e RECT descreve
    # a estrutura do monitor. Nenhum processo externo é necessário nesta etapa.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PichauWallpaper {
    // Interface oficial do Windows que a tela de Personalizacao usa (shobjidl_core.h).
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDesktopWallpaper {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
        uint GetMonitorDevicePathCount();
        void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out RECT displayRect);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(DESKTOP_WALLPAPER_POSITION position);
        DESKTOP_WALLPAPER_POSITION GetPosition();
        // Recebe um IShellItemArray (a PASTA com todas as imagens do slideshow).
        void SetSlideshow([MarshalAs(UnmanagedType.Interface)] object items);
        void GetSlideshow([MarshalAs(UnmanagedType.Interface)] out object items);
        void SetSlideshowOptions(DESKTOP_SLIDESHOW_OPTIONS options, uint slideshowTick);
        void GetSlideshowOptions(out DESKTOP_SLIDESHOW_OPTIONS options, out uint slideshowTick);
        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, DESKTOP_SLIDESHOW_DIRECTION direction);
        DESKTOP_WALLPAPER_STATUS GetStatus();
        void Enable(bool enable);
    }

    public enum DESKTOP_WALLPAPER_POSITION { DWPOS_CENTER = 0, DWPOS_TILE = 1, DWPOS_STRETCH = 2, DWPOS_FIT = 3, DWPOS_FILL = 4, DWPOS_SPAN = 5 }
    [Flags] public enum DESKTOP_SLIDESHOW_OPTIONS : uint { DSO_SHUFFLEIMAGES = 0x1 }
    public enum DESKTOP_SLIDESHOW_DIRECTION { DSD_FORWARD = 0, DSD_BACKWARD = 1 }
    public enum DESKTOP_WALLPAPER_STATUS { DWS_DISABLED = 0, DWS_ENABLED = 1 }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }

    [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
    public class DesktopWallpaperClass { }

    public static class Wallpaper {
        // Cria um IShellItem a partir do caminho da pasta.
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPath, IntPtr pbc,
            ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);

        // Cria um IShellItemArray a partir de um unico IShellItem (a pasta).
        // SetSlideshow usa esse array para incluir TODAS as imagens da pasta.
        [DllImport("shell32.dll", PreserveSig = false)]
        private static extern void SHCreateShellItemArrayFromShellItem(
            [MarshalAs(UnmanagedType.Interface)] object psi,
            ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppsiItemArray);

        public static void Efetivar(string pasta, uint intervaloMs, bool aleatorio) {
            Guid iidShellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"); // IShellItem
            object shellItem;
            SHCreateItemFromParsingName(pasta, IntPtr.Zero, ref iidShellItem, out shellItem);

            Guid iidShellItemArray = new Guid("B63EA76D-1F85-456F-A19C-48159EFA858B"); // IShellItemArray
            object shellItemArray;
            SHCreateShellItemArrayFromShellItem(shellItem, ref iidShellItemArray, out shellItemArray);

            IDesktopWallpaper dw = (IDesktopWallpaper)new DesktopWallpaperClass();
            dw.SetSlideshowOptions(aleatorio ? DESKTOP_SLIDESHOW_OPTIONS.DSO_SHUFFLEIMAGES : 0, intervaloMs);
            dw.SetPosition(DESKTOP_WALLPAPER_POSITION.DWPOS_FILL);
            // Aponta o slideshow para a PASTA INTEIRA (nao para uma imagem).
            dw.SetSlideshow(shellItemArray);
        }
    }
}
'@ -ErrorAction Stop

    # Converte os parâmetros PowerShell para os tipos esperados pelo método C#.
    $aleatorio = [bool]$Aleatorio
    [PichauWallpaper.Wallpaper]::Efetivar($Destino, [uint32]$IntervaloMs, $aleatorio)
    Log 'Slideshow NATIVO aplicado a partir da PASTA (sem definir imagem individual).'
} catch {
    Log ('Aviso: falha ao aplicar o slideshow via API nativa (' + $_.Exception.Message + '). Tentando recarregar as configuracoes.')
    # Fallback: forca o Windows a reler o plano de fundo (mantendo o slideshow por pasta).
    try {
        Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@ -ErrorAction SilentlyContinue
        # 0x0014 solicita atualização do papel de parede; a flag 3 combina
        # atualização das preferências e notificação dos aplicativos.
        $SPI_SETDESKWALLPAPER = 0x0014
        [void][Win32.Native]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $null, 3)
    } catch {}
}

# Encerramento do fluxo: os detalhes das tentativas e dos avisos ficam no log.
Log ("Slideshow configurado: pasta='$Destino' | imagens={0} | intervalo={1}ms" -f $imagens.Count, $IntervaloMs)
exit 0
