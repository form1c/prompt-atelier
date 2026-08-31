@echo off
rem scripts\reset_admin_password.bat — launcher only.
rem The logic lives in scripts\lib\reset_admin_password.rb
setlocal
ruby "%~dp0lib\reset_admin_password.rb" %*
if errorlevel 1 pause
endlocal
