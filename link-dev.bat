@echo off
setlocal enabledelayedexpansion

set "REPO=%~dp0"
set "MPV=%APPDATA%\mpv"

rem --- sanity check: can we even create symlinks? ---
mklink "%TEMP%\mpv_symlink_test.tmp" "%~f0" >nul 2>&1
if errorlevel 1 (
    echo ERROR: mklink failed - Developer Mode is likely off, or this needs to run as Administrator.
    echo Enable: Settings -^> For developers -^> Developer Mode, then try again.
    pause
    exit /b 1
)
del "%TEMP%\mpv_symlink_test.tmp"

call :link "scripts\torrserver.lua"
call :link "modules\native-dialog.lua"
call :link "modules\platform.lua"
call :link "modules\torrserver-update.lua"
call :link "modules\utils.lua"
call :link "script-opts\torrserver.conf"

echo Done.
pause
exit /b

:link
set "REL=%~1"
set "SRC=%REPO%%REL%"
set "DST=%MPV%\%REL%"

if not exist "%SRC%" (
    echo SKIP ^(missing in repo^): %SRC%
    exit /b
)

fsutil reparsepoint query "%DST%" >nul 2>&1
if not errorlevel 1 (
    echo SKIP ^(already a symlink^): %DST%
    exit /b
)

if exist "%DST%" (
    echo Backing up existing file: %DST%.bak
    copy /y "%DST%" "%DST%.bak" >nul
    del "%DST%"
)

mklink "%DST%" "%SRC%"
if errorlevel 1 (
    echo ERROR creating symlink for %DST% - restoring backup if any.
    if exist "%DST%.bak" move /y "%DST%.bak" "%DST%" >nul
)
exit /b