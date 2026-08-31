@echo off
rem scripts\seed_demo.bat - launcher only. The logic lives in scripts\lib\seed_demo.rb
setlocal
ruby "%~dp0lib\seed_demo.rb" %*
exit /b %ERRORLEVEL%
