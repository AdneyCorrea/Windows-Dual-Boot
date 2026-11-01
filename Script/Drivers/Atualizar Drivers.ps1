
<#
Atualizar Drivers.ps1 - V11.3 IDS EXATOS / CACHE / RAPIDO / VIDEO PRIMEIRO + REDE/WIFI PRIORITARIO
- Video antes do chipset; seleciona IDs completos nas secoes Models, nao por trechos do INF.
- Filtra arquitetura/build; indexa modelos uma vez e evita repetir instalacoes e timeouts.
- Expande somente macros presentes na linha, pre-filtra INFs e usa prazo proprio para video.
- No modo normal, complementos por pasta sao limitados aos dispositivos pendentes.
- Para Intel Ultra: primeiro tenta INFs exatos rapidamente; se sobrar driver, cai no lote do Chipset Ultra.
- Evita testar INF NVIDIA problematica nvmdi.inf por padrao, pois gerava timeout.
- Adiciona fase prioritaria para Rede/WiFi, incluindo Intel, Realtek, Qualcomm/Atheros, MediaTek/Ralink e Broadcom.
#>
# ===========================================================================
# 1. PARAMETROS E PREPARACAO DO AMBIENTE
# ===========================================================================
# ModoCompleto amplia a busca; TodosErros inclui todos os codigos PnP diferentes de zero.
# ForcarLoteFabricante/ForcarVideoLote habilitam tentativas em lote.
# UseDismFallback habilita DISM; SemLoteUltra impede o lote especifico Intel Ultra.
# NaoPausar e mantido como parametro de compatibilidade dos chamadores.
# Os limites abaixo controlam tempo por lote/INF e quantidade de candidatos.
param(
    [switch]$ModoCompleto,
    [switch]$TodosErros,
    [switch]$ForcarLoteFabricante,
    [switch]$ForcarVideoLote,
    [switch]$UseDismFallback,
    [switch]$SemLoteUltra,
    [switch]$NaoPausar,
    [int]$BatchTimeoutSec = 360,
    [int]$InfTimeoutSec = 35,
    # Pacotes de video grandes precisam de prazo proprio; nao sao varias tentativas.
    [int]$VideoTimeoutSec = 180,
    [int]$MaxCandidatesPerDevice = 2
)
$ErrorActionPreference='Continue'
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle='Atualizar Drivers' } catch {}

# Corrige erro inicial quando o script e chamado de formas diferentes.
# Em alguns cenarios, $MyInvocation.MyCommand.Path vem nulo dentro de funcoes.
$script:ScriptDir = $null
try { if ($PSScriptRoot) { $script:ScriptDir = $PSScriptRoot } } catch {}
if (-not $script:ScriptDir) { try { if ($PSCommandPath) { $script:ScriptDir = Split-Path -Parent $PSCommandPath } } catch {} }
if (-not $script:ScriptDir) { try { $mp = $MyInvocation.MyCommand.Path; if ($mp) { $script:ScriptDir = Split-Path -Parent $mp } } catch {} }
if (-not $script:ScriptDir) { try { $script:ScriptDir = (Get-Location).Path } catch {} }

