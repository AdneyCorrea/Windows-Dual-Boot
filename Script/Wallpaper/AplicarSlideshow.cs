// ============================================================================
// APLICADOR AUTÔNOMO DE SLIDESHOW DO WINDOWS
// ============================================================================
// Esta versão C# funciona como utilitário separado do painel de diagnóstico.
// Fluxo: argumentos -> localizar imagens -> copiar -> configurar registro ->
// aplicar a pasta pela API COM do Windows -> solicitar releitura -> encerrar.
// As declarações de interoperabilidade ficam no final e seguem o contrato do SO.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace PichauSlideshow
{
    // Executavel autonomo que aplica a pasta "Wallpaper" como APRESENTACAO DE SLIDES
    // (papel de parede) usando a API NATIVA do Windows (IDesktopWallpaper).
    //
    // - Nao depende de PowerShell nem de ExecutionPolicy.
    // - Copia a pasta INTEIRA para o disco local e a define como slideshow.
    // - Troca de imagem a cada 1 minuto (configuravel).
    //
    // Uso:
    //   AplicarSlideshow.exe                 -> copia/usa C:\Windows\Setup\Scripts\Wallpaper
    //   AplicarSlideshow.exe -Aleatorio      -> embaralha as imagens
    //   AplicarSlideshow.exe -SemCopiar      -> nao copia; usa a pasta de destino atual
    internal static class Program
    {
        // Constantes e chamada Win32 usadas para pedir a releitura do wallpaper.
        private const int SPI_SETDESKWALLPAPER = 0x0014;
        private const int SPIF_UPDATEINIFILE = 0x0001;
        private const int SPIF_SENDCHANGE = 0x0002;

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

        // Formatos aceitos na descoberta e na contagem das imagens da pasta.
        private static readonly string[] ExtensoesImagem =
            { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".webp" };

        // --------------------------------------------------------------------
        // 1. ENTRADA, PREPARAÇÃO DAS IMAGENS E APLICAÇÃO
        // --------------------------------------------------------------------
        // Interpreta as opções sem diferenciar maiúsculas/minúsculas. As opções
        // de caminho e intervalo consomem o argumento seguinte quando disponível.
        private static int Main(string[] args)
        {
            bool aleatorio = false, semCopiar = false, semPausa = false;
            string pasta = null, destino = @"C:\Windows\Setup\Scripts\Wallpaper";
            int intervaloMs = 60000;

            // Mantém os valores padrão quando uma opção não tem valor válido.
            // O intervalo informado é aceito somente a partir de 1.000 ms.
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "-aleatorio" || a == "/aleatorio") aleatorio = true;
                else if (a == "-semcopiar" || a == "/semcopiar") semCopiar = true;
                else if (a == "-sempausa" || a == "/sempausa") semPausa = true;
                else if ((a == "-pasta" || a == "/pasta") && i + 1 < args.Length) pasta = args[++i];
                else if ((a == "-destino" || a == "/destino") && i + 1 < args.Length) destino = args[++i];
                else if ((a == "-intervalo" || a == "/intervalo") && i + 1 < args.Length)
                {
                    int v; if (int.TryParse(args[++i], out v) && v >= 1000) intervaloMs = v;
                }
            }

            // O mesmo diagnóstico é mostrado no console e salvo no log temporário.
            Console.OutputEncoding = Encoding.UTF8;
            Log("==== AplicarSlideshow (executavel) ====");
            Log("Pasta de imagens (destino local): " + destino);
            Log("Intervalo: " + intervaloMs + " ms");

            // 1) Localizar a pasta de origem (parametro, destino local ou pendrive).
            string origem = LocalizarOrigem(pasta, destino);
            if (origem == null)
            {
                Log("ERRO: nenhuma pasta com imagens foi encontrada. Informe -Pasta \"D:\\Script\\Wallpaper\".");
                return Fim(1, semPausa);
            }
            Log("Origem das imagens: " + origem);

            // 2) Copiar a pasta INTEIRA para o disco local (uma unica vez).
            if (!semCopiar && !MesmoCaminho(origem, destino))
            {
                Log("Copiando a pasta inteira para o disco local...");
                if (!CopiarPasta(origem, destino))
                {
                    Log("AVISO: falha ao copiar; tentando usar a origem diretamente.");
                    destino = origem;
                }
                else Log("Copia concluida.");
            }
            else
            {
                Log("Copia ignorada (origem == destino ou -SemCopiar).");
            }

            // Confirma a presença de uma pasta de destino com imagens aceitas
            // antes de alterar o registro e a configuração de plano de fundo.
            if (!Directory.Exists(destino))
            {
                Log("ERRO: pasta de destino nao existe: " + destino);
                return Fim(1, semPausa);
            }

            int qtd = ContarImagens(destino);
            if (qtd == 0)
            {
                Log("ERRO: nenhuma imagem valida encontrada em " + destino);
                return Fim(1, semPausa);
            }
            Log("Imagens encontradas: " + qtd);

            // 3) Configurar o registro (fallback e para a tela de Personalizacao).
            ConfigurarRegistro(destino, intervaloMs, aleatorio);

            // 4) Aplicar a PASTA como slideshow pela API nativa.
            bool ok = AplicarSlideshowNativo(destino, intervaloMs, aleatorio);
            if (ok) Log("Slideshow NATIVO aplicado a partir da PASTA (sem definir imagem individual).");
            else Log("AVISO: a API nativa falhou; a configuracao de registro foi gravada como fallback.");

            // 5) Forcar o Windows a reler o plano de fundo (sem definir imagem individual).
            RelerWallpaper();

            Log("Concluido: pasta='" + destino + "' | imagens=" + qtd + " | intervalo=" + intervaloMs + "ms");
            return Fim(0, semPausa);
        }

        // --------------------------------------------------------------------
        // 2. MENSAGENS E ENCERRAMENTO
        // --------------------------------------------------------------------
        // Devolve o código de saída e mantém a janela aberta, salvo -SemPausa.
        // A leitura de tecla pode falhar quando não há console interativo.
        private static int Fim(int codigo, bool semPausa)
        {
            if (!semPausa)
            {
                Console.WriteLine();
                Console.WriteLine("Pressione qualquer tecla para fechar...");
                try { Console.ReadKey(true); } catch { }
            }
            return codigo;
        }

        // Grava data e hora local. Falhas no arquivo de log não interrompem a
        // configuração do slideshow; a mensagem do console continua disponível.
        private static void Log(string m)
        {
            string linha = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + m;
            Console.WriteLine(linha);
            try
            {
                string log = Path.Combine(Path.GetTempPath(), "AplicarSlideshow.log");
                File.AppendAllText(log, linha + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        // --------------------------------------------------------------------
        // 3. DESCOBERTA E CÓPIA DAS PASTAS
        // --------------------------------------------------------------------
        // Prioriza -Pasta, depois o destino local e por fim as unidades listadas.
        // O primeiro candidato existente com imagens diretamente nele é usado.
        private static string LocalizarOrigem(string preferida, string destino)
        {
            var candidatos = new List<string>();
            if (!string.IsNullOrEmpty(preferida)) candidatos.Add(preferida);
            if (!string.IsNullOrEmpty(destino)) candidatos.Add(destino);

            // Procura "Script\Wallpaper" e "Wallpaper" em todas as unidades (pendrive).
            foreach (char c in "DEFGHIJKLMNOPQRSTUVWXYZC")
            {
                candidatos.Add(c + @":\Script\Wallpaper");
                candidatos.Add(c + @":\Wallpaper");
            }

            // Evita repetir candidatos que diferem apenas no uso de maiúsculas.
            var vistos = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string cand in candidatos)
            {
                if (string.IsNullOrEmpty(cand) || !vistos.Add(cand)) continue;
                try
                {
                    if (Directory.Exists(cand) && ContarImagens(cand) > 0) return cand;
                }
                catch { }
            }
            return null;
        }

        // Conta somente arquivos da própria pasta, sem percorrer subpastas.
        // Pastas inacessíveis retornam a quantidade acumulada até a falha.
        private static int ContarImagens(string pasta)
        {
            int n = 0;
            try
            {
                foreach (string f in Directory.GetFiles(pasta))
                {
                    string ext = Path.GetExtension(f).ToLowerInvariant();
                    foreach (string e in ExtensoesImagem) if (ext == e) { n++; break; }
                }
            }
            catch { }
            return n;
        }

        // Normaliza os caminhos para reconhecer também aliases como "." e "..".
        // A comparação não resolve links simbólicos nem pontos de montagem.
        private static bool MesmoCaminho(string a, string b)
        {
            if (a == null || b == null) return false;
            try
            {
                return string.Equals(CaminhoComparavel(a), CaminhoComparavel(b), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        // Retira separadores finais depois de resolver o caminho absoluto.
        private static string CaminhoComparavel(string caminho)
        {
            return Path.GetFullPath(caminho).TrimEnd('\\', '/');
        }

        // Impede que a substituição do destino apague uma raiz de volume ou a
        // origem. Pastas aninhadas também criariam recursão durante a cópia.
        private static bool CopiaSegura(string origem, string destino)
        {
            try
            {
                string a = CaminhoComparavel(origem);
                string b = CaminhoComparavel(destino);
                if (string.Equals(a, b, StringComparison.OrdinalIgnoreCase)) return true;
                string raiz = CaminhoComparavel(Path.GetPathRoot(Path.GetFullPath(destino)));
                if (string.Equals(b, raiz, StringComparison.OrdinalIgnoreCase)) return false;
                return !a.StartsWith(b + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    && !b.StartsWith(a + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        // Prepara o destino e tenta Robocopy antes de recorrer à cópia C#.
        // O sucesso exige encontrar ao menos uma imagem válida no destino.
        private static bool CopiarPasta(string origem, string destino)
        {
            if (!CopiaSegura(origem, destino))
            {
                Log("ERRO: copia recusada. O destino deve ser uma pasta separada da origem e nao pode ser a raiz de uma unidade.");
                return false;
            }
            if (MesmoCaminho(origem, destino)) return true;

            try
            {
                // O fluxo atual substitui o conteúdo anterior do destino.
                if (Directory.Exists(destino)) Directory.Delete(destino, true);
                Directory.CreateDirectory(destino);
            }
            catch { }

            // Preferencia: robocopy (copia a pasta inteira de uma vez).
            try
            {
                string robocopy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "Robocopy.exe");
                if (TentarRobocopy(origem, destino, robocopy)) return ContarImagens(destino) > 0;
            }
            catch (TimeoutException ex)
            {
                // Sem confirmação de encerramento não inicia outra cópia sobre
                // o mesmo destino; o chamador ainda pode utilizar a pasta origem.
                Log("Erro ao aguardar Robocopy: " + ex.Message);
                return false;
            }
            catch { }

            // Só recorre à cópia manual se Robocopy faltar, falhar ou exceder a
            // espera. Códigos de sucesso não repetem a transferência dos arquivos.
            try
            {
                CopiarRecursivo(origem, destino);
                return ContarImagens(destino) > 0;
            }
            catch (Exception ex)
            {
                Log("Erro ao copiar: " + ex.Message);
                return false;
            }
        }

        // /E inclui subpastas vazias; /R:1 e /W:1 limitam tentativas e espera.
        // O Windows considera 0 a 7 resultados sem falha de cópia; 8 ou mais
        // indicam erro. Sem conclusão em dois minutos, a alternativa é usada.
        private static bool TentarRobocopy(string origem, string destino, string robocopy)
        {
            if (!File.Exists(robocopy)) return false;
            var psi = new ProcessStartInfo(robocopy,
                "\"" + origem + "\" \"" + destino + "\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            using (var p = Process.Start(psi))
            {
                if (!p.WaitForExit(120000))
                {
                    // Encerra somente este processo e confirma sua saída antes
                    // de permitir que a cópia manual use o mesmo destino.
                    try { p.Kill(); }
                    catch
                    {
                        if (!p.HasExited) throw new TimeoutException("Nao foi possivel encerrar a copia que excedeu o tempo limite.");
                    }
                    if (!p.WaitForExit(5000)) throw new TimeoutException("Robocopy nao encerrou apos a solicitacao de parada.");
                    return false;
                }
                return p.ExitCode >= 0 && p.ExitCode < 8;
            }
        }

        // Recria a árvore de diretórios e copia todos os arquivos, incluindo
        // arquivos auxiliares que não fazem parte da contagem de imagens.
        private static void CopiarRecursivo(string origem, string destino)
        {
            Directory.CreateDirectory(destino);
            foreach (string dir in Directory.GetDirectories(origem))
            {
                string alvo = Path.Combine(destino, Path.GetFileName(dir));
                CopiarRecursivo(dir, alvo);
            }
            foreach (string file in Directory.GetFiles(origem))
            {
                File.Copy(file, Path.Combine(destino, Path.GetFileName(file)), true);
            }
        }

        // --------------------------------------------------------------------
        // 4. CONFIGURAÇÃO DO USUÁRIO E API NATIVA
        // --------------------------------------------------------------------
        // Configura as preferências HKCU do usuário atual: tipo slideshow,
        // pasta, intervalo, ordem aleatória e preenchimento da área de trabalho.
        private static void ConfigurarRegistro(string pasta, int intervaloMs, bool aleatorio)
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers"))
                {
                    k.SetValue("BackgroundType", 2, RegistryValueKind.DWord);
                    k.SetValue("SlideshowPath", pasta, RegistryValueKind.String);
                }
                using (var k = Registry.CurrentUser.CreateSubKey(@"Control Panel\Personalization\Desktop Slideshow"))
                {
                    k.SetValue("Interval", intervaloMs, RegistryValueKind.DWord);
                    k.SetValue("Shuffle", aleatorio ? 1 : 0, RegistryValueKind.DWord);
                }
                using (var k = Registry.CurrentUser.CreateSubKey(@"Control Panel\Desktop"))
                {
                    k.SetValue("WallpaperStyle", "10", RegistryValueKind.String); // Preencher
                    k.SetValue("TileWallpaper", "0", RegistryValueKind.String);
                }
                Log("Registro do slideshow configurado (fallback/Personalizacao).");
            }
            catch (Exception ex)
            {
                Log("AVISO: nao foi possivel gravar o registro: " + ex.Message);
            }
        }

        // Converte a pasta em objetos do Shell aceitos por IDesktopWallpaper.
        // A configuração no registro já foi tentada quando esta etapa é chamada.
        private static bool AplicarSlideshowNativo(string pasta, int intervaloMs, bool aleatorio)
        {
            try
            {
                // IShellItem representa o caminho; IShellItemArray é a coleção
                // exigida pela chamada SetSlideshow do Windows.
                object shellItem;
                Guid iidShellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                SHCreateItemFromParsingName(pasta, IntPtr.Zero, ref iidShellItem, out shellItem);

                object shellItemArray;
                Guid iidArray = new Guid("B63EA76D-1F85-456F-A19C-48159EFA858B");
                SHCreateShellItemArrayFromShellItem(shellItem, ref iidArray, out shellItemArray);

                // Ativa as opções antes de associar a pasta ao slideshow.
                var dw = (IDesktopWallpaper)new DesktopWallpaperClass();
                dw.SetSlideshowOptions(aleatorio ? DSO_SHUFFLEIMAGES : 0, (uint)intervaloMs);
                dw.SetPosition(DWPOS_FILL);
                dw.SetSlideshow(shellItemArray);
                return true;
            }
            catch (Exception ex)
            {
                Log("Erro na API nativa: " + ex.Message);
                return false;
            }
        }

        // Solicita atualização das preferências sem escolher uma imagem avulsa.
        private static void RelerWallpaper()
        {
            try { SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, null, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE); }
            catch { }
        }

        // --------------------------------------------------------------------
        // 5. INTEROPERABILIDADE COM O WINDOWS (P/INVOKE E COM)
        // --------------------------------------------------------------------
        // PreserveSig=false converte HRESULT de falha em exceções .NET, tratadas
        // pela etapa de aplicação. Os GUIDs identificam as interfaces do Shell.
        // ---- P/Invoke -------------------------------------------------------
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPath, IntPtr pbc,
            ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);

        [DllImport("shell32.dll", PreserveSig = false)]
        private static extern void SHCreateShellItemArrayFromShellItem(
            [MarshalAs(UnmanagedType.Interface)] object psi,
            ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppsiItemArray);

        // ---- COM IDesktopWallpaper (shobjidl_core.h) ------------------------
        // Valores nativos: embaralhar as imagens e preencher a área do monitor.
        private const uint DSO_SHUFFLEIMAGES = 0x1;
        private const int DWPOS_FILL = 4;

        // A ordem dos métodos deve acompanhar a interface COM original mesmo
        // para métodos não chamados aqui, pois determina sua posição na vtable.
        [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDesktopWallpaper
        {
            void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
            [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
            [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
            uint GetMonitorDevicePathCount();
            void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out RECT displayRect);
            void SetBackgroundColor(uint color);
            uint GetBackgroundColor();
            void SetPosition(int position);
            int GetPosition();
            void SetSlideshow([MarshalAs(UnmanagedType.Interface)] object items);
            void GetSlideshow([MarshalAs(UnmanagedType.Interface)] out object items);
            void SetSlideshowOptions(uint options, uint slideshowTick);
            void GetSlideshowOptions(out uint options, out uint slideshowTick);
            void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
            int GetStatus();
            void Enable(bool enable);
        }

        // Estrutura compatível com RECT, utilizada pelo contrato do monitor.
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int left, top, right, bottom; }

        // Classe COM que fornece a implementação de IDesktopWallpaper no SO.
        [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
        private class DesktopWallpaperClass { }
    }
}
