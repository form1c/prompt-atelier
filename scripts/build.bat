@echo off
rem scripts\build.bat — launcher only. The logic lives in scripts\lib\build.rb
setlocal
ruby "%~dp0lib\build.rb" %*
if errorlevel 1 pause
endlocal