# ===========================================================================
# 2. LOCALIZACAO DO REPOSITORIO, LOG E EXECUCAO DE COMANDOS DO WINDOWS
# ===========================================================================
# Confere se o processo atual possui privilegios de administrador.
function IsAdmin {
    try {
        $id=[Security.Principal.WindowsIdentity]::GetCurrent()
        $p=New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
# Procura DriversRepo junto ao script, nos diretorios superiores e nas unidades locais.
function FindRepo {
    $list=@()
    $sd=$script:ScriptDir
    if($sd){
        $list += (Join-Path $sd 'DriversRepo')
        try { $parent = Split-Path -Parent $sd; if($parent){ $list += (Join-Path $parent 'DriversRepo') } } catch {}
        try { $grandParent = Split-Path -Parent $parent; if($grandParent){ $list += (Join-Path $grandParent 'DriversRepo') } } catch {}
        try { $greatGrandParent = Split-Path -Parent $grandParent; if($greatGrandParent){ $list += (Join-Path $greatGrandParent 'DriversRepo') } } catch {}
    }
    $list += 'D:\DriversRepo','E:\DriversRepo','F:\DriversRepo','G:\DriversRepo','C:\DriversRepo'
    try { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3" | ForEach-Object { $list += (Join-Path ($_.DeviceID+'\') 'DriversRepo') } } catch {}
    foreach($p in ($list|Select-Object -Unique)){
        if($p -and (Test-Path -LiteralPath $p) -and ((Test-Path -LiteralPath (Join-Path $p 'INTEL')) -or (Test-Path -LiteralPath (Join-Path $p 'AMD')) -or (Test-Path -LiteralPath (Join-Path $p 'NVIDIA')))){
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $null
}
# Resolve o repositorio antes de criar o log que sera usado pelas etapas seguintes.
$Repo=FindRepo
if(-not $Repo){ Write-Host 'ERRO: DriversRepo nao encontrado.' -ForegroundColor Red; exit 2 }
$LogDir=Join-Path $Repo '_Logs'; New-Item -ItemType Directory -Path $LogDir -Force|Out-Null
$Stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$Log=Join-Path $LogDir "AtualizarDrivers_$Stamp.log"
# Grava uma mensagem com data no log e repete a mensagem colorida no console.
function L([string]$m,[ConsoleColor]$c=[ConsoleColor]::Gray){
    $line='[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m
    Add-Content -Path $Log -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $m -ForegroundColor $c
}

# Grava comandos temporarios na codificacao OEM para preservar caminhos com simbolos.
function Write-OemFile([string]$Path,[string]$Text){
    try{
        $cp=[Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        $enc=[Text.Encoding]::GetEncoding($cp)
        [IO.File]::WriteAllText($Path,$Text,$enc)
    } catch {
        # Fallback: evita ASCII, pois ASCII quebra caminhos como INTEL\4º.
        [IO.File]::WriteAllText($Path,$Text,[Text.Encoding]::Default)
    }
}
# Executa um comando em .cmd temporario, limita sua duracao e captura codigo/saida.
# Em timeout, encerra a arvore do comando e preserva a saida parcial no log.
# O bloco finally remove os arquivos temporarios e libera o objeto do processo.
function RunCmd([string]$Command,[string]$Desc,[int]$Timeout=60){
    if($script:DriverProcessStopFailed){throw 'Execucao interrompida: nao foi possivel confirmar o encerramento da instalacao anterior. Reinicie e confira o log antes de tentar novamente.'}
    $id=[guid]::NewGuid().ToString('N')
    $bat=Join-Path $env:TEMP "drv_$id.cmd"
    $out=Join-Path $env:TEMP "drv_$id.out"
    $batText=@"
@echo off
>"$out" echo [CMD] $Command
$Command >>"$out" 2>&1
set RC=%ERRORLEVEL%
echo [RET] %RC% >>"$out"
exit /b %RC%
"@
    # IMPORTANTE: gravar o .cmd em OEM.
    # Antes estava em ASCII e isso quebrava pastas com caractere especial, ex.: D:\DriversRepo\INTEL\4º.
    Write-OemFile $bat $batText
    L "EXEC: $Desc" Cyan; L "CMD : $Command"
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$env:ComSpec; $psi.Arguments="/d /c `"$bat`""; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $p=New-Object Diagnostics.Process; $p.StartInfo=$psi
    try{
        [void]$p.Start(); $ok=$p.WaitForExit($Timeout*1000)
        if(-not $ok){
            # Encerrar somente cmd.exe deixava pnputil trabalhando em segundo plano,
            # concorrendo com as fases seguintes. Em timeout real, encerra a arvore.
            try{
                $stopInfo=New-Object Diagnostics.ProcessStartInfo
                $stopInfo.FileName=Join-Path $env:WINDIR 'System32\taskkill.exe'
                $stopInfo.Arguments="/PID $($p.Id) /T /F"
                $stopInfo.UseShellExecute=$false; $stopInfo.CreateNoWindow=$true
                $stopInfo.RedirectStandardOutput=$true; $stopInfo.RedirectStandardError=$true
                $stopProcess=[Diagnostics.Process]::Start($stopInfo)
                try{
                    $stopped=$stopProcess.WaitForExit(5000)
                    if(-not $stopped -or $stopProcess.ExitCode -ne 0){
                        L 'AVISO: nao foi possivel confirmar encerramento da arvore; abortando novas instalacoes para evitar concorrencia.' Red
                        $script:DriverProcessStopFailed=$true
                        try{$p.Kill()}catch{}
                    }
                }finally{$stopProcess.Dispose()}
            }catch{$script:DriverProcessStopFailed=$true;try{$p.Kill()}catch{}}
            L "TIMEOUT: $Desc excedeu ${Timeout}s. Consulte a saida parcial abaixo." Yellow
        }
        $code=if($ok){$p.ExitCode}else{124}; $text=''
        if(Test-Path $out){
            $lines=@(Get-Content $out -ErrorAction SilentlyContinue); $text=($lines -join "`n")
            $show=@($lines|Select-Object -First 45)
            if($lines.Count -gt 65){$show+='... saida resumida ...'; $show+=($lines|Select-Object -Last 15)}
            foreach($x in $show){ if($x){L "OUT : $x"} }
        }
        L "RET : $code"; return [pscustomobject]@{Code=$code;Text=$text}
    } catch { L "ERRO: $($_.Exception.Message)" Red; return [pscustomobject]@{Code=999;Text=$_.Exception.Message} }
    finally { try{$p.Dispose()}catch{}; Remove-Item $bat,$out -Force -ErrorAction SilentlyContinue }
}
# Seleciona INFs para pendentes; instalacao indiscriminada de pasta exige modo explicito.
function PnpFolder([string]$Folder,[string]$Desc,[int]$Timeout=$BatchTimeoutSec){
    if(-not(Test-Path -LiteralPath $Folder)){L "Pasta nao encontrada: $Folder" Yellow; return [pscustomobject]@{Code=999;Text='Pasta nao encontrada'} }
    # Complementos tambem exigem um dispositivo pendente compativel no modo normal.
    # /subdirs indiscriminado so e usado com as flags explicitas de lote/completo.
    if(-not ($ModoCompleto -or $ForcarLoteFabricante -or $ForcarVideoLote)){
        $pending=@(Targets)
        $candidates=@(FindInfsForMany @($Folder) $pending 1)
        $code=0
        foreach($candidate in $candidates){
            $result=PnpInf $candidate.Path "$Desc - INF compativel"
            if($result.Code -ne 0){$code=$result.Code}
        }
        return [pscustomobject]@{Code=$code;Text="Selecao direcionada: $($candidates.Count) INF(s)"}
    }
    $pnp="$env:WINDIR\System32\pnputil.exe"
    return (RunCmd ('"{0}" /add-driver "{1}" /subdirs /install' -f $pnp,(Join-Path $Folder '*.inf')) $Desc $Timeout)
}
# Instala um INF especifico com o limite de tempo configurado por arquivo.
function PnpInf([string]$Inf,[string]$Desc){
    if(-not(Test-Path -LiteralPath $Inf)){return [pscustomobject]@{Code=999;Text='INF nao encontrado'} }
    # Nao repetir pacotes ja processados ou que esgotaram o timeout nesta execucao.
    if($null -eq $script:InfInstallResults){$script:InfInstallResults=@{}}
    $key=[IO.Path]::GetFullPath($Inf)
    if($script:InfInstallResults.ContainsKey($key)){
        L "INF ja tentado nesta execucao; reutilizando resultado: $Inf"
        return $script:InfInstallResults[$key]
    }
    $pnp="$env:WINDIR\System32\pnputil.exe"
    $timeout=$InfTimeoutSec
    $metadata=Get-InfModels (ReadInf $Inf) $Inf
    if($metadata.Class -eq 'DISPLAY'){
        # 35s interrompia nv_dispi mesmo correto; a GPU era identificada depois.
        $timeout=[math]::Max($InfTimeoutSec,$VideoTimeoutSec)
    }
    $result=RunCmd ('"{0}" /add-driver "{1}" /install' -f $pnp,$Inf) $Desc $timeout
    $script:InfInstallResults[$key]=$result
    return $result
}
# Solicita ao Windows uma nova enumeracao PnP; Async permite a varredura assincrona.
function Scan([switch]$Async){
    $pnp="$env:WINDIR\System32\pnputil.exe"
    if($Async){ [void](RunCmd ('"{0}" /scan-devices /async' -f $pnp) 'scan-devices async' 60) }
    else { [void](RunCmd ('"{0}" /scan-devices' -f $pnp) 'scan-devices' 90) }
}
# Aplica os drivers de uma pasta pelo DISM quando esse fallback for solicitado.
function DismFolder([string]$Folder){
    $dism="$env:WINDIR\System32\dism.exe"
    return (RunCmd ('"{0}" /Online /Add-Driver /Driver:"{1}" /Recurse' -f $dism,$Folder) "DISM $Folder" 600)
}

# ===========================================================================
# 3. INVENTARIO DE DISPOSITIVOS E IDENTIFICADORES PARA BUSCA
# ===========================================================================
# Le uma propriedade PnP e uniformiza a resposta como lista, inclusive quando vazia.
function PropArr($iid,$key){
    try{ $v=(Get-PnpDeviceProperty -InstanceId $iid -KeyName $key -ErrorAction Stop).Data; if($null -eq $v){@()} elseif($v -is [array]){@($v)} else{@([string]$v)} }catch{@()}
}
# Deduz o fabricante pelos identificadores PCI, USB e ACPI do dispositivo.
function Vendor($ids){
    $s=($ids -join '|').ToUpperInvariant()
    if($s -match 'VEN_10DE'){'NVIDIA'}
    elseif($s -match 'VEN_1002|VEN_1022|ACPI\\AMDI|\*AMDI|VEN_AMDI'){'AMD'}
    elseif($s -match 'VEN_8086|VID_8087|ACPI\\INTC|\*INTC'){'INTEL'}
    elseif($s -match 'VEN_10EC|VID_0BDA'){'REALTEK'}
    elseif($s -match 'VEN_168C|VEN_17CB|VID_0CF3'){'QUALCOMM'}
    elseif($s -match 'VEN_14C3|VEN_1814|VID_148F|VID_0E8D'){'MEDIATEK'}
    elseif($s -match 'VEN_14E4|VID_0A5C'){'BROADCOM'}
    else{'UNKNOWN'}
}
# Preserva a lista real de IDs do Windows, na ordem de especificidade, para localizar INFs.
function Tokens($ids){
    # Preserva IDs completos e a ordem HardwareIds -> CompatibleIds do Windows.
    # Nao inventa IDs sem SUBSYS/MI nem aceita um prefixo SWC de outro dispositivo.
    $seen=@{}
    foreach($raw in $ids){
        $id=([string]$raw).Trim().ToUpperInvariant()
        if(-not $id -or $seen.ContainsKey($id)){continue}
        $seen[$id]=$true
        $id
    }
}

# Consulta dispositivos pendentes, inclui video basico e ignora mouse/teclado.
# Uma falha de inventario gera erro para impedir que consulta vazia pareca instalacao concluida.
function Targets{
    $out=@()
    try{$all=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)}
    catch{throw "Nao foi possivel consultar os dispositivos. A instalacao nao foi verificada: $($_.Exception.Message)"}
    if($all.Count -eq 0){throw 'A consulta de dispositivos retornou vazia. Nao e possivel confirmar a instalacao.'}
    foreach($d in $all){
        $name=[string]$d.Name; $cls=[string]$d.PNPClass; $err=[int]$d.ConfigManagerErrorCode; $iid=[string]$d.PNPDeviceID; if(-not $iid){continue}
        $basic=($d.Service -eq 'BasicDisplay' -or ((($cls -eq 'Display') -or ($name -match 'Video|V.deo|Display')) -and ($name -match 'Basico|B.sico|Basic|Microsoft Basic')))
        # Componente System do Windows, nao um adaptador grafico. Erros reais seguem em $prob.
        if($cls -eq 'System' -and $iid -match '^ROOT\\BASICDISPLAY\\'){$basic=$false}
        # Conjunto ampliado de codigos de problema: antes era {1,28,31,39,43}.
        # Agora inclui 10 (nao iniciou), 18 (reinstalar), 24 (device ausente),
        # 52 (driver nao assinado) e 0x0A/0x1C. Isso evita "passar direto" em
        # dispositivos que ficam pendentes com outro codigo de erro.
        if($TodosErros){$prob=($err -ne 0)}else{$prob=(@(1,10,18,24,28,31,39,43,52) -contains $err)}
        if(-not($basic -or $prob)){continue}
        if($cls -match 'Keyboard|Mouse' -or $name -match 'Teclado|Mouse|HID-compliant mouse|HID Keyboard'){continue}
        $hw=@(PropArr $iid 'DEVPKEY_Device_HardwareIds'); $cp=@(PropArr $iid 'DEVPKEY_Device_CompatibleIds'); $ids=@($hw+$cp+$iid)|Where-Object{$_}
        $out += [pscustomobject]@{Name=$name;Class=$cls;Err=$err;Id=$iid;HW=$hw;Compat=$cp;Vendor=(Vendor $ids);Tokens=(Tokens @($hw+$cp));BasicVideo=$basic}
    }
    @($out)
}
# Consulta nome e fabricante da CPU, usando UNKNOWN quando a leitura nao estiver disponivel.
function CpuInfo{
    try{ $n=(Get-CimInstance Win32_Processor|Select-Object -First 1 -ExpandProperty Name); if($n -match 'AMD'){$v='AMD'}elseif($n -match 'Intel'){$v='INTEL'}else{$v='UNKNOWN'}; [pscustomobject]@{Name=$n;Vendor=$v} }
    catch{[pscustomobject]@{Name='';Vendor='UNKNOWN'}}
}
# Reconhece Intel Ultra pelo nome da CPU ou por identificadores de dispositivos da plataforma.
function IsUltra($cpu,$tg){
    if($cpu.Vendor -eq 'INTEL' -and $cpu.Name -match 'Ultra'){return $true}
    foreach($t in $tg){ $s=($t.Id+'|'+(($t.HW+$t.Compat)-join '|')).ToUpperInvariant(); if($s -match 'ACPI\\INTC1042|\*INTC1042|PCI\\VEN_8086&DEV_(7F|AD|AE)[0-9A-F]{2}'){return $true} }
    return $false
}
# ---------------------------------------------------------------------------
# Cache global de INFs e de listagem de pastas.
# Motivo: o script lia o mesmo INF (e re-varria a mesma arvore) varias vezes em
# fases diferentes, o que deixava a atualizacao lenta. Agora cada arquivo e lido
# no maximo uma vez por execucao, e a listagem de *.inf por pasta tambem e memoizada.
# ---------------------------------------------------------------------------
# ===========================================================================
# 4. CACHE, PONTUACAO DOS INFS E PASTAS DE CADA FABRICANTE
# ===========================================================================
$script:InfTextCache = @{}
$script:InfListCache = @{}

# Lista os INFs recursivamente e reutiliza a listagem em chamadas futuras da mesma pasta.
function Get-InfFiles([string]$Root){
    if(-not $Root){return @()}
    if($script:InfListCache.ContainsKey($Root)){return $script:InfListCache[$Root]}
    $files=@()
    try{ $files=@(Get-ChildItem -LiteralPath $Root -Filter *.inf -Recurse -File -Force -ErrorAction SilentlyContinue) }catch{ $files=@() }
    $script:InfListCache[$Root]=$files
    return $files
}
# Le o INF uma vez, converte para maiusculas e guarda o texto no cache da execucao.
function ReadInf($p){
    if(-not $p){return ''}
    if($script:InfTextCache.ContainsKey($p)){return $script:InfTextCache[$p]}
    $txt=''
    try{ $txt=[IO.File]::ReadAllText($p,[Text.Encoding]::Default).ToUpperInvariant() }
    catch{ try{ $txt=[IO.File]::ReadAllText($p).ToUpperInvariant() }catch{ $txt='' } }
    $script:InfTextCache[$p]=$txt
    return $txt
}
# Pontua correspondencias de Hardware ID e aplica prioridades por fabricante/caminho.
# DisplayOnly restringe candidatos a INFs cuja classe declarada seja Display.
# Cache de modelos: so IDs nas secoes declaradas em Manufacturer participam da
# selecao. Comentarios, Strings, nomes de arquivos e prefixos nao provam suporte.
# Interpreta apenas as secoes necessarias. Comentarios integrais sao descartados
# antes do tratamento de aspas; descricoes e instalacao nao sao modelos de hardware.
function Get-InfSectionLines([string]$body){
    foreach($raw in ($body -split '\r?\n')){
        $line=$raw.Trim()
        if(-not $line -or $line.StartsWith(';')){continue}
        if($line.IndexOf(';') -ge 0){$line=([regex]::Replace($line,';(?=(?:[^"\r\n]*"[^"\r\n]*")*[^"\r\n]*$).*$', '')).Trim()}
        if($line){$line}
    }
}
function Get-InfModels([string]$txt,[string]$path){
    if($null -eq $script:InfModelCache){$script:InfModelCache=@{}}
    if($script:InfModelCache.ContainsKey($path)){return $script:InfModelCache[$path]}
    # Indexa limites de secoes em .NET; nao interpreta milhares de diretivas de
    # copia/registro que nao participam da compatibilidade do dispositivo.
    $sections=@{}
    $logicalText=[regex]::Replace($txt,'\\[ \t]*\r?\n[ \t]*','')
    $headers=[regex]::Matches($logicalText,'(?m)^[ \t]*\[([^\]\r\n]+)\][ \t]*(?:;[^\r\n]*)?\r?$')
    for($h=0;$h -lt $headers.Count;$h++){
        $begin=$headers[$h].Index+$headers[$h].Length
        $end=if($h+1 -lt $headers.Count){$headers[$h+1].Index}else{$logicalText.Length}
        $section=$headers[$h].Groups[1].Value
        $body=$logicalText.Substring($begin,$end-$begin)
        if($sections.ContainsKey($section)){$sections[$section]+=$body}else{$sections[$section]=$body}
    }
    $strings=@{}
    foreach($line in @(Get-InfSectionLines $sections['STRINGS'])){
        if($line -match '^([^=]+)=(.*)$'){$strings[$Matches[1].Trim()]=$Matches[2].Trim().Trim('"')}
    }
    $expand={param([string]$value)
        # Resolve apenas as macros presentes nesta linha; nao percorre milhares
        # de strings do fabricante para cada modelo (gargalo confirmado no log).
        if($value.IndexOf('%') -lt 0){return $value}
        return [regex]::Replace($value,'%([^%]+)%',[Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $key=$match.Groups[1].Value
            if($strings.ContainsKey($key)){return [string]$strings[$key]}
            return $match.Value
        })
    }
    $arch=$env:PROCESSOR_ARCHITEW6432
    if(-not $arch){$arch=$env:PROCESSOR_ARCHITECTURE}
    if(-not $arch){$arch='AMD64'}
    $native='NT'+$arch
    if($null -eq $script:InfTargetOs){
        $script:InfTargetOs=[Environment]::OSVersion.Version
        try{
            $win=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            if($win.CurrentMajorVersionNumber){
                $script:InfTargetOs=[version]::new([int]$win.CurrentMajorVersionNumber,[int]$win.CurrentMinorVersionNumber,[int]$win.CurrentBuildNumber)
            }
        }catch{}
    }
    $os=$script:InfTargetOs
    $models=@{}
    foreach($line in @(Get-InfSectionLines $sections['MANUFACTURER'])){
        if($line -notmatch '^[^=]+=(.+)$'){continue}
        $fields=@((& $expand $Matches[1]) -split ',' | ForEach-Object {$_.Trim().Trim('"')})
        $base=$fields[0]; $eligible=@()
        if($fields.Count -eq 1){$eligible+= [pscustomobject]@{Name=$base;Rank=0L}}
        for($i=1;$i -lt $fields.Count;$i++){
            $dec=$fields[$i]
            if($dec -notmatch '^(NT(?:AMD64|X86|ARM64|ARM)?)(?:\.(.*))?$'){continue}
            $platform=$Matches[1];$ver=$Matches[2]
            if($platform -ne 'NT' -and $platform -ne $native){continue}
            $v=@($ver -split '\.');$major=0;$minor=0;$build=0
            if($v.Count -gt 0 -and $v[0]){$major=[int]$v[0]}
            if($v.Count -gt 1 -and $v[1]){$minor=[int]$v[1]}
            if($v.Count -gt 4 -and $v[4]){$build=[int]$v[4]}
            if($major -gt $os.Major -or ($major -eq $os.Major -and $minor -gt $os.Minor)){continue}
            if($major -eq $os.Major -and $minor -eq $os.Minor -and $build -gt $os.Build){continue}
            if($v.Count -gt 2 -and $v[2] -and $v[2] -ne '1'){continue}
            $rank=[long]$major*1000000000+[long]$minor*10000000+$build
            if($platform -eq $native){$rank+=100000000000L}
            $eligible+=[pscustomobject]@{Name=($base+'.'+$dec);Rank=$rank}
        }
        $selected=$eligible|Where-Object{$sections.ContainsKey($_.Name)}|Sort-Object Rank -Descending|Select-Object -First 1
        if($selected){$models[$selected.Name]=$true}
    }
    $ids=@{}
    foreach($name in $models.Keys){
        foreach($line in @(Get-InfSectionLines $sections[$name])){
            if($line -notmatch '^[^=]+=(.+)$'){continue}
            $parts=@((& $expand $Matches[1]) -split ',')
            for($i=1;$i -lt $parts.Count;$i++){
                $id=$parts[$i].Trim().Trim('"').ToUpperInvariant()
                if($id){$ids[$id]=$true}
            }
        }
    }
    $class=''
    foreach($line in @(Get-InfSectionLines $sections['VERSION'])){if($line -match '^CLASS\s*=\s*(.+)$'){$class=(& $expand $Matches[1]).Trim().Trim('"')}}
    $result=[pscustomobject]@{Ids=$ids;Class=$class}
    $script:InfModelCache[$path]=$result
    return $result
}
function ScoreInfText([string]$txt,[string]$path,[array]$tokens,[string]$vendor,[switch]$DisplayOnly){
    if(-not $txt){return 0}
    if($null -eq $script:InfModelCache -or -not $script:InfModelCache.ContainsKey($path)){
        $possible=$false
        foreach($id in $tokens){if($id -and $txt.Contains(([string]$id).ToUpperInvariant())){$possible=$true;break}}
        # Se o ID e composto por macros, a ausencia literal nao pode rejeitar o INF.
        if(-not $possible -and $txt -notmatch '(?m)^[^;=\r\n]+=[^,\r\n]+,[^;\r\n]*%'){return 0}
    }
    $model=Get-InfModels $txt $path
    if($DisplayOnly -and $model.Class -ne 'DISPLAY'){return 0}
    $score=0
    # IDs completos e ordenados pelo Windows. O melhor ID sempre supera bonus de pasta.
    for($index=0;$index -lt $tokens.Count;$index++){
        $id=([string]$tokens[$index]).ToUpperInvariant()
        if($model.Ids.ContainsKey($id)){$score=(1000-[math]::Min($index,999))*10000;break}
    }
    if($score -le 0){return 0}
    $up=$path.ToUpperInvariant(); $file=[IO.Path]::GetFileName($up)
    if($vendor -eq 'NVIDIA'){
        if($up -match '\\RTX\\'){$score+=120}
        if($file -eq 'NV_DISPI.INF'){$score+=700}
        elseif($file -eq 'NVDDI.INF'){$score+=250}
        elseif($file -eq 'NVMDI.INF'){$score-=900}
        if($up -match 'COMPLEMENTOS|PPC|_OLD|OLD'){$score-=400}
        if($txt -match '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$'){$score+=160}
    }
    if($vendor -eq 'INTEL'){
        if($up -match 'NPU'){$score+=200}
        if($up -match 'CHIPSET ULTRA|DTT|IPF|RPL|MTL|METEOR|ARROW|LUNAR'){$score+=150}
        if($up -match 'TIGERLAKE'){$score-=300}
    }
    if($vendor -eq 'AMD'){
        if($up.Contains('\AMD\[GRAPH] AM5\')){$score+=420}
        elseif($up.Contains('\AMD\[GRAPH] NEW\')){$score+=260}
        elseif($up.Contains('\AMD\[GRAPH]')){$score+=160}
        if($file -match '^U[0-9A-F]{7}\.INF$'){$score+=120}
        if($up -match 'AMD CHIPSET'){$score+=80}
        if($txt -match '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$'){$score+=160}
    }

    if($txt -match '(?m)^\s*CLASS\s*=\s*NET\s*$'){$score+=260}
    if($up -match 'WIFI|WI-FI|WLAN|WIRELESS|NETWORK|NET|LAN|ETHERNET'){$score+=90}
    # Bluetooth: nao deixar penalizacao impedir instalacao.
    # Como bluetooth pode aparecer sem CLASS=NET em alguns INF, atenuamos a penalizacao.
    if(($up -match 'BLUETOOTH|\\BT\\|BT_|_BT') -and ($txt -notmatch '(?m)^\s*CLASS\s*=\s*NET\s*$')){$score-=80}

    if($vendor -eq 'REALTEK'){
        if($up -match 'REALTEK|RTL|RTW|WLAN|LAN'){$score+=130}
    }
    if($vendor -eq 'QUALCOMM'){
        if($up -match 'QUALCOMM|ATHEROS|QCA|KILLER|WLAN|WIRELESS'){$score+=140}
    }
    if($vendor -eq 'MEDIATEK'){
        if($up -match 'MEDIATEK|RALINK|MTK|WLAN|WIRELESS'){$score+=140}
    }
    if($vendor -eq 'BROADCOM'){
        if($up -match 'BROADCOM|BCM|WLAN|WIRELESS'){$score+=140}
    }
    return $score
}
# Busca e ordena os melhores INFs para um dispositivo, respeitando o limite Max.
function FindInf($roots,$tokens,$vendor,[switch]$DisplayOnly,[int]$Max=2){
    $visited=@{}; $map=@{}; $roots=@($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique); if(-not $tokens){return @()}
    foreach($root in $roots){
        L "Busca INF exata em: $root"
        $infs=@(Get-InfFiles $root)
        L "  INF encontrados: $($infs.Count)"
        foreach($inf in $infs){
            if($visited.ContainsKey($inf.FullName)){continue}; $visited[$inf.FullName]=$true
            $up=$inf.FullName.ToUpperInvariant()
            if($vendor -eq 'NVIDIA' -and -not $ModoCompleto){ if($up -match 'NVMDI\.INF$|COMPLEMENTOS|PPC|_OLD|OLD'){continue} }
            $txt=ReadInf $inf.FullName
            $score=ScoreInfText $txt $inf.FullName $tokens $vendor -DisplayOnly:$DisplayOnly
            if($score -gt 0){$map[$inf.FullName]=[math]::Max([int]$map[$inf.FullName],$score)}
        }
    }
    @($map.GetEnumerator()|Sort-Object Value -Descending|Select-Object -First $Max|ForEach-Object{[pscustomobject]@{Path=$_.Key;Score=$_.Value}})
}
# Percorre os INFs para varios dispositivos de uma vez e seleciona os melhores de cada um.
function FindInfsForMany($roots,[array]$devices,[int]$MaxPerDevice=1){
    $roots=@($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique)
    $devices=@($devices|Where-Object{$_.Tokens})
    if($devices.Count -eq 0){return @()}
    $visited=@{}; $best=@{}
    foreach($root in $roots){
        L "Busca multipla INF exata em: $root" Cyan
        $infs=@(Get-InfFiles $root)
        L "  INF encontrados: $($infs.Count)"
        foreach($inf in $infs){
            if($visited.ContainsKey($inf.FullName)){continue}; $visited[$inf.FullName]=$true
            $txt=ReadInf $inf.FullName; if(-not $txt){continue}
            foreach($d in $devices){
                $score=ScoreInfText $txt $inf.FullName $d.Tokens $d.Vendor
                if($score -le 0){continue}
                $key=$d.Id
                if(-not $best.ContainsKey($key)){$best[$key]=New-Object Collections.Generic.List[object]}
                $best[$key].Add([pscustomobject]@{Device=$d;Path=$inf.FullName;Score=$score})
            }
        }
    }
    $sel=@()
    foreach($key in $best.Keys){ $sel += @($best[$key] | Sort-Object Score -Descending | Select-Object -First $MaxPerDevice) }
    @($sel | Sort-Object Path -Unique | Sort-Object Score -Descending)
}
# Localiza pastas graficas Intel conforme a geracao, incluindo nomes descobertos no repositorio.
function Get-IntelGraphicsRoots {
    $intelRoot = Join-Path $Repo 'INTEL'
    if (-not (Test-Path -LiteralPath $intelRoot)) { return @() }
    
    $genFolderNames = switch ($script:IntelGen) {
        '4' { @('4º', '4°', '4ª', '4') }
        '7-10' { @('7th', '8th', '9th', '10th', '7º a 10º', '7-10º', '7 a 10º', '7º', '8º', '9º', '10º') }
        '11-14' { @('11º a 14º', '11-14º', '11 a 14º', '11º', '12º', '13º', '14º') }
        'Ultra' { @('Graphics', 'Chipset Ultra') }
        '4' { @('Graphics') }
        default { @('Graphics') }
    }
    
    $roots = @()
    foreach ($folderName in $genFolderNames) {
        $fullPath = Join-Path $intelRoot $folderName
        if (Test-Path -LiteralPath $fullPath) {
            $roots += $fullPath
        }
    }
    
    # Dynamic folder discovery
    try {
        Get-ChildItem -LiteralPath $intelRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $n = $_.Name.ToUpperInvariant()
            switch ($script:IntelGen) {
                '4' {
                    if ($n -match '(^|[^0-9])4([^0-9]|$)' -or $n -match 'QUARTA|4\s*(º|ª|°|O|A|TH|GEN|GERACAO)?') {
                        $roots += $_.FullName
                    }
                }
                '7-10' {
                    if ($n -match '(^|[^0-9])(7|8|9|10)([^0-9]|$)') { $roots += $_.FullName }
                }
                '11-14' {
                    if ($n -match '(^|[^0-9])(11|12|13|14)([^0-9]|$)') { $roots += $_.FullName }
                }
            }
        }
    } catch {}
    
    @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

# Localiza variantes de nome da pasta Intel de quarta geracao, inclusive com simbolos ordinais.
function Get-IntelFourthGenRoots {
    $roots=@()
    $intelRoot=Join-Path $Repo 'INTEL'
    if(-not(Test-Path -LiteralPath $intelRoot)){return @()}
    # Caminhos explicitos para nao depender so da varredura quando a pasta tem simbolo especial.
    $roots += (Join-Path $intelRoot '4º')
    $roots += (Join-Path $intelRoot '4°')
    $roots += (Join-Path $intelRoot '4ª')
    $roots += (Join-Path $intelRoot '4')
    try{
        Get-ChildItem -LiteralPath $intelRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $n=$_.Name.ToUpperInvariant()
            # Pega pastas como "4", "4o", "4a", "4th", "4 gen", "4 geracao" e tambem "4º/4ª/4°".
            if($n -match '(^|[^0-9])4([^0-9]|$)' -or $n -match 'QUARTA|4\s*(º|ª|°|O|A|TH)?'){
                $roots += $_.FullName
            }
        }
    } catch {}
    @($roots|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique)
}
# Traduz o nome do processador Intel para os grupos de geracoes usados nas pastas.
function Get-IntelGenCpu($cpuName) {
    if (-not $cpuName -or [string]$cpuName -notmatch 'Intel') { return 'Other' }
    $n = [string]$cpuName
    # Ultra deve ser reconhecido antes de numeros de modelo ou frequencia.
    if ($n -match 'CORE\s*(?:\(TM\))?\s*ULTRA|METEOR LAKE|ARROW LAKE|LUNAR LAKE') { return 'Ultra' }

    $gen = 0
    if ($n -match '\bi[3579][-\s]+([1-9]\d{3,4})[a-z]*\b') {
        $model = $Matches[1]
        if ($model.Length -eq 5) { $gen = [int]$model.Substring(0,2) }
        else { $gen = [int]$model.Substring(0,1) }
    } elseif ($n -match '(?<!\d)(1[0-4]|[4-9])\s*(?:º|ª|°|TH|GEN|GERACAO)\b') {
        $gen = [int]$Matches[1]
    }
    if ($gen -eq 4) { return '4' }
    if ($gen -ge 7 -and $gen -le 10) { return '7-10' }
    if ($gen -ge 11 -and $gen -le 14) { return '11-14' }
    if ($n -match 'ALDER|RAPTOR|ROCKET|\bRPL\b') { return '11-14' }
    return 'Other'
}
# Define a ordem de pastas provaveis de cada fabricante e acrescenta pastas comuns de rede.
function RootsFor($vendor){
    $intelGenRoots=@()
    try { 
        if ($script:IntelGen -ne 'Other') { 
            $intelGenRoots = @(Get-IntelGraphicsRoots) 
        } 
    } catch {}
    $netRoots=@()
    # Em Intel geracoes especificas, alguns repositorios guardam video/rede/chipset juntos em pastas de geracao.
    $netRoots += $intelGenRoots
    $netRoots += @(
        (Join-Path $Repo 'NETWORK'),
        (Join-Path $Repo 'NET'),
        (Join-Path $Repo 'LAN'),
        (Join-Path $Repo 'WIFI'),
        (Join-Path $Repo 'WI-FI'),
        (Join-Path $Repo 'WLAN'),
        (Join-Path $Repo 'WIRELESS'),
        (Join-Path $Repo 'DRIVERS WIFI'),
        (Join-Path $Repo 'DRIVERS REDE')
    )
    switch($vendor){
        'NVIDIA'{ @((Join-Path $Repo 'NVIDIA\RTX'),(Join-Path $Repo 'NVIDIA')) }
        'AMD'{ @((Join-Path $Repo 'AMD')) }
'INTEL'{ @($intelGenRoots + @((Join-Path $Repo 'INTEL\Graphics'),(Join-Path $Repo 'INTEL\WiFi'),(Join-Path $Repo 'INTEL\Wi-Fi'),(Join-Path $Repo 'INTEL\Wireless'),(Join-Path $Repo 'INTEL\LAN'),(Join-Path $Repo 'INTEL\Network'),(Join-Path $Repo 'INTEL\Intel Chipset'),(Join-Path $Repo 'INTEL')) + $netRoots) }
        'REALTEK'{ @((Join-Path $Repo 'REALTEK'),(Join-Path $Repo 'RTL'),(Join-Path $Repo 'LAN\REALTEK'),(Join-Path $Repo 'WIFI\REALTEK')) + $netRoots }
        'QUALCOMM'{ @((Join-Path $Repo 'QUALCOMM'),(Join-Path $Repo 'ATHEROS'),(Join-Path $Repo 'KILLER'),(Join-Path $Repo 'QCA'),(Join-Path $Repo 'WIFI\QUALCOMM'),(Join-Path $Repo 'WIFI\ATHEROS')) + $netRoots }
        'MEDIATEK'{ @((Join-Path $Repo 'MEDIATEK'),(Join-Path $Repo 'MTK'),(Join-Path $Repo 'RALINK'),(Join-Path $Repo 'WIFI\MEDIATEK'),(Join-Path $Repo 'WIFI\RALINK')) + $netRoots }
        'BROADCOM'{ @((Join-Path $Repo 'BROADCOM'),(Join-Path $Repo 'BCM'),(Join-Path $Repo 'WIFI\BROADCOM')) + $netRoots }
        'NETWORK'{ $netRoots }
        default{ @($Repo) }
    }
}
# Reconhece candidatos de rede/Wi-Fi pela classe, nome ou identificadores conhecidos.
function IsNetworkTarget($d){
    if($null -eq $d -or $d.BasicVideo){return $false}
    $s=(($d.Name+'|'+$d.Class+'|'+$d.Id+'|'+(($d.HW+$d.Compat)-join '|'))).ToUpperInvariant()
    if($d.Class -match '^Net$|Network'){return $true}
    if($s -match 'NETWORK CONTROLLER|CONTROLADOR DE REDE|CONTROLADORA DE REDE|WI-FI|WIFI|WIRELESS|WLAN|802\.11|ETHERNET|ADAPTADOR DE REDE'){return $true}
    if($s -match 'PCI\\VEN_(8086|10EC|168C|17CB|14C3|1814|14E4)&DEV_'){return $true}
    if($s -match 'USB\\VID_(0BDA|148F|0E8D|0CF3|8087|0A5C)&PID_'){return $true}
    return $false
}
# ===========================================================================
# 5. INSTALACOES PRIORITARIAS E INSTALADOR DO PROXY DE HUB
# ===========================================================================
# Identifica somente o Proxy de Hub MSFT8000, incluindo a forma ACPI abreviada.
# As ancoras evitam confundir DEV_8000 com DEV_80000 ou outro fabricante.
function Test-ProxyHubHardwareId {
    param([string[]]$Ids)
    foreach ($id in @($Ids)) {
        if ($id -and $id.Trim() -match '^(?:ACPI\\(?:VEN_MSFT&DEV_8000(?:&[^\\]+)?|MSFT8000)(?:\\.*)?|\*MSFT8000)$') { return $true }
    }
    return $false
}

# Rele o estado nativo para decidir instalar e para conferir o resultado depois.
# Nao depende do subconjunto de codigos de problema usado na busca geral por INF.
function Get-ProxyHubDevices {
    $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)
    foreach ($device in $devices) {
        $ids = @($device.PNPDeviceID) + @($device.HardwareID) + @($device.CompatibleID)
        if (Test-ProxyHubHardwareId -Ids $ids) {
            $code = if ($null -eq $device.ConfigManagerErrorCode) { -1 } else { [int]$device.ConfigManagerErrorCode }
            [pscustomobject]@{ Id = [string]$device.PNPDeviceID; Name = [string]$device.Name; Err = $code }
        }
    }
}

# Prefere a copia proxima do atualizador. Aceita Outros na raiz da midia como
# alternativa para computadores que ainda usam a disposicao anterior do pacote.
function Find-ProxyHubInstaller {
    $name = 'DISPOSITIVO DE PROXY HUB.EXE'
    $candidates = @()
    if ($script:ScriptDir) {
        $candidates += Join-Path $script:ScriptDir ('ProxyHub\' + $name)
        $candidates += Join-Path $script:ScriptDir $name
    }
    if ($Repo) {
        $mediaRoot = Split-Path -Parent $Repo
        if ($mediaRoot) { $candidates += Join-Path $mediaRoot ('Outros\' + $name) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

# Executa o instalador fornecido somente se o hardware exato estiver pendente.
# Sem switches presumidos: o SFX original ja chama InstUpd.exe pela configuracao.
# Retorno zero do programa nao basta: a confirmacao vem de uma nova consulta PnP.
function Install-ProxyHubMissing {
    try { $devices = @(Get-ProxyHubDevices) }
    catch { L ('Proxy de Hub: falha ao consultar dispositivos: ' + $_.Exception.Message) Yellow; return 'InventoryError' }
    if ($devices.Count -eq 0) { return 'Absent' }
    $pending = @($devices | Where-Object { $_.Err -ne 0 })
    if ($pending.Count -eq 0) { L 'Proxy de Hub MSFT8000 ja esta sem erros; instalacao ignorada.'; return 'Healthy' }

    $installer = Find-ProxyHubInstaller
    if (-not $installer) {
        L 'Proxy de Hub MSFT8000 pendente, mas DISPOSITIVO DE PROXY HUB.EXE nao foi encontrado em ProxyHub.' Yellow
        return 'InstallerMissing'
    }
    L ('FASE PROXY DE HUB: instalando MSFT8000 por ' + $installer) Cyan
    foreach ($device in $pending) { L ('Proxy pendente: {0} | Erro={1} | ID={2}' -f $device.Name, $device.Err, $device.Id) }
    try {
        $process = Start-Process -FilePath $installer -WorkingDirectory (Split-Path -Parent $installer) -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($null -eq $process -or $null -eq $process.ExitCode) { throw 'O instalador nao informou o codigo de saida.' }
        $code = [int]$process.ExitCode
        L ('Instalador Proxy de Hub finalizou com codigo ' + $code)
        if ($code -ne 0 -and $code -ne 3010) { L 'Instalador Proxy de Hub retornou falha; consulte o log e o estado do dispositivo.' Yellow; return 'Failed' }
        if ($code -eq 3010) { $script:ProxyHubRebootRequired = $true }
        Scan
        Start-Sleep -Seconds 2
        try { $after = @(Get-ProxyHubDevices) }
        catch { L ('Proxy de Hub: nao foi possivel confirmar o resultado: ' + $_.Exception.Message) Yellow; return 'InventoryError' }
        if ($code -eq 3010) { L 'Proxy de Hub: reinicie o Windows para confirmar o driver.' Yellow; return 'RebootRequired' }
        if ($after.Count -gt 0 -and @($after | Where-Object { $_.Err -ne 0 }).Count -eq 0) {
            L 'Proxy de Hub MSFT8000 confirmado sem erros apos a instalacao.' Green
            return 'Resolved'
        }
        L 'Proxy de Hub: instalador executado, mas o dispositivo ainda nao foi confirmado sem erros.' Yellow
        return 'Pending'
    }
    catch { L ('Falha ao executar instalador Proxy de Hub: ' + $_.Exception.Message) Red; return 'Failed' }
}


# Prioriza Bluetooth com busca por IDs, instalacao do pacote e nova tentativa para pendentes.
function InstallBluetoothMissingPriority([array]$tg){
    if(-not $tg){return}

    # Detecta dispositivos pendentes com pistas de Bluetooth (por Id/tokens/name/class).
    $bt=@($tg | Where-Object{
        if(-not $_){return $false}
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        # Bluetooth pode aparecer como varios padroes; incluir tambem radios comuns (BT/WIDCOMM/Qualcomm BT etc.)
        return ($s -match 'BLUETOOTH|\\BT\\|BT_|_BT|BTH\\|WIDCOMM|AIR\\|RADIO\\|LE\\|802\\.15')
    })

    if($bt.Count -eq 0){return}

    L "FASE BLUETOOTH PRIORITARIA: $($bt.Count) dispositivo(s) Bluetooth pendente(s)." Cyan
    foreach($d in $bt){
        L "BT TARGET: $($d.Name) | Classe=$($d.Class) | Err=$($d.Err) | Vendor=$($d.Vendor) | ID=$($d.Id)" Cyan
        if($d.Tokens){L "  TOKENS: $($d.Tokens -join ' | ')"}
    }

    # Roots: usar o repo inteiro (raiz pendrive) para garantir que sempre exista fallback.
    # E também tenta pastas comuns de fabricante para melhorar chance de acerto.
    $roots = @()
    $roots += @($Repo)
    foreach($v in @($bt|Select-Object -ExpandProperty Vendor -Unique)){
        if($v -and $v -ne 'UNKNOWN'){
            $roots += (RootsFor $v)
        }
    }

    $roots = @($roots | Where-Object{$_ -and (Test-Path -LiteralPath $_)} | Select-Object -Unique)
    L "BT: buscando INF em roots: $($roots -join ' | ')" Cyan

    # Rodada 1: busca por tokens.
    $cands = FindInfsForMany $roots $bt 2

    # Fallback adicional: se tokens não casarem bem, pega INFs cujo texto contenha BT/BLUETOOTH.
    if($cands.Count -eq 0){
        # Debug: se falhar, ajuda a entender se existem sequer INFs com BLUETOOTH no Repo.
        try{
            $btInfCount = (@(Get-InfFiles $Repo) | Where-Object{
                try{ (ReadInf $_.FullName) -match 'BLUETOOTH|\\BT\\|BT_|_BT|WIDCOMM|BTH' }catch{ $false }
            }).Count
            L ("BT: contagem aproximada de INFs com palavras BT/BLUETOOTH no Repo = {0}" -f $btInfCount) Yellow
        }catch{}

        L 'BT: nenhum INF encontrado por tokens; fazendo fallback por texto (BLUETOOTH/BT) no Repo.' Yellow
        $allInfs = @(Get-InfFiles $Repo)
        $map=@{}
        foreach($inf in $allInfs){
            $upTxt = ReadInf $inf.FullName
            if(-not $upTxt){continue}
            if($upTxt -match 'BLUETOOTH|\\BT\\|BT_|_BT'){
                foreach($d in $bt){
                    $score = ScoreInfText $upTxt $inf.FullName $d.Tokens $d.Vendor
                    if($score -gt 0){
                        if(-not $map.ContainsKey($d.Id)){$map[$d.Id]=New-Object Collections.Generic.List[object]}
                        $map[$d.Id].Add([pscustomobject]@{Device=$d;Path=$inf.FullName;Score=$score})
                    }
                }
            }
        }
        $sel=@()
        foreach($k in $map.Keys){
            $sel += @($map[$k] | Sort-Object Score -Descending | Select-Object -First 2)
        }
        $cands = @($sel | Sort-Object Path -Unique | Sort-Object Score -Descending)
    }

    L "BT: INFs selecionados: $($cands.Count)" Cyan
    foreach($c in $cands){
        L "INF Bluetooth Score=$($c.Score): $($c.Path)" Cyan
        [void](PnpInf $c.Path "Bluetooth $($c.Device.Name)")
        $folder=Split-Path -Parent $c.Path
        if($folder -and (Test-Path -LiteralPath $folder)){
            [void](PnpFolder $folder "Bluetooth pasta do INF - $($c.Device.Name)" 180)
        }
    }

    # Rodada 2: re-tenta o que sobrou (para evitar "passou direto" quando o INF não amarrou de primeira).
    Scan -Async
    $tg2=Targets
    $bt2=@($tg2 | Where-Object{
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        return ($s -match 'BLUETOOTH|\\BT\\|BT_|_BT|RADIO\\|AIR\\|802\\.15|WIDCOMM|BTH\\')
    })
    if($bt2.Count -gt 0){
        L "BT: ainda restam $($bt2.Count) pendente(s). Repetindo busca curta por tokens no Repo." Yellow
        $c2=FindInfsForMany @($Repo) $bt2 2
        foreach($c in $c2){
            L "INF Bluetooth (rodada2) Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Bluetooth(2) $($c.Device.Name)")
        }
        Scan -Async
    }
}

# Busca o coprocessador de audio AMD e exige compatibilidade do ID declarado no modelo do INF.
function InstallAmdAudioCoprocessor([array]$tg){
    # ACP pode aparecer como Controlador de multimidia, sem nome AMD/Audio.
    $devices=@($tg | Where-Object{
        $_.Vendor -eq 'AMD' -and (
            $_.Name -match 'Audio|ACP|Co.?Processor|Coprocessador' -or
            (($_.HW + @($_.Id)) -join '|') -match 'VEN_1022&DEV_15E2'
        )
    })
    foreach($d in $devices){
        L "AMD ACP: $($d.Name) | ID=$($d.Id) | Erro=$($d.Err)" Cyan
        $chipsetRoot=Join-Path $Repo 'AMD\AMD CHIPSET'
        $candidates=@(FindInf @($chipsetRoot) $d.Tokens 'AMD' -Max 100)
        # Comparacao completa evita escolher REV_60/62/6F/63 para REV_00.
        $deviceIds=@($d.HW + @($d.Id) | ForEach-Object {
            $id=([string]$_).ToUpperInvariant()
            $id
            $id -replace '&SUBSYS_[0-9A-F]{8}',''
        })
        $compatible={
            param($candidate)
            $txt=ReadInf $candidate.Path
            $modelIds=@([regex]::Matches($txt,'(?im)^\s*[^;\r\n=]+\s*=\s*[^,\r\n]+,\s*(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}[^,\s;]*)') | ForEach-Object { $_.Groups[1].Value })
            foreach($modelId in $modelIds){
                foreach($deviceId in $deviceIds){
                    if($deviceId -eq $modelId -or $deviceId.StartsWith($modelId+'&')){return $true}
                }
            }
            return $false
        }
        $candidates=@($candidates | Where-Object { & $compatible $_ })
        if($candidates.Count -eq 0){
            $candidates=@(FindInf @($Repo) $d.Tokens 'AMD' -Max 100 | Where-Object { & $compatible $_ })
        }
        if($candidates.Count -eq 0){
            L "AMD ACP: nenhum INF compativel no DriversRepo. Hardware IDs: $($d.HW -join ' | ')" Yellow
            continue
        }
        foreach($c in $candidates){
            [void](PnpInf $c.Path "AMD Audio CoProcessor - $($d.Name)")
            [void](PnpFolder (Split-Path -Parent $c.Path) 'AMD ACP - pacote complementar' $BatchTimeoutSec)
            Scan
            $state=Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -eq $d.Id } | Select-Object -First 1
            if($state -and $state.ConfigManagerErrorCode -eq 0){
                L 'AMD ACP: dispositivo sem erro confirmado.' Green
                break
            }
        }
    }
}

# Prioriza codecs de audio com busca nas pastas comuns e fallback para todo o repositorio.
function InstallAudioMissingPriority([array]$tg){
    # Fase dedicada para audio (HDAUDIO/Realtek/Conexant/VIA).
    # Antes esses codecs nao entravam no foco e as vezes ficavam como
    # "Dispositivo de High Definition Audio" pendente mesmo com INF no Repo.
    $aud=@($tg | Where-Object{
        if(-not $_){return $false}
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        return ($_.Class -match '^MEDIA$|AudioEndpoint|^System$' -and $s -match 'AUDIO|HDAUDIO|HDAUDIO\\FUNC|HIGH DEFINITION|REALTEK|CONEXANT|SOUND') -or ($s -match 'HDAUDIO\\FUNC_0[0-9]')
    })
    if($aud.Count -eq 0){return}

    L "FASE AUDIO PRIORITARIA: $($aud.Count) dispositivo(s) de audio pendente(s)." Cyan
    foreach($d in $aud){
        L "AUDIO TARGET: $($d.Name) | Classe=$($d.Class) | Err=$($d.Err) | Vendor=$($d.Vendor) | ID=$($d.Id)" Cyan
        if($d.Tokens){L "  TOKENS AUDIO: $($d.Tokens -join ' | ')"}
    }

    $roots=@()
    foreach($v in @($aud|Select-Object -ExpandProperty Vendor -Unique)){
        if($v -and $v -ne 'UNKNOWN'){ $roots += (RootsFor $v) }
    }
    # Pastas comuns de audio + Repo (busca ampla com cache e barata).
    $roots += @(
        (Join-Path $Repo 'AUDIO'),
        (Join-Path $Repo 'REALTEK'),
        (Join-Path $Repo 'HDAUDIO'),
        (Join-Path $Repo 'SOUND'),
        (Join-Path $Repo 'Complementos')
    )
    $roots = @($roots | Where-Object{$_ -and (Test-Path -LiteralPath $_)} | Select-Object -Unique)

    $cands = FindInfsForMany $roots $aud 2
    if($cands.Count -eq 0){
        L 'AUDIO: nenhum INF nas pastas provaveis; varrendo DriversRepo por tokens.' Yellow
        $cands = FindInfsForMany @($Repo) $aud 2
    }

    L "AUDIO: INFs selecionados: $($cands.Count)" Cyan
    foreach($c in $cands){
        L "INF Audio Score=$($c.Score): $($c.Path)" Cyan
        [void](PnpInf $c.Path "Audio $($c.Device.Name)")
        $folder=Split-Path -Parent $c.Path
        if($folder -and (Test-Path -LiteralPath $folder)){
            [void](PnpFolder $folder "Audio pasta do INF - $($c.Device.Name)" 180)
        }
    }
}

# Prioriza rede/Wi-Fi por fabricante e instala candidatos encontrados por Hardware ID.
function InstallNetworkPriority([array]$tg){
    $net=@($tg|Where-Object{ IsNetworkTarget $_ })
    if($net.Count -eq 0){return}
    L "FASE REDE/WIFI PRIORITARIA: $($net.Count) dispositivo(s) de rede pendente(s)." Cyan
    foreach($n in $net){
        L "REDE/WIFI TARGET: $($n.Name) | Classe=$($n.Class) | Err=$($n.Err) | Vendor=$($n.Vendor) | ID=$($n.Id)" Cyan
        if($n.Tokens){L "  TOKENS REDE/WIFI: $($n.Tokens -join ' | ')"}
    }
    foreach($v in @($net|Select-Object -ExpandProperty Vendor -Unique)){
        $devs=@($net|Where-Object{$_.Vendor -eq $v})
        $roots=@()
        if($v -ne 'UNKNOWN'){$roots+=(RootsFor $v)}
        $roots+=(RootsFor 'NETWORK')
        $roots=@($roots|Where-Object{$_}|Select-Object -Unique)
        L "Rede/WiFi Vendor=$v | buscando primeiro em pastas provaveis." Cyan
        $cands=FindInfsForMany $roots $devs 2
        if($cands.Count -eq 0){
            L "Rede/WiFi Vendor=$v | nenhum INF nas pastas provaveis. Fazendo varredura exata no DriversRepo para nao deixar WiFi passar." Yellow
            $cands=FindInfsForMany @($Repo) $devs 2
        }
        L "Rede/WiFi Vendor=$v | INFs selecionados: $($cands.Count)" Cyan
        foreach($c in $cands){
            L "INF Rede/WiFi Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Rede/WiFi $($c.Device.Name)")
            $folder=Split-Path -Parent $c.Path
            if($folder -and (Test-Path -LiteralPath $folder)){
                [void](PnpFolder $folder "Rede/WiFi pasta do INF - $($c.Device.Name)" 180)
            }
        }
    }
}


# Repete a tentativa de video Intel nas pastas da geracao quando o adaptador ainda usa driver basico.
function InstallIntelGraphicsAggressive {
    $roots = @(Get-IntelGraphicsRoots)
    if ($roots.Count -eq 0) { return }
    $basic = @(Targets | Where-Object { $_.BasicVideo })

    $should = $false
    $intelBasic = @($basic | Where-Object { $_.Vendor -eq 'INTEL' })
    if ($intelBasic.Count -gt 0) { $should = $true }

    if (-not $should) { return }

    L "FASE INTEL GEN VIDEO REFORCADO (Gen=$script:IntelGen): Adaptador Basico Microsoft detectado. Priorizando pastas Intel $script:IntelGen." Cyan
    L "Pastas Intel encontradas: $($roots -join ' | ')" Cyan

    foreach ($b in $intelBasic) {
        if($script:IntelVideoRebootRequired -contains $b.Id){continue}
        L "VIDEO INTEL TARGET: $($b.Name) | Gen=$script:IntelGen | ID=$($b.Id)" Cyan
        if ($b.Tokens) { L "  TOKENS: $($b.Tokens -join ' | ')" }
        $cands = FindInf $roots $b.Tokens 'INTEL' -DisplayOnly -Max $MaxCandidatesPerDevice
        foreach ($c in $cands) {
            L "INF video Intel Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Video Intel Gen=$script:IntelGen - INF exato")
            $folder = Split-Path -Parent $c.Path
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                [void](PnpFolder $folder "Video Intel Gen=$script:IntelGen - pasta do INF" 300)
            }
            Scan
            if(Test-VideoDeviceReady $b.Id){break}
            if(Repair-IntelBasicVideo $b $c.Path){break}
        }
    }

    Scan -Async
    if (@((Targets) | Where-Object { $_.BasicVideo -and $_.Vendor -eq 'INTEL' }).Count -gt 0) {
        L "Video Intel ainda Basico. Aplicando lote completo gen $script:IntelGen." Yellow
        foreach ($r in $roots) { [void](PnpFolder $r "Video Intel Gen=$script:IntelGen - lote completo" 900) }
        Scan -Async
    }

    # DISM /Online /Add-Driver nao instala drivers na sessao Windows ativa.
    # A recuperacao acima usa a API de instalacao para o hardware correspondente.
}
# Informa se a lista de alvos deixou de conter video basico.
function IsVideoResolved{
    $t=Targets
    return (@($t|Where-Object{$_.BasicVideo}).Count -eq 0)
}
# Valida a GPU real no inventario: classe Display, sem erro e com servico de driver ativo.
function Test-VideoDeviceReady([string]$DeviceId) {
    # Confirma o dispositivo real; texto do pnputil sozinho nao prova ativacao.
    try {
        $device = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPDeviceID -eq $DeviceId } | Select-Object -First 1
        return ($null -ne $device -and $device.PNPClass -eq 'Display' -and
            $device.ConfigManagerErrorCode -eq 0 -and $device.Service -and
            $device.Service -notmatch '^BasicDisplay$' -and $device.Name -notmatch 'B.sico|Basico|Basic')
    } catch { return $false }
}
# Carrega uma ponte C# para a API newdev.dll e devolve sucesso, erro e necessidade de reiniciar.
function Invoke-IntelDriverUpdate([string]$HardwareId,[string]$Inf) {
    if(-not ('Pichau.IntelVideoInstaller' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Pichau {
    public class IntelVideoResult {
        public bool Success;
        public bool RebootRequired;
        public int Error;
    }
    public static class IntelVideoInstaller {
        [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateDriverForPlugAndPlayDevicesW(
            IntPtr hwnd, string hardwareId, string inf, uint flags,
            [MarshalAs(UnmanagedType.Bool)] out bool reboot);
        public static IntelVideoResult Install(string hardwareId, string inf) {
            bool reboot;
            // FORCE | NONINTERACTIVE: somente chamado para Intel ainda em BasicDisplay.
            bool ok = UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, inf, 5, out reboot);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            return new IntelVideoResult { Success=ok, RebootRequired=reboot, Error=error };
        }
    }
}
'@ -ErrorAction Stop
    }
    [Pichau.IntelVideoInstaller]::Install($HardwareId,$Inf)
}
# Tenta recuperar somente Intel ainda em video basico, com INF compativel confirmado.
# Evita repetir o mesmo par dispositivo/INF e registra quando o Windows exige reinicio.
function Repair-IntelBasicVideo($Device,[string]$Inf) {
    # Nunca substitui um driver Intel ativo: valida o estado atual antes de recuperar.
    $current=@(Targets | Where-Object { $_.Id -eq $Device.Id -and $_.Vendor -eq 'INTEL' -and $_.BasicVideo })
    if($current.Count -ne 1 -or -not (Test-Path -LiteralPath $Inf -PathType Leaf)){return $false}
    $txt=ReadInf $Inf
    if($txt -notmatch '(?m)^\s*CLASS\s*=\s*DISPLAY\s*$'){return $false}
    # Confirma um ID real/compativel declarado no modelo do INF (nao comentarios).
    # VEN/DEV sem SUBSYS costuma estar em CompatibleIds, nao em HardwareIds.
    $matchingId=$null
    foreach($hw in @($current[0].HW+$current[0].Compat)){
        if($hw -notmatch '^PCI\\VEN_8086&DEV_[0-9A-F]{4}'){continue}
        $pattern='(?im)^\s*[^;\r\n=]+=[^;\r\n]*,\s*"?'+[regex]::Escape($hw)+'"?\s*(?:;[^\r\n]*)?$'
        if($txt -match $pattern){$matchingId=$hw;break}
    }
    # Direciona a API ao HardwareId mais especifico, incluindo SUBSYS/REV se disponivel.
    $hardwareId=@($current[0].HW | Where-Object { $_ -match '^PCI\\VEN_8086&DEV_[0-9A-F]{4}' } | Select-Object -First 1)
    if(-not $matchingId -or $hardwareId.Count -ne 1){L "Recuperacao Intel ignorada: INF sem ID compativel confirmado de $($Device.Id)." Yellow;return $false}
    $hardwareId=[string]$hardwareId[0]
    $key=$Device.Id+'|'+$Inf
    if(-not $script:IntelVideoRepairAttempts){$script:IntelVideoRepairAttempts=@{}}
    if($script:IntelVideoRepairAttempts.ContainsKey($key)){return $false}
    $script:IntelVideoRepairAttempts[$key]=$true
    L "RECUPERACAO INTEL: pnputil nao ativou o video. Aplicando INF compativel ao hardware $hardwareId : $Inf" Yellow
    try{
        $result=Invoke-IntelDriverUpdate $hardwareId ([IO.Path]::GetFullPath($Inf))
        if($result.RebootRequired){
            $script:IntelVideoRebootRequired=@($script:IntelVideoRebootRequired)+$Device.Id
            L 'Windows solicitou reinicializacao para concluir o driver Intel. Reinicio automatico desativado.' Yellow
        }
        if(-not $result.Success){
            $detail=(New-Object ComponentModel.Win32Exception($result.Error)).Message
            L "FALHA RECUPERACAO INTEL: codigo=$($result.Error) | $detail | Consulte $env:WINDIR\INF\setupapi.dev.log" Red
            return $false
        }
        Scan
        if(Test-VideoDeviceReady $Device.Id){L 'RECUPERACAO INTEL: driver de video ativo confirmado.' Green;return $true}
        if($result.RebootRequired){return $true}
        L 'A API terminou, mas o driver Intel ainda nao foi confirmado ativo.' Yellow
    }catch{L "FALHA RECUPERACAO INTEL: $($_.Exception.Message)" Red}
    return $false
}
# Executa a fase inicial de video, dando prioridade ao INF compativel e validando sua ativacao.
function InstallVideoFirst([array]$tg){
    $basic=@($tg|Where-Object{ $_.BasicVideo -and @('NVIDIA','AMD','INTEL') -contains $_.Vendor })
    foreach($g in $basic){
        L "FASE 1 VIDEO PRIMEIRO: $($g.Vendor) basico detectado." Cyan
        $roots=@()
        if($g.Vendor -eq 'NVIDIA'){
            # NVIDIA: tenta primeiro pastas especificas (RTX), depois faz fallback para NVIDIA.
            # Ajuste para GT series (ex.: GT610/GT1030): usar D:\DriversRepo\NVIDIA\GT quando existir.
            if(Test-Path -LiteralPath (Join-Path $Repo 'NVIDIA\RTX')){ $roots += (Join-Path $Repo 'NVIDIA\RTX') }

            # Detecta placa "GT" pelas Tokens/Ids (sem depender do nome amigavel do Windows).
            $isGT = $false
            try{
                if($g.Tokens){
                    foreach($t in $g.Tokens){
                        if($t -and ($t -match 'GT[0-9]{3,4}' -or $t -match 'NVIDIA\\GT\\')){ $isGT = $true; break }
                    }
                }
            } catch {}

            if($isGT){
                $gtRoot = (Join-Path $Repo 'NVIDIA\GT')
                if(Test-Path -LiteralPath $gtRoot){
                    $roots += $gtRoot
                }
            }

            # Fallback para pasta geral NVIDIA.
            if($ModoCompleto){ $roots += (Join-Path $Repo 'NVIDIA') }
            else {
                # Mesmo no modo rapido, incluir fallback NVIDIA
                if(Test-Path -LiteralPath (Join-Path $Repo 'NVIDIA')){ $roots += (Join-Path $Repo 'NVIDIA') }
            }
        } elseif($g.Vendor -eq 'AMD'){
            $roots+=(Join-Path $Repo 'AMD')
        } elseif($g.Vendor -eq 'INTEL'){
            $roots += @(Get-IntelGraphicsRoots)
            if(Test-Path -LiteralPath (Join-Path $Repo 'INTEL\Graphics')){$roots+=(Join-Path $Repo 'INTEL\Graphics')}
            $roots+=(Join-Path $Repo 'INTEL')
        }
        $c=@()
        if($g.Vendor -eq 'INTEL'){
            # Prioriza o pacote da geracao, incluindo INTEL\7th, antes da arvore geral.
            $c=@(FindInf @(Get-IntelGraphicsRoots) $g.Tokens $g.Vendor -DisplayOnly -Max $MaxCandidatesPerDevice)
        }
        if($c.Count -eq 0){ $c=@(FindInf $roots $g.Tokens $g.Vendor -DisplayOnly -Max $MaxCandidatesPerDevice) }
        if($c.Count -eq 0){
            L 'Nenhum INF de video exato encontrado rapidamente.' Yellow
            if($ForcarVideoLote){
                if($g.Vendor -eq 'NVIDIA' -and (Test-Path -LiteralPath (Join-Path $Repo 'NVIDIA\RTX'))){[void](PnpFolder (Join-Path $Repo 'NVIDIA\RTX') 'NVIDIA RTX lote forcado' $BatchTimeoutSec)}
                elseif($g.Vendor -eq 'AMD'){[void](PnpFolder (Join-Path $Repo 'AMD') 'AMD lote forcado' $BatchTimeoutSec)}
            }
            continue
        }
        foreach($i in $c){
            L "INF video Score=$($i.Score): $($i.Path)" Cyan
            $r=PnpInf $i.Path "Video $($g.Vendor)"
            # Atualiza a enumeracao e verifica se o driver deixou de ser basico.
            Scan
            if(Test-VideoDeviceReady $g.Id){
                L 'Driver de video ativo confirmado no dispositivo. Pulando demais candidatos de video.' Green
                break
            }
            if($g.Vendor -eq 'INTEL' -and (Repair-IntelBasicVideo $g $i.Path)){break}
            # So a verificacao do dispositivo confirma o driver ativo.
        }
    }
}

# ===========================================================================
# 6. FLUXO PRINCIPAL: INVENTARIO, FASES DE INSTALACAO E NOVAS VERIFICACOES
# ===========================================================================
# A lista tg e recarregada entre fases para trabalhar apenas com alvos restantes.
# A ordem atual de chamadas e preservada para manter as dependencias dos pacotes.
Clear-Host
L '============================================================' Cyan
$script:IntelVideoRepairAttempts=@{}
$script:IntelVideoRebootRequired=@()
$script:ProxyHubRebootRequired=$false
L "Versao=DriverSelection-Fast-2 / IntelVideoRecovery-2 | Script=$PSCommandPath | PowerShell=$($PSVersionTable.PSVersion)"
L '  ATUALIZAR DRIVERS' Cyan
L '============================================================' Cyan
$cpu=CpuInfo; $tg=Targets; $script:IntelGen = Get-IntelGenCpu $cpu.Name; $ultra=IsUltra $cpu $tg; $ultraPath=Join-Path $Repo 'INTEL\Chipset Ultra'
L "Repo=$Repo | CPU=$($cpu.Vendor) | NomeCPU=$($cpu.Name) | IntelGen=$script:IntelGen | IntelUltra=$ultra | Admin=$(IsAdmin)"
L "ModoCompleto=$ModoCompleto | ForcarVideoLote=$ForcarVideoLote | ForcarLoteFabricante=$ForcarLoteFabricante | DISM=$UseDismFallback | SemLoteUltra=$SemLoteUltra"
L "Dispositivos alvo: $($tg.Count)"
foreach($t in $tg){ L "TARGET: $($t.Name) | Err=$($t.Err) | Vendor=$($t.Vendor) | ID=$($t.Id)"; if($t.Tokens){L "  TOKENS: $($t.Tokens -join ' | ')"} }
if(-not(IsAdmin)){ L 'ERRO: execute Atualizar Drivers.cmd como administrador.' Red; exit 5 }

# 1) Video primeiro, para tentar entrar no Windows ja com driver de video atualizado.
InstallVideoFirst $tg
Scan -Async
$tg=Targets

# (debug removido)

# Corrige cenarios em que a pasta D:\DriversRepo\INTEL\4º existia, mas o CMD temporario quebrava o caractere º.
InstallIntelGraphicsAggressive
$tg=Targets

# 1.5) Rede/WiFi prioritario, para nao deixar controladora WiFi pendente quando o INF existe no DriversRepo.
InstallNetworkPriority $tg
Scan -Async
$tg=Targets

# 1.55) Bluetooth prioritario: evitar passar direto quando existir INF em DriversRepo.
InstallBluetoothMissingPriority $tg
Scan -Async
$tg=Targets
# 1.57) Audio prioritario: codecs HDAUDIO/Realtek/Conexant que antes passavam direto.
InstallAmdAudioCoprocessor $tg
$tg=Targets
InstallAudioMissingPriority $tg
Scan -Async
$tg=Targets
# 1.6) Intel 4a geracao: fallback especifico para video/rede em D:\DriversRepo\INTEL\4...
# Resolve casos em que o driver existe na pasta da geracao, mas o Windows nao amarrou no INF exato na primeira tentativa.
InstallIntelGraphicsAggressive
$tg=Targets

# 1.6.5) Intel 4a: Controlador de Barramento SM (SMBus) - procurar primeiro no caminho dedicado.
# Motivo: reduzir risco e acelerar a instalacao do SMBus/SM Bus.
if($script:IntelGen -eq '4'){
    $smBusPendentes=@($tg | Where-Object{
        if(-not $_){return $false}
        $s=(($_.Name+'|'+$_.Class+'|'+$_.Id+'|'+(($_.HW+$_.Compat)-join '|'))).ToUpperInvariant()
        return ($s -match 'SM\\BUS|SMBUS|SM BUS|BARRAMENTO SM|CONTROLADOR DE BARRAMENTO SM|SMBUS' -or $s -match 'SMBUS\\|SMBUS&|SMB\\')
    })

    if($smBusPendentes.Count -gt 0){
        $smRoot = Join-Path $Repo 'INTEL\Intel Chipset\Controlador_Barramento_SM'
        if(Test-Path -LiteralPath $smRoot){
            L "FASE 1.6.5 SMBUS Intel 4a: $($smBusPendentes.Count) pendente(s). Buscando INF em: $smRoot" Yellow
            $candsSM = FindInfsForMany @($smRoot) $smBusPendentes 2
            if($candsSM.Count -eq 0){
                L "SMBUS: nenhum INF encontrado no diretorio dedicado. Fallback curto no repo raiz para nao deixar pendente." Yellow
                $candsSM = FindInfsForMany @($Repo) $smBusPendentes 2
            }

            foreach($c in $candsSM){
                L "INF SMBUS Score=$($c.Score): $($c.Path)" Cyan
                [void](PnpInf $c.Path "SMBus/SM Bus Intel 4a")
                $folder=Split-Path -Parent $c.Path
                if($folder -and (Test-Path -LiteralPath $folder)){
                    [void](PnpFolder $folder "SMBus pasta do INF" 180)
                }
            }
            Scan -Async
            $tg=Targets
        } else {
            L "FASE 1.6.5 SMBUS: diretorio dedicado nao encontrado: $smRoot" Yellow
        }
    }
}

# 2) Intel Ultra rapido: tenta INFs exatos primeiro. So cai no lote se ainda sobrar.

# Observacao: so faz busca em INTEL\Chipset Ultra quando CPU for Core Ultra.
if($ultra){
    $intelTargets=@($tg|Where-Object{ -not $_.BasicVideo -and $_.Vendor -eq 'INTEL' })
    if($intelTargets.Count -gt 0){
        L "FASE 2 INTEL ULTRA RAPIDA: tentando INFs exatos antes do lote pesado. Dispositivos=$($intelTargets.Count)" Cyan

        $ultraRoot1 = (Join-Path $Repo 'INTEL\Chipset Ultra')
        $ultraRoot2 = (Join-Path $Repo 'INTEL\Intel Chipset')
        $ultraRoot3 = (Join-Path $Repo 'INTEL')
        $ultraRoot4 = $Repo

        # Cascata de roots para INFs exatos (primeiro Chipset Ultra; se faltar, fallback progressivo)
        $cands=@()
        foreach($r in @($ultraRoot1,$ultraRoot2,$ultraRoot3,$ultraRoot4)){
            if(Test-Path -LiteralPath $r){
                L "ULTRA RAPIDA: buscando INFs exatos em: $r" Cyan
                $try=FindInfsForMany @($r) $intelTargets 1
                if($try -and $try.Count -gt 0){
                    $cands += $try
                }
            }
        }

        $cands = @($cands | Sort-Object Score -Descending | Select-Object -First $intelTargets.Count | Sort-Object Path -Unique)
        L "INFs exatos selecionados: $($cands.Count)" Cyan
        foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }

        Scan -Async
        $tg=Targets
        $remainingIntel=@($tg|Where-Object{ -not $_.BasicVideo -and $_.Vendor -eq 'INTEL' })

        if($remainingIntel.Count -gt 0 -and -not $SemLoteUltra){
            $rootsLote=@()
            foreach($r in @($ultraRoot1,$ultraRoot2,$ultraRoot3,$ultraRoot4)){
                if(Test-Path -LiteralPath $r){ $rootsLote += $r }
            }

            # Aplica lote completo progressivo: começa no mais específico e vai relaxando até $Repo.
            foreach($lr in $rootsLote){
                if($remainingIntel.Count -le 0){ break }
                L "FASE 3 INTEL ULTRA LOTE: still restam $($remainingIntel.Count) dispositivo(s). Aplicando em lote: $lr" Yellow
                [void](PnpFolder $lr "Intel Ultra - fallback lote $lr" $BatchTimeoutSec)
                if($UseDismFallback){ L "DISM fallback solicitado para Intel Ultra (root=$lr)." Yellow; [void](DismFolder $lr) }
                Scan -Async
                $tg=Targets
                $remainingIntel=@($tg|Where-Object{ -not $_.BasicVideo -and $_.Vendor -eq 'INTEL' })
            }
        }
    }
} else {
    # Configuracoes gerais: busca em lote por fabricante para evitar varrer a mesma pasta varias vezes.
    $others=@($tg|Where-Object{ -not $_.BasicVideo })
    if($others.Count -gt 0){
        L "FASE 2 GERAL RAPIDA: INF exato em lote para $($others.Count) dispositivo(s)." Cyan
        foreach($v in @($others|Select-Object -ExpandProperty Vendor -Unique)){
            $devs=@($others|Where-Object{$_.Vendor -eq $v})
            if($v -eq 'UNKNOWN'){
                # Antes pulavamos UNKNOWN para nao varrer o Repo inteiro. Como agora a
                # leitura de INFs e cacheada (uma unica passada), vale buscar no Repo
                # para nao deixar driver pendente por falta de classificacao de fabricante.
                L "Vendor=UNKNOWN: buscando por tokens no DriversRepo (cache ativo, baixo custo)." Yellow
                $cands=FindInfsForMany @($Repo) $devs 1
                L "Vendor=UNKNOWN | INFs selecionados: $($cands.Count)" Cyan
                foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
                continue
            }
            $roots=RootsFor $v
            if($ModoCompleto){$roots+=$Repo}
            $cands=FindInfsForMany $roots $devs 1
            L "Vendor=$v | INFs selecionados: $($cands.Count)" Cyan
            foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
        }
        Scan -Async
        $tg=Targets
    }
}

# 2.7.5) MSI Hidden ACPI (Software Component Interface / MBID0001)
# Seu caso no log: dispositivo pendente com ID=ACPI\MBID0001\1 e Erro=28 (ConfigManagerErrorCode).
# Tenta aplicar o INF complementar que fica em D:\DriversRepo\Complementos\MSI.
try{
    $msiInf = Join-Path $Repo 'Complementos\MSI\msiswacpi.inf'
    if(-not (Test-Path -LiteralPath $msiInf)){
        # fallback direto no disco (caso o $Repo mude)
        $msiInf = 'D:\DriversRepo\Complementos\MSI\msiswacpi.inf'
    }

    $msiPend = @($tg | Where-Object{
        if(-not $_){return $false}
        $idT = ([string]$_.Id)
        return ($idT -match 'ACPI\\MBID0001')
    })

    if($msiPend.Count -gt 0){
        if(Test-Path -LiteralPath $msiInf){
            L "FASE 2.7.5 MSI: $($msiPend.Count) pendente(s) ACPI\\MBID0001. Instalando INF: $msiInf" Yellow
            [void](PnpInf $msiInf 'MSI Software Component Interface')
            Scan -Async
            $tg = Targets
        } else {
            L "FASE 2.7.5 MSI: pendente ACPI\\MBID0001, mas msiswacpi.inf nao encontrado em: $msiInf" Red
        }
    }
}catch{ L "FASE 2.7.5 MSI: erro durante instalacao: $($_.Exception.Message)" Red }

# 2.8) Intel Ultra - fase dedicada para SWC (PPM/DTT/DTTCFG)
# (Seu caso: hardware IDs começam com SWC\VID_8086_* e ficam com Erro=28.)
try{
    $swcPend=@($tg | Where-Object{
        if(-not $_){return $false}
        $idT=(($_.Id) -as [string])
        $tok=(($_.HW + $_.Compat) -join '|')
        $s=(($idT+'|'+$tok).ToUpperInvariant())
        return ($s -match 'SWC\\VID_8086|PPM_|DTT_|DTTCFG|PPM\\|DTT\\|DTTCFG\\')
    })
    if($swcPend.Count -gt 0){
        L "FASE 2.8 INTEL ULTRA SWC: $($swcPend.Count) dispositivo(s) pendente(s)." Yellow
        $ultraSwcRoots=@()
        $r1 = Join-Path $Repo 'INTEL\Chipset Ultra'
        $r2 = Join-Path $Repo 'INTEL\Intel Chipset'
        $r3 = Join-Path $Repo 'INTEL'
        $r4 = $Repo
        foreach($rr in @($r1,$r2,$r3,$r4)){
            if(Test-Path -LiteralPath $rr){$ultraSwcRoots += $rr}
        }

        # Busca por tokens exatos primeiro.
        $candsSWC = FindInfsForMany $ultraSwcRoots $swcPend 3

        # Fallback: se tokens não casarem, procura no texto por GUID/VID8086 e palavras de PPM/DTT.
        if($candsSWC.Count -eq 0){
            L 'SWC: sem INF por tokens. Fallback por texto (VID_8086/PPM/DTT) no Repo.' Yellow
            $allInfs = @(Get-InfFiles $r1)
            if($allInfs.Count -eq 0){ $allInfs = @(Get-InfFiles $r4) }
            $map=@{}
            foreach($inf in $allInfs){
                $upTxt = ReadInf $inf.FullName
                if(-not $upTxt){continue}
                if($upTxt -match 'VID_8086|SWC\\VID_8086|PPM_|DTT_|DTTCFG'){
                    foreach($d in $swcPend){
                        $score = ScoreInfText $upTxt $inf.FullName $d.Tokens $d.Vendor
                        # Força: se o INF contiver explicitamente o padrão SWC, sobe score.
                        if($score -gt 0 -and ($upTxt -match 'SWC\\VID_8086' -or $upTxt -match 'PPM_|DTT_|DTTCFG')){$score += 250}
                        if($score -gt 0){
                            if(-not $map.ContainsKey($d.Id)){$map[$d.Id]=New-Object Collections.Generic.List[object]}
                            $map[$d.Id].Add([pscustomobject]@{Device=$d;Path=$inf.FullName;Score=$score})
                        }
                    }
                }
            }
            $sel=@()
            foreach($k in $map.Keys){
                $sel += @($map[$k] | Sort-Object Score -Descending | Select-Object -First 3)
            }
            $candsSWC = @($sel | Sort-Object Path -Unique | Sort-Object Score -Descending)
        }

        L "SWC: INFs selecionados: $($candsSWC.Count)" Yellow
        foreach($c in $candsSWC){
            L "INF SWC Score=$($c.Score): $($c.Path)" Cyan
            [void](PnpInf $c.Path "Intel Ultra SWC $($c.Device.Name)")
        }

        Scan -Async
        $tg = Targets
    }
}catch{
    L "FASE 2.8 SWC: erro durante busca/instalacao: $($_.Exception.Message)" Red
}

# 3) Complementar geral: se sobrou algo, busca exata nas pastas de fabricante.
$others=@($tg|Where-Object{ -not $_.BasicVideo })
if($others.Count -gt 0){
    L "FASE COMPLEMENTAR: ainda restaram $($others.Count) dispositivo(s). Busca curta por Hardware ID exato." Cyan
    foreach($v in @($others|Select-Object -ExpandProperty Vendor -Unique)){
        $devs=@($others|Where-Object{$_.Vendor -eq $v})
        if($v -eq 'UNKNOWN'){
            # Ver FASE 2: agora buscamos UNKNOWN no Repo com cache, em vez de pular.
            L "FASE COMPLEMENTAR UNKNOWN: buscando tokens restantes no DriversRepo." Yellow
            $candsU=FindInfsForMany @($Repo) $devs 1
            foreach($c in $candsU){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
            continue
        }
        $roots=RootsFor $v; if($ModoCompleto){$roots+=$Repo}
        $cands=FindInfsForMany $roots $devs 1
        foreach($c in $cands){ L "INF Score=$($c.Score): $($c.Path)" Cyan; [void](PnpInf $c.Path $c.Device.Name) }
    }
}

if($ForcarLoteFabricante -and -not $ultra){
    L 'FASE LOTE FORCADO: fabricantes restantes.' Yellow
    foreach($v in @((Targets)|Where-Object{$_.Vendor -ne 'UNKNOWN'}|Select-Object -ExpandProperty Vendor -Unique)){
        foreach($r in (RootsFor $v|Where-Object{Test-Path -LiteralPath $_}|Select-Object -Unique)){ [void](PnpFolder $r "Lote $v" $BatchTimeoutSec) }
    }
}

# ===========================================================================
# 7. RESUMO DO COMPUTADOR E RESULTADO DA VERIFICACAO FINAL
# ===========================================================================
# Codigos finais: 0 = sem alvos; 1 = pendencias; 3010 = reinicio Intel necessario.
# Falta de repositorio retorna 2; falta de privilegios administrativos retorna 5.
# O Proxy de Hub pode aparecer apos chipset/SWC; tenta o EXE antes da verificacao final.
[void](Install-ProxyHubMissing)

L 'Scan final.' Cyan; Scan
L 'RESULTADO FINAL' Green
Start-Sleep 2

# Resumo breve do PC (CPU/RAM/GPU/Armazenamento)
# Observacao: em alguns ambientes o script pode ser executado em contexto/powershell sem o parser de expressao esperado.
# Para evitar quebra, coletamos com cmdlets simples e guardamos tudo em strings.
try{
    $cpuObj = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $cpuName = ''
    try{ if($cpuObj -and $cpuObj.Name){ $cpuName = [string]$cpuObj.Name } }catch{}

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -First 1
    $memGB = ''
    try{ if($cs -and $cs.TotalPhysicalMemory){ $memGB = [math]::Round(($cs.TotalPhysicalMemory/1GB),1).ToString() } }catch{}

    $gpuStr = ''
    try{
        $gpus = Get-CimInstance -ClassName Win32_VideoController | Select-Object Name,AdapterRAM | Sort-Object Name
        $parts=@()
        foreach($g in $gpus){
            $ramTxt=''
            try{
                if($g.AdapterRAM){ $ramTxt = ( [math]::Round(($g.AdapterRAM/1GB),1) ).ToString() + 'GB' }
            }catch{}
            $n = ''
            try{ if($g.Name){ $n=[string]$g.Name } }catch{}
            if(-not $n){ $n='GPU' }
            if($ramTxt){ $parts += @($n + ' (' + $ramTxt + ')') } else { $parts += @($n) }
        }
        if($parts -and $parts.Count -gt 0){ $gpuStr = ($parts -join ' | ') } else { $gpuStr='(nao detectada via WMI)' }
    } catch { $gpuStr='(falha ao coletar GPU via WMI)' }

    $diskStr=''
    try{
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID,Size,FreeSpace
        $dparts=@()
        foreach($d in $disks){
            $szTxt=''
            $freeTxt=''
            try{ if($d.Size){ $szTxt = [math]::Round(($d.Size/1GB),1).ToString() } }catch{}
            try{ if($d.FreeSpace){ $freeTxt = [math]::Round(($d.FreeSpace/1GB),1).ToString() } }catch{}
            $dparts += @([string]$d.DeviceID + ': ' + $szTxt + 'GB (livre ' + $freeTxt + 'GB)')
        }
        if($dparts -and $dparts.Count -gt 0){ $diskStr = ($dparts -join ' | ') } else { $diskStr='(sem discos fisicos reportados)' }
    } catch { $diskStr='(falha ao coletar armazenamento via WMI)' }

    $cpuTxt = if($cpuName){$cpuName}else{'(nao detectada)'}
    $ramTxt = if($memGB){$memGB}else{'(nao detectada)'}
    # Remove “(4GB)” e similares no caso solicitado (ex.: RTX 5060 (4GB)).
    # Mantém o nome da GPU, mas remove quantidade/VRAM entre parênteses.
    $gpuStr = $gpuStr -replace '\s*\([^)]*\d+\s*(GB|MB|TB)[^)]*\)\s*',' '
    $gpuStr = ($gpuStr -replace '\s+',' ').Trim()

    L "Resumo do PC: CPU=$cpuTxt | RAM=${ramTxt}GB | GPU=$gpuStr | Armazenamento=$diskStr" Green
} catch {

    L "Resumo do PC: (falha ao coletar detalhes via WMI: $($_.Exception.Message))" Yellow
}

Start-Sleep 3


$end=Targets
# Inclui video basico no resultado: pacote adicionado nao confirma driver ativo.
$prob=@($end)
if($prob.Count){
    L "Ainda restam $($prob.Count) dispositivo(s) alvo:" Yellow
    foreach($p in $prob){L " - $($p.Name) | Erro=$($p.Err) | Vendor=$($p.Vendor) | ID=$($p.Id)" Yellow}
}else{
    L 'Nenhum dispositivo alvo restante.' Green
}
L "Log salvo em: $Log" Cyan
if($script:IntelVideoRebootRequired.Count -gt 0 -or $script:ProxyHubRebootRequired){L 'Reinicie o Windows e execute novamente para confirmar o resultado.' Yellow;exit 3010}
if($prob.Count -gt 0){exit 1}
exit 0

