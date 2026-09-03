@echo off
setlocal
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  set PYTHON_EXE=.venv\Scripts\python.exe
) else (
  where py >nul 2>nul
  if %errorlevel%==0 (
    set PYTHON_EXE=py
  ) else (
    set PYTHON_EXE=python
  )
)
echo Compilando Python...
%PYTHON_EXE% -m compileall backend tests
if errorlevel 1 exit /b 1
echo Executando testes...
%PYTHON_EXE% -m pytest
