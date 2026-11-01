# Execute com Windows PowerShell. Carrega apenas funcoes; nao instala drivers reais.
$ErrorActionPreference='Stop'
$sourcePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'Atualizar Drivers.ps1'
$tokens=$null;$errorsFound=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errorsFound)
if($errorsFound.Count){throw ($errorsFound|Out-String)}
foreach($name in @('Write-OemFile','Tokens','Get-InfSectionLines','Get-InfModels','ScoreInfText','ReadInf','Get-InfFiles','FindInf','FindInfsForMany','PnpInf','PnpFolder')){
    $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Invoke-Expression $function.Extent.Text
}
function L {param($m,$c)}
function Assert($condition,$message){if(-not $condition){throw $message};Write-Output "OK: $message"}
$script:InfTargetOs=[version]'10.0.19045'
$script:InfTextCache=@{};$script:InfListCache=@{};$script:InfModelCache=@{};$script:InfInstallResults=@{}
$script:Calls=0; $InfTimeoutSec=35; $VideoTimeoutSec=180; $script:LastTimeout=0
function RunCmd {param($Command,$Desc,$Timeout) $script:Calls++;$script:LastTimeout=$Timeout;[pscustomobject]@{Code=124;Text='timeout simulado'}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('DriverSelection-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
try{
    $header="[VERSION]`nCLASS=DISPLAY`n[MANUFACTURER]`n%M%=MODELS,NTAMD64`n[MODELS.NTAMD64]`n"
    $full='PCI\VEN_1002&DEV_6FDF&SUBSYS_12341002'
    $generic='PCI\VEN_1002&DEV_6FDF'
    $ids=@(Tokens @($full,$generic))
    Assert ($ids.Count -eq 2 -and $ids[0] -eq $full) 'Preserva IDs completos e ordem de especificidade'
    $exact=$header+'%D%=INSTALL,'+$full
    $other=$header+'%D%=INSTALL,PCI\VEN_1002&DEV_6FDF&SUBSYS_99991002'
    $comment=$header+'; %D%=INSTALL,'+$full+"`n[STRINGS]`nLABEL="+$full
    $s1=ScoreInfText $exact 'exact.inf' $ids 'AMD' -DisplayOnly
    $s2=ScoreInfText ($header+'%D%=INSTALL,'+$generic) 'generic.inf' $ids 'AMD' -DisplayOnly
    Assert ($s1 -gt $s2 -and $s2 -gt 0) 'ID exato supera ID generico, inclusive com bonus de pasta'
    Assert ((ScoreInfText $other 'other.inf' $ids 'AMD') -eq 0) 'Rejeita outro SUBSYS apesar de compartilhar VEN/DEV'
    Assert ((ScoreInfText $comment 'comment.inf' $ids 'AMD') -eq 0) 'Ignora IDs em comentarios e Strings'
    $arch=$exact.Replace('NTAMD64','NTX86')
    Assert ((ScoreInfText $arch 'x86.inf' $ids 'AMD') -eq 0) 'Rejeita arquitetura incorreta'
    $future=$exact.Replace('NTAMD64','NTAMD64.10.0...99999')
    Assert ((ScoreInfText $future 'future.inf' $ids 'AMD') -eq 0) 'Rejeita build futura do Windows'
    $usb=$header+'%D%=INSTALL,USB\VID_8087&PID_1234&MI_02'
    Assert ((ScoreInfText $usb 'usb.inf' @('USB\VID_8087&PID_1234&MI_01','USB\VID_8087&PID_1234') 'INTEL') -eq 0) 'Rejeita outra interface USB MI'
    $swc=$header+'%D%=INSTALL,SWC\VID_8086&PID_OTHER'
    Assert ((ScoreInfText $swc 'swc.inf' @('SWC\VID_8086&PID_RIGHT') 'INTEL') -eq 0) 'Rejeita prefixo SWC sem modelo correspondente'
    $quoted="[VERSION]`nCLASS=`"DISPLAY`"`n[MANUFACTURER]`n%M%=MODELS,NTAMD64`n[MODELS.NTAMD64]`n%D%=INSTALL,%ID%`n[STRINGS]`nID=`"$full`""
    Assert ((ScoreInfText $quoted 'quoted.inf' $ids 'AMD' -DisplayOnly) -gt 0) 'Expande macros de ID e classe entre aspas'
    $multi="[VERSION]`nCLASS=DISPLAY`n[MANUFACTURER]`n%M%=MODELS,NTAMD64.10.0...19041,NTAMD64.10.0...22000`n[MODELS.NTAMD64.10.0...19041]`n%D%=INSTALL,$full`n[MODELS.NTAMD64.10.0...22000]`n%D%=INSTALL,PCI\VEN_1002&DEV_9999"
    Assert ((ScoreInfText $multi 'multi.inf' $ids 'AMD') -gt 0) 'Seleciona secao adequada ao Windows 10, sem usar a do Windows 11'
    $inf=Join-Path $fixture 'exact.inf'
    [IO.File]::WriteAllText($inf,$exact)
    $null=PnpInf $inf 'teste';$null=PnpInf $inf 'segunda fase'
    Assert ($script:Calls -eq 1) 'Timeout do mesmo INF nao e repetido em outra fase'
    Assert ($script:LastTimeout -eq 180) 'Video recebe prazo proprio sem reduzir o limite dos demais drivers'
    function Targets {[pscustomobject]@{Id='TEST';Tokens=$ids;Vendor='AMD'}}
    $before=$script:Calls
    $null=PnpFolder $fixture 'complementos'
    Assert ($script:Calls -eq $before) 'Complementos usam selecao direcionada e cache, sem lote indiscriminado'
    $macro=$header+'%D%=INSTALL,PCI\VEN_%VENDOR%&DEV_6FDF'+"`n[STRINGS]`nVENDOR=1002"
    Assert ((ScoreInfText $macro 'macro.inf' @($generic) 'AMD') -gt 0) 'Pre-filtro preserva IDs compostos por macros'
    foreach($vendor in @('INTEL','NVIDIA','AMD')){
        $vendorId=switch($vendor){'INTEL'{'8086'};'NVIDIA'{'10DE'};'AMD'{'1002'}}
        $hardware="PCI\VEN_$vendorId&DEV_1234"
        $candidate=$header+'%D%=INSTALL,'+$hardware
        Assert ((ScoreInfText $candidate ($vendor+'.inf') @($hardware) $vendor -DisplayOnly) -gt 0) "Selecao independente de marca: $vendor"
    }
    $cached=Get-InfModels '' 'exact.inf'
    Assert ($cached.Ids.ContainsKey($full)) 'Indice dos modelos e reutilizado sem reler o INF'
    # Exerce o timeout real apenas com um processo de espera, nunca pnputil.
    $realRun=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'RunCmd'},$true)
    Invoke-Expression $realRun.Extent.Text
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $slow=RunCmd 'powershell.exe -NoProfile -Command "Write-Output DRIVER_TIMEOUT_FIXTURE; Start-Sleep -Seconds 30"' 'teste de timeout inocuo' 2
    $timer.Stop()
    Assert ($slow.Code -eq 124 -and $timer.Elapsed.TotalSeconds -lt 15) 'Timeout real encerra a espera sem aguardar 30 segundos'
    Assert ($slow.Text -match 'DRIVER_TIMEOUT_FIXTURE') 'Saida parcial e preservada apos timeout'
}finally{
    # Remove apenas a pasta temporaria criada por este teste, nunca o repositorio.
    if($fixture -and (Split-Path -Parent $fixture) -eq ([IO.Path]::GetTempPath()).TrimEnd('\')){
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
Write-Output 'Todos os testes passaram. Nenhum driver foi instalado.'