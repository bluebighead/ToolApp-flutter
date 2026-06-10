# ToolApp Admin 一键启动脚本 (PowerShell 版本)
# 双击 .bat 文件启动，或在 PowerShell 中运行: .\启动 ToolApp Admin.ps1

param(
    [switch]$ForceReinstall = $false
)

$ErrorActionPreference = 'Stop'
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$AdminPath = Join-Path $ScriptPath "toolapp-admin"

# 设置 UTF-8 编码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 检查 node.js 是否安装
try {
    $nodeVersion = node --version 2>$null
    if (-not $nodeVersion) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "  错误: 未检测到 Node.js!" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "请先安装 Node.js (建议 v18 或更高版本)"
        Write-Host "下载地址: https://nodejs.org/"
        Write-Host ""
        Read-Host "按回车键退出"
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  错误: 未检测到 Node.js!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "请先安装 Node.js (建议 v18 或更高版本)"
    Write-Host "下载地址: https://nodejs.org/"
    Write-Host ""
    Read-Host "按回车键退出"
    exit 1
}

# 清屏并显示标题
Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ToolApp Admin 数据库管理软件" -ForegroundColor Cyan
Write-Host "         正在启动中..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Node.js 版本: $nodeVersion" -ForegroundColor Green
Write-Host ""

# 切换到 toolapp-admin 目录
Set-Location $AdminPath

# 检查是否需要安装依赖
$NodeModulesPath = Join-Path $AdminPath "node_modules"
$ShouldInstall = $false

if ($ForceReinstall) {
    $ShouldInstall = $true
    Write-Host "[1/2] 强制重新安装依赖..." -ForegroundColor Yellow
} elseif (-not (Test-Path $NodeModulesPath)) {
    $ShouldInstall = $true
    Write-Host "[1/2] 首次启动，正在安装依赖..." -ForegroundColor Yellow
    Write-Host "   （这可能需要 2-5 分钟，请耐心等待）" -ForegroundColor DarkGray
}

if ($ShouldInstall) {
    Write-Host ""
    $InstallStart = Get-Date
    npm install
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "  依赖安装失败，请检查网络连接" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Read-Host "按回车键退出"
        exit 1
    }
    $InstallTime = (Get-Date) - $InstallStart
    Write-Host ""
    Write-Host "[2/2] 依赖安装完成！用时 $([math]::Round($InstallTime.TotalSeconds, 1)) 秒" -ForegroundColor Green
}

# 启动应用
Write-Host ""
Write-Host "正在启动开发服务器和 Electron 客户端..." -ForegroundColor Cyan
Write-Host "提示: 关闭此窗口即可退出程序" -ForegroundColor DarkGray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

npm run dev

Write-Host ""
Write-Host "程序已退出。" -ForegroundColor Gray
Write-Host ""
