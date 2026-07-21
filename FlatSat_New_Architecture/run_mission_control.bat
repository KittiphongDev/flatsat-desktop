@echo off
REM =====================================================================
REM  FlatSat Mission Control - One-Click Launcher (Windows)
REM  Double-click this file to start everything.
REM =====================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ===========================================
echo    Starting FlatSat Mission Control...
echo ===========================================
echo.

REM ---- Python check ----
where python >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python 3 is required but was not found.
  echo Install it from https://www.python.org/downloads/ and try again.
  echo ^(During install, tick "Add python.exe to PATH".^)
  echo.
  pause
  exit /b 1
)

REM ---- 1. Dependencies ----
echo [1/3] Checking Python dependencies...
python -m pip install --quiet --disable-pip-version-check -r "PC_Bridge\requirements.txt"
if errorlevel 1 (
  echo WARNING: Could not install Python dependencies. The bridge may not start.
  echo.
)

REM ---- 2. Bridge ----
REM Free port 8080 if a previous bridge is still holding it (prevents
REM "address already in use").
for /f "tokens=5" %%P in ('netstat -ano ^| findstr ":8080" ^| findstr "LISTENING"') do (
  echo [2/3] Clearing a leftover bridge on port 8080 ^(PID %%P^)...
  taskkill /PID %%P /F >nul 2>&1
)
echo [2/3] Starting ground-station bridge...
cd PC_Bridge
start "FlatSat Bridge" /min python gs_bridge.py
cd ..
timeout /t 2 /nobreak >nul

REM ---- 3. Dashboard ----
echo [3/3] Launching dashboard...
cd Dashboard
set "BIN=build\windows\x64\runner\Release\flatsat_dashboard.exe"

if not exist "%BIN%" (
  echo.
  echo No prebuilt app found. Building it once with Flutter...
  echo This can take a few minutes the first time. Please wait.
  echo.
  where flutter >nul 2>&1
  if errorlevel 1 (
    echo ERROR: No built app found and Flutter is not installed / not on PATH.
    echo Either install Flutter, or copy a prebuilt build\windows folder here.
    echo.
    goto :cleanup
  )
  REM 'call' is REQUIRED - flutter is a .bat; without call, control never returns.
  call flutter build windows > "flutter_build_log.txt" 2>&1
  echo ----- build output -----
  type "flutter_build_log.txt"
  echo ------------------------
)

if exist "%BIN%" (
  echo Starting dashboard...
  start "" "%BIN%"
) else (
  echo.
  echo ERROR: The Windows build did not complete. See the build output above
  echo   ^(also saved to Dashboard\flutter_build_log.txt^).
  echo The most common cause is a missing Visual Studio "Desktop development
  echo   with C++" workload. Run diagnose_windows.bat for a full check.
  echo.
)

:cleanup
cd ..
echo.
echo When you close the dashboard, this window stops the bridge.
echo Stopping bridge...
taskkill /FI "WINDOWTITLE eq FlatSat Bridge*" /T /F >nul 2>&1
echo Done.
echo.
pause
endlocal
