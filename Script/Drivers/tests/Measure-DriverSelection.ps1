param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$InventoryLog,
    [string]$DriverScript
)
# Somente leitura: nao carrega o fluxo principal nem funcoes de instalacao.
$ErrorActionPreference='Stop'
if(-not $DriverScript){$DriverScript=Join-Path (Split-Path -Parent $PSScriptRoot) 'Atualizar Drivers.ps1'}
$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($DriverScript,[ref]$t,[ref]$e)
if($e.Count){throw($e|Out-String)}
foreach($name in @('ReadInf','Get-InfSectionLines','Get-InfModels','ScoreInfText','Get-InfFiles','FindInf','FindInfsForMany')){
    $f=$a.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if($f){Invoke-Expression $f.Extent.Text}
}
function L {param($m,$c)}
$script:InfTextCache=@{};$script:InfModelCache=@{};$script:InfListCache=@{}
$script:InfTargetOs=[version]'10.0.26100'
$devices=@();$target=$null
foreach($line in [IO.File]::ReadLines($InventoryLog)){
    if($line -match 'TARGET: (.*?) \| Err=.*?Vendor=(\w+) \| ID=(.+)$'){
        $target=[pscustomobject]@{Name=$Matches[1];Vendor=$Matches[2];Id=$Matches[3];Tokens=@()}
    }elseif($target -and $line -match 'TOKENS: (.+)$'){
        $target.Tokens=@($Matches[1] -split ' \| ');$devices+=$target;$target=$null
    }
}
foreach($vendor in @('NVIDIA','AMD','INTEL')){
    $targets=@($devices|Where-Object Vendor -eq $vendor)
    if(-not $targets.Count){continue}
    $root=Join-Path $Repo $vendor
    $watch=[Diagnostics.Stopwatch]::StartNew()
    if($vendor -eq 'NVIDIA'){$selected=@(FindInf @($root) $targets[0].Tokens $vendor -DisplayOnly -Max 2)}
    else{$selected=@(FindInfsForMany @($root) $targets 1)}
    $watch.Stop()
    [pscustomobject]@{Vendor=$vendor;Seconds=[math]::Round($watch.Elapsed.TotalSeconds,3);Candidates=$selected.Count;Paths=($selected.Path -join ' | ')}
}