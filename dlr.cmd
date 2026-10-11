@echo off
:: dlr.cmd - DupeLocatR command-line shim
:: Usage: dlr [folder] | dlr help | dlr -DryRun [folder]

setlocal
set "SCRIPT=%~dp0DupeLocatr.ps1"

if not exist "%SCRIPT%" (
    echo [DupeLocatR] ERROR: DupeLocatr.ps1 not found next to dlr.cmd
    exit /b 1
)

:: Help commands
if /i "%~1"=="help" goto HELP
if /i "%~1"=="-h" goto HELP
if /i "%~1"=="--help" goto HELP
if "%~1"=="-?" goto HELP
if "%~1"=="/?" goto HELP

:: Dry-run mode: use the current directory unless a folder is supplied
if /i "%~1"=="-DryRun" goto DRYRUN

:: Normal mode
if "%~1"=="" (
    set "TARGET=%CD%"
) else (
    set "TARGET=%~f1"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Path "%TARGET%"
exit /b %ERRORLEVEL%

:DRYRUN
if "%~2"=="" (
    set "TARGET=%CD%"
) else (
    set "TARGET=%~f2"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Path "%TARGET%" -DryRun
exit /b %ERRORLEVEL%

:HELP
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Help
exit /b %ERRORLEVEL%
