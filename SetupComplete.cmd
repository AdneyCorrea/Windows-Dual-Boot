@echo off
setlocal EnableExtensions

rem MAPA: prepara os arquivos; FirstLogonCommands no XML e o unico gatilho dos drivers.
rem Chamado pelo Windows ao concluir a instalacao; nao deve ser executado como teste.
rem Consulte README.md e docs/ARQUITETURA.md na midia para o fluxo completo.

rem 01. Destinos locais, logs e marcadores usados para evitar execucao duplicada.
set "LOG=C:\Windows\Temp\SetupComplete-Pichau.log"
set "SCRIPTS=C:\Windows\Setup\Scripts"
set "TEMP=C:\Windows\Temp"
set "CUSTOM=C:\Windows\Web\Custom"
set "WALL=%CUSTOM%\wallpaper.jpg"
set "LOCKSCREEN=%CUSTOM%\lockscreen.jpg"
set "LOCAL_DRIVER_CMD=%SCRIPTS%\Atualizar Drivers.cmd"
set "LOCAL_DRIVER_PS1=%SCRIPTS%\Atualizar Drivers.ps1"
set "LOCAL_FIRSTLOGON_PS1=%SCRIPTS%\Iniciar-PrimeiroLogon.ps1"
set "LOCAL_PROXY_DIR=%SCRIPTS%\ProxyHub"
set "LOCAL_QC_DIR=%SCRIPTS%\Controle de Qualidade"
set "LOCAL_QC_EXE=%LOCAL_QC_DIR%\Controle de Qualidade.exe"
set "LOCAL_VC_EXE=%SCRIPTS%\[AquaX]Visual C++.exe"
set "LOCAL_OCCT_EXE=%SCRIPTS%\OCCT.exe"
set "LOCAL_OCCT_CFG=%SCRIPTS%\OCCT.config.json"
set "LOCAL_BIOS_CMD=%SCRIPTS%\BIOS.cmd"
set "LOCAL_WALLPAPER_DIR=%SCRIPTS%\Wallpaper"
set "LOCAL_SLIDESHOW_PS1=%SCRIPTS%\AplicarSlideshow.ps1"
set "FIRSTLOGON_CMD=%SCRIPTS%\Pichau_FirstLogon_AtualizarDrivers.cmd"
set "STARTUP_CMD=C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Pichau_FirstLogon_AtualizarDrivers.cmd"
set "RUNONCE_KEY=HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce"
set "RUNONCE_VAL=PichauAtualizarDrivers"
set "DONE=%TEMP%\PichauAtualizarDrivers.done"
set "LOCKDIR=%TEMP%\PichauAtualizarDrivers.lock"
set "MEDIA="
set "DRIVER_OK="

if not exist "%TEMP%" mkdir "%TEMP%" >nul 2>&1
if not exist "%SCRIPTS%" mkdir "%SCRIPTS%" >nul 2>&1
if not exist "%CUSTOM%" mkdir "%CUSTOM%" >nul 2>&1

call :log ========================================================
call :log SetupComplete iniciado

rem 02. Procura a midia pelas pastas esperadas sem depender de uma letra fixa.
for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z C) do (
    if not defined MEDIA if exist "%%D:\Script\LaunchInstall_UI.ps1" set "MEDIA=%%D:\Script"
    if not defined MEDIA if exist "%%D:\Script\Instalador\LaunchInstall_UI.ps1" set "MEDIA=%%D:\Script"
    if not defined MEDIA if exist "%%D:\Script\Drivers\Atualizar Drivers.cmd" if exist "%%D:\Script\Drivers\Atualizar Drivers.ps1" set "MEDIA=%%D:\Script"
    if not defined MEDIA if exist "%%D:\Script\Atualizar Drivers.cmd" if exist "%%D:\Script\Atualizar Drivers.ps1" set "MEDIA=%%D:\Script"
    if not defined MEDIA if exist "%%D:\Script\Controle de Qualidade\Controle de Qualidade.exe" set "MEDIA=%%D:\Script"
    if not defined MEDIA if exist "%%D:\Atualizar Drivers.cmd" if exist "%%D:\Atualizar Drivers.ps1" set "MEDIA=%%D:\"
    if not defined MEDIA if exist "%%D:\Controle de Qualidade\Controle de Qualidade.exe" set "MEDIA=%%D:\"
    if not defined MEDIA if exist "%%D:\Script\Branding\wallpaper.jpg" set "MEDIA=%%D:\Script"
    if not defined MEDIA if exist "%%D:\Script\wallpaper.jpg" set "MEDIA=%%D:\Script"
)

rem 03. Copia as imagens de identidade visual se a midia estiver acessivel.
if defined MEDIA (
    call :log Midia encontrada em %MEDIA%
    if exist "%MEDIA%\Branding\wallpaper.jpg" (copy /Y "%MEDIA%\Branding\wallpaper.jpg" "%WALL%" >>"%LOG%" 2>>&1) else if exist "%MEDIA%\wallpaper.jpg" copy /Y "%MEDIA%\wallpaper.jpg" "%WALL%" >>"%LOG%" 2>>&1
    if exist "%MEDIA%\Branding\lockscreen.jpg" (copy /Y "%MEDIA%\Branding\lockscreen.jpg" "%LOCKSCREEN%" >>"%LOG%" 2>>&1) else if exist "%MEDIA%\lockscreen.jpg" copy /Y "%MEDIA%\lockscreen.jpg" "%LOCKSCREEN%" >>"%LOG%" 2>>&1
) else (
    call :log AVISO: pasta Script do pendrive nao encontrada. Usando apenas arquivos ja copiados, se existirem.
)

rem 04. Prepara os scripts e utilitarios na ordem exigida pelo primeiro logon.
call :remove_old_driver_files
call :copy_only_atualizar_drivers
call :copy_proxy_hub
call :copy_visual_cpp
call :copy_controle_qualidade
call :copy_occt
call :copy_bios
call :copy_wallpaper
call :fix_uac_for_firstlogon
call :clear_old_triggers

rem 05. Confere os arquivos. Nao registra RunOnce nem Startup.
if exist "%LOCAL_DRIVER_CMD%" if exist "%LOCAL_DRIVER_PS1%" if exist "%LOCAL_FIRSTLOGON_PS1%" set "DRIVER_OK=1"
if not defined DRIVER_OK (
    call :log ERRO: Arquivos obrigatorios dos drivers ou controlador ausentes em %SCRIPTS%.
    goto :finish
)

call :log Drivers preparados. FirstLogonCommands fara uma unica chamada ao controlador oculto.

rem 06. Encerra o fluxo principal; as rotinas abaixo sao chamadas por CALL.
:finish
call :log SetupComplete finalizado
exit /b 0

rem ROTINA remove_old_driver_files: Remove nomes antigos somente da pasta local de instalacao para evitar conflitos.

:remove_old_driver_files
call :log Removendo scripts antigos de drivers para evitar conflito
for %%F in (
    "%SCRIPTS%\Instalar_Drivers_Offline.cmd"
    "%SCRIPTS%\Instalar_Drivers_Offline.ps1"
    "%SCRIPTS%\Instalar_Drivers_Offline_Rapido.cmd"
    "%SCRIPTS%\Instalar_Drivers_Offline_Rapido.ps1"
    "%SCRIPTS%\Instalar_Drivers_Offline - RAPIDO.cmd"
    "%SCRIPTS%\Instalar_Drivers_Offline - RAPIDO.ps1"
) do if exist "%%~F" del /f /q "%%~F" >>"%LOG%" 2>>&1
goto :eof

rem ROTINA copy_only_atualizar_drivers: Copia o atualizador da estrutura organizada; aceita tambem a estrutura antiga plana.

