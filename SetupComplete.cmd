@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "LOG=C:\Windows\Temp\SetupComplete-Pichau.log"
set "SCRIPTDIR=C:\Windows\Setup\Scripts"
set "CUSTOM=C:\Windows\Web\Custom"
set "WALL=%CUSTOM%\wallpaper.jpg"
set "LOCK=%CUSTOM%\lockscreen.jpg"
set "MEDIA="
set "DEFAULTUSER=C:\Users\Default\NTUSER.DAT"
set "APPLYPS1=%SCRIPTDIR%\ApplyUserBranding.ps1"
set "FIRSTLOGONCMD=%SCRIPTDIR%\FirstLogon_Pichau.cmd"

if not exist "C:\Windows\Temp" mkdir "C:\Windows\Temp" >nul 2>&1
if not exist "%SCRIPTDIR%" mkdir "%SCRIPTDIR%" >nul 2>&1
if not exist "%CUSTOM%" mkdir "%CUSTOM%" >nul 2>&1

call :log ========================================================
call :log SetupComplete iniciado

for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\Script" (
        set "MEDIA=%%D:\Script"
        goto :media_found
    )
)

:media_found
if defined MEDIA (
    call :log Midia encontrada em %MEDIA%
) else (
    call :log Pasta Script do pendrive nao encontrada
)

call :copy_media
call :apply_branding_files
call :clear_policies
call :write_apply_ps1
call :write_firstlogon_cmd
call :remove_old_triggers
call :prepare_default_user
call :prepare_machine_runonce

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f >>"%LOG%" 2>>&1

call :log SetupComplete finalizado
exit /b 0

:copy_media
if not defined MEDIA goto :eof

if exist "%MEDIA%\wallpaper.jpg" (
    copy /Y "%MEDIA%\wallpaper.jpg" "%WALL%" >>"%LOG%" 2>>&1
    call :log wallpaper.jpg copiado
) else (
    call :log wallpaper.jpg nao encontrado no pendrive
)

if exist "%MEDIA%\lockscreen.jpg" (
    copy /Y "%MEDIA%\lockscreen.jpg" "%LOCK%" >>"%LOG%" 2>>&1
    call :log lockscreen.jpg copiado
) else (
    call :log lockscreen.jpg nao encontrado no pendrive
)

if exist "%MEDIA%\Instalar_Drivers_Offline.cmd" (
    copy /Y "%MEDIA%\Instalar_Drivers_Offline.cmd" "%SCRIPTDIR%\Instalar_Drivers_Offline.cmd" >>"%LOG%" 2>>&1
    call :log Instalar_Drivers_Offline.cmd copiado para %SCRIPTDIR%
) else (
    call :log Instalar_Drivers_Offline.cmd nao encontrado no pendrive
)

if exist "%MEDIA%\Instalar_Drivers_Offline.ps1" (
    copy /Y "%MEDIA%\Instalar_Drivers_Offline.ps1" "%SCRIPTDIR%\Instalar_Drivers_Offline.ps1" >>"%LOG%" 2>>&1
    call :log Instalar_Drivers_Offline.ps1 copiado para %SCRIPTDIR%
) else (
    call :log Instalar_Drivers_Offline.ps1 nao encontrado no pendrive
)
goto :eof

:apply_branding_files
if exist "%WALL%" (
    if not exist "C:\Windows\Web\Wallpaper\Windows" mkdir "C:\Windows\Web\Wallpaper\Windows" >nul 2>&1
    copy /Y "%WALL%" "C:\Windows\Web\Wallpaper\Windows\img0.jpg" >>"%LOG%" 2>>&1
    if exist "C:\Windows\Web\4K\Wallpaper\Windows" (
        for %%F in ("C:\Windows\Web\4K\Wallpaper\Windows\*.jpg") do copy /Y "%WALL%" "%%~fF" >>"%LOG%" 2>>&1
    )
    call :log Arquivos padrao de wallpaper atualizados
)

if exist "%LOCK%" (
    if exist "C:\Windows\Web\Screen" (
        for %%F in ("C:\Windows\Web\Screen\*.jpg") do copy /Y "%LOCK%" "%%~fF" >>"%LOG%" 2>>&1
    )
    call :log Arquivos padrao de lockscreen atualizados
)
goto :eof

:clear_policies
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v NoChangingWallPaper /f >nul 2>&1
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v NoChangingWallPaper /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /f >nul 2>&1
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /f >nul 2>&1
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /f >nul 2>&1
reg delete "HKLM\Software\Policies\Microsoft\Windows\Personalization" /v LockScreenImage /f >nul 2>&1
reg delete "HKLM\Software\Policies\Microsoft\Windows\Personalization" /v NoChangingLockScreen /f >nul 2>&1
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\PersonalizationCSP" /f >nul 2>&1
call :log Politicas de personalizacao removidas

