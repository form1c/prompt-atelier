@echo off
rem scripts\backup.bat — launcher only. The logic lives in scripts\lib\backup.rb
setlocal
ruby "%~dp0lib\backup.rb" %*
if errorlevel 1 pause
endlocal
