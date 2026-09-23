@echo off
setlocal EnableExtensions

rem =============================================================================
rem Confia na CA publica do Headlamp apenas para o usuario atual do Windows.
rem
rem A chave privada nunca sai do WSL. O certificado publico e copiado para um
rem arquivo temporario, importado com certutil.exe -user e apagado em seguida.
rem Este script nao abre portas e normalmente nao requer CMD como administrador.
rem
rem Uso: 30-trust-headlamp-ca.cmd [DISTRIBUICAO]
rem Ex.: 30-trust-headlamp-ca.cmd Ubuntu-26.04
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help

set "DISTRO=%~1"
if not defined DISTRO set "DISTRO=Ubuntu-26.04"
set "CERT_FILE=%TEMP%\kubernetes-wsl-headlamp-%RANDOM%.crt"

where.exe wsl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: wsl.exe nao foi encontrado.
  exit /b 1
)
where.exe certutil.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: certutil.exe nao foi encontrado.
  exit /b 1
)

echo Copiando a CA publica do Headlamp a partir de "%DISTRO%"...
wsl.exe -d "%DISTRO%" --user root -- cat /etc/kubernetes/pki/headlamp/ca.crt > "%CERT_FILE%"
if errorlevel 1 goto :copy_error

findstr.exe /c:"-----BEGIN CERTIFICATE-----" "%CERT_FILE%" >nul
if errorlevel 1 goto :copy_error

echo Confiando na CA somente para o usuario atual do Windows...
certutil.exe -user -addstore -f Root "%CERT_FILE%"
if errorlevel 1 goto :cert_error

del /q "%CERT_FILE%" >nul 2>&1
echo CA instalada. Feche e abra novamente o navegador.
exit /b 0

:copy_error
del /q "%CERT_FILE%" >nul 2>&1
echo ERRO: nao foi possivel ler /etc/kubernetes/pki/headlamp/ca.crt em "%DISTRO%".
echo Confirme que a instalacao terminou e que essa e a distribuicao correta.
exit /b 1

:cert_error
del /q "%CERT_FILE%" >nul 2>&1
echo ERRO: certutil nao conseguiu instalar a CA no repositorio do usuario atual.
exit /b 1

:help
echo Uso: %~nx0 [DISTRIBUICAO]
echo.
echo Importa somente a CA publica para o repositorio do usuario atual.
echo Padrao: DISTRIBUICAO=Ubuntu-26.04.
exit /b 0
