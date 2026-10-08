@echo off
setlocal
title rocom-capture - Windows build

rem Prefer installed Go; also support the portable toolchain in this workspace.
where go >nul 2>&1
if errorlevel 1 (
    for /d %%D in ("%~dp0dist\tools\toolchain\golang.org\toolchain@*.windows-amd64") do (
        if exist "%%~fD\bin\go.exe" (
            set "PATH=%%~fD\bin;%PATH%"
            set "GOCACHE=%~dp0dist\tools\gocache"
            set "GOMODCACHE=%~dp0dist\tools\gomodcache"
        )
    )
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\build.ps1" %*
set "BUILD_EXIT=%ERRORLEVEL%"
echo.
if "%BUILD_EXIT%"=="0" (
    echo Build completed. Output: "%~dp0dist\windows-amd64"
) else (
    echo Build failed. Please check the error above.
)
if not "%ROCOM_BUILD_NO_PAUSE%"=="1" pause
exit /b %BUILD_EXIT%
