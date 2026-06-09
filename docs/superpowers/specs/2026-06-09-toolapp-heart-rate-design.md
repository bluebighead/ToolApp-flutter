# 心率广播接收器设计文档

## 概述

心率广播接收器是ToolApp的第四个工具，用于接收心率广播设备发送的心率数据，并实时显示在手机屏幕上。

## 需求

- 支持BLE蓝牙低功耗和WiFi UDP两种接收方式
- 实时显示心率数值（BPM）
- 提供折线图显示心率历史趋势
- 用户可灵活切换显示模式（数字/图表/组合）
- 用户可切换连接方式（BLE/WiFi UDP）

## 架构

### 文件结构

```
lib/
├── pages/
│   └── heart_rate_page.dart          # 主页面
├── widgets/
│   ├── heart_rate_display.dart       # 数字显示组件
│   └── heart_rate_chart.dart         # 折线图组件
└── utils/
    ├── heart_rate_ble.dart           # BLE接收工具
    └── heart_rate_udp.dart           # UDP接收工具
```

### 数据流

1. 用户选择连接方式（BLE/UDP）
2. 启动对应接收器
3. 接收原始数据并解析为BPM
4. 更新当前心率和历史队列
5. UI响应式刷新

## BLE实现

- 使用 `flutter_reactive_ble` 插件
- 扫描心率设备（Heart Rate Service UUID: 0x180D）
- 连接并订阅心率测量特征值（0x2A37）
- 解析标准心率特征值格式

## UDP实现

- 使用Dart原生 `RawDatagramSocket`
- 监听指定端口（默认8888）
- 解析纯数字格式（预留JSON解析）
- 提供端口配置接口

## 显示模式

- 数字模式：大号BPM数值
- 图表模式：折线图（最近60个点）
- 组合模式：数字+图表
- 顶部切换按钮控制

## 权限

- BLUETOOTH_SCAN, BLUETOOTH_CONNECT
- INTERNET（UDP）
- ACCESS_FINE_LOCATION（BLE扫描需要）

## 依赖

- flutter_reactive_ble: ^5.3.0
- 复用现有 fl_chart, permission_handler