:copy_only_atualizar_drivers
if defined MEDIA (
    if exist "%MEDIA%\Drivers\Atualizar Drivers.cmd" (
        copy /Y "%MEDIA%\Drivers\Atualizar Drivers.cmd" "%LOCAL_DRIVER_CMD%" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\Drivers\Atualizar Drivers.cmd
    ) else if exist "%MEDIA%\Atualizar Drivers.cmd" (
        copy /Y "%MEDIA%\Atualizar Drivers.cmd" "%LOCAL_DRIVER_CMD%" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\Atualizar Drivers.cmd
    ) else (
        call :log ERRO: nao encontrei %MEDIA%\Atualizar Drivers.cmd
    )

    if exist "%MEDIA%\Drivers\Atualizar Drivers.ps1" (
        copy /Y "%MEDIA%\Drivers\Atualizar Drivers.ps1" "%LOCAL_DRIVER_PS1%" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\Drivers\Atualizar Drivers.ps1
    ) else if exist "%MEDIA%\Atualizar Drivers.ps1" (
        copy /Y "%MEDIA%\Atualizar Drivers.ps1" "%LOCAL_DRIVER_PS1%" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\Atualizar Drivers.ps1
    ) else (
        call :log ERRO: nao encontrei %MEDIA%\Atualizar Drivers.ps1
    )
)
rem Copia o controlador oculto para a chamada unica de primeiro logon definida no XML.
if defined MEDIA (
    if exist "%MEDIA%\Drivers\Iniciar-PrimeiroLogon.ps1" (
        copy /Y "%MEDIA%\Drivers\Iniciar-PrimeiroLogon.ps1" "%LOCAL_FIRSTLOGON_PS1%" >>"%LOG%" 2>>&1
    ) else if exist "%MEDIA%\Iniciar-PrimeiroLogon.ps1" (
        copy /Y "%MEDIA%\Iniciar-PrimeiroLogon.ps1" "%LOCAL_FIRSTLOGON_PS1%" >>"%LOG%" 2>>&1
    )
)

goto :eof

rem ROTINA copy_proxy_hub: Disponibiliza o EXE; o atualizador decide se o hardware precisa dele.
:copy_proxy_hub
if defined MEDIA (
    for %%P in (
        "%MEDIA%\Drivers\ProxyHub\DISPOSITIVO DE PROXY HUB.EXE"
        "%MEDIA%\..\Outros\DISPOSITIVO DE PROXY HUB.EXE"
        "%MEDIA%\ProxyHub\DISPOSITIVO DE PROXY HUB.EXE"
    ) do if exist "%%~P" (
        if not exist "%LOCAL_PROXY_DIR%" mkdir "%LOCAL_PROXY_DIR%" >nul 2>&1
        copy /Y "%%~P" "%LOCAL_PROXY_DIR%\DISPOSITIVO DE PROXY HUB.EXE" >>"%LOG%" 2>>&1
        call :log Instalador Proxy de Hub copiado.
        goto :eof
    )
)
goto :eof

rem ROTINA copy_visual_cpp: Localiza e copia o instalador Visual C++ para uso apos os drivers.

:copy_visual_cpp
if defined MEDIA (
    for %%V in (
        "%MEDIA%\Utilitarios\[AquaX]Visual C++.exe"
        "%MEDIA%\[AquaX]Visual C++.exe"
        "%MEDIA%\Visual C++.exe"
        "%MEDIA%\AquaX Visual C++.exe"
    ) do (
        if exist "%%~V" (
            copy /Y "%%~V" "%LOCAL_VC_EXE%" >>"%LOG%" 2>>&1
            call :log Copiado: %%~V para %LOCAL_VC_EXE%
            goto :eof
        )
    )
    call :log AVISO: instalador Visual C++ nao encontrado em %MEDIA%
)
goto :eof

rem ROTINA copy_occt: Disponibiliza a ferramenta independente OCCT; nao integra o painel.

:copy_occt
rem Copia o OCCT (exe + config) para C:\Windows\Setup\Scripts.
rem Disponibiliza o executavel para uso independente na instalacao local.
rem O painel de diagnostico nao possui botao nem rota para executar OCCT.
if defined MEDIA (
    for %%O in (
        "%MEDIA%\Utilitarios\OCCT.exe"
        "%MEDIA%\..\(4) OCCT.exe"
        "%MEDIA%\OCCT.exe"
        "%MEDIA%\Controle de Qualidade\OCCT.exe"
    ) do if exist "%%~O" (
        copy /Y "%%~O" "%LOCAL_OCCT_EXE%" >>"%LOG%" 2>>&1
        if exist "%%~dpOOCCT.config.json" copy /Y "%%~dpOOCCT.config.json" "%LOCAL_OCCT_CFG%" >>"%LOG%" 2>>&1
        call :log Copiado OCCT de %%~dpO para %SCRIPTS%
        goto :copy_occt_ensure_cfg
    )
    call :log AVISO: OCCT.exe nao encontrado em %MEDIA% nem em %MEDIA%\Controle de Qualidade
) else (
    call :log AVISO: pasta Script do pendrive nao encontrada; nao foi possivel copiar o OCCT.
)
rem ROTINA copy_occt_ensure_cfg: Completa a configuracao OCCT caso o executavel tenha sido encontrado em outra pasta.

