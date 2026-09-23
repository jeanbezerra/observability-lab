@echo off
setlocal EnableExtensions

rem =============================================================================
rem Abre o acesso local do Windows ao Headlamp do cluster.
rem
rem A abertura consiste em habilitar e iniciar, dentro do WSL, o servico systemd
rem k8s-headlamp-local.service. Esse servico executa kubectl port-forward preso a
rem 127.0.0.1. Nao ha UFW, Windows Firewall, netsh portproxy, NodePort ou acesso
rem pela rede corporativa. Atualmente a unica porta publicada e a 30443/TCP.
rem
rem O enable torna a escolha persistente: o tunel volta no proximo boot do WSL.
rem Para fecha-lo e impedir o inicio automatico, use 80-close-cluster-ports.cmd.
rem
rem Uso: 20-open-cluster-ports.cmd [DISTRIBUICAO] [PORTA]
rem Ex.: 20-open-cluster-ports.cmd Ubuntu-26.04 30443
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
  echo ERRO: wsl.exe nao foi encontrado.
  exit /b 1
)

echo Verificando o servico "%SERVICE%" em "%DISTRO%"...
wsl.exe -d "%DISTRO%" --user root -- systemctl cat --no-pager "%SERVICE%" >nul 2>&1
if errorlevel 1 (
  echo ERRO: o servico de encaminhamento nao foi instalado.
  echo Execute install-all.sh dentro do Ubuntu e tente novamente.
  exit /b 1
)

echo Habilitando o encaminhamento local persistente...
wsl.exe -d "%DISTRO%" --user root -- systemctl enable --now "%SERVICE%"
if errorlevel 1 (
  echo ERRO: systemd nao conseguiu habilitar ou iniciar "%SERVICE%".
  echo Consulte: wsl.exe -d "%DISTRO%" --user root -- journalctl -u "%SERVICE%" -n 100 --no-pager
  exit /b 1
)

wsl.exe -d "%DISTRO%" --user root -- systemctl is-active --quiet "%SERVICE%"
if errorlevel 1 (
  echo ERRO: o servico foi acionado, mas nao permaneceu ativo.
  exit /b 1
)

where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo AVISO: curl.exe nao existe; o servico esta ativo, mas a URL nao foi testada.
  echo Acesse: https://localhost:%PORT%/?lng=pt
  exit /b 0
)

echo Aguardando https://localhost:%PORT% responder...
for /l %%I in (1,1,15) do (
  curl.exe --insecure --silent --output NUL --connect-timeout 1 --max-time 3 "https://localhost:%PORT%/"
  if not errorlevel 1 goto :ready
  timeout.exe /t 1 /nobreak >nul
)

echo ERRO: o servico esta ativo, mas localhost:%PORT% nao respondeu.
echo Verifique localhostForwarding=true e execute 00-check-environment.cmd.
exit /b 1

:ready
echo Encaminhamento aberto com sucesso somente em https://localhost:%PORT%/.
echo Nenhuma porta foi liberada para a LAN, VPN ou rede corporativa.
exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO] [PORTA]
echo.
echo Habilita e inicia o tunel local e persistente do Headlamp.
echo Padroes: DISTRIBUICAO=Ubuntu-26.04 e PORTA=30443.
exit /b 0
