@echo off
rem ==========================================================================
rem  Cross-platform dev wrapper for Windows (cmd.exe / PowerShell).
rem  macOS / Linux / Git Bash / WSL users: use ./erpnext (same arguments).
rem
rem  Runs `docker compose` with BOTH env files loaded automatically:
rem    .env                -> your local settings/secrets (from .env.example)
rem    deploy/release.env  -> pinned versions (ERPNEXT_VERSION, MARIADB_VERSION)
rem
rem  Usage (pass any docker compose subcommand/args):
rem    .\erpnext up --build
rem    .\erpnext restart erpnext
rem    .\erpnext exec erpnext bash
rem    .\erpnext down
rem ==========================================================================
setlocal
rem Run from this script's directory so relative paths always resolve.
cd /d "%~dp0"

if not exist ".env" (
  copy /Y ".env.example" ".env" >nul
  echo ^>^> Created .env from .env.example - review secrets before production use.
)

docker compose --env-file .env --env-file deploy/release.env %*
endlocal
