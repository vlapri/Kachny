@echo off
rem ===========================================================================
rem  Kachna v2 - spoustec pro Windows
rem  Dvojklikem spusti kachnu bez okna konzole. Blokaci skriptu (ExecutionPolicy)
rem  obchazi jen pro tento jeden skript, systemove nastaveni nemeni.
rem  Ladeni (chyby se vypisi do konzole):  powershell_kachna_v2.cmd ladeni
rem  Ukonceni: prave tlacitko na kachne nebo na ikone vedle hodin -> Ukoncit
rem ===========================================================================
setlocal
set "KACHNA=%~dp0powershell_kachna_v2.ps1"

if not exist "%KACHNA%" (
    echo Soubor "%KACHNA%" nebyl nalezen.
    echo Soubory powershell_kachna_v2.cmd a powershell_kachna_v2.ps1 musi byt ve stejne slozce.
    pause
    exit /b 1
)

if /i "%~1"=="ladeni" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%KACHNA%"
    pause
    exit /b
)

rem conhost --headless = PowerShell bez viditelneho okna (Windows 10 1809 a novejsi)
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%KACHNA%"
