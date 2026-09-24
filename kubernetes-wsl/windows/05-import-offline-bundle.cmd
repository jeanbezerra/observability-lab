@echo off
setlocal EnableExtensions

rem =============================================================================
rem Importa o bundle de artefatos na pasta offline-cache do projeto.
rem
rem O arquivo .tar.gz deve ter sido criado por prepare-offline-bundle.sh em uma
rem maquina Ubuntu 26.04 com Internet e com a mesma arquitetura. O bundle possui
rem .deb, Helm, Flannel e charts, mas NAO possui imagens de conteiner.
rem
rem Este script usa apenas tar.exe do Windows; nao usa PowerShell, nao altera
rem firewall e nao precisa ser executado como administrador.
rem
rem Uso: 05-import-offline-bundle.cmd ARQUIVO_TAR_GZ
rem =============================================================================

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help
if "%~1"=="" goto :missing_argument

set "ARCHIVE=%~f1"
if not exist "%ARCHIVE%" (
  echo ERRO: arquivo nao encontrado: "%ARCHIVE%"
  exit /b 2
)

where.exe tar.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: tar.exe nao foi encontrado neste Windows.
  echo Extraia manualmente o arquivo dentro da pasta offline-cache do projeto.
  exit /b 1
)

for %%I in ("%~dp0..") do set "PROJECT_ROOT=%%~fI"
set "CACHE_DIR=%PROJECT_ROOT%\offline-cache"
if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%"
if errorlevel 1 (
  echo ERRO: nao foi possivel criar "%CACHE_DIR%".
  exit /b 1
)

echo Validando a estrutura do arquivo...
tar.exe -tzf "%ARCHIVE%" >nul
if errorlevel 1 (
  echo ERRO: o arquivo nao e um .tar.gz valido.
  exit /b 1
)

echo Importando artefatos em "%CACHE_DIR%"...
tar.exe -xzf "%ARCHIVE%" -C "%CACHE_DIR%"
if errorlevel 1 (
  echo ERRO: tar.exe nao conseguiu extrair o bundle.
  exit /b 1
)

if exist "%CACHE_DIR%\amd64\bundle.env" goto :imported
if exist "%CACHE_DIR%\arm64\bundle.env" goto :imported
echo ERRO: o arquivo foi extraido, mas bundle.env nao foi encontrado.
exit /b 1

:imported
echo Bundle importado. O install-all.sh usara o cache automaticamente se a Internet falhar.
echo Para proibir downloads de artefatos, defina ARTIFACT_MODE="cache" em cluster.env.
echo Imagens de conteiner continuam dependendo de acesso aos registries.
exit /b 0

:missing_argument
echo ERRO: informe o caminho do arquivo .tar.gz.
echo Exemplo: %~nx0 "C:\Temp\kubernetes-wsl-artifacts-ubuntu-26.04-v1.36-amd64.tar.gz"
exit /b 2

:help
echo Uso: %~nx0 ARQUIVO_TAR_GZ
echo.
echo Extrai um bundle gerado por prepare-offline-bundle.sh em offline-cache.
echo Nao usa PowerShell, nao altera firewall e nao inclui imagens de conteiner.
exit /b 0
