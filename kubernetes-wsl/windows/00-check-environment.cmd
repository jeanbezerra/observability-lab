@echo off
setlocal EnableExtensions

rem =============================================================================
rem Verificacao somente leitura do WSL 2 e do acesso local ao Headlamp.
rem
rem Este script NAO inicia nem encerra servicos, NAO altera firewall e NAO cria
rem encaminhamento de porta. Ele pode iniciar a distribuicao WSL apenas para
rem consultar seu estado, comportamento normal do comando wsl.exe.
rem
rem Uso: 00-check-environment.cmd [DISTRIBUICAO] [PORTA]
rem Ex.: 00-check-environment.cmd Ubuntu-26.04 30443
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "DISTRO=%~1"
if not defined DISTRO set "DISTRO=Ubuntu-26.04"
set "PORT=%~2"
if not defined PORT set "PORT=30443"
set "SERVICE=k8s-headlamp-local.service"

where.exe wsl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: wsl.exe nao foi encontrado. Solicite a habilitacao do WSL 2 a TI.
  exit /b 1
)

rem Mantem a distribuicao viva por alguns segundos durante as consultas. Isso
rem evita uma corrida do WSL quando ainda nao existem servicos persistentes.
start "" /b wsl.exe -d "%DISTRO%" --user root -- sleep 15 >nul 2>&1
choice.exe /c Y /n /d Y /t 1 >nul

echo [1/5] Verificando a distribuicao "%DISTRO%"...
wsl.exe -d "%DISTRO%" --user root -- test -r /etc/os-release >nul 2>&1
if errorlevel 1 (
  echo ERRO: a distribuicao "%DISTRO%" nao existe ou nao pode ser iniciada.
  echo Confira os nomes com: wsl.exe --list --verbose
  exit /b 1
)

echo [2/5] Verificando se "%DISTRO%" usa WSL 2...
wsl.exe -d "%DISTRO%" --user root -- grep -qi "WSL2" /proc/sys/kernel/osrelease
if errorlevel 1 (
  echo ERRO: "%DISTRO%" nao foi identificada como WSL 2.
  echo Confira com: wsl.exe --list --verbose
  exit /b 1
)

echo [3/5] Verificando systemd como PID 1 em "%DISTRO%"...
wsl.exe -d "%DISTRO%" --user root -- grep -qxi "systemd" /proc/1/comm
if errorlevel 1 (
  echo ERRO: systemd nao esta ativo como PID 1 em "%DISTRO%".
  echo Execute prepare-wsl.sh e depois 10-restart-wsl.cmd.
  exit /b 1
)

echo [4/5] Verificando o servico de encaminhamento local em "%DISTRO%"...
wsl.exe -d "%DISTRO%" --user root -- systemctl cat --no-pager "%SERVICE%" >nul 2>&1
if errorlevel 1 (
  echo ERRO: o servico "%SERVICE%" ainda nao foi instalado.
  echo Conclua install-all.sh dentro do Ubuntu antes de abrir a porta.
  exit /b 1
)

wsl.exe -d "%DISTRO%" --user root -- systemctl is-active --quiet "%SERVICE%"
if errorlevel 1 (
  echo INFO: encaminhamento fechado. Use 20-open-cluster-ports.cmd para abri-lo.
) else (
  echo OK: o servico de encaminhamento esta ativo no WSL.
)

echo [5/5] Verificando https://localhost:%PORT% no Windows...
where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo AVISO: curl.exe nao existe; a verificacao HTTP foi ignorada.
  exit /b 0
)

curl.exe --insecure --silent --output NUL --connect-timeout 2 --max-time 4 "https://localhost:%PORT%/"
if errorlevel 1 (
  echo INFO: a porta TCP %PORT% nao esta respondendo no localhost do Windows.
) else (
  echo OK: Headlamp respondeu somente pelo endereco local configurado.
)

exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO] [PORTA]
echo.
echo Faz verificacoes somente leitura de WSL 2, systemd, servico e Headlamp.
echo Padroes: DISTRIBUICAO=Ubuntu-26.04 e PORTA=30443.
exit /b 0
