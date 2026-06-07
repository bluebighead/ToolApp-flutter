# Debug: M3U8 segments 复制失败

**日期**：2026-06-07
**状态**：[OPEN]
**现象**：
- 浅扫 M3U8 成功
- 用户选择 M3U8 后，复制阶段耗时较长
- 复制完成后 destDir 里**只有 M3U8 文件本身（几 KB）**，没有 segments 文件夹

**预期**：
- 启发式命中同名 segments 文件夹（`测试视频.m3u8` → `测试视频/`）→ 整文件夹复制
- 或解析 M3U8 逐个复制 segments

**实际**：
- 只有 M3U8 几 KB 文件
- segments 一个都没拷过来

---

## 假设（Hypotheses）

1. **H1：启发式没命中** — `tree.findFile("测试视频")` 在 SAF 下找不到同名文件夹（可能是大小写、文件名编码、tree.findFile 行为问题）
2. **H2：启发式命中但 copyDirRecursiveSaf 失败** — 文件夹找到了但列出/复制子项时报错（比如权限、子项命名）
3. **H3：解析兜底没找到 segment 引用** — M3U8 文件内容里 segment 是用绝对 URL 而不是相对路径（FFmpeg 自己下，导致 0 个本地 segment 复制）
4. **H4：解析兜底找到了引用但 copySingleFile 不支持带 `/` 的相对路径** — 比如 M3U8 里写 `测试视频/seg_001.ts`，`tree.findFile("测试视频/seg_001.ts")` 在 SAF 下查不到（SAF findFile 只查直接子项，不支持 `/`）
5. **H5：segments 引用是裸文件名（如 `seg_001.ts`）但实际在子文件夹下** — M3U8 没写路径前缀，segments 散在 `测试视频/` 子目录里

**主怀疑**：H1 或 H4，因为用户描述"长时间复制"暗示确实在尝试做点什么（不是 0 个引用直接返回），但最终 0 个 segment 被拷。

---

## 收集证据（Instrumentation）

第一步先加日志（不修逻辑），让用户重试一次然后看 logcat 拿真实运行时数据。

**已加的 instrumentation：**
- `tryCopyHeuristicFolder`：打印 root 下所有直接子项名字、findFile 结果、isDirectory、复制完成数
- `parseAndCopySegments`：打印 M3U8 全文前 30 行、segmentRefs 前 10 个、每个 ref 的 sourceRel 转换、是否成功
- `copySingleFile`：打印 relPath 特征（是否含 /）、basename、SAF findFile 命中情况

**操作：**
- instrumented 版本（v1.6.11+37）已装到手机
- adb logcat 已在后台收集，输出到 `debug-logcat.txt`，过滤 `SafHelper:I *:S`
- ⏳ **请用户复现一次**（打开 App → 选 M3U8 目录 → 选 M3U8 → 等复制完成）

---

## 分析（已确认）

| # | 假设 | 状态 | 证据 |
|---|---|---|---|
| H1 | 启发式未命中 | ✅ CONFIRMED | `[DBG-HEURISTIC] findFile('TUE-142 尾随...MissAV...2896591493') 返回 null` — 启发式找的是去后缀名，但用户的 segments 文件夹实际叫 `<M3U8文件名>.m3u8_contents`（带 `.m3u8_contents` 后缀） |
| H2 | 启发式命中但 copyDirRecursiveSaf 失败 | ❌ 拒绝 | 启发式根本没命中，无需分析 |
| H3 | segments 是 URL | ❌ 拒绝 | M3U8 内容是相对路径 `...m3u8_contents/N` |
| H4 | copySingleFile 不支持 `/` | ✅ CONFIRMED | `[DBG-COPY] SAF findFile('...m3u8_contents/0') 返回 null` |
| H5 | 散文件无路径 | ❌ 拒绝 | segment refs 全部带路径 |

**额外发现**：root children 列表（38 项）里**完全没有 TUE-142 字符串**（验证了），但 listM3u8InDir 报告 40 个 M3U8 — 推测 **TUE-142 在 Quark 云端未下载到本地缓存**，listFiles 拿不到它。这超出代码修复范围，需用户先在夸克里点开让它同步完。

**真正的代码 bug**：
- 启发式只尝试了"去后缀的同名"这一个候选，**没考虑** `<M3U8文件名>.m3u8_contents` 这种命名约定
- `copySingleFile` 在 SAF 模式下没处理含 `/` 的相对路径

## 修复（已实施）

### 修复 1：多候选启发式 + 从 segment refs 提取候选
`copyM3u8WithSegments` 从单一候选改成依次试 4 个：
- a) `<M3U8文件名>.m3u8_contents`（实测最常见）
- b) `<M3U8文件名>`（去 .m3u8 后缀）
- c) `<M3U8完整文件名>`
- d) 从 M3U8 内容第一行 segment ref 提取父目录名

### 修复 2：`copySingleFile` SAF 模式支持多段路径
原 `tree.findFile(relPath)` 不支持 `/`。改为：
- 按 `/` split
- 链式 findFile（每一段都查直接子项）
- destDir 下保留子目录结构
- FS 模式同步支持子目录

### 修复 3：兜底失败时日志更明确
如果所有启发式都失败且解析也复制了 0 个，输出提示："可能 M3U8 引用了 URL 形式的 segments，或对应 segments 文件夹在云端未下载到本地。"

## 验证（待补）

版本已升至 1.6.12+38，新 APK 已编译并安装到 `d6e30fdf`。

## 已知限制
- **云端未下载的 segments 文件夹复制不了**：用户需先在夸克里点开让它同步完成
- TUE-142 这类"先浅扫可见、实际未下载"的情况，listFiles 拿不到，SAF 也无法复制 — 这是云盘抽象层的限制，代码层面无解

## 复现步骤
1. 在 Quark 客户端把对应 M3U8 文件的 segments 文件夹（`*.m3u8_contents/`）打开一下让本地缓存
2. 在 App 里选 M3U8 → 期望：能整文件夹复制；如果不行，也能从 M3U8 内容里提取 segments 路径，链式 findFile 逐个复制
