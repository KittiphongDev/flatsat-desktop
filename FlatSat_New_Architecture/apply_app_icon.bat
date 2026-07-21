@echo off
REM =====================================================================
REM  FlatSat - Apply the app icon
REM  Regenerates platform icons from Dashboard\assets\icons\app_icon.png
REM  Run this after changing that PNG.
REM =====================================================================
setlocal
cd /d "%~dp0Dashboard"

echo ===========================================
echo    Generating FlatSat app icons...
echo ===========================================
echo.

where flutter >nul 2>&1
if errorlevel 1 (
  echo ERROR: Flutter was not found on PATH.
  echo.
  pause
  exit /b 1
)

if not exist "assets\icons\app_icon.png" (
  echo ERROR: assets\icons\app_icon.png not found.
  echo Put your square PNG there ^(512x512 or larger^) and run this again.
  echo.
  pause
  exit /b 1
)

echo [1/2] Fetching packages...
REM 'call' is REQUIRED - flutter/dart are .bat files; without it control never returns.
call flutter pub get
if errorlevel 1 (
  echo.
  echo ERROR: flutter pub get failed. See the output above.
  echo.
  pause
  exit /b 1
)

echo.
echo [2/2] Generating icons...
call dart run flutter_launcher_icons
if errorlevel 1 (
  echo.
  echo ERROR: Icon generation failed. See the output above.
  echo.
  pause
  exit /b 1
)

echo.
echo ===========================================
echo  Done. Windows icon written to:
echo    Dashboard\windows\runner\resources\app_icon.ico
echo.
echo  IMPORTANT: Windows caches exe icons. Do a clean rebuild:
echo    flutter clean  then  run_mission_control.bat
echo ===========================================
echo.
pause
endlocal
