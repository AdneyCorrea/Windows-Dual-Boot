#requires -Version 5.1
<#
.SYNOPSIS
  Bloqueia a descoberta de rede (multicast/broadcast) em PCs de bancada
  enquanto estao ligados na rede da empresa, e desfaz tudo antes de o PC ir
  para o cliente.

.DESCRIPTION
  Uso na bancada:
    1. ANTES de ligar o cabo de rede: opcao [2] (bloqueio agressivo).
    2. Ao TIRAR o cabo, antes de embalar: opcao [4] (desfazer).

  O PC de bancada e o produto do cliente. Com o bloqueio ativo ele NAO acha
  impressora de rede, TV, Chromecast, nem outros PCs, e jogos/consoles perdem
  UPnP. Por isso, enquanto o bloqueio estiver ativo:
    - o menu mostra uma faixa vermelha "NAO ENVIAR AO CLIENTE";
    - fica um arquivo de alerta na area de trabalho publica;
    - sair do script avisa de novo.
  O [4] remove tudo, inclusive o alerta e o backup: o PC fica como veio da
  instalacao, sem rastro deste script.

  O que e bloqueado:
    Recomendado [1]
      - mDNS          UDP 5353       (inclui as consultas WebRTC dos navegadores)
      - LLMNR         UDP/TCP 5355   (+ politica do Windows)
      - SSDP/UPnP     UDP 1900
      - WS-Discovery  UDP 3702
      - UDP 12345     (broadcast "Z-SEARCH" visto na rede da montagem)
      - Servicos SSDPSRV, upnphost, fdPHost e FDResPub desabilitados
      - Redes conectadas que nao sao de dominio passam para Publica
    Agressivo [2]
      - Tudo acima
      - NetBIOS over TCP/IP desativado, e UDP 137/138 bloqueado

  As regras de firewall so funcionam com o Firewall do Windows LIGADO. O
  script confere, liga os perfis se estiverem desligados (e o [4] devolve
  como estavam), e avisa se o servico de firewall nao estiver disponivel.

  Nao altera DHCP, DNS normal, IP, gateway nem acesso a Internet.
#>

# Fluxo do utilitário: definir configurações e funções -> verificar elevação ->
# exibir menu -> aplicar, consultar ou restaurar conforme a opção escolhida.
# As alterações de rede só começam nas ações disparadas pelo menu.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIGURACAO
# ---------------------------------------------------------------------------

# O backup é compartilhado entre execuções e usuários do computador. O prefixo
# identifica exclusivamente as regras criadas e removidas por este utilitário.
$BaseDir    = Join-Path $env:ProgramData 'Pichau\NetworkDiscoveryBlock'
$StateFile  = Join-Path $BaseDir 'state.json'
$RulePrefix = 'Pichau-Bench-DiscoveryBlock'

$DnsClientKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'