:copy_occt_ensure_cfg
rem Garante que a config do OCCT exista junto do exe, copiando de qualquer
rem copia local conhecida (pasta do app ou raiz dos scripts).
if not exist "%LOCAL_OCCT_CFG%" (
    for %%C in (
        "%MEDIA%\Utilitarios\OCCT.config.json"
        "%LOCAL_QC_DIR%\OCCT.config.json"
        "%MEDIA%\OCCT.config.json"
        "%MEDIA%\Controle de Qualidade\OCCT.config.json"
    ) do if not exist "%LOCAL_OCCT_CFG%" if exist "%%~C" copy /Y "%%~C" "%LOCAL_OCCT_CFG%" >>"%LOG%" 2>>&1
)
if exist "%LOCAL_OCCT_EXE%" ( call :log OCCT presente em %LOCAL_OCCT_EXE% ) else ( call :log AVISO: OCCT.exe ausente em %SCRIPTS% apos a copia. )
goto :eof
rem ROTINA copy_bios: Copia o comando de reinicio em firmware, com caminhos alternativos.

:copy_bios
rem Copia o BIOS.cmd para C:\Windows\Setup\Scripts.
rem O launcher do Controle de Qualidade procura o BIOS.cmd na pasta pai
rem (C:\Windows\Setup\Scripts\BIOS.cmd) e depois na propria pasta do app,
rem por isso o script precisa existir aqui apos o SetupComplete.
if defined MEDIA (
    for %%B in (
        "%MEDIA%\Utilitarios\BIOS.cmd"
        "%MEDIA%\BIOS.cmd"
        "%MEDIA%\Controle de Qualidade\BIOS.cmd"
    ) do if exist "%%~B" (
        copy /Y "%%~B" "%LOCAL_BIOS_CMD%" >>"%LOG%" 2>>&1
        call :log Copiado BIOS.cmd de %%~dpB para %SCRIPTS%
        goto :copy_bios_done
    )
    call :log AVISO: BIOS.cmd nao encontrado em %MEDIA% nem em %MEDIA%\Controle de Qualidade
) else (
    call :log AVISO: pasta Script do pendrive nao encontrada; nao foi possivel copiar o BIOS.cmd.
)
rem ROTINA copy_bios_done: Finaliza a copia do comando BIOS e registra o resultado.

:copy_bios_done
if exist "%LOCAL_BIOS_CMD%" ( call :log BIOS.cmd presente em %LOCAL_BIOS_CMD% ) else ( call :log AVISO: BIOS.cmd ausente em %SCRIPTS% apos a copia. )
goto :eof

rem ROTINA copy_wallpaper: Copia imagens e aplicadores usados pelo pos-processamento automatico dos drivers.

