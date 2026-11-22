@echo off
setlocal
title IAGO SYSTEM ACSN - HOMOLOGACAO 8095

cd /d "%~dp0" || goto :falha

set "PORTA=8095"
set "URL=http://127.0.0.1:%PORTA%"
set "CHROME_EXE="
set "CHROME_PROFILE="

echo ============================================
echo  IAGO SYSTEM ACSN - PORTA %PORTA%
echo ============================================
echo.

if not exist ".venv\Scripts\python.exe" (
    echo Python local nao encontrado. Confira a instalacao do Iago System.
    goto :falha
)

for %%C in (
    "%ProgramFiles%\Google\Chrome\Application\chrome.exe"
    "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
    "%LocalAppData%\Google\Chrome\Application\chrome.exe"
) do if not defined CHROME_EXE if exist "%%~C" set "CHROME_EXE=%%~C"

if not defined CHROME_EXE (
    echo Chrome nao encontrado nos caminhos padrao.
    goto :falha
)

for /f %%G in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()"') do (
    set "CHROME_PROFILE=%TEMP%\chrome_iago_acsn_%PORTA%_%%G"
)

if not defined CHROME_PROFILE (
    echo Nao foi possivel gerar o caminho do novo perfil do Chrome.
    goto :falha
)

echo Encerrando servidor anterior na porta %PORTA%...
powershell -NoProfile -Command "$ids = Get-NetTCPConnection -LocalPort %PORTA% -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; foreach ($serverPid in $ids) { Stop-Process -Id $serverPid -Force -ErrorAction Stop }; for ($i = 0; $i -lt 20; $i++) { if (-not (Get-NetTCPConnection -LocalPort %PORTA% -State Listen -ErrorAction SilentlyContinue)) { exit 0 }; Start-Sleep -Milliseconds 250 }; exit 1"

if errorlevel 1 (
    echo Nao foi possivel liberar a porta %PORTA%.
    goto :falha
)

echo Iniciando servidor...
start "Servidor IAGO SYSTEM ACSN - %PORTA%" cmd /k .venv\Scripts\python.exe -m scripts.iniciar_local %*

echo Aguardando resposta em %URL%...
powershell -NoProfile -Command "$limite = (Get-Date).AddSeconds(60); do { try { $r = Invoke-WebRequest -Uri '%URL%/' -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { exit 0 } } catch {}; Start-Sleep -Seconds 1 } while ((Get-Date) -lt $limite); exit 1" >nul 2>&1

if errorlevel 1 (
    echo O servidor nao respondeu em 60 segundos. Confira a janela do servidor.
    goto :falha
)

echo Abrindo Chrome com perfil novo...
start "" "%CHROME_EXE%" ^
    --user-data-dir="%CHROME_PROFILE%" ^
    --no-first-run ^
    --no-default-browser-check ^
    --new-window ^
    "%URL%"

exit /b 0

:falha
pause
exit /b 1