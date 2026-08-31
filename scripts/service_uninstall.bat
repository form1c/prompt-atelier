@echo off
rem scripts\service_uninstall.bat — launcher only. The logic lives in scripts\lib\service_uninstall.rb
setlocal
ruby "%~dp0lib\service_uninstall.rb" %*
if errorlevel 1 pause
endlocal
