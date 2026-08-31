@echo off
rem scripts\import_all.bat — launcher only. The logic lives in scripts\lib\import_all.rb
setlocal
ruby "%~dp0lib\import_all.rb" %*
if errorlevel 1 pause
endlocal
