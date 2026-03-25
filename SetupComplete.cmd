@echo off

:: garantir boot
bcdboot C:\Windows /f ALL >nul 2>&1

:: remover apps provisionados
powershell -command "Get-AppxProvisionedPackage -Online | Where-Object {$_.DisplayName -notlike '*Store*'} | Remove-AppxProvisionedPackage -Online" >nul 2>&1

:: desativar consumer features
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f >nul 2>&1

:: desativar apps sugeridos
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v PreInstalledAppsEverEnabled /t REG_DWORD /d 0 /f >nul 2>&1

:: desativar animação de primeiro login
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f >nul 2>&1

:: desativar privacidade inicial
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f >nul 2>&1

:: branding automatico
for %%i in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%i:\Script\Set-Branding.ps1 (
        powershell -ExecutionPolicy Bypass -NoProfile -File "%%i:\Script\Set-Branding.ps1"
        goto :branding_done
    )
)

:branding_done
exit