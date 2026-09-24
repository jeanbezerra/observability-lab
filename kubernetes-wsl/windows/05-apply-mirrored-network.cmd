@echo off
setlocal EnableExtensions

rem =============================================================================
rem Aplica uma alteracao ja salva em %UserProfile%\.wslconfig.
rem
rem networkingMode e uma configuracao global da VM WSL 2. Por isso este script
rem usa wsl.exe --shutdown e encerra TODAS as distribuicoes WSL em execucao.
rem Ele nao copia nem sobrescreve .wslconfig, nao usa PowerShell e nao altera
rem Windows Firewall, Hyper-V Firewall ou UFW.
rem
rem Uso: 05-apply-mirrored-network.cmd [DISTRIBUICAO]
rem Ex.: 05-apply-mirrored-network.cmd Ubuntu-26.04
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "DISTRO=%~1"
if not defined DISTRO set "DISTRO=Ubuntu-26.04"

set "INVALID_DISTRO="
for /f "delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" %%A in ("%DISTRO%") do set "INVALID_DISTRO=1"
if defined INVALID_DISTRO (
  echo ERRO: DISTRIBUICAO aceita somente letras, numeros, ponto, sublinhado e hifen.
  exit /b 2
)

where.exe wsl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: wsl.exe nao foi encontrado.
  exit /b 1
)

if not exist "%UserProfile%\.wslconfig" (
  echo ERRO: %UserProfile%\.wslconfig nao existe.
  echo Revise e copie primeiro windows\.wslconfig.example para esse caminho.
  exit /b 1
)

echo ATENCAO: esta operacao encerrara todas as distribuicoes WSL e seus processos.
choice.exe /C SN /N /M "Continuar? [S/N] "
if errorlevel 2 exit /b 0

echo Encerrando a VM global do WSL 2...
wsl.exe --shutdown
if errorlevel 1 (
  echo ERRO: wsl.exe --shutdown falhou.
  exit /b 1
)

echo Aguardando a configuracao global ser recarregada...
timeout.exe /t 8 /nobreak >nul

echo Iniciando "%DISTRO%"...
wsl.exe -d %DISTRO% --user root -- /bin/true >nul 2>&1
if errorlevel 1 (
  echo ERRO: "%DISTRO%" nao iniciou. Confira com: wsl.exe --list --verbose
  exit /b 1
)

set "NETWORK_MODE="
for /f "delims=" %%M in ('wsl.exe -d %DISTRO% --user root -- wslinfo --networking-mode 2^>nul') do set "NETWORK_MODE=%%M"
if not defined NETWORK_MODE (
  echo ERRO: wslinfo nao informou o modo de rede. Atualize pelo CMD com: wsl.exe --update
  exit /b 1
)
if /i not "%NETWORK_MODE%"=="mirrored" (
  echo ERRO: modo detectado: "%NETWORK_MODE%". Era esperado "mirrored".
  echo Confira %UserProfile%\.wslconfig e a versao com: wsl.exe --version
  exit /b 1
)

echo Rede mirrored aplicada com sucesso em "%DISTRO%".
echo Execute 00-check-environment.cmd para verificar o restante do ambiente.
exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO]
echo.
echo Reinicia a VM global do WSL e confirma networkingMode=mirrored.
echo Nao copia .wslconfig e nao altera regras de firewall.
echo Padrao: DISTRIBUICAO=Ubuntu-26.04.
exit /b 0
