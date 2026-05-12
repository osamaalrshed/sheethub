@echo off
REM ────────────────────────────────────────────────────────────────────────────
REM Launches PostgreSQL, NocoDB, nginx, and the sync-service.
REM Each runs in its own console window — closing them stops the service.
REM ────────────────────────────────────────────────────────────────────────────

if not exist ".env" (
    echo [ERROR] .env not found. Copy .env.example to .env and fill in passwords first.
    exit /b 1
)
call .env

set "ROOT=%~dp0"
set "PG_BIN=%ROOT%_bin\postgres\bin"
set "PG_DATA=%ROOT%data\postgres"
set "NGINX_DIR=%ROOT%_bin\nginx"
set "NOCODB_EXE=%ROOT%_bin\nocodb\Noco.exe"
set "PY=%ROOT%_bin\python\python.exe"

if not exist "%PG_DATA%\PG_VERSION" (
    echo [ERROR] PostgreSQL not initialized. Run init-postgres.bat first.
    exit /b 1
)

REM ── 1) PostgreSQL ───────────────────────────────────────────────────────────
echo Starting PostgreSQL on port %POSTGRES_PORT% ...
start "SheetsHub - PostgreSQL" /D "%PG_BIN%" cmd /k "postgres.exe -D ""%PG_DATA%"" -p %POSTGRES_PORT%"
timeout /t 4 /nobreak >nul

REM ── 2) NocoDB ──────────────────────────────────────────────────────────────
echo Starting NocoDB on internal port %NC_PORT_INTERNAL% ...
set NC_DB=pg://127.0.0.1:%POSTGRES_PORT%?u=%POSTGRES_NOCODB_USER%^&p=%POSTGRES_NOCODB_PASSWORD%^&d=nocodb_meta
set NC_AUTH_JWT_SECRET=%NC_AUTH_JWT_SECRET%
set NC_ADMIN_EMAIL=%NC_ADMIN_EMAIL%
set NC_ADMIN_PASSWORD=%NC_ADMIN_PASSWORD%
set NC_ALLOW_LOCAL_HOOK_URL=true
set NC_ALLOW_LOCAL_EXTERNAL_DBS=true
set NC_PUBLIC_URL=http://localhost:%NOCODB_PORT%
set NC_ATTACHMENT_FIELD_SIZE=52428800
set NC_REQUEST_BODY_SIZE=52428800
set PORT=%NC_PORT_INTERNAL%

start "SheetsHub - NocoDB" /D "%ROOT%_bin\nocodb" cmd /k "Noco.exe"
timeout /t 5 /nobreak >nul

REM ── 3) nginx ───────────────────────────────────────────────────────────────
echo Starting nginx on port %NOCODB_PORT% ...
REM nginx looks for conf/ relative to its working directory
if not exist "%NGINX_DIR%\conf\nginx.conf" (
    echo Copying nginx config and assets into _bin\nginx\conf\ ...
    if not exist "%NGINX_DIR%\conf" mkdir "%NGINX_DIR%\conf"
    copy /Y "%ROOT%nginx\nginx.conf"          "%NGINX_DIR%\conf\nginx.conf" >nul
    copy /Y "%ROOT%nginx\custom.css"          "%NGINX_DIR%\conf\custom.css" >nul
    copy /Y "%ROOT%nginx\admin-detector.js"   "%NGINX_DIR%\conf\admin-detector.js" >nul
)
start "SheetsHub - nginx" /D "%NGINX_DIR%" cmd /k "nginx.exe -g ""daemon off;"""

REM ── 4) sync-service ─────────────────────────────────────────────────────────
echo Starting sync-service (Postgres -> ClickHouse) ...
set PG_HOST=127.0.0.1
set PG_PORT=%POSTGRES_PORT%
set PG_USER=%POSTGRES_NOCODB_USER%
set PG_PASSWORD=%POSTGRES_NOCODB_PASSWORD%
set PG_DATABASE=business_inputs
set CH_HOST=%CH_HOST%
set CH_PORT=%CH_PORT%
set CH_USER=%CH_USER%
set CH_PASSWORD=%CH_PASSWORD%
set CH_DATABASE=%CH_DATABASE%

start "SheetsHub - sync" /D "%ROOT%sync" cmd /k """%PY%"" sync.py"

echo.
echo All services starting. Open http://localhost:%NOCODB_PORT% in your browser.
echo To stop everything: run stop.bat (or close the four console windows).
