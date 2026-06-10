@echo off
chcp 65001 >nul
title ToolApp Admin - 一键启动
color 0B

echo.
echo ========================================
echo     ToolApp Admin 数据库管理软件
echo            正在启动中...
echo ========================================
echo.

cd /d "%~dp0toolapp-admin"

if not exist node_modules (
    echo [1/2] 首次启动，正在安装依赖，请稍候...
    echo     （这可能需要 2-5 分钟，请耐心等待）
    echo.
    call npm install
    echo.
    echo [2/2] 依赖安装完成！
)

echo.
echo 正在启动开发服务器和 Electron 客户端...
echo 提示：关闭窗口即可退出程序
echo.
echo ========================================
echo.

call npm run dev

echo.
echo 程序已退出。
pause
