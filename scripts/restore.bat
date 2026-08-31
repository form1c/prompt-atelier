@echo off
rem scripts\restore.bat — launcher only. The logic lives in scripts\lib\restore.rb
setlocal
ruby "%~dp0lib\restore.rb" %*
if errorlevel 1 pause
endlocal
