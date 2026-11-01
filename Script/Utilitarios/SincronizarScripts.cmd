@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
title Sincronizar Scripts para o disco local

rem ============================================================
rem SincronizarScripts.cmd
rem
rem Copia TODOS os arquivos necessarios da pasta Script (pendrive/midia)
rem para o disco local (C:\Windows\Setup\Scripts), garantindo que o
rem fluxo de primeiro logon funcione:
rem   - Atualizar Drivers.cmd / .ps1
rem   - Controle de Qualidade (app completo + launcher atualizado)
rem   - AplicarSlideshow.exe / .ps1  (wallpaper/slideshow)
rem   - Pasta Wallpaper (imagens do slideshow)
rem   - Visual C++, OCCT, BIOS.cmd, wallpapers de branding
rem
rem Use isto quando o computador ja foi formatado e voce quer apenas
rem aplicar/atualizar os arquivos no disco local sem reinstalar tudo.
rem ============================================================

rem 01. Resolve a pasta Script na estrutura atual ou em uma copia plana antiga.
set "SRC=%~dp0"
if exist "%~dp0..\Drivers\Atualizar Drivers.ps1" for %%S in ("%~dp0..") do set "SRC=%%~fS\"
set "MEDIA_ROOT=%SRC%"
if exist "%SRC%..\SetupComplete.cmd" for %%M in ("%SRC%..") do set "MEDIA_ROOT=%%~fM\"
rem 02. Destino e log; o primeiro argumento pode indicar outra pasta.
set "DEST=C:\Windows\Setup\Scripts"
rem Permite informar um destino alternativo como 1o argumento (util para testes):
if not "%~1"=="" set "DEST=%~1"
rem Log: usa C:\Windows\Temp quando disponivel/gravavel; senao a pasta TEMP do usuario.
set "LOG=C:\Windows\Temp\SincronizarScripts.log"
if not exist "C:\Windows\Temp" mkdir "C:\Windows\Temp" >nul 2>&1
if not exist "C:\Windows\Temp" set "LOG=%TEMP%\SincronizarScripts.log"
(echo.>>"%LOG%") 2>nul || set "LOG=%TEMP%\SincronizarScripts.log"

for %%L in ("%LOG%") do if not exist "%%~dpL" mkdir "%%~dpL" >nul 2>&1
if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1

rem 03. Solicita elevacao; as copias seguintes atualizam a instalacao local.
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Solicitando permissao de administrador...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

echo ============================================================
echo   SINCRONIZAR SCRIPTS PARA O DISCO LOCAL
echo ============================================================
echo   Origem : %SRC%
echo   Destino: %DEST%
echo ============================================================
echo.

call :log ========================================================
call :log Sincronizacao iniciada
call :log Origem: %SRC%
call :log Destino: %DEST%

rem 04. Copia os arquivos atuais para os nomes planos esperados pelo primeiro logon.
call :copiar_arquivo "Drivers\Atualizar Drivers.cmd" "Atualizar Drivers.cmd"
call :copiar_arquivo "Drivers\Atualizar Drivers.ps1" "Atualizar Drivers.ps1"
call :copiar_arquivo "Drivers\Iniciar-PrimeiroLogon.ps1" "Iniciar-PrimeiroLogon.ps1"
call :copiar_arquivo "Drivers\ProxyHub\DISPOSITIVO DE PROXY HUB.EXE" "DISPOSITIVO DE PROXY HUB.EXE" "%DEST%\ProxyHub"
call :copiar_arquivo "Wallpaper\AplicarSlideshow.exe" "AplicarSlideshow.exe"
call :copiar_arquivo "Wallpaper\AplicarSlideshow.ps1" "AplicarSlideshow.ps1"
call :copiar_arquivo "Utilitarios\BIOS.cmd" "BIOS.cmd"
if exist "%SRC%Utilitarios\OCCT.exe" (
  call :copiar_arquivo "Utilitarios\OCCT.exe" "OCCT.exe"
) else (
  call :copiar_arquivo "(4) OCCT.exe" "OCCT.exe" "%DEST%" "%MEDIA_ROOT%"
)
call :copiar_arquivo "Utilitarios\OCCT.config.json" "OCCT.config.json"
call :copiar_arquivo "Utilitarios\[AquaX]Visual C++.exe" "[AquaX]Visual C++.exe"
call :copiar_arquivo "Branding\wallpaper.jpg" "wallpaper.jpg"
call :copiar_arquivo "Branding\lockscreen.jpg" "lockscreen.jpg"
call :copiar_arquivo "Instalador\winpe-wallpaper.jpg" "winpe-wallpaper.jpg"
call :copiar_arquivo "Branding\logo.png" "logo.png"
if exist "%SRC%LaunchInstall_UI.ps1" (
  call :copiar_arquivo "LaunchInstall_UI.ps1" "LaunchInstall_UI.ps1" "%DEST%\Script"
) else (
  call :copiar_arquivo "Instalador\LaunchInstall_UI.ps1" "LaunchInstall_UI.ps1" "%DEST%\Script"
)
call :copiar_arquivo "SetupComplete.cmd" "SetupComplete.cmd" "%DEST%" "%MEDIA_ROOT%"
call :copiar_arquivo "autounattend-win10.xml" "autounattend-win10.xml" "%DEST%" "%MEDIA_ROOT%"
call :copiar_arquivo "autounattend-win11.xml" "autounattend-win11.xml" "%DEST%" "%MEDIA_ROOT%"

