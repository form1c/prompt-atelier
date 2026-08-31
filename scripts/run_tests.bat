@echo off
rem scripts\run_tests.bat — launcher only. The logic lives in scripts\lib\run_tests.rb
setlocal
ruby "%~dp0lib\run_tests.rb" %*
if errorlevel 1 pause
endlocal
