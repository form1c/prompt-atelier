@echo off
rem scripts\start_portable.bat — launcher only. The logic lives in scripts\lib\start_portable.rb
setlocal
ruby "%~dp0lib\start_portable.rb" %*
if errorlevel 1 pause
endlocal
