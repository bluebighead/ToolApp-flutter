# Debug Session: batch-convert-failure

**Status:** [OPEN]
**Created:** 2026-06-08
**Bug:** 批量转换 M3U8 文件时，所有文件均提示失败

## Symptoms
- M3U8 文件批量复制成功后显示在批量转换窗口
- 所有文件右侧显示"转换中"后，均提示失败
- 具体错误信息待用户提供

## Hypotheses
1. **H1: 输入文件路径错误** - 批量转换时使用的 inputPath 指向的文件不存在（临时目录路径不对或文件未正确复制）
2. **H2: FFmpeg 执行失败** - FFmpeg 二进制文件未正确加载或执行参数有误
3. **H3: 输出路径无效** - outputPath 生成逻辑有问题（SAF 路径或权限问题）
4. **H4: 并发冲突** - 多个转换任务同时执行时资源竞争导致失败

## Instrumentation Plan
- 在批量转换任务启动时记录每个任务的 inputPath 和文件存在性
- 在 FFmpeg 执行前后记录详细日志
- 记录失败时的完整错误堆栈

## Evidence
(待用户提供日志后填写)

## Fix
(待分析后填写)

## Verification
(待用户确认后填写)
