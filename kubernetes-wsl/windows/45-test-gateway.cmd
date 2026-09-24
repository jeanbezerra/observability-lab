@echo off
setlocal EnableExtensions

rem =============================================================================
rem Testa o Envoy Gateway pelo localhost do Windows sem alterar seu estado.
rem
rem O codigo e os cabecalhos HTTP sao exibidos. HTTP 404 significa que o Envoy
rem respondeu, mas nenhuma HTTPRoute correspondeu ao caminho "/". Este script
rem nao inicia o tunel; use antes 25-open-gateway-port.cmd.
rem
rem Uso: 45-test-gateway.cmd [PORTA]
rem Ex.: 45-test-gateway.cmd 30080
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "PORT=%~1"
if not defined PORT set "PORT=30080"

set "INVALID_PORT="
for /f "delims=0123456789" %%A in ("%PORT%") do set "INVALID_PORT=1"
if defined INVALID_PORT (
  echo ERRO: PORTA deve conter somente numeros.
  exit /b 2
)

where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: curl.exe nao foi encontrado neste Windows.
  exit /b 1
)

echo Testando http://localhost:%PORT%/ ...
curl.exe --silent --show-error --dump-header - --output NUL --connect-timeout 2 --max-time 10 "http://localhost:%PORT%/"
if errorlevel 1 (
  echo ERRO: o Gateway nao respondeu.
  echo Execute primeiro 25-open-gateway-port.cmd.
  exit /b 1
)

echo.
echo OK: o Envoy respondeu. HTTP 404 e esperado se nenhuma rota casar com "/".
exit /b 0

:help
echo Uso: %~nx0 [PORTA]
echo.
echo Exibe os cabecalhos da resposta do Envoy Gateway sem alterar servicos.
echo Padrao: PORTA=30080.
exit /b 0
