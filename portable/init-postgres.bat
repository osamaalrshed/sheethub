@echo off
REM ────────────────────────────────────────────────────────────────────────────
REM One-time PostgreSQL initialization for the portable stack.
REM Creates data folder, runs initdb, creates databases + users, loads samples.
REM Safe to re-run — it skips steps already done.
REM ────────────────────────────────────────────────────────────────────────────

setlocal enabledelayedexpansion

if not exist ".env" (
    echo [ERROR] .env not found. Copy .env.example to .env and fill in passwords first.
    exit /b 1
)
call .env

set "PG_BIN=%~dp0_bin\postgres\bin"
set "PG_DATA=%~dp0data\postgres"

if not exist "%PG_BIN%\postgres.exe" (
    echo [ERROR] PostgreSQL not found at %PG_BIN%
    echo         Download from https://www.enterprisedb.com/download-postgresql-binaries
    echo         and extract so postgres.exe is at _bin\postgres\bin\postgres.exe
    exit /b 1
)

if exist "%PG_DATA%\PG_VERSION" (
    echo [skip] PostgreSQL data folder already exists at %PG_DATA%
) else (
    echo [1/4] Initializing PostgreSQL data folder...
    mkdir "%PG_DATA%" 2>nul
    echo %POSTGRES_SUPERUSER_PASSWORD%> "%TEMP%\pgpw.txt"
    "%PG_BIN%\initdb.exe" -D "%PG_DATA%" -U %POSTGRES_SUPERUSER% --pwfile="%TEMP%\pgpw.txt" -E UTF8 --auth-local=md5 --auth-host=md5
    del "%TEMP%\pgpw.txt"
    if errorlevel 1 ( echo [ERROR] initdb failed. & exit /b 1 )
)

echo [2/4] Starting PostgreSQL briefly to run setup SQL...
"%PG_BIN%\pg_ctl.exe" -D "%PG_DATA%" -l "%~dp0data\pg-init.log" -o "-p %POSTGRES_PORT%" start
if errorlevel 1 ( echo [ERROR] pg_ctl start failed. & exit /b 1 )

set PGPASSWORD=%POSTGRES_SUPERUSER_PASSWORD%

echo [3a/4] Creating databases and users...
"%PG_BIN%\psql.exe" -U %POSTGRES_SUPERUSER% -h 127.0.0.1 -p %POSTGRES_PORT% -d postgres -v ON_ERROR_STOP=1 ^
    -v nocodb_user=%POSTGRES_NOCODB_USER% ^
    -v nocodb_pw=%POSTGRES_NOCODB_PASSWORD% ^
    -v etl_user=%ETL_READER_USER% ^
    -v etl_pw=%ETL_READER_PASSWORD% ^
    -f postgres\init-windows.sql

if errorlevel 1 ( echo [ERROR] SQL init failed. & "%PG_BIN%\pg_ctl.exe" -D "%PG_DATA%" stop & exit /b 1 )

echo [3b/4] Loading sample business data into business_inputs...
"%PG_BIN%\psql.exe" -U %POSTGRES_SUPERUSER% -h 127.0.0.1 -p %POSTGRES_PORT% -d business_inputs -v ON_ERROR_STOP=1 -f postgres\init\03-load-sample-data.sql
if errorlevel 1 ( echo [WARN] Sample data load returned errors; continuing. )

echo [3c/4] Installing audit triggers in business_inputs...
"%PG_BIN%\psql.exe" -U %POSTGRES_SUPERUSER% -h 127.0.0.1 -p %POSTGRES_PORT% -d business_inputs -v ON_ERROR_STOP=1 -f postgres\init\04-audit.sql
if errorlevel 1 ( echo [WARN] Audit install returned errors; continuing. )

echo [4/4] Stopping PostgreSQL...
"%PG_BIN%\pg_ctl.exe" -D "%PG_DATA%" stop

echo.
echo Done. Run start.bat to launch the full stack.
endlocal
