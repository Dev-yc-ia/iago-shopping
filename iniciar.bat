@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

set "HOST=127.0.0.1"
set "PORT=8010"
set "APP_URL=http://%HOST%:%PORT%"
set "HEALTH_URL=%APP_URL%/health"
set "CHROME_PROFILE_BASE=%TEMP%\IAGO_Shopping_Chrome_Profile_8010"
set "CHROME_PROFILE=%CHROME_PROFILE_BASE%"

echo ============================================================
echo IAGO Shopping - inicializacao local
echo URL: %APP_URL%
echo Porta exclusiva: %PORT%
echo ============================================================
echo.

if exist ".venv\Scripts\python.exe" (
  set "PYTHON_EXE=%CD%\.venv\Scripts\python.exe"
) else (
  where py >nul 2>nul
  if !errorlevel!==0 (
    set "PYTHON_EXE=py"
  ) else (
    set "PYTHON_EXE=python"
  )
)

echo Verificando processos que escutam somente a porta %PORT%...
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do (
  if not "%%P"=="0" (
    echo Encerrando processo da porta %PORT%: PID %%P
    taskkill /PID %%P /F >nul 2>nul
  )
)

echo Limpando perfil temporario isolado do Chrome do Shopping...
if exist "%CHROME_PROFILE%" (
  rd /s /q "%CHROME_PROFILE%" >nul 2>nul
)
if exist "%CHROME_PROFILE%" (
  echo Perfil temporario anterior ainda esta em uso. Criando perfil limpo para esta execucao.
  set "CHROME_PROFILE=%CHROME_PROFILE_BASE%_%RANDOM%%RANDOM%"
  if exist "!CHROME_PROFILE!" (
    rd /s /q "!CHROME_PROFILE!" >nul 2>nul
  )
)
mkdir "%CHROME_PROFILE%" >nul 2>nul

echo Iniciando backend em %APP_URL%...
start "IAGO Shopping API 8010" /D "%CD%" "%PYTHON_EXE%" -B -m uvicorn backend.main:app --host %HOST% --port %PORT%

echo Aguardando health check em %HEALTH_URL%...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='%HEALTH_URL%'; $ok=$false; for ($i=1; $i -le 40; $i++) { try { $r=Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 2; if ($r.StatusCode -eq 200) { $ok=$true; break } } catch { Start-Sleep -Milliseconds 500 } }; if (-not $ok) { exit 1 }"
if errorlevel 1 (
  echo [ERRO] O backend nao respondeu em %HEALTH_URL%.
  echo Verifique a janela "IAGO Shopping API 8010".
  pause
  exit /b 1
)

set "CHROME_EXE="
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME_EXE=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined CHROME_EXE if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME_EXE=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not defined CHROME_EXE if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" set "CHROME_EXE=%LocalAppData%\Google\Chrome\Application\chrome.exe"

echo Abrindo IAGO Shopping com perfil temporario isolado...
if defined CHROME_EXE (
  start "IAGO Shopping Chrome" "%CHROME_EXE%" ^
    --user-data-dir="%CHROME_PROFILE%" ^
    --disk-cache-dir="%CHROME_PROFILE%\Cache" ^
    --disk-cache-size=1 ^
    --media-cache-size=1 ^
    --disable-application-cache ^
    --disable-background-networking ^
    --new-window "%APP_URL%"
) else (
  echo Chrome nao encontrado nos locais padrao. Abrindo no navegador padrao.
  start "" "%APP_URL%"
)

echo.
echo IAGO Shopping iniciado em %APP_URL%.
echo A janela do backend permanece separada para logs e encerramento manual.
endlocal
