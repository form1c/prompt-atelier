@echo off
rem scripts\install.bat — launcher only. The logic lives in scripts\lib\install.rb
setlocal
ruby "%~dp0lib\install.rb" %*
if errorlevel 1 pause
endlocal
