@echo off
setlocal EnableExtensions

rem =============================================================================
rem Remove a confianca na CA do Headlamp do usuario atual do Windows.
rem
rem Este script nao fecha portas nem altera o cluster. Para fechar o tunel local,
rem execute antes 80-close-cluster-ports.cmd.
rem
rem Uso: 90-untrust-headlamp-ca.cmd
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

where.exe certutil.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: certutil.exe nao foi encontrado.
  exit /b 1
)

echo Removendo a CA do Headlamp do repositorio do usuario atual do Windows...
certutil.exe -user -delstore Root "kubernetes-wsl-headlamp-ca"
if errorlevel 1 (
  echo ERRO: a CA nao foi encontrada ou nao pode ser removida.
  exit /b 1
)

echo CA removida.
exit /b 0

:help
echo Uso: %~nx0
echo.
echo Remove somente a CA do Headlamp do repositorio do usuario atual.
exit /b 0
