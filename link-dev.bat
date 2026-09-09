@echo off
setlocal

set "REPO=%~dp0"
set "MPV=%APPDATA%\mpv"

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
if exist "%MPV%\%REL%" (
    if exist "%MPV%\%REL%\*" (
        rem it's a real folder, not our file - skip to avoid deleting something unrelated
        echo SKIP (is a folder): %MPV%\%REL%
        exit /b
    )
    del "%MPV%\%REL%"
)
mklink "%MPV%\%REL%" "%REPO%%REL%"
exit /b