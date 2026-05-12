@echo off
REM Stops all SheetsHub portable services.

call .env 2>nul

echo Stopping nginx...
"%~dp0_bin\nginx\nginx.exe" -p "%~dp0_bin\nginx" -s stop 2>nul

echo Stopping PostgreSQL...
"%~dp0_bin\postgres\bin\pg_ctl.exe" -D "%~dp0data\postgres" stop 2>nul

echo Stopping NocoDB and sync-service (close their console windows manually,
echo or use Task Manager if any process is left running).

taskkill /FI "WINDOWTITLE eq SheetsHub - NocoDB*" /F 2>nul
taskkill /FI "WINDOWTITLE eq SheetsHub - sync*" /F 2>nul
taskkill /FI "WINDOWTITLE eq SheetsHub - nginx*" /F 2>nul
taskkill /FI "WINDOWTITLE eq SheetsHub - PostgreSQL*" /F 2>nul

echo Done.
