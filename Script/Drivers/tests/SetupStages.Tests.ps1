# Testa o fluxo de primeiro logon sem instalar drivers ou executar utilitarios.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$t=$null;$e=$null
$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Script/Drivers/Iniciar-PrimeiroLogon.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw($e|Out-String)}
foreach($f in $a.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $f.Extent.Text}
function Assert($condition,$message){if(-not $condition){throw $message};Write-Output "OK: $message"}
$script:Calls=New-Object Collections.Generic.List[object];$script:MockExit=0
function Invoke-PichauSetupCommand {param($ScriptDirectory,$Arguments,$Hidden) $script:Calls.Add([pscustomobject]@{Args=$Arguments;Hidden=$Hidden});return $script:MockExit}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('FirstLogon-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tempRoot
try{
    foreach($name in @('autounattend-win10.xml','autounattend-win11.xml')){
        [xml]$xml=[IO.File]::ReadAllText((Join-Path $root $name))
        $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        $early=$xml.SelectNodes('//u:settings[@pass="specialize"]//u:Path[contains(text(),"Iniciar-PrimeiroLogon")]',$ns)
        $logon=$xml.SelectNodes('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine',$ns)
        Assert ($early.Count -eq 0) "$name nao instala drivers em specialize"
        Assert ($logon.Count -eq 1 -and $logon[0].InnerText -match 'Iniciar-PrimeiroLogon.ps1' -and $logon[0].InnerText -notmatch '-Stage') "$name aciona somente o primeiro logon"
    }
    foreach($file in @('Atualizar Drivers.cmd','Atualizar Drivers.ps1')){[IO.File]::WriteAllText((Join-Path $tempRoot $file),'fixture')}
    $mutex='Local\FirstLogon-'+[guid]::NewGuid().ToString('N')
    $state=Join-Path $tempRoot 'normal'
    $result=Invoke-FirstLogonDriversOnce $tempRoot $state $mutex
    $null=Invoke-FirstLogonDriversOnce $tempRoot $state $mutex
    Assert ($result -eq 0 -and $script:Calls.Count -eq 1) 'Execucao automatica unica'
    Assert ($script:Calls[0].Args -eq '-NaoPausar' -and -not $script:Calls[0].Hidden) 'CMD visivel recebe drivers e pos-processamento juntos'
    foreach($code in @(1,3010)){
        $script:MockExit=$code;$state=Join-Path $tempRoot ('return-'+$code)
        $result=Invoke-FirstLogonDriversOnce $tempRoot $state $mutex
        $before=$script:Calls.Count
        $null=Invoke-FirstLogonDriversOnce $tempRoot $state $mutex
        $saved=Get-Content (Join-Path $state 'PichauAtualizarDrivers.result.json') -Raw|ConvertFrom-Json
        Assert ($result -eq $code -and $saved.ExitCode -eq $code -and $before -eq $script:Calls.Count) "Codigo $code preservado sem repeticao automatica"
    }
    $state=Join-Path $tempRoot 'interrupted';$null=New-Item -ItemType Directory -Path $state
    [IO.File]::WriteAllText((Join-Path $state 'PichauAtualizarDrivers.once'),'reservado')
    $before=$script:Calls.Count
    $result=Invoke-FirstLogonDriversOnce $tempRoot $state $mutex
    Assert ($result -eq 999 -and $before -eq $script:Calls.Count) 'Reserva interrompida nao autoriza segunda instalacao'
    $cmdSource=[IO.File]::ReadAllText((Join-Path $root 'Script/Drivers/Atualizar Drivers.cmd'))
    $cmdSource=$cmdSource.Substring(0,$cmdSource.IndexOf('rem ROTINA CONFIGURAR_PLANO_ENERGIA:'))
    $cmdSource=$cmdSource.Replace('fltmc >nul 2>&1','cmd /d /c exit 0')
    $cmdSource=$cmdSource.Replace('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PS_ARGS%','echo DRIVERS>>"%~dp0events.txt"')
    foreach($entry in @(@('CONFIGURAR_PLANO_ENERGIA','POWER'),@('APLICAR_SLIDESHOW','WALL'),@('EXECUTAR_VISUAL_CPP','VC'),@('ABRIR_CONTROLE_QUALIDADE','QC'))){
        $cmdSource+="`r`n:$($entry[0])`r`necho $($entry[1])>>`"%~dp0events.txt`"`r`nexit /b 0`r`n"
    }
    $cmdPath=Join-Path $tempRoot 'Atualizar Drivers.cmd'
    [IO.File]::WriteAllText($cmdPath,$cmdSource,[Text.Encoding]::ASCII)
    foreach($case in @(@{Args='-NaoPausar';Expected='POWER,DRIVERS,WALL,VC,QC'},@{Args='/SomenteDrivers';Expected='POWER,DRIVERS'})){
        $events=Join-Path $tempRoot 'events.txt'
        if(Test-Path $events){Remove-Item -LiteralPath $events}
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$env:ComSpec;$psi.Arguments='/d /c ""{0}" {1}"' -f $cmdPath,$case.Args
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $proc=[Diagnostics.Process]::Start($psi)
        try{$null=$proc.StandardOutput.ReadToEnd();$null=$proc.StandardError.ReadToEnd();$proc.WaitForExit();Assert ($proc.ExitCode -eq 0) "CMD termina corretamente: $($case.Args)"}finally{$proc.Dispose()}
        Assert (((Get-Content $events)-join ',') -eq $case.Expected) "CMD executa etapas corretas: $($case.Args)"
    }
    foreach($relative in @('Script/LaunchInstall_UI.ps1','Script/Drivers/Atualizar Drivers.ps1')){
        $t=$null;$e=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$t,[ref]$e)
        Assert ($e.Count -eq 0) "Sintaxe valida: $relative"
    }
}finally{
    if($tempRoot -and (Split-Path -Parent $tempRoot) -eq ([IO.Path]::GetTempPath()).TrimEnd('\')){Remove-Item -LiteralPath $tempRoot -Recurse -Force}
}
Write-Output 'Fluxo de primeiro logon validado sem instalar drivers reais.'