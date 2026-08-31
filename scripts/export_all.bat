@echo off
rem scripts\export_all.bat — launcher only. The logic lives in scripts\lib\export_all.rb
setlocal
ruby "%~dp0lib\export_all.rb" %*
if errorlevel 1 pause
endlocal