goto :eof

:write_apply_ps1
> "%APPLYPS1%" (
    echo $ErrorActionPreference = 'SilentlyContinue'
    echo $wall = 'C:\Windows\Web\Custom\wallpaper.jpg'
    echo $log = 'C:\Windows\Temp\FirstLogon-Pichau.log'
    echo Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop' -Name 'NoChangingWallPaper' -ErrorAction SilentlyContinue
    echo Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'Wallpaper' -ErrorAction SilentlyContinue
    echo Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'WallpaperStyle' -ErrorAction SilentlyContinue
    echo if ^(Test-Path $wall^) ^{
    echo ^    New-Item -Path 'HKCU:\Control Panel\Desktop' -Force ^| Out-Null
    echo ^    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wall
    echo ^    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    echo ^    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    echo ^    Remove-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TranscodedImageCache -ErrorAction SilentlyContinue
    echo ^    Add-Type @"
    echo using System.Runtime.InteropServices;
    echo public class NativeWallpaper {
    echo     [DllImport^("user32.dll", SetLastError=true, CharSet=CharSet.Auto^)]
    echo     public static extern bool SystemParametersInfo^(int uAction, int uParam, string lpvParam, int fuWinIni^);
    echo }
    echo "@
    echo ^    [NativeWallpaper]::SystemParametersInfo^(20, 0, $wall, 3^) ^| Out-Null
    echo ^    Add-Content -Path $log -Value ^("[" + ^(Get-Date -Format 'dd/MM/yyyy HH:mm:ss'^) + "] Wallpaper aplicado"^)
    echo }
)
call :log ApplyUserBranding.ps1 gerado
goto :eof

:write_firstlogon_cmd
> "%FIRSTLOGONCMD%" (
    echo @echo off
    echo setlocal EnableExtensions DisableDelayedExpansion
    echo title Pos-Instalacao Pichau - Atualizacao de Drivers
    echo color 0A
    echo set "LOG=C:\Windows\Temp\FirstLogon-Pichau.log"
    echo set "DONE=C:\Windows\Temp\FirstLogon-Pichau.done"
    echo set "RUNNING=C:\Windows\Temp\FirstLogon-Pichau.running"
    echo set "DRIVERLOG=C:\Windows\Temp\InstalarDriversPrimeiroLogon.log"
    echo set "SCRIPTDIR=C:\Windows\Setup\Scripts"
    echo set "DRIVERCMD=%%SCRIPTDIR%%\Instalar_Drivers_Offline.cmd"
    echo set "DRIVERPS1=%%SCRIPTDIR%%\Instalar_Drivers_Offline.ps1"
    echo set "ERR=0"
    echo if exist "%%DONE%%" exit /b 0
    echo if exist "%%RUNNING%%" exit /b 0
    echo ^> "%%RUNNING%%" echo iniciado
    echo if not exist "C:\Windows\Temp" mkdir "C:\Windows\Temp" ^>nul 2^>^&1
    echo ^>^>"%%LOG%%" echo ========================================================
    echo ^>^>"%%LOG%%" echo [%%date%% %%time%%] FirstLogon iniciado
    echo cls
    echo echo ========================================================
    echo echo          POS-INSTALACAO PICHAU - PRIMEIRO LOGON
    echo echo ========================================================
    echo echo.
    echo echo [1/3] Aplicando wallpaper...
    echo if exist "%%SCRIPTDIR%%\ApplyUserBranding.ps1" ^(
    echo ^    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%%SCRIPTDIR%%\ApplyUserBranding.ps1"
    echo ^    ^>^>"%%LOG%%" echo [%%date%% %%time%%] ApplyUserBranding executado
    echo ^) else ^(
    echo ^    ^>^>"%%LOG%%" echo [%%date%% %%time%%] ApplyUserBranding.ps1 nao encontrado
    echo ^)
    echo echo.
    echo echo [2/3] Preparando atualizacao de drivers...
    echo if not exist "%%DRIVERCMD%%" if not exist "%%DRIVERPS1%%" ^(
    echo ^    for %%%%D in ^(D E F G H I J K L M N O P Q R S T U V W X Y Z^) do ^(
    echo ^        if exist "%%%%D:\Script\Instalar_Drivers_Offline.cmd" copy /Y "%%%%D:\Script\Instalar_Drivers_Offline.cmd" "%%DRIVERCMD%%" ^>nul 2^>^&1
    echo ^        if exist "%%%%D:\Script\Instalar_Drivers_Offline.ps1" copy /Y "%%%%D:\Script\Instalar_Drivers_Offline.ps1" "%%DRIVERPS1%%" ^>nul 2^>^&1
    echo ^    ^)
    echo ^)
    echo if exist "%%DRIVERCMD%%" ^(
    echo ^    echo Executando: %%DRIVERCMD%%
    echo ^    ^>^>"%%LOG%%" echo [%%date%% %%time%%] Executando Instalar_Drivers_Offline.cmd
    echo ^    pushd "%%SCRIPTDIR%%" ^>nul 2^>^&1
    echo ^    call "%%DRIVERCMD%%"
    echo ^    set "ERR=%%ERRORLEVEL%%"
    echo ^    popd ^>nul 2^>^&1
    echo ^) else if exist "%%DRIVERPS1%%" ^(
    echo ^    echo Executando: %%DRIVERPS1%%
    echo ^    ^>^>"%%LOG%%" echo [%%date%% %%time%%] Executando Instalar_Drivers_Offline.ps1
    echo ^    pushd "%%SCRIPTDIR%%" ^>nul 2^>^&1
    echo ^    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%%DRIVERPS1%%"
    echo ^    set "ERR=%%ERRORLEVEL%%"
    echo ^    popd ^>nul 2^>^&1
    echo ^) else ^(
    echo ^    echo Script de drivers nao encontrado.
    echo ^    ^>^>"%%LOG%%" echo [%%date%% %%time%%] Script de drivers nao encontrado
    echo ^    set "ERR=1"
    echo ^)
    echo echo.
    echo echo [3/3] Finalizando...
    echo ^>^>"%%LOG%%" echo [%%date%% %%time%%] Atualizacao finalizada com codigo %%ERR%%
    echo del /f /q "%%RUNNING%%" ^>nul 2^>^&1
    echo if "%%ERR%%"=="0" ^(
    echo ^    ^> "%%DONE%%" echo ok
    echo ^)
    echo echo.
    echo if "%%ERR%%"=="0" ^(
    echo ^    echo CONCLUIDO. Log: C:\Windows\Temp\FirstLogon-Pichau.log
    echo ^) else ^(
    echo ^    echo FALHA OU SCRIPT NAO ENCONTRADO. Verifique:
    echo ^    echo C:\Windows\Temp\FirstLogon-Pichau.log
    echo ^    echo C:\Windows\Temp\InstalarDriversPrimeiroLogon.log
    echo ^)
    echo echo.
    echo pause
    echo exit /b %%ERR%%
)
call :log FirstLogon_Pichau.cmd gerado
goto :eof

