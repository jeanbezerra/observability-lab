@echo off
setlocal EnableExtensions

rem =============================================================================
rem Abre o acesso HTTP local do Windows ao Envoy Gateway.
rem
rem O servico k8s-gateway-local.service descobre o Service gerenciado pelo
rem Gateway e executa kubectl port-forward preso a 127.0.0.1. Nenhuma regra de
rem UFW ou Windows Firewall e criada; nao ha netsh portproxy, NodePort ou
rem LoadBalancer. Use 75-close-gateway-port.cmd ao terminar.
rem
rem Uso: 25-open-gateway-port.cmd [DISTRIBUICAO] [PORTA]
rem Ex.: 25-open-gateway-port.cmd Ubuntu-26.04 30080
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "DISTRO=%~1"
if not defined DISTRO set "DISTRO=Ubuntu-26.04"
set "PORT=%~2"
if not defined PORT set "PORT=30080"
set "SERVICE=k8s-gateway-local.service"

set "INVALID_DISTRO="
for /f "delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" %%A in ("%DISTRO%") do set "INVALID_DISTRO=1"
if defined INVALID_DISTRO (
  echo ERRO: DISTRIBUICAO aceita somente letras, numeros, ponto, sublinhado e hifen.
  exit /b 2
)
set "INVALID_PORT="
for /f "delims=0123456789" %%A in ("%PORT%") do set "INVALID_PORT=1"
if defined INVALID_PORT (
  echo ERRO: PORTA deve conter somente numeros.
  exit /b 2
)

where.exe wsl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: wsl.exe nao foi encontrado.
  exit /b 1
)

echo Verificando o servico "%SERVICE%" em "%DISTRO%"...
wsl.exe -d %DISTRO% --user root -- systemctl cat --no-pager %SERVICE% >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: o encaminhamento do Gateway ainda nao foi instalado.
  echo Execute install-all.sh dentro do Ubuntu e tente novamente.
  exit /b 1
)

echo Habilitando o encaminhamento HTTP local persistente...
wsl.exe -d %DISTRO% --user root -- systemctl enable --now %SERVICE%
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: systemd nao conseguiu habilitar ou iniciar "%SERVICE%".
  echo Consulte: wsl.exe -d %DISTRO% --user root -- journalctl -u %SERVICE% -n 100 --no-pager
  exit /b 1
)

wsl.exe -d %DISTRO% --user root -- systemctl is-active --quiet %SERVICE%
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: o servico foi acionado, mas nao permaneceu ativo.
  exit /b 1
)

where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo AVISO: curl.exe nao existe; o servico esta ativo, mas o HTTP nao foi testado.
  echo Acesse: http://localhost:%PORT%/
  exit /b 0
)

echo Aguardando http://localhost:%PORT% responder...
for /l %%I in (1,1,20) do (
  curl.exe --silent --output NUL --connect-timeout 1 --max-time 3 "http://localhost:%PORT%/"
  if not errorlevel 1 goto :ready
  ping.exe -n 2 127.0.0.1 >nul
)

echo ERRO: o servico esta ativo, mas localhost:%PORT% nao respondeu.
echo Confira os logs do servico e se o Gateway aparece como Programmed=True.
exit /b 1

:ready
echo Gateway acessivel somente em http://localhost:%PORT%/.
echo Uma resposta HTTP 404 e normal enquanto nenhuma HTTPRoute estiver associada.
exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO] [PORTA]
echo.
echo Habilita e inicia o tunel HTTP local e persistente do Envoy Gateway.
echo Padroes: DISTRIBUICAO=Ubuntu-26.04 e PORTA=30080.
exit /b 0