rem Pasta Wallpaper (imagens do slideshow) - copia a pasta inteira de uma vez.
echo Copiando pasta Wallpaper...
if exist "%SRC%Wallpaper" (
  if exist "%DEST%\Wallpaper" rmdir /s /q "%DEST%\Wallpaper" >nul 2>&1
  robocopy "%SRC%Wallpaper" "%DEST%\Wallpaper" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF "AplicarSlideshow.exe" "AplicarSlideshow.ps1" "AplicarSlideshow.cs" >>"%LOG%" 2>&1
  call :log Pasta Wallpaper copiada.
) else (
  call :log AVISO: pasta Wallpaper nao encontrada em %SRC%Wallpaper
)

rem Controle de Qualidade (app completo, incluindo launcher.ps1 atualizado).
echo Copiando Controle de Qualidade...
if exist "%SRC%Controle de Qualidade\Controle de Qualidade.exe" (
  if exist "%DEST%\Controle de Qualidade" rmdir /s /q "%DEST%\Controle de Qualidade" >nul 2>&1
  robocopy "%SRC%Controle de Qualidade" "%DEST%\Controle de Qualidade" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >>"%LOG%" 2>&1
  if exist "%DEST%\Controle de Qualidade\Controle de Qualidade.exe" (
    call :log Controle de Qualidade copiado com sucesso.
  ) else (
    call :log ERRO: falha ao copiar Controle de Qualidade.
  )
) else (
  call :log AVISO: Controle de Qualidade nao encontrado em %SRC%Controle de Qualidade
)

echo.
echo ============================================================
echo   CONCLUIDO
echo ============================================================
echo Arquivos essenciais no disco local:
call :verificar "%DEST%\Atualizar Drivers.cmd"
call :verificar "%DEST%\Atualizar Drivers.ps1"
call :verificar "%DEST%\AplicarSlideshow.exe"
call :verificar "%DEST%\AplicarSlideshow.ps1"
call :verificar "%DEST%\Controle de Qualidade\Controle de Qualidade.exe"
call :verificar "%DEST%\Controle de Qualidade\launcher.ps1"
call :verificar "%DEST%\Wallpaper"
call :verificar "%DEST%\Script\LaunchInstall_UI.ps1"

call :log Sincronizacao finalizada.
echo.
echo Log: %LOG%
exit /b 0

rem ROTINA copiar_arquivo: Copia um arquivo e registra ausencia sem interromper os demais arquivos.

:copiar_arquivo
rem Recebe origem relativa, nome final, destino opcional e pasta de origem opcional.
set "ARQ=%~1"
set "NOME=%~2"
set "PASTA=%~3"
set "ORIGEM=%~4"
if not defined ORIGEM set "ORIGEM=%SRC%"
if not defined PASTA set "PASTA=%DEST%"
if not exist "%PASTA%" mkdir "%PASTA%" >nul 2>&1
if exist "%ORIGEM%%ARQ%" (
  copy /Y "%ORIGEM%%ARQ%" "%PASTA%\%NOME%" >>"%LOG%" 2>&1
  call :log Copiado: %ARQ% como %NOME%
  echo   [OK] %ARQ% como %NOME%
) else (
  call :log AVISO: %ARQ% nao encontrado em %ORIGEM%
  echo   [--] %ARQ% - nao encontrado na origem
)
exit /b 0

rem ROTINA verificar: Mostra se cada arquivo essencial existe no destino.

:verificar
if exist "%~1" (
  echo   [OK] %~1
) else (
  echo   [FALTA] %~1
)
exit /b 0

rem ROTINA log: Acrescenta mensagens com data e hora no arquivo de log.

:log
echo [%date% %time%] %*>>"%LOG%"
exit /b 0