:copy_wallpaper
rem Copia a pasta Script\Wallpaper inteira (uma unica vez) para o disco local.
rem Ela sera usada como apresentacao de slides (papel de parede) ao final da atualizacao de drivers.
rem Usa robocopy para trazer a pasta completa sem precisar listar imagem por imagem.
if defined MEDIA (
    if exist "%MEDIA%\Wallpaper" (
        call :log Copiando pasta Wallpaper para %LOCAL_WALLPAPER_DIR%
        if exist "%LOCAL_WALLPAPER_DIR%" rmdir /s /q "%LOCAL_WALLPAPER_DIR%" >>"%LOG%" 2>>&1
        robocopy "%MEDIA%\Wallpaper" "%LOCAL_WALLPAPER_DIR%" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >>"%LOG%" 2>>&1
        if exist "%LOCAL_WALLPAPER_DIR%" ( call :log Pasta Wallpaper copiada com sucesso. ) else ( call :log ERRO: falha ao copiar a pasta Wallpaper. )
    ) else (
        call :log AVISO: pasta Wallpaper nao encontrada em %MEDIA%
    )

    rem Copia o script que aplica a pasta como slideshow nativo do Windows.
    if exist "%MEDIA%\Wallpaper\AplicarSlideshow.ps1" (
        copy /Y "%MEDIA%\Wallpaper\AplicarSlideshow.ps1" "%LOCAL_SLIDESHOW_PS1%" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\Wallpaper\AplicarSlideshow.ps1
    ) else if exist "%MEDIA%\AplicarSlideshow.ps1" (
        copy /Y "%MEDIA%\AplicarSlideshow.ps1" "%LOCAL_SLIDESHOW_PS1%" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\AplicarSlideshow.ps1
    ) else (
        call :log AVISO: AplicarSlideshow.ps1 nao encontrado em %MEDIA%
    )
    rem Copia o executavel independente que aplica o slideshow (para rodar manualmente).
    if exist "%MEDIA%\Wallpaper\AplicarSlideshow.exe" (
        copy /Y "%MEDIA%\Wallpaper\AplicarSlideshow.exe" "%SCRIPTS%\AplicarSlideshow.exe" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\Wallpaper\AplicarSlideshow.exe
    ) else if exist "%MEDIA%\AplicarSlideshow.exe" (
        copy /Y "%MEDIA%\AplicarSlideshow.exe" "%SCRIPTS%\AplicarSlideshow.exe" >>"%LOG%" 2>>&1
        call :log Copiado: %MEDIA%\AplicarSlideshow.exe
    ) else (
        call :log AVISO: AplicarSlideshow.exe nao encontrado em %MEDIA%
    )
)
goto :eof

rem ROTINA copy_controle_qualidade: Copia o painel completo, incluindo scripts e arquivos web.

:copy_controle_qualidade
if defined MEDIA (
    if exist "%MEDIA%\Controle de Qualidade\Controle de Qualidade.exe" (
        call :log Copiando Controle de Qualidade para %LOCAL_QC_DIR%
        if exist "%LOCAL_QC_DIR%" rmdir /s /q "%LOCAL_QC_DIR%" >>"%LOG%" 2>>&1
        robocopy "%MEDIA%\Controle de Qualidade" "%LOCAL_QC_DIR%" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >>"%LOG%" 2>>&1
        if exist "%LOCAL_QC_EXE%" (
            call :log Controle de Qualidade copiado com sucesso.
        ) else (
            call :log ERRO: falha ao copiar Controle de Qualidade.
        )
    ) else (
        call :log AVISO: Controle de Qualidade nao encontrado em %MEDIA%\Controle de Qualidade
    )
)
goto :eof

rem ROTINA fix_uac_for_firstlogon: Prepara as politicas existentes de elevacao e o servico Appinfo.

:fix_uac_for_firstlogon
call :log Aplicando configuracao de elevacao para o primeiro logon
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f >>"%LOG%" 2>>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f >>"%LOG%" 2>>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f >>"%LOG%" 2>>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v FilterAdministratorToken /t REG_DWORD /d 0 /f >>"%LOG%" 2>>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f >>"%LOG%" 2>>&1
sc config Appinfo start= demand >>"%LOG%" 2>>&1
sc start Appinfo >>"%LOG%" 2>>&1
goto :eof

rem ROTINA clear_old_triggers: Limpa gatilhos e marcadores anteriores antes de preparar o primeiro logon.

:clear_old_triggers
call :log Limpando gatilhos antigos
reg delete "%RUNONCE_KEY%" /v "%RUNONCE_VAL%" /f >>"%LOG%" 2>>&1
reg delete "%RUNONCE_KEY%" /v "PichauFirstLogonDrivers" /f >>"%LOG%" 2>>&1
if exist "%STARTUP_CMD%" del /f /q "%STARTUP_CMD%" >>"%LOG%" 2>>&1
if exist "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Pichau_FirstLogon_Drivers.cmd" del /f /q "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Pichau_FirstLogon_Drivers.cmd" >>"%LOG%" 2>>&1
if exist "%FIRSTLOGON_CMD%" del /f /q "%FIRSTLOGON_CMD%" >>"%LOG%" 2>>&1
if exist "%DONE%" del /f /q "%DONE%" >>"%LOG%" 2>>&1
if exist "%LOCKDIR%" rmdir /s /q "%LOCKDIR%" >>"%LOG%" 2>>&1
goto :eof

rem ROTINA log: Recebe o texto apos CALL e o acrescenta ao log com data e hora.

:log
echo [%date% %time%] %*>>"%LOG%"
goto :eof
