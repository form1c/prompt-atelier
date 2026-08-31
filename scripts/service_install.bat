@echo off
rem scripts\service_install.bat — launcher only. The logic lives in scripts\lib\service_install.rb
setlocal
ruby "%~dp0lib\service_install.rb" %*
if errorlevel 1 pause
endlocal
