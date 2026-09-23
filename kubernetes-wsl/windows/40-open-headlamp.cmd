@echo off
setlocal EnableExtensions

rem =============================================================================
rem Abre o Headlamp no navegador padrao do Windows.
rem
rem O script valida a URL quando curl.exe esta disponivel. Ele nao inicia o
rem encaminhamento; use antes 20-open-cluster-ports.cmd. Tambem nao altera a CA.
rem
rem Uso: 40-open-headlamp.cmd [PORTA]
rem Ex.: 40-open-headlamp.cmd 30443
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "PORT=%~1"
if not defined PORT set "PORT=30443"

where.exe curl.exe >nul 2>&1
if errorlevel 1 goto :open_browser

curl.exe --insecure --silent --output NUL --connect-timeout 2 --max-time 4 "https://localhost:%PORT%/"
if errorlevel 1 (
  echo ERRO: https://localhost:%PORT% nao esta respondendo.
  echo Execute primeiro 20-open-cluster-ports.cmd.
  exit /b 1
)

:open_browser
start "" "https://localhost:%PORT%/?lng=pt"
if errorlevel 1 (
  echo ERRO: o navegador padrao nao pode ser iniciado.
  exit /b 1
)
exit /b 0

:help
echo Uso: %~nx0 [PORTA]
echo.
echo Valida e abre o Headlamp no navegador padrao.
echo Padrao: PORTA=30443.
exit /b 0
