@echo off
rem Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
rem Licensed under the Microsoft Public License (MS-PL).

setlocal

set "DLX_EWDK_ROOT=%~1"
if "%DLX_EWDK_ROOT%"=="" set "DLX_EWDK_ROOT=E:"

set "DLX_CONFIGURATION=%~2"
if "%DLX_CONFIGURATION%"=="" set "DLX_CONFIGURATION=Debug"

set "DLX_INFVERIF=%DLX_EWDK_ROOT%\Program Files\Windows Kits\10\Tools\10.0.28000.0\x64\infverif.exe"
set "DLX_PACKAGE=%~dp0..\src\x64\%DLX_CONFIGURATION%\DeckLux.Sensor"
set "DLX_INF=%DLX_PACKAGE%\DeckLuxSensor.inf"

if not exist "%DLX_INFVERIF%" (
    echo DeckLux: InfVerif was not found at "%DLX_INFVERIF%".
    exit /b 2
)

if not exist "%DLX_INF%" (
    echo DeckLux: generated INF was not found at "%DLX_INF%".
    exit /b 2
)

echo DeckLux: validating Windows Driver requirements...
"%DLX_INFVERIF%" /w /v "%DLX_INF%"
if errorlevel 1 exit /b 1

echo DeckLux: validating Universal driver requirements...
"%DLX_INFVERIF%" /u /v "%DLX_INF%"
if errorlevel 1 exit /b 1

echo DeckLux: validating Windows 11 24H2 isolation requirements...
"%DLX_INFVERIF%" /h /v "%DLX_INF%"
if errorlevel 1 exit /b 1

echo DeckLux: INF validation passed.
exit /b 0
