@echo off
title ToolApp Admin
color 0B
echo.
echo ========================================
echo   ToolApp Admin - Database Manager
echo ========================================
echo.

cd /d "%~dp0toolapp-admin"

REM Check Node.js
where node >nul 2>&1
if errorlevel 1 (
    color 0C
    echo ERROR: Node.js is not installed!
    echo Please install Node.js from https://nodejs.org/
    echo.
    pause
    exit /b 1
)

echo Node.js found. Starting ToolApp Admin...
echo.

REM Install dependencies if needed
if not exist node_modules (
    echo Installing dependencies...
    call npm.cmd install
    if errorlevel 1 (
        color 0C
        echo ERROR: Failed to install dependencies!
        pause
        exit /b 1
    )
)

echo Starting Vite + Electron...
echo (Window will open in 10-30 seconds)
echo Keep this window open. Close it to exit.
echo ========================================
echo.

call npx.cmd concurrently "npx.cmd vite" "npx.cmd wait-on http://localhost:5173 && npx.cmd electron ."
