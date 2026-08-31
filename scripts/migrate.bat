@echo off
rem scripts\migrate.bat — launcher only. The logic lives in scripts\lib\migrate.rb
setlocal
ruby "%~dp0lib\migrate.rb" %*
if errorlevel 1 pause
endlocal