:remove_old_triggers
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Run" /v PichauFirstLogon /f >nul 2>&1
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v InstalarDriversPrimeiroLogon /f >nul 2>&1
reg delete "HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v PichauFirstLogon /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v PichauFirstLogon /f >nul 2>&1
del /f /q "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Pichau_FirstLogon_Launcher.cmd" >nul 2>&1
del /f /q "C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Pichau_FirstLogon_Launcher.cmd" >nul 2>&1
call :log Gatilhos antigos removidos
goto :eof

:prepare_default_user
if not exist "%DEFAULTUSER%" (
    call :log NTUSER.DAT do Default User nao encontrado
    goto :eof
)

reg load HKU\DEFUSER "%DEFAULTUSER%" >>"%LOG%" 2>>&1
reg delete "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" /v NoChangingWallPaper /f >nul 2>&1
reg delete "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /f >nul 2>&1
reg delete "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /f >nul 2>&1
if exist "%WALL%" (
    reg add "HKU\DEFUSER\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "C:\Windows\Web\Custom\wallpaper.jpg" /f >>"%LOG%" 2>>&1
    reg add "HKU\DEFUSER\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f >>"%LOG%" 2>>&1
    reg add "HKU\DEFUSER\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f >>"%LOG%" 2>>&1
)
reg add "HKU\DEFUSER\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v PichauApplyBranding /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Setup\Scripts\ApplyUserBranding.ps1" /f >>"%LOG%" 2>>&1
reg unload HKU\DEFUSER >>"%LOG%" 2>>&1
call :log Default User preparado
goto :eof

:prepare_machine_runonce
reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v PichauFirstLogon /t REG_SZ /d "cmd.exe /k \"C:\Windows\Setup\Scripts\FirstLogon_Pichau.cmd\"" /f >>"%LOG%" 2>>&1
call :log HKLM RunOnce preparado
goto :eof

:log
echo [%date% %time%] %*>>"%LOG%"
goto :eof
