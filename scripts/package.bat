@echo off
rem scripts\package.bat — launcher only. The logic lives in scripts\lib\package.rb
setlocal
ruby "%~dp0lib\package.rb" %*
if errorlevel 1 pause
endlocal
