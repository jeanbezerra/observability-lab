@echo off
setlocal EnableExtensions

rem =============================================================================
rem Verificacao somente leitura do WSL 2, Headlamp e Envoy Gateway.
rem
rem Este script NAO inicia nem encerra servicos, NAO altera firewall e NAO cria
rem encaminhamento de porta. Ele pode iniciar a distribuicao WSL apenas para
rem consultar seu estado, comportamento normal do comando wsl.exe.
rem
rem Uso: 00-check-environment.cmd [DISTRIBUICAO] [PORTA_HEADLAMP] [PORTA_GATEWAY]
rem Ex.: 00-check-environment.cmd Ubuntu-26.04 30443 30080
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "DISTRO=%~1"
if not defined DISTRO set "DISTRO=Ubuntu-26.04"
set "PORT=%~2"
if not defined PORT set "PORT=30443"
set "GATEWAY_PORT=%~3"
if not defined GATEWAY_PORT set "GATEWAY_PORT=30080"
set "HEADLAMP_SERVICE=k8s-headlamp-local.service"
set "GATEWAY_SERVICE=k8s-gateway-local.service"

set "INVALID_DISTRO="
for /f "delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" %%A in ("%DISTRO%") do set "INVALID_DISTRO=1"
if defined INVALID_DISTRO (
  echo ERRO: DISTRIBUICAO aceita somente letras, numeros, ponto, sublinhado e hifen.
  exit /b 2
)
set "INVALID_PORT="
for /f "delims=0123456789" %%A in ("%PORT%") do set "INVALID_PORT=1"
if defined INVALID_PORT (
  echo ERRO: PORTA_HEADLAMP deve conter somente numeros.
  exit /b 2
)
set "INVALID_GATEWAY_PORT="
for /f "delims=0123456789" %%A in ("%GATEWAY_PORT%") do set "INVALID_GATEWAY_PORT=1"
if defined INVALID_GATEWAY_PORT (
  echo ERRO: PORTA_GATEWAY deve conter somente numeros.
  exit /b 2
)

where.exe wsl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: wsl.exe nao foi encontrado. Solicite a habilitacao do WSL 2 a TI.
  exit /b 1
)

echo [1/7] Verificando a distribuicao "%DISTRO%"...
wsl.exe -d %DISTRO% --user root -- test -r /etc/os-release >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: a distribuicao "%DISTRO%" nao existe ou nao pode ser iniciada.
  echo Confira os nomes com: wsl.exe --list --verbose
  exit /b 1
)

echo [2/7] Verificando se "%DISTRO%" usa WSL 2...
wsl.exe -d %DISTRO% --user root -- grep -qi "WSL2" /proc/sys/kernel/osrelease
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: "%DISTRO%" nao foi identificada como WSL 2.
  echo Confira com: wsl.exe --list --verbose
  exit /b 1
)

echo [3/7] Verificando systemd como PID 1 em "%DISTRO%"...
wsl.exe -d %DISTRO% --user root -- grep -qxi "systemd" /proc/1/comm
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: systemd nao esta ativo como PID 1 em "%DISTRO%".
  echo Execute prepare-wsl.sh e depois 10-restart-wsl.cmd.
  exit /b 1
)

echo [4/7] Verificando o encaminhamento do Headlamp em "%DISTRO%"...
wsl.exe -d %DISTRO% --user root -- systemctl cat --no-pager %HEADLAMP_SERVICE% >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: o servico "%HEADLAMP_SERVICE%" ainda nao foi instalado.
  echo Conclua install-all.sh dentro do Ubuntu antes de abrir a porta.
  exit /b 1
)

wsl.exe -d %DISTRO% --user root -- systemctl is-active --quiet %HEADLAMP_SERVICE%
if not "%ERRORLEVEL%"=="0" (
  echo INFO: encaminhamento fechado. Use 20-open-cluster-ports.cmd para abri-lo.
) else (
  echo OK: o encaminhamento do Headlamp esta ativo no WSL.
)

echo [5/7] Verificando o encaminhamento do Envoy Gateway em "%DISTRO%"...
wsl.exe -d %DISTRO% --user root -- systemctl cat --no-pager %GATEWAY_SERVICE% >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: o servico "%GATEWAY_SERVICE%" ainda nao foi instalado.
  echo Conclua install-all.sh dentro do Ubuntu antes de abrir a porta.
  exit /b 1
)

wsl.exe -d %DISTRO% --user root -- systemctl is-active --quiet %GATEWAY_SERVICE%
if not "%ERRORLEVEL%"=="0" (
  echo INFO: Gateway fechado. Use 25-open-gateway-port.cmd para abri-lo.
) else (
  echo OK: o encaminhamento do Gateway esta ativo no WSL.
)

echo [6/7] Verificando https://localhost:%PORT% no Windows...
where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo AVISO: curl.exe nao existe; as verificacoes HTTP foram ignoradas.
  exit /b 0
)

curl.exe --insecure --silent --output NUL --connect-timeout 2 --max-time 4 "https://localhost:%PORT%/"
if errorlevel 1 (
  echo INFO: a porta TCP %PORT% nao esta respondendo no localhost do Windows.
) else (
  echo OK: Headlamp respondeu somente pelo endereco local configurado.
)

echo [7/7] Verificando http://localhost:%GATEWAY_PORT% no Windows...
curl.exe --silent --output NUL --connect-timeout 2 --max-time 4 "http://localhost:%GATEWAY_PORT%/"
if errorlevel 1 (
  echo INFO: a porta TCP %GATEWAY_PORT% nao esta respondendo no localhost do Windows.
) else (
  echo OK: Envoy Gateway respondeu pelo endereco local configurado.
)

exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO] [PORTA_HEADLAMP] [PORTA_GATEWAY]
echo.
echo Faz verificacoes somente leitura de WSL 2, systemd, Headlamp e Gateway.
echo Padroes: DISTRIBUICAO=Ubuntu-26.04, HEADLAMP=30443 e GATEWAY=30080.
exit /b 0
