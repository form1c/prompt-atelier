@echo off
rem scripts\start_development.bat — launcher only. The logic lives in scripts\lib\start_development.rb
setlocal
ruby "%~dp0lib\start_development.rb" %*
if errorlevel 1 pause
endlocal