# Alerta visivel para quem for embalar o PC. Removido pelo [4].
$AlertFile = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) `
    'ATENCAO - BLOQUEIO DE REDE ATIVO - DESFAZER ANTES DE ENVIAR AO CLIENTE.txt'

# Serviços que publicam ou descobrem equipamentos na rede local.
$ServicesToDisable = @(
    'SSDPSRV',   # SSDP Discovery
    'upnphost',  # UPnP Device Host
    'fdPHost',   # Function Discovery Provider Host
    'FDResPub'   # Function Discovery Resource Publication
)

# Tipo de inicializacao padrao do Windows 10/11 para esses servicos. Usado no
# [4] quando o backup nao existe mais: o PC do cliente precisa voltar ao
# padrao de qualquer jeito.
$ServiceDefaults = @{
    'SSDPSRV'  = 'Manual'
    'upnphost' = 'Manual'
    'fdPHost'  = 'Manual'
    'FDResPub' = 'Manual'
}

# Regras do modo recomendado e as extras do agressivo. A contagem e usada
# para dizer se o bloqueio esta completo.
$BaseRules = @(
    @{ Suffix = 'mDNS-Out-UDP-5353';   Direction = 'Outbound'; Protocol = 'UDP'; Port = 5353 }
    @{ Suffix = 'mDNS-In-UDP-5353';    Direction = 'Inbound';  Protocol = 'UDP'; Port = 5353 }
    @{ Suffix = 'LLMNR-Out-UDP-5355';  Direction = 'Outbound'; Protocol = 'UDP'; Port = 5355 }
    @{ Suffix = 'LLMNR-In-UDP-5355';   Direction = 'Inbound';  Protocol = 'UDP'; Port = 5355 }
    @{ Suffix = 'LLMNR-Out-TCP-5355';  Direction = 'Outbound'; Protocol = 'TCP'; Port = 5355 }
    @{ Suffix = 'LLMNR-In-TCP-5355';   Direction = 'Inbound';  Protocol = 'TCP'; Port = 5355 }
    @{ Suffix = 'SSDP-Out-UDP-1900';   Direction = 'Outbound'; Protocol = 'UDP'; Port = 1900 }
    @{ Suffix = 'SSDP-In-UDP-1900';    Direction = 'Inbound';  Protocol = 'UDP'; Port = 1900 }
    @{ Suffix = 'WSD-Out-UDP-3702';    Direction = 'Outbound'; Protocol = 'UDP'; Port = 3702 }
    @{ Suffix = 'WSD-In-UDP-3702';     Direction = 'Inbound';  Protocol = 'UDP'; Port = 3702 }
    @{ Suffix = 'ZSEARCH-Out-UDP-12345'; Direction = 'Outbound'; Protocol = 'UDP'; Port = 12345 }
    @{ Suffix = 'ZSEARCH-In-UDP-12345';  Direction = 'Inbound';  Protocol = 'UDP'; Port = 12345 }
)
$NetBiosRules = @(
    @{ Suffix = 'NetBIOS-NS-Out-UDP-137';  Direction = 'Outbound'; Protocol = 'UDP'; Port = 137 }
    @{ Suffix = 'NetBIOS-NS-In-UDP-137';   Direction = 'Inbound';  Protocol = 'UDP'; Port = 137 }
    @{ Suffix = 'NetBIOS-DGM-Out-UDP-138'; Direction = 'Outbound'; Protocol = 'UDP'; Port = 138 }
    @{ Suffix = 'NetBIOS-DGM-In-UDP-138';  Direction = 'Inbound';  Protocol = 'UDP'; Port = 138 }
)

# ---------------------------------------------------------------------------
# INTERFACE
# ---------------------------------------------------------------------------

# Padronizam o significado visual das mensagens sem alterar o fluxo de execução.
function Write-Info([string]$Message)         { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)           { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message)         { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-ErrorMessage([string]$Message) { Write-Host "[ERRO] $Message" -ForegroundColor Red }

# Mantém o resultado da ação visível até o operador pressionar ENTER.
function Pause-Script {
    Write-Host ''
    [void](Read-Host 'Pressione ENTER para continuar')
}

# Verifica o token da sessão atual para decidir se será necessária elevação UAC.
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Alerta reutilizado no cabeçalho, após aplicar o bloqueio e antes de sair.
function Write-ClienteWarning {
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#                                                          #' -ForegroundColor Red
    Write-Host '#    BLOQUEIO DE REDE ATIVO  -  NAO ENVIAR AO CLIENTE      #' -ForegroundColor Red
    Write-Host '#                                                          #' -ForegroundColor Red
    Write-Host '#    Antes de embalar: tire o cabo e use a opcao [4]       #' -ForegroundColor Red
    Write-Host '#    para DESFAZER o bloqueio.                             #' -ForegroundColor Red
    Write-Host '#                                                          #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
}

# Reconstrói o cabeçalho e consulta novamente o estado ao abrir cada tela.
function Show-Header {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '     PICHAU - CONTROLE DE DESCOBERTA DE REDE / BANCADA' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host "Computador : $env:COMPUTERNAME"
    Write-Host "Usuario    : $env:USERNAME"
    Write-Host ''
    if ((Get-BlockState).Active) { Write-ClienteWarning }
}

# Apenas apresenta as opções; a execução de cada ação fica no switch principal.
function Show-Menu {
    Show-Header
    Write-Host 'Escolha uma opcao:' -ForegroundColor White
    Write-Host ''
    Write-Host '  [1] Aplicar bloqueio RECOMENDADO' -ForegroundColor Green
    Write-Host '      mDNS, LLMNR, SSDP/UPnP, WS-Discovery, UDP 12345 e servicos de descoberta.'
    Write-Host ''
    Write-Host '  [2] Aplicar bloqueio AGRESSIVO  (usar ANTES de ligar o cabo)' -ForegroundColor Yellow
    Write-Host '      Tudo acima + NetBIOS UDP 137/138.'
    Write-Host ''
    Write-Host '  [3] Ver STATUS atual' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [4] DESFAZER o bloqueio  (usar ANTES de enviar ao cliente)' -ForegroundColor Magenta
    Write-Host ''
    Write-Host '  [0] Sair'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# ESTADO DO BLOQUEIO
# ---------------------------------------------------------------------------

# Retorna somente regras cujo nome começa com o prefixo definido na configuração.
function Get-ScriptRules {
    return @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$RulePrefix-*" })
}

# Separa existência/execução do serviço dos perfis habilitados. Ter regras
# cadastradas não basta: o firewall também precisa estar efetivamente ativo.
function Get-FirewallHealth {
    $svc = Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue
    $profiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue |
        Select-Object Name, @{ N = 'Enabled'; E = { [string]$_.Enabled } })
    $off = @($profiles | Where-Object { $_.Enabled -ne 'True' })
    return [pscustomobject]@{
        ServiceRunning = ($svc -and $svc.Status -eq 'Running')
        ServiceExists  = [bool]$svc
        Profiles       = $profiles
        AllOn          = ($profiles.Count -gt 0 -and $off.Count -eq 0)
    }
}

# Qualquer vestigio conta como ativo: o que importa e que o PC nao va para o
# cliente com NADA disto ligado.
function Get-BlockState {
    # Levanta sinais de configuração para status e verificações de restauração.
    # Active é determinado pelos marcadores próprios: regras, backup ou alerta.
    $rules = Get-ScriptRules
    $llmnr = Get-ItemProperty -Path $DnsClientKey -Name 'EnableMulticast' -ErrorAction SilentlyContinue
    $disabledSvcs = @(foreach ($s in $ServicesToDisable) {
        $c = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
        if ($c -and $c.StartMode -eq 'Disabled') { $s }
    })
    $netbiosOff = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
        Where-Object { $_.TcpipNetbiosOptions -eq 2 })
    return [pscustomobject]@{
        Active         = ($rules.Count -gt 0 -or (Test-Path $StateFile) -or (Test-Path -LiteralPath $AlertFile))
        Rules          = $rules
        LlmnrDisabled  = ($null -ne $llmnr -and $llmnr.EnableMulticast -eq 0)
        DisabledSvcs   = $disabledSvcs
        NetbiosOff     = $netbiosOff
        StateExists    = (Test-Path $StateFile)
        AlertExists    = (Test-Path -LiteralPath $AlertFile)
    }
}

# ---------------------------------------------------------------------------
# BACKUP DO ESTADO ORIGINAL
# ---------------------------------------------------------------------------

# Captura os valores necessários para desfazer a configuração antes de aplicar
# qualquer bloqueio: LLMNR, serviços, perfis de rede, NetBIOS e perfis de firewall.
function Save-InitialState {
    # Preserva o PRIMEIRO backup: rodar [1] e depois [2] nao pode fazer o
    # "original" virar o estado ja bloqueado.
    if (Test-Path $StateFile) {
        Write-Info 'Backup do estado original ja existe; sera preservado.'
        return
    }

    New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

    $llmnrProp = Get-ItemProperty -Path $DnsClientKey -Name 'EnableMulticast' -ErrorAction SilentlyContinue

    # Preserva o tipo de inicialização e a condição de execução de cada serviço,
    # incluindo o indicador de inicialização automática atrasada.
    $services = @(foreach ($s in $ServicesToDisable) {
        $c = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
        if ($c) {
            [pscustomobject]@{
                Name             = $c.Name
                StartMode        = $c.StartMode
                DelayedAutoStart = [bool]$c.DelayedAutoStart
                State            = $c.State
            }
        }
    })

    # SettingID permite reencontrar cada adaptador na restauração, mesmo que
    # a ordem em que os adaptadores são enumerados mude entre execuções.
    $netbios = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                SettingID           = $_.SettingID
                Description         = $_.Description
                TcpipNetbiosOptions = [int]$_.TcpipNetbiosOptions
            }
        })

    $state = [pscustomobject]@{
        SavedAt          = (Get-Date).ToString('o')
        LLMNR            = [pscustomobject]@{
            Exists = ($null -ne $llmnrProp)
            Value  = if ($null -ne $llmnrProp) { [int]$llmnrProp.EnableMulticast } else { $null }
        }
        Services         = $services
        NetworkProfiles  = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                              Select-Object Name, InterfaceAlias, InterfaceIndex,
                                            @{ N = 'NetworkCategory'; E = { [string]$_.NetworkCategory } })
        NetBIOS          = $netbios
        FirewallProfiles = @((Get-FirewallHealth).Profiles)
    }

    # O JSON conserva a hierarquia e é lido pela opção de desfazer.
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
    Write-Ok "Estado original salvo em $StateFile"
}

# ---------------------------------------------------------------------------
# FIREWALL
# ---------------------------------------------------------------------------

# Recria uma regra pelo nome para permitir reaplicação sem duplicatas. Em saída
# a porta é remota; em entrada a porta é local. A regra vale para qualquer perfil.
function Add-BlockRule([hashtable]$Rule) {
    $name = "$RulePrefix-$($Rule.Suffix)"
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    $params = @{
        Name        = $name
        DisplayName = $name
        Group       = $RulePrefix
        Description = 'Bloqueio de descoberta de rede para PCs de bancada. Remover antes de enviar ao cliente.'
        Direction   = $Rule.Direction
        Protocol    = $Rule.Protocol
        Action      = 'Block'
        Profile     = 'Any'
        Enabled     = 'True'
    }
    if ($Rule.Direction -eq 'Outbound') { $params.RemotePort = $Rule.Port } else { $params.LocalPort = $Rule.Port }
    New-NetFirewallRule @params | Out-Null
}

# Regra de firewall nao faz nada com o firewall desligado. Liga os perfis que
# estiverem desligados (o backup guarda como estavam) e devolve se o firewall
# esta efetivamente filtrando.
function Enable-FirewallForBlock {
    $h = Get-FirewallHealth
    if (-not $h.ServiceExists -or -not $h.ServiceRunning) {
        Write-ErrorMessage 'O servico do Firewall do Windows (MpsSvc) nao esta rodando.'
        Write-ErrorMessage 'As regras serao criadas, mas NAO terao efeito ate o firewall voltar.'
        return $false
    }
    foreach ($p in $h.Profiles) {
        if ($p.Enabled -ne 'True') {
            try {
                Set-NetFirewallProfile -Name $p.Name -Enabled True
                Write-Ok "Firewall ligado no perfil $($p.Name) (o [4] devolve como estava)."
            }
            catch {
                Write-ErrorMessage "Nao foi possivel ligar o firewall no perfil $($p.Name): $($_.Exception.Message)"
            }
        }
    }
    return (Get-FirewallHealth).AllOn
}

# Cria as regras comuns e acrescenta as de NetBIOS no modo agressivo. Ao voltar
# ao recomendado, remove as regras extras deixadas por uma execução anterior.
function Set-FirewallBlockRules([switch]$IncludeNetBios) {
    Write-Info 'Criando regras de firewall...'
    foreach ($r in $BaseRules) { Add-BlockRule $r }
    if ($IncludeNetBios) {
        foreach ($r in $NetBiosRules) { Add-BlockRule $r }
    } else {
        # Uma execucao agressiva anterior pode ter deixado as de NetBIOS.
        Get-ScriptRules | Where-Object { $_.Name -like "$RulePrefix-NetBIOS-*" } |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    Write-Ok "$((Get-ScriptRules).Count) regra(s) de bloqueio ativas."
}

# ---------------------------------------------------------------------------
# CONFIGURACOES DO WINDOWS
# ---------------------------------------------------------------------------

# Desativa a resolução multicast pela política do cliente DNS do Windows.
function Disable-LLMNR {
    New-Item -Path $DnsClientKey -Force | Out-Null
    New-ItemProperty -Path $DnsClientKey -Name 'EnableMulticast' -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Ok 'LLMNR desativado.'
}

# Converte redes conectadas em públicas, preservando as autenticadas em domínio
# e as que já são públicas. Redes ausentes neste momento não são modificadas.
function Set-NonDomainProfilesPublic {
    $conexoes = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($conexoes.Count -eq 0) {
        Write-Info 'Nenhuma rede conectada agora (normal antes de ligar o cabo). As regras valem para qualquer rede.'
        return
    }
    foreach ($conexao in $conexoes) {
        if ([string]$conexao.NetworkCategory -notin @('DomainAuthenticated', 'Public')) {
            try {
                Set-NetConnectionProfile -InterfaceIndex $conexao.InterfaceIndex -NetworkCategory Public
                Write-Ok "Rede '$($conexao.Name)' alterada para Publica."
            }
            catch {
                Write-Warn "Nao foi possivel alterar '$($conexao.Name)' para Publica."
            }
        }
    }
}

# Para e desabilita os serviços configurados, tolerando serviços inexistentes
# nesta edição do Windows e registrando falhas individuais para o operador.
function Disable-DiscoveryServices {
    foreach ($svcName in $ServicesToDisable) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Info "Servico $svcName nao existe nesta instalacao."
            continue
        }
        try {
            if ($svc.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction Stop }
            Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop
            Write-Ok "$svcName parado e desabilitado."
        }
        catch {
            Write-Warn "Falha ao alterar ${svcName}: $($_.Exception.Message)"
        }
    }
}

# Aplica a opção 2 (desativado) somente aos adaptadores com IP habilitado. As
# regras de porta complementam o bloqueio para adaptadores ligados posteriormente.
function Disable-NetBIOS {
    $adapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)
    foreach ($adapter in $adapters) {
        try {
            $result = Invoke-CimMethod -InputObject $adapter -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 }
            if ($result.ReturnValue -eq 0) { Write-Ok "NetBIOS desativado: $($adapter.Description)" }
            else { Write-Warn "NetBIOS retornou codigo $($result.ReturnValue): $($adapter.Description)" }
        }
        catch {
            Write-Warn "Falha ao desativar NetBIOS: $($adapter.Description)"
        }
    }
    Write-Info 'Adaptador ligado depois (ex.: Wi-Fi USB) fica coberto pelas regras UDP 137/138.'
}

# Cria o lembrete operacional na área de trabalho pública. O texto é um arquivo
# de saída para a equipe e contém as instruções de remoção antes do envio.
function Write-AlertFile {
    $texto = @"
ATENCAO - BLOQUEIO DE REDE DE BANCADA ATIVO
==========================================

Este PC esta com a descoberta de rede BLOQUEADA para uso na bancada
(Pichau-Bench-DiscoveryBlock), aplicado em $(Get-Date -Format 'dd/MM/yyyy HH:mm').

NAO ENVIE ESTE PC AO CLIENTE ASSIM.
Com o bloqueio, o cliente nao consegue achar impressora de rede, TV,
Chromecast nem outros PCs, e jogos/consoles perdem UPnP.

Para desfazer:
  1. Tire o cabo de rede.
  2. Rode o script Bloquear-Descoberta-Rede-Bancada-Interativo.ps1
  3. Escolha a opcao [4] DESFAZER.

Este arquivo some sozinho quando o bloqueio e desfeito.
"@
    Set-Content -LiteralPath $AlertFile -Value $texto -Encoding UTF8
    Write-Ok 'Alerta "NAO ENVIAR AO CLIENTE" criado na area de trabalho.'
}

# ---------------------------------------------------------------------------
# APLICACAO
# ---------------------------------------------------------------------------

# Orquestra a aplicação na ordem necessária: backup antes das alterações,
# alerta visível, preparação do firewall e configurações do modo escolhido.
function Invoke-ApplyBlock([switch]$Aggressive) {
    Show-Header
    $titulo = if ($Aggressive) { 'APLICANDO BLOQUEIO AGRESSIVO' } else { 'APLICANDO BLOQUEIO RECOMENDADO' }
    Write-Host $titulo -ForegroundColor Yellow
    Write-Host '------------------------------------------------------------'
    Write-Host ''

    $problemas = @()
    try {
        Save-InitialState
        Write-AlertFile
        $firewallOk = Enable-FirewallForBlock
        if (-not $firewallOk) { $problemas += 'Firewall do Windows nao esta filtrando: as regras de porta NAO tem efeito.' }
        Disable-LLMNR
        Set-NonDomainProfilesPublic
        Disable-DiscoveryServices
        Set-FirewallBlockRules -IncludeNetBios:$Aggressive
        if ($Aggressive) { Disable-NetBIOS }

        # Confere a quantidade de regras esperada para o modo selecionado.
        $esperadas = $BaseRules.Count + $(if ($Aggressive) { $NetBiosRules.Count } else { 0 })
        $criadas = (Get-ScriptRules).Count
        if ($criadas -lt $esperadas) { $problemas += "So $criadas de $esperadas regras de firewall foram criadas." }
    }
    catch {
        $problemas += $_.Exception.Message
    }

    Write-Host ''
    if ($problemas.Count -eq 0) {
        Write-Host '============================================================' -ForegroundColor Green
        Write-Host ' BLOQUEIO APLICADO E EFETIVO' -ForegroundColor Green
        Write-Host '============================================================' -ForegroundColor Green
    } else {
        Write-Host '============================================================' -ForegroundColor Red
        Write-Host ' BLOQUEIO APLICADO COM PROBLEMAS' -ForegroundColor Red
        Write-Host '============================================================' -ForegroundColor Red
        $problemas | ForEach-Object { Write-ErrorMessage $_ }
    }
    Write-Host ''
    Write-ClienteWarning
    Pause-Script
}

# ---------------------------------------------------------------------------
# DESFAZER
# ---------------------------------------------------------------------------

# Recupera o tipo de inicialização salvo e inicia o serviço caso ele estivesse
# em execução no backup. A alternativa sc.exe cobre o PowerShell 5.1.
function Restore-ServiceState([string]$Name, [string]$StartMode, [bool]$Delayed, [string]$State) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    try {
        if ($StartMode -eq 'Auto' -and $Delayed) {
            # Set-Service do 5.1 nao conhece "automatico atrasado".
            & sc.exe config $Name start= delayed-auto | Out-Null
        } else {
            $tipo = switch ($StartMode) { 'Auto' { 'Automatic' } 'Disabled' { 'Disabled' } default { 'Manual' } }
            Set-Service -Name $Name -StartupType $tipo
        }
        if ($State -eq 'Running') { Start-Service -Name $Name -ErrorAction SilentlyContinue }
        Write-Ok "Servico $Name restaurado ($StartMode)."
    }
    catch {
        Write-Warn "Falha ao restaurar ${Name}: $($_.Exception.Message)"
    }
}

# Exige a confirmação operacional do menu e desfaz as alterações por categoria.
# Sem backup legível, usa os padrões definidos neste arquivo onde aplicável.
function Invoke-Restore {
    Show-Header
    Write-Host 'DESFAZER BLOQUEIO (preparar para enviar ao cliente)' -ForegroundColor Magenta
    Write-Host '------------------------------------------------------------'
    Write-Host ''

    $answer = Read-Host 'Tirou o cabo de rede e quer desfazer o bloqueio? (S/N)'
    if ("$answer" -notmatch '^(s|sim)$') {
        Write-Info 'Operacao cancelada. O bloqueio continua ATIVO.'
        Pause-Script
        return
    }

    # Um backup ausente ou ilegível mantém o fluxo de recuperação disponível.
    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content -Path $StateFile -Raw | ConvertFrom-Json }
        catch { Write-Warn "Backup ilegivel ($($_.Exception.Message)); sera usado o padrao do Windows." }
    } else {
        Write-Warn 'Backup nao encontrado: restaurando para o PADRAO do Windows.'
    }

    # 1. Regras de firewall
    Get-ScriptRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-Ok 'Regras de bloqueio removidas.'

    # 2. LLMNR
    if ($state -and $state.LLMNR.Exists) {
        New-Item -Path $DnsClientKey -Force | Out-Null
        New-ItemProperty -Path $DnsClientKey -Name 'EnableMulticast' -PropertyType DWord -Value ([int]$state.LLMNR.Value) -Force | Out-Null
        Write-Ok "Politica LLMNR restaurada para $($state.LLMNR.Value)."
    } else {
        Remove-ItemProperty -Path $DnsClientKey -Name 'EnableMulticast' -ErrorAction SilentlyContinue
        Write-Ok 'LLMNR de volta ao padrao (politica nao configurada).'
    }

    # 3. Servicos
    foreach ($s in $ServicesToDisable) {
        $salvo = if ($state) { @($state.Services) | Where-Object { $_.Name -eq $s } | Select-Object -First 1 }
        if ($salvo) {
            Restore-ServiceState -Name $s -StartMode $salvo.StartMode -Delayed ([bool]$salvo.DelayedAutoStart) -State $salvo.State
        } else {
            Restore-ServiceState -Name $s -StartMode $ServiceDefaults[$s] -Delayed $false -State 'Stopped'
        }
    }

    # 4. NetBIOS: do backup; sem backup, 0 (padrao: segue o DHCP)
    foreach ($adapter in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)) {
        $salvo = if ($state) { @($state.NetBIOS) | Where-Object { $_.SettingID -eq $adapter.SettingID } | Select-Object -First 1 }
        $valor = if ($salvo) { [int]$salvo.TcpipNetbiosOptions } else { 0 }
        if ([int]$adapter.TcpipNetbiosOptions -ne $valor) {
            try {
                $null = Invoke-CimMethod -InputObject $adapter -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]$valor }
                Write-Ok "NetBIOS restaurado ($valor): $($adapter.Description)"
            }
            catch { Write-Warn "Falha ao restaurar NetBIOS: $($adapter.Description)" }
        }
    }

    # 5. Perfis de rede que ainda existirem (com o cabo fora, normalmente nenhum)
    if ($state) {
        foreach ($item in @($state.NetworkProfiles)) {
            $atual = Get-NetConnectionProfile -InterfaceIndex $item.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $atual -or [string]$atual.NetworkCategory -eq 'DomainAuthenticated') { continue }
            if ([string]$item.NetworkCategory -notin @('Public', 'Private')) { continue }
            try {
                Set-NetConnectionProfile -InterfaceIndex $item.InterfaceIndex -NetworkCategory $item.NetworkCategory
                Write-Ok "Perfil '$($item.InterfaceAlias)' restaurado para $($item.NetworkCategory)."
            }
            catch { Write-Warn "Nao foi possivel restaurar o perfil '$($item.InterfaceAlias)'." }
        }
    }

    # 6. Firewall: so desliga de novo o perfil que ESTAVA desligado antes
    if ($state -and $state.FirewallProfiles) {
        foreach ($p in @($state.FirewallProfiles)) {
            if ($p.Enabled -and $p.Enabled -ne 'True') {
                try {
                    Set-NetFirewallProfile -Name $p.Name -Enabled $p.Enabled
                    Write-Ok "Firewall do perfil $($p.Name) devolvido para $($p.Enabled)."
                }
                catch { Write-Warn "Nao foi possivel devolver o firewall do perfil $($p.Name)." }
            }
        }
    }

    # 7. Sem rastro: alerta, backup e pasta
    Remove-Item -LiteralPath $AlertFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $BaseDir -Force -ErrorAction SilentlyContinue
    $pai = Split-Path $BaseDir -Parent
    if ((Test-Path $pai) -and -not (Get-ChildItem -LiteralPath $pai -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $pai -Force -ErrorAction SilentlyContinue
    }

    # Conferencia final pelo efeito
    $b = Get-BlockState
    $sobras = @()
    if ($b.Rules.Count -gt 0)       { $sobras += "$($b.Rules.Count) regra(s) de firewall" }
    if ($b.LlmnrDisabled -and -not ($state -and $state.LLMNR.Exists)) { $sobras += 'LLMNR desativado' }
    $aindaDesab = @($b.DisabledSvcs | Where-Object {
        $s = $_; -not ($state -and (@($state.Services) | Where-Object { $_.Name -eq $s -and $_.StartMode -eq 'Disabled' }))
    })
    if ($aindaDesab.Count -gt 0)    { $sobras += "servico(s) ainda desabilitado(s): $($aindaDesab -join ', ')" }
    if ($b.AlertExists)             { $sobras += 'arquivo de alerta na area de trabalho' }
    if ($b.StateExists)             { $sobras += 'arquivo de backup' }

    Write-Host ''
    if ($sobras.Count -eq 0) {
        Write-Host '============================================================' -ForegroundColor Green
        Write-Host ' BLOQUEIO DESFEITO - PC PRONTO PARA O CLIENTE' -ForegroundColor Green
        Write-Host '============================================================' -ForegroundColor Green
    } else {
        Write-Host '============================================================' -ForegroundColor Red
        Write-Host ' DESFEITO COM PENDENCIAS - NAO ENVIE AINDA' -ForegroundColor Red
        Write-Host '============================================================' -ForegroundColor Red
        $sobras | ForEach-Object { Write-ErrorMessage "Ainda presente: $_" }
        Write-Host 'Rode o [4] de novo. Se persistir, chame o suporte.' -ForegroundColor Yellow
    }
    Pause-Script
}

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------

# Consulta e apresenta a situação atual; não aplica configurações. Os detalhes
# permitem distinguir regras cadastradas de firewall efetivamente filtrando.
function Show-Status {
    Show-Header
    Write-Host 'STATUS ATUAL' -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------'
    Write-Host ''

    $b = Get-BlockState
    $f = Get-FirewallHealth
    $netbiosRules = @($b.Rules | Where-Object { $_.Name -like "$RulePrefix-NetBIOS-*" })

    if (-not $b.Active) {
        Write-Host 'Bloqueio    : INATIVO - PC como veio da instalacao' -ForegroundColor Green
    } elseif ($netbiosRules.Count -gt 0) {
        Write-Host 'Bloqueio    : ATIVO (AGRESSIVO)' -ForegroundColor Red
    } else {
        Write-Host 'Bloqueio    : ATIVO (RECOMENDADO)' -ForegroundColor Red
    }

    Write-Host ("Regras      : {0} regra(s) do script" -f $b.Rules.Count)
    if ($b.Active) {
        if ($f.ServiceRunning -and $f.AllOn) {
            Write-Host 'Firewall    : LIGADO - as regras estao em efeito' -ForegroundColor Green
        } else {
            Write-Host 'Firewall    : DESLIGADO/PARCIAL - as regras NAO tem efeito' -ForegroundColor Red
        }
    } else {
        $txt = if ($f.ServiceRunning -and $f.AllOn) { 'ligado' } else { 'desligado ou parcial' }
        Write-Host "Firewall    : $txt"
    }
    Write-Host ("LLMNR       : {0}" -f $(if ($b.LlmnrDisabled) { 'DESATIVADO' } else { 'padrao' }))
    Write-Host ("Backup      : {0}" -f $(if ($b.StateExists) { $StateFile } else { 'nenhum' }))
    Write-Host ("Alerta      : {0}" -f $(if ($b.AlertExists) { 'na area de trabalho' } else { 'nenhum' }))
    Write-Host ''

    Write-Host 'PERFIS DO FIREWALL' -ForegroundColor White
    $f.Profiles | Format-Table -AutoSize | Out-Host

    Write-Host 'SERVICOS DE DESCOBERTA' -ForegroundColor White
    Get-Service -Name $ServicesToDisable -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-Host

    Write-Host 'REDES CONECTADAS' -ForegroundColor White
    $conexoes = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($conexoes.Count -gt 0) { $conexoes | Select-Object Name, InterfaceAlias, NetworkCategory | Format-Table -AutoSize | Out-Host }
    else { Write-Host '  nenhuma'; Write-Host '' }

    Write-Host 'NETBIOS DOS ADAPTADORES  (0 = padrao/DHCP, 1 = ligado, 2 = desligado)' -ForegroundColor White
    Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
        Select-Object Description, TcpipNetbiosOptions | Format-Table -AutoSize | Out-Host

    Pause-Script
}

# ---------------------------------------------------------------------------
# PRINCIPAL
# ---------------------------------------------------------------------------

# Carregado com ". .\script.ps1" (testes), so define as funcoes.
if ($MyInvocation.InvocationName -eq '.') { return }

# A elevação abre novamente o mesmo arquivo no Windows PowerShell; a instância
# atual encerra após solicitá-la. Cancelamento ou falha resulta em saída com erro.
if (-not (Test-IsAdministrator)) {
    try {
        Write-Host ''
        Write-Host 'Este script precisa de privilegios de administrador.' -ForegroundColor Yellow
        Write-Host 'Solicitando elevacao pelo UAC...' -ForegroundColor Cyan
        Start-Process -FilePath 'powershell.exe' -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
    catch {
        Write-Host ''
        Write-Host 'Nao foi possivel obter privilegios de administrador.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
        [void](Read-Host 'Pressione ENTER para sair')
        exit 1
    }
}

# Mantém o menu ativo até a opção 0. Os modos agressivo e desfazer possuem suas
# próprias confirmações e a saída relembra pendências quando há bloqueio ativo.
do {
    Show-Menu
    $option = "$(Read-Host 'Opcao')".Trim()

    switch ($option) {
        '1' { Invoke-ApplyBlock }
        '2' {
            Show-Header
            Write-Host 'O modo agressivo tambem desativa o NetBIOS.' -ForegroundColor Yellow
            $answer = Read-Host 'Aplicar o bloqueio AGRESSIVO? (S/N)'
            if ("$answer" -match '^(s|sim)$') { Invoke-ApplyBlock -Aggressive }
        }
        '3' { Show-Status }
        '4' { Invoke-Restore }
        '0' {
            Clear-Host
            if ((Get-BlockState).Active) {
                Write-ClienteWarning
                Write-Host 'Lembre de rodar a opcao [4] antes de enviar este PC ao cliente.' -ForegroundColor Yellow
                Write-Host ''
                [void](Read-Host 'Pressione ENTER para sair')
            }
            Write-Host 'Encerrando...' -ForegroundColor Cyan
        }
        default {
            Write-Host ''
            Write-Warn 'Opcao invalida.'
            Start-Sleep -Seconds 1
        }
    }
}
while ($option -ne '0')
