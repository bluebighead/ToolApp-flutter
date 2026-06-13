@echo off
title ToolApp Server
color 0A

cd /d "%~dp0"
if not exist "toolapp-server\server.js" (
    color 0C
    echo.
    echo ========================================
    echo   ERROR: Cannot find toolapp-server\server.js
    echo   Current directory: %CD%
    echo ========================================
    echo.
    pause
    exit /b 1
)
cd /d "%~dp0toolapp-server"

echo.
echo ========================================
echo   ToolApp Server - Data Sync Service
echo ========================================
echo.

where node >nul 2>&1
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

if not exist node_modules (
    echo First time setup - installing dependencies...
    echo This may take 1-3 minutes
    echo.
    call npm install
    if errorlevel 1 (
        color 0C
        echo ERROR: Failed to install dependencies!
        echo.
        pause
        exit /b 1
    )
    echo.
    echo Dependencies installed!
)

echo Checking port 3000...
netstat -ano | findstr ":3000" | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    color 0E
    echo.
    echo WARNING: Port 3000 is already in use!
    echo The server may already be running.
    echo.
    echo   1. Close this window if server is already running
    echo   2. Press any key to try starting anyway
    echo.
    pause
    color 0A
)

echo.
echo ========================================
echo   网络信息 / Network Info
echo ========================================
echo.
echo 主机名: %COMPUTERNAME%
echo.
echo 局域网 IP 地址:
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /i "IPv4"') do (
    for /f "tokens=* delims= " %%B in ("%%A") do echo    - %%B
)
echo.
echo 完整网卡信息:
ipconfig | findstr /i /c:"适配器" /c:"IPv4" /c:"子网掩码" /c:"默认网关"
echo.
echo ========================================
echo.

echo Starting ToolApp Server...
echo Server URL: http://localhost:3000
echo.
echo Keep this window open. Close it to stop the server.
echo ========================================
echo.

node server.js 2>&1

echo.
if %errorlevel% neq 0 (
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
