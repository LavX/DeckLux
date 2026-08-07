@echo off
rem Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
rem Licensed under the Microsoft Public License (MS-PL).

setlocal

set "DLX_EWDK_ROOT=%~1"
if "%DLX_EWDK_ROOT%"=="" set "DLX_EWDK_ROOT=E:"

set "DLX_CONFIGURATION=%~2"
if "%DLX_CONFIGURATION%"=="" set "DLX_CONFIGURATION=Debug"
if /i not "%DLX_CONFIGURATION%"=="Debug" if /i not "%DLX_CONFIGURATION%"=="Release" (
    echo DeckLux: configuration must be Debug or Release.
    exit /b 2
)

if not exist "%DLX_EWDK_ROOT%\BuildEnv\SetupBuildEnv.cmd" (
    echo DeckLux: EWDK environment was not found under %DLX_EWDK_ROOT%.
    exit /b 2
)

call "%DLX_EWDK_ROOT%\BuildEnv\SetupBuildEnv.cmd" amd64
if errorlevel 1 exit /b 1

pushd "%~dp0.."
if not exist "artifacts" mkdir "artifacts"

msbuild DeckLux.sln /m /t:Rebuild /p:Configuration=%DLX_CONFIGURATION% /p:Platform=x64 /bl:artifacts\DeckLux.%DLX_CONFIGURATION%.binlog
set "DLX_BUILD_EXIT=%errorlevel%"

if not "%DLX_BUILD_EXIT%"=="0" goto build_done
artifacts\tests\%DLX_CONFIGURATION%\DeckLux.CoreTests.exe
set "DLX_BUILD_EXIT=%errorlevel%"
if not "%DLX_BUILD_EXIT%"=="0" goto build_done

powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Calibration.Tests.ps1
set "DLX_BUILD_EXIT=%errorlevel%"
if not "%DLX_BUILD_EXIT%"=="0" goto build_done

call scripts\verify-ewdk.cmd "%DLX_EWDK_ROOT%" %DLX_CONFIGURATION%
set "DLX_BUILD_EXIT=%errorlevel%"
if not "%DLX_BUILD_EXIT%"=="0" goto build_done

if /i not "%DLX_CONFIGURATION%"=="Release" goto build_done
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\New-DeckLuxRelease.ps1 -EwdkRoot "%DLX_EWDK_ROOT%" -Force
set "DLX_BUILD_EXIT=%errorlevel%"

:build_done
popd
exit /b %DLX_BUILD_EXIT%
