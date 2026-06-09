# 心率页面UI优化设计文档

## 概述

将心率广播接收器页面的顶部切换按钮改为下拉框形式，并在AppBar右上角添加使用说明按钮。

## 变更内容

### 1. 顶部切换区域
- **当前**: 两个 OutlinedButton.icon 按钮（BLE/WiFi UDP 切换、数字/图表/组合 切换）
- **改为**: 两个 DropdownMenu 下拉框，带标签文字

### 2. AppBar 右上角
- 添加 `IconButton(Icons.help_outline)` 使用说明按钮
- 点击弹出 AlertDialog 对话框，显示使用说明

### 3. 使用说明内容
- BLE连接方式说明（3步）
- WiFi UDP方式说明（2步）
- 显示模式说明（3种模式）
- 设备记忆功能说明

## 文件变更

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `lib/pages/heart_rate_page.dart` | 修改 | 替换顶部按钮为下拉框，添加AppBar使用说明按钮 |
