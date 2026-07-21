@echo off
REM =====================================================================
REM  FlatSat Mission Control - One-Click Launcher (Windows)
REM  Double-click this file to start everything.
REM =====================================================================
setlocal
cd /d "%~dp0"

echo ===========================================
echo    Starting FlatSat Mission Control...
echo ===========================================

REM ---- Python check ----
where python >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python 3 is required but was not found.
  echo Install it from https://www.python.org/downloads/ and try again.
  pause
  exit /b 1
)

REM ---- 1. Dependencies ----
echo [1/3] Checking Python dependencies...
python -m pip install --quiet --disable-pip-version-check -r "PC_Bridge\requirements.txt"

REM ---- 2. Bridge ----
echo [2/3] Starting ground-station bridge...
cd PC_Bridge
start "FlatSat Bridge" /min python gs_bridge.py
cd ..
timeout /t 2 /nobreak >nul

REM ---- 3. Dashboard ----
echo [3/3] Launching dashboard...
cd Dashboard
set "BIN=build\windows\x64\runner\Release\flatsat_dashboard.exe"
if exist "%BIN%" (
  "%BIN%"
) else (
  where flutter >nul 2>&1
  if errorlevel 1 (
    echo ERROR: No built app found and Flutter is not installed.
    echo Either install Flutter, or build the app once with: flutter build windows
    pause
  ) else (
    flutter run -d windows
  )
)

REM ---- Cleanup ----
echo Closing... stopping bridge.
taskkill /FI "WINDOWTITLE eq FlatSat Bridge*" /T /F >nul 2>&1
endlocal
