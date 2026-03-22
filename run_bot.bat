@echo off
setlocal
REM UTF-8 в консоли (кириллица в echo; сохраняй .bat в UTF-8)
chcp 65001 >nul
set PYTHONUTF8=1
title Sonaria Farm - Bot
cd /d "%~dp0"

set "PY="
if exist "%~dp0.venv\Scripts\python.exe" set "PY=%~dp0.venv\Scripts\python.exe"
if not defined PY if exist "%~dp0venv\Scripts\python.exe" set "PY=%~dp0venv\Scripts\python.exe"

if not defined PY (
    echo [ОШИБКА] Не найден интерпретатор: .venv\Scripts\python.exe или venv\Scripts\python.exe
    echo Создай окружение: python -m venv .venv
    echo Установи зависимости: .venv\Scripts\pip.exe install -r requirements.txt
    echo.
    echo Нажми любую клавишу, чтобы закрыть окно.
    pause >nul
    exit /b 1
)

echo Остановка бота: нажми Ctrl+C в этом окне.
echo Логи идут ниже. Окно не закроется само после ошибки или остановки.
echo.
"%PY%" -u bot_main.py

echo.
echo -----------------------------------------
echo Сессия завершена. Нажми любую клавишу, чтобы закрыть окно.
pause >nul
