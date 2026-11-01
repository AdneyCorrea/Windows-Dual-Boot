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
        private const int SPI_SETDESKWALLPAPER = 0x0014;
        private const int SPIF_UPDATEINIFILE = 0x0001;
        private const int SPIF_SENDCHANGE = 0x0002;

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

        private static readonly string[] ExtensoesImagem =
            { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".webp" };

        private static int Main(string[] args)
        {
            bool aleatorio = false, semCopiar = false, semPausa = false;
            string pasta = null, destino = @"C:\Windows\Setup\Scripts\Wallpaper";
            int intervaloMs = 60000;

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

        private static bool MesmoCaminho(string a, string b)
        {
            if (a == null || b == null) return false;
            return string.Equals(a.TrimEnd('\\'), b.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }

        private static bool CopiarPasta(string origem, string destino)
        {
            try
            {
                if (Directory.Exists(destino)) Directory.Delete(destino, true);
                Directory.CreateDirectory(destino);
            }
            catch { }

            // Preferencia: robocopy (copia a pasta inteira de uma vez).
            try
            {
                string robocopy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "Robocopy.exe");
                if (File.Exists(robocopy))
                {
                    var psi = new ProcessStartInfo(robocopy,
                        "\"" + origem + "\" \"" + destino + "\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP");
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    using (var p = Process.Start(psi)) p.WaitForExit(120000);
                }
            }
            catch { }

            // Fallback: copia recursiva manual (garante funcionar em qualquer caso).
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

        private static bool AplicarSlideshowNativo(string pasta, int intervaloMs, bool aleatorio)
        {
            try
            {
                object shellItem;
                Guid iidShellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                SHCreateItemFromParsingName(pasta, IntPtr.Zero, ref iidShellItem, out shellItem);

                object shellItemArray;
                Guid iidArray = new Guid("B63EA76D-1F85-456F-A19C-48159EFA858B");
                SHCreateShellItemArrayFromShellItem(shellItem, ref iidArray, out shellItemArray);

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

        private static void RelerWallpaper()
        {
            try { SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, null, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE); }
            catch { }
        }

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
        private const uint DSO_SHUFFLEIMAGES = 0x1;
        private const int DWPOS_FILL = 4;

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

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int left, top, right, bottom; }

        [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
        private class DesktopWallpaperClass { }
    }
}
