@echo off
setlocal
fltmc >nul 2>&1
if errorlevel 1 (
  echo Execute este arquivo em um Prompt de Comando como Administrador.
  exit /b 1
)
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0..\scripts\lib\windows-time.ps1" -Mode apply
exit /b %ERRORLEVEL%
