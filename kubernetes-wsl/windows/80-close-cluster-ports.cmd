@echo off
setlocal EnableExtensions

rem =============================================================================
rem Fecha o acesso local do Windows ao Headlamp do cluster.
rem
rem O script para e desabilita k8s-headlamp-local.service. Assim a porta local
rem permanece fechada mesmo depois de reiniciar o WSL. O cluster, seus Pods e as
rem portas internas continuam funcionando somente dentro da distribuicao.
rem
rem Nenhuma regra de firewall e removida porque os scripts nunca criam regras de
rem firewall ou netsh portproxy. Para reabrir, use 20-open-cluster-ports.cmd.
rem
rem Uso: 80-close-cluster-ports.cmd [DISTRIBUICAO] [PORTA]
rem Ex.: 80-close-cluster-ports.cmd Ubuntu-26.04 30443
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
  echo ERRO: o servico de encaminhamento nao foi encontrado.
  echo Se o cluster nao foi instalado, nenhuma porta foi aberta por este projeto.
  exit /b 1
)

echo Parando e desabilitando o encaminhamento local...
wsl.exe -d "%DISTRO%" --user root -- systemctl disable --now "%SERVICE%"
if errorlevel 1 (
  echo ERRO: systemd nao conseguiu parar ou desabilitar "%SERVICE%".
  exit /b 1
)

wsl.exe -d "%DISTRO%" --user root -- systemctl is-active --quiet "%SERVICE%"
if not errorlevel 1 (
  echo ERRO: o servico ainda esta ativo.
  exit /b 1
)

where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo Encaminhamento fechado. curl.exe nao existe para validar a porta no Windows.
  exit /b 0
)

echo Aguardando a porta localhost:%PORT% fechar...
for /l %%I in (1,1,10) do (
  curl.exe --insecure --silent --output NUL --connect-timeout 1 --max-time 2 "https://localhost:%PORT%/"
  if errorlevel 1 goto :closed
  timeout.exe /t 1 /nobreak >nul
)

echo ERRO: o servico foi parado, mas outro processo ainda responde em localhost:%PORT%.
echo Confira a porta com: netstat.exe -ano ^| findstr.exe ":%PORT%"
exit /b 1

:closed
echo Encaminhamento fechado e desabilitado com sucesso.
echo O cluster continua executando internamente no WSL, sem porta publicada por estes scripts.
exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO] [PORTA]
echo.
echo Para e desabilita persistentemente o tunel local do Headlamp.
echo Padroes: DISTRIBUICAO=Ubuntu-26.04 e PORTA=30443.
exit /b 0
