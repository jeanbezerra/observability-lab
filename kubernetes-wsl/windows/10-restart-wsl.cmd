@echo off
setlocal EnableExtensions

rem =============================================================================
rem Reinicia somente a distribuicao WSL informada.
rem
rem Use depois de alterar /etc/wsl.conf ou %UserProfile%\.wslconfig. O comando
rem termina a VM da distribuicao e a inicia novamente; nenhuma regra de firewall
rem ou configuracao do Windows e alterada.
rem
rem Uso: 10-restart-wsl.cmd [DISTRIBUICAO]
rem Ex.: 10-restart-wsl.cmd Ubuntu-26.04
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

echo Verificando a distribuicao "%DISTRO%"...
wsl.exe -d %DISTRO% -- /bin/true >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: "%DISTRO%" nao existe ou nao pode ser iniciada.
  echo Confira os nomes com: wsl.exe --list --verbose
  exit /b 1
)

echo Encerrando a distribuicao WSL "%DISTRO%"...
wsl.exe --terminate %DISTRO%
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: nao foi possivel encerrar "%DISTRO%".
  exit /b 1
)

echo Iniciando novamente "%DISTRO%"...
wsl.exe -d %DISTRO% -- /bin/true >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERRO: a distribuicao foi encerrada, mas nao reiniciou corretamente.
  exit /b 1
)

echo Concluido. Use 00-check-environment.cmd para verificar o ambiente.
exit /b 0

:help
echo Uso: %~nx0 [DISTRIBUICAO]
echo.
echo Encerra e inicia novamente apenas a distribuicao indicada.
echo Padrao: DISTRIBUICAO=Ubuntu-26.04.
exit /b 0
