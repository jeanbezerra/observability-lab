@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem =============================================================================
rem Baixa ou importa o bundle de artefatos e o extrai em offline-cache.
rem
rem Sem argumento, baixa o .tar.gz e o .sha256 do bucket S3 configurado abaixo
rem para dist\, valida SHA-256 e extrai. Se o bundle local de dist\ ja possuir o
rem hash publicado, o download grande e ignorado.
rem
rem Com um argumento, importa um .tar.gz local e exige o arquivo .sha256 ao lado
rem dele. O bundle possui .deb, Helm, Flannel e charts, mas NAO possui imagens.
rem
rem Usa apenas curl.exe, certutil.exe e tar.exe; nao usa PowerShell, nao altera
rem firewall e nao precisa ser executado como administrador do Windows.
rem
rem Uso:
rem   05-import-offline-bundle.cmd
rem   05-import-offline-bundle.cmd ARQUIVO_TAR_GZ
rem =============================================================================

set "BUNDLE_NAME=kubernetes-wsl-artifacts-ubuntu-26.04-v1.36-amd64.tar.gz"
set "BUNDLE_URL=https://observability-lab-177862772785-sa-east-1-an.s3.sa-east-1.amazonaws.com/kubernetes-wsl-artifacts-ubuntu-26.04-v1.36-amd64.tar.gz"
set "CHECKSUM_URL=https://observability-lab-177862772785-sa-east-1-an.s3.sa-east-1.amazonaws.com/kubernetes-wsl-artifacts-ubuntu-26.04-v1.36-amd64.tar.gz.sha256"

if /i "%~1"=="/?" goto :help
if /i "%~1"=="--help" goto :help
if not "%~2"=="" goto :too_many_arguments

where.exe certutil.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: certutil.exe nao foi encontrado; o SHA-256 nao pode ser validado.
  exit /b 1
)
where.exe tar.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: tar.exe nao foi encontrado neste Windows.
  exit /b 1
)

for %%I in ("%~dp0..") do set "PROJECT_ROOT=%%~fI"
set "CACHE_DIR=%PROJECT_ROOT%\offline-cache"

if not "%~1"=="" goto :use_local_file

where.exe curl.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: curl.exe nao foi encontrado; informe um bundle local como argumento.
  exit /b 1
)

set "DIST_DIR=%PROJECT_ROOT%\dist"
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
if errorlevel 1 (
  echo ERRO: nao foi possivel criar "%DIST_DIR%".
  exit /b 1
)
set "ARCHIVE=%DIST_DIR%\%BUNDLE_NAME%"
set "CHECKSUM_FILE=%ARCHIVE%.sha256"

echo Baixando o checksum publicado...
curl.exe --fail --location --silent --show-error --retry 3 --connect-timeout 15 ^
  --output "%CHECKSUM_FILE%.download" "%CHECKSUM_URL%"
if errorlevel 1 (
  del /q "%CHECKSUM_FILE%.download" >nul 2>&1
  echo ERRO: nao foi possivel baixar o checksum do S3.
  exit /b 1
)
move /y "%CHECKSUM_FILE%.download" "%CHECKSUM_FILE%" >nul
if errorlevel 1 (
  echo ERRO: nao foi possivel salvar "%CHECKSUM_FILE%".
  exit /b 1
)

if not exist "%ARCHIVE%" goto :download_bundle
echo Validando o bundle existente em dist\...
call :verify_checksum "%ARCHIVE%" "%CHECKSUM_FILE%"
if not errorlevel 1 goto :archive_ready
echo AVISO: o bundle existente nao corresponde ao checksum publicado; ele sera substituido.

:download_bundle
echo Baixando o bundle de aproximadamente 191 MiB do S3...
curl.exe --fail --location --show-error --retry 3 --connect-timeout 15 ^
  --output "%ARCHIVE%.download" "%BUNDLE_URL%"
if errorlevel 1 (
  del /q "%ARCHIVE%.download" >nul 2>&1
  echo ERRO: nao foi possivel baixar o bundle do S3.
  exit /b 1
)
call :verify_checksum "%ARCHIVE%.download" "%CHECKSUM_FILE%"
if errorlevel 1 (
  del /q "%ARCHIVE%.download" >nul 2>&1
  echo ERRO: o bundle baixado nao corresponde ao SHA-256 publicado.
  exit /b 1
)
move /y "%ARCHIVE%.download" "%ARCHIVE%" >nul
if errorlevel 1 (
  echo ERRO: nao foi possivel salvar "%ARCHIVE%".
  exit /b 1
)
goto :archive_ready

:use_local_file
set "ARCHIVE=%~f1"
set "CHECKSUM_FILE=%~f1.sha256"
if not exist "%ARCHIVE%" (
  echo ERRO: arquivo nao encontrado: "%ARCHIVE%"
  exit /b 2
)
if not exist "%CHECKSUM_FILE%" (
  echo ERRO: checksum nao encontrado: "%CHECKSUM_FILE%"
  echo Copie tambem o .sha256 gerado ou execute sem argumentos para baixar do S3.
  exit /b 2
)
call :verify_checksum "%ARCHIVE%" "%CHECKSUM_FILE%"
if errorlevel 1 (
  echo ERRO: o arquivo local nao corresponde ao SHA-256 informado.
  exit /b 1
)

:archive_ready
echo SHA-256 validado com sucesso.
echo Validando a estrutura do arquivo...
tar.exe -tzf "%ARCHIVE%" >nul
if errorlevel 1 (
  echo ERRO: o arquivo nao e um .tar.gz valido.
  exit /b 1
)

if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%"
if errorlevel 1 (
  echo ERRO: nao foi possivel criar "%CACHE_DIR%".
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

:verify_checksum
setlocal EnableExtensions DisableDelayedExpansion
set "EXPECTED_SHA="
for /f "usebackq tokens=1" %%H in ("%~2") do if not defined EXPECTED_SHA set "EXPECTED_SHA=%%H"
if not defined EXPECTED_SHA (
  endlocal
  exit /b 1
)
if "%EXPECTED_SHA:~63,1%"=="" (
  endlocal
  exit /b 1
)
if not "%EXPECTED_SHA:~64,1%"=="" (
  endlocal
  exit /b 1
)
for /f "delims=0123456789abcdefABCDEF" %%H in ("%EXPECTED_SHA%") do (
  endlocal
  exit /b 1
)

set "ACTUAL_SHA="
for /f "skip=1 delims=" %%H in ('certutil.exe -hashfile "%~1" SHA256 2^>nul') do if not defined ACTUAL_SHA set "ACTUAL_SHA=%%H"
set "ACTUAL_SHA=%ACTUAL_SHA: =%"
if /i not "%ACTUAL_SHA%"=="%EXPECTED_SHA%" (
  endlocal
  exit /b 1
)
endlocal
exit /b 0

:too_many_arguments
echo ERRO: informe no maximo um caminho de bundle local.
exit /b 2

:help
echo Uso:
echo   %~nx0
echo   %~nx0 ARQUIVO_TAR_GZ
echo.
echo Sem argumento, baixa bundle e checksum do S3, valida e extrai no projeto.
echo Com argumento, usa o arquivo local e exige ARQUIVO_TAR_GZ.sha256 ao lado.
echo Nao usa PowerShell, nao altera firewall e nao inclui imagens de conteiner.
exit /b 0
