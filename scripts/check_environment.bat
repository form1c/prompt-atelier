@echo off
rem scripts\check_environment.bat — launcher only. The logic lives in scripts\lib\check_environment.rb
setlocal
ruby "%~dp0lib\check_environment.rb" %*
if errorlevel 1 pause
endlocal
