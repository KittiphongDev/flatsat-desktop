@echo off
REM =====================================================================
REM  FlatSat - Windows diagnostics
REM  Double-click this file. It writes diagnostics.txt next to itself,
REM  then opens it in Notepad. Send that file back for a precise fix.
REM =====================================================================
setlocal
cd /d "%~dp0"
set "LOG=%~dp0diagnostics.txt"

echo Running FlatSat Windows diagnostics...
echo This may take a few minutes (it attempts a build at the end).
echo.

echo FlatSat Windows Diagnostics > "%LOG%"
echo Generated: %date% %time% >> "%LOG%"
echo. >> "%LOG%"

echo ==== where python ==== >> "%LOG%"
where python >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo ==== python --version ==== >> "%LOG%"
python --version >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo ==== where flutter ==== >> "%LOG%"
where flutter >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo ==== flutter --version ==== >> "%LOG%"
call flutter --version >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo ==== flutter doctor -v ==== >> "%LOG%"
call flutter doctor -v >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo ==== flutter devices ==== >> "%LOG%"
call flutter devices >> "%LOG%" 2>&1
echo. >> "%LOG%"

echo ==== flutter build windows (Dashboard) ==== >> "%LOG%"
cd Dashboard
call flutter build windows >> "%LOG%" 2>&1
cd ..
echo. >> "%LOG%"
echo ==== end ==== >> "%LOG%"

echo.
echo Done. Results saved to:
echo   %LOG%
echo Opening it now...
start "" notepad "%LOG%"
echo.
pause
endlocal
