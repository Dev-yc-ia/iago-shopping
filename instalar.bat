@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  set PYTHON_EXE=py
) else (
  set PYTHON_EXE=python
)
echo Criando ambiente local em .venv...
%PYTHON_EXE% -m venv .venv
if errorlevel 1 (
  echo Falha ao criar o ambiente Python.
  exit /b 1
)
echo Instalando dependencias fixadas...
".venv\Scripts\python.exe" -m pip install --upgrade pip
".venv\Scripts\python.exe" -m pip install -r requirements.txt
echo.
echo Instala??o conclu?da. Use iniciar.bat para abrir o servidor local.
