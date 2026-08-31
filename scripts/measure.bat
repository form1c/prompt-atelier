@echo off
rem scripts\measure.bat — launcher only. The logic lives in scripts\lib\measure.rb
setlocal
ruby "%~dp0lib\measure.rb" %*
if errorlevel 1 pause
endlocal
