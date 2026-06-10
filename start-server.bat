@echo off
title ToolApp Server
color 0A
echo.
echo ========================================
echo   ToolApp Server - Data Sync Service
echo ========================================
echo.
cd /d "%~dp0toolapp-server"

REM 检查 Node.js 是否安装
node --version >nul 2>&1
if errorlevel 1 (
    color 0C
    echo ERROR: Node.js is not installed!
    echo Please install Node.js from https://nodejs.org/
    echo.
    pause
    exit /b 1
)
for /f "delims=" %%i in ('node --version') do set NODE_VER=%%i
echo Node.js version: %NODE_VER%
echo.

REM 安装依赖（首次运行时）
if not exist node_modules (
    echo First time setup - installing dependencies...
    echo (This may take 1-3 minutes)
    echo.
    call npm install
    if errorlevel 1 (
        color 0C
        echo ERROR: Failed to install dependencies!
        pause
        exit /b 1
    )
    echo.
    echo Dependencies installed!
)

REM 检查端口 3000 是否已被占用
echo Checking port 3000...
netstat -ano | findstr ":3000" | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    color 0E
    echo.
    echo WARNING: Port 3000 is already in use!
    echo The server may already be running.
    echo.
    echo Options:
    echo   1. Close this window if server is already running
    echo   2. Press any key to try starting anyway
    echo.
    pause
    color 0A
)

REM 启动服务器
echo.
echo Starting ToolApp Server...
echo Server URL: http://localhost:3000
echo.
echo Keep this window open. Close it to stop the server.
echo.
echo ========================================
echo.

node server.js

REM 服务器退出后显示状态
echo.
if errorlevel 1 (
    color 0C
    echo ========================================
    echo   Server exited with ERROR (code %errorlevel%)
    echo ========================================
) else (
    color 0E
    echo ========================================
    echo   Server stopped normally
    echo ========================================
)
echo.
pause
