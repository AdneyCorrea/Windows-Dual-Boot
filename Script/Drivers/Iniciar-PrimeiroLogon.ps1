<#
.SYNOPSIS
    Executa atualizador e pos-processamento uma vez no primeiro logon.
.DESCRIPTION
    O XML aciona somente esta entrada. Nao instala drivers em specialize.
    Mutex e reserva atomica impedem concorrencia ou repeticao automatica.
    O controlador e oculto; o CMD do atualizador permanece visivel como no fluxo
    original. O resultado real, inclusive 3010, fica salvo para diagnostico.
#>
$ErrorActionPreference='Stop'

function Test-FirstLogonAdministrator {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-PichauSetupLog([string]$StateDirectory,[string]$Message){
    try{Add-Content -LiteralPath (Join-Path $StateDirectory 'FirstLogon-AtualizarDrivers.log') -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) -Encoding UTF8 -ErrorAction Stop}catch{}
}

function Invoke-PichauSetupCommand([string]$ScriptDirectory,[string]$Arguments,[bool]$Hidden){
    $cmd=Join-Path $ScriptDirectory 'Atualizar Drivers.cmd'
    if(-not (Test-Path -LiteralPath $cmd -PathType Leaf)){throw "Atualizador ausente: $cmd"}
    $style=if($Hidden){'Hidden'}else{'Normal'}
    $process=$null
    try{
        $commandArguments='/d /c ""{0}" {1}"' -f $cmd,$Arguments
        $process=Start-Process -FilePath $env:ComSpec -ArgumentList $commandArguments -WorkingDirectory $ScriptDirectory -WindowStyle $style -PassThru -ErrorAction Stop
        $null=$process.Handle
        # Aguarda somente o CMD; o painel de qualidade pode continuar aberto.
        $process.WaitForExit()
        if($null -eq $process.ExitCode){throw 'Atualizador nao retornou codigo de saida.'}
        return [int]$process.ExitCode
    }finally{if($process){$process.Dispose()}}
}

function Invoke-PichauStageOnce {
    param([string]$Name,[string]$ScriptDirectory,[string]$StateDirectory,[string]$Arguments,[bool]$Hidden,
          [string]$MutexName='Global\PichauPreparacaoSetup')
    $mutex=$null;$locked=$false;$claimed=$false
    $resultPath=Join-Path $StateDirectory ($Name+'.result.json')
    $oncePath=Join-Path $StateDirectory ($Name+'.once')
    try{
        New-Item -ItemType Directory -Path $StateDirectory -Force -ErrorAction Stop | Out-Null
        $mutex=[Threading.Mutex]::new($false,$MutexName)
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'O atualizador ja esta executando; nenhuma tarefa concorrente foi iniciada.'}
        if(Test-Path -LiteralPath $oncePath){
            if(Test-Path -LiteralPath $resultPath){return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)}
            return [pscustomobject]@{Stage=$Name;ExitCode=999;Status='Interrompido';FinishedAt=$null}
        }
        $stream=$null
        try{$stream=[IO.File]::Open($oncePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$claimed=$true}
        finally{if($stream){$stream.Dispose()}}
        Write-PichauSetupLog $StateDirectory ("Inicio: $Name; argumentos: $Arguments")
        $exitCode=Invoke-PichauSetupCommand $ScriptDirectory $Arguments $Hidden
        $status=if($exitCode -eq 0){'Concluido'}elseif($exitCode -eq 3010){'ReinicioNecessario'}else{'PendenciasOuFalha'}
        $result=[pscustomobject]@{Stage=$Name;ExitCode=[int]$exitCode;Status=$status;FinishedAt=(Get-Date -Format o)}
        $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8 -ErrorAction Stop
        Write-PichauSetupLog $StateDirectory ("Fim: $Name; codigo: $exitCode; status: $status")
        return $result
    }catch{
        Write-PichauSetupLog $StateDirectory ("Falha: $Name; "+$_.Exception.Message)
        if($claimed){
            $result=[pscustomobject]@{Stage=$Name;ExitCode=999;Status='FalhaNoAcionamento';Error=$_.Exception.Message;FinishedAt=(Get-Date -Format o)}
            try{$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8 -ErrorAction Stop}catch{}
            return $result
        }
        throw
    }finally{
        if($locked -and $mutex){$mutex.ReleaseMutex()}
        if($mutex){$mutex.Dispose()}
    }
}

function Invoke-FirstLogonDriversOnce {
    param([string]$ScriptDirectory,[string]$StateDirectory,
          [string]$MutexName='Global\PichauAtualizarDriversAutoOnce')
    foreach($name in @('Atualizar Drivers.cmd','Atualizar Drivers.ps1')){
        if(-not (Test-Path -LiteralPath (Join-Path $ScriptDirectory $name) -PathType Leaf)){
            throw "Arquivo obrigatorio ausente: $name"
        }
    }
    # Sem /SomenteDrivers: o CMD instala drivers e depois executa slideshow,
    # Visual C++ e Controle de Qualidade, preservando o codigo do atualizador.
    $result=Invoke-PichauStageOnce -Name 'PichauAtualizarDrivers' -ScriptDirectory $ScriptDirectory -StateDirectory $StateDirectory -Arguments '-NaoPausar' -Hidden $false -MutexName $MutexName
    return [int]$result.ExitCode
}

try{
    if(-not (Test-FirstLogonAdministrator)){
        $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -ErrorAction Stop | Out-Null
        exit 0
    }
    exit (Invoke-FirstLogonDriversOnce -ScriptDirectory $PSScriptRoot -StateDirectory (Join-Path $env:SystemRoot 'Temp'))
}catch{
    Write-PichauSetupLog (Join-Path $env:SystemRoot 'Temp') $_.Exception.Message
    exit 1
}