---
name: deveco-studio-hilog
description: HarmonyOS日志分析助手，专注于hilog日志查看、崩溃日志分析、日志导出(-logZip)、手动日志分析。包含完整的hilog命令、hidumper堆栈转储、崩溃日志自动解压分析功能。支持Windows/macOS/Linux跨平台。
license: MIT
metadata:
  author: HarmonyOS Agent Skills Team
  version: "1.0.0"
compatibility: Designed for DevEco Studio. Requires Python 3.6+. Depends on deveco-studio-emulator skill.
---

# HarmonyOS日志分析助手

专注于DevEco Studio模拟器和应用日志的查看、分析、导出和崩溃诊断。包含完整的hilog命令、崩溃日志自动解压分析功能。

---

## 快速导航

| 功能模块 | 说明 | 参考文档 |
|---------|------|---------|
| **环境配置** | DevEco Studio路径配置（依赖emulator skill） | 本页 "环境配置" 章节 |
| **hilog日志** | 基础命令、进程过滤、错误日志 | [hilog.md](references/hilog.md)、[hilog-advanced.md](references/hilog-advanced.md) |
| **崩溃分析** | 自动解压分析崩溃日志 | [crash-log-analysis.md](references/crash-log-analysis.md) |
| **日志导出** | 使用-logZip导出完整日志包 | [log-export-analysis.md](references/log-export-analysis.md) |
| **手动日志** | 手动保存日志分析 | [manual-log-analysis.md](references/manual-log-analysis.md) |
| **hidumper** | 堆栈转储分析工具 | [hidumper.md](references/hidumper.md) |

---

## 🚀 快速开始

### 应用日志查看（推荐）

**重要**：查看应用日志推荐使用进程ID过滤，而非标签过滤。

```bash
# 步骤1：查找应用进程ID
hdc shell aa dump -a

# 步骤2：使用进程ID过滤日志
hdc shell hilog -P {进程ID}              # 实时日志
hdc shell hilog -x -n 200 -P {进程ID}    # 历史日志（200行）
hdc shell hilog -L E -P {进程ID}         # 错误日志
```

### 崩溃日志分析

**Windows:**
```powershell
# 自动查找实例路径（推荐）
.\scripts\analyze-crash-log.ps1 -AutoFind
```

**macOS/Linux:**
```bash
python scripts/analyze_crash_log.py
```

---

## 环境配置

### 配置依赖说明

本skill的路径配置**优先依赖** `deveco-studio-emulator` skill的配置：

1. **优先级1**：读取 `../deveco-studio-emulator/scripts/config.json`
2. **优先级2**：如果配置不存在，运行 `python ../deveco-studio-emulator/scripts/setup.py`
3. **优先级3**：环境变量

### 配置文件位置

配置文件路径：`../deveco-studio-emulator/scripts/config.json`

配置内容示例：
```json
{
  "devecoStudioPath": "C:\\Program Files\\Huawei\\DevEco Studio",
  "emulatorPath": "C:\\Program Files\\Huawei\\DevEco Studio\\tools\\emulator\\emulator.exe",
  "hdcPath": "C:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe",
  "emulatorInstancePath": "C:\\Users\\YourName\\Huawei\\emulator\\deployed\\MyPhone",
  "emulatorDeployPath": "C:\\Users\\YourName\\Huawei\\emulator\\deployed",
  "tempPath": "C:\\Temp"
}
```

### 初始化配置

如果配置文件不存在，需要先初始化：

```bash
# 方法1：运行emulator skill的setup.py
python ../deveco-studio-emulator/scripts/setup.py

# 方法2：指定DevEco Studio路径
python ../deveco-studio-emulator/scripts/setup.py --deveco-path "C:\\Program Files\\Huawei\\DevEco Studio"
```

### 环境变量（可选）

也可以通过环境变量配置路径：

**Windows:**
```powershell
$env:DEVECO_STUDIO_PATH = "C:\Program Files\Huawei\DevEco Studio"
$env:HDC_PATH = "$env:DEVECO_STUDIO_PATH\sdk\default\openharmony\toolchains\hdc.exe"
$env:EMULATOR_INSTANCE_PATH = "C:\Users\YourName\Huawei\emulator\deployed\MyPhone"
```

**macOS/Linux:**
```bash
export DEVECO_STUDIO_PATH="/Applications/DevEco-Studio.app/Contents"
export HDC_PATH="$DEVECO_STUDIO_PATH/sdk/default/openharmony/toolchains/hdc"
export EMULATOR_INSTANCE_PATH="$HOME/Huawei/emulator/deployed/MyPhone"
```

---

## hilog日志查看

### 应用日志查看（推荐）

**重要**：查看应用日志推荐使用进程ID过滤，而非标签过滤。

```bash
# 步骤1：查找应用进程ID
hdc shell aa dump -a

# 输出示例：
# AppRunningRecord ID #10
#   process name [com.example.myapplication]
#   pid #2869  uid #20020059
#   state #BACKGROUND

# 步骤2：使用进程ID过滤日志
hdc shell hilog -P 2869              # 实时日志
hdc shell hilog -x -n 200 -P 2869    # 历史日志（200行）
hdc shell hilog -L E -P 2869         # 错误日志
```

### 基础命令

```bash
hilog                      # 实时查看日志（阻塞模式）
hilog -x                   # 非阻塞查看，读完退出
hilog -L E                 # 只显示Error级别
hilog -T "MyTag"           # 按标签过滤
hilog -n 100               # 显示前100行
hilog -r                   # 清除buffer日志
hilog -g                   # 查询buffer大小
```

**详细参考**：参见 `references/hilog.md` 和 `references/hilog-advanced.md`

---

## 崩溃日志分析

### 自动解压崩溃日志

当模拟器发生崩溃时，日志会自动保存在实例路径下的 `Log\crash_report` 目录。

**步骤1：获取实例路径**
```bash
emulator -list -details
```

**步骤2：使用脚本自动分析**

**Windows:**
```powershell
# 自动查找实例路径（推荐）
.\scripts\analyze-crash-log.ps1 -AutoFind

# 指定实例路径
.\scripts\analyze-crash-log.ps1 -InstancePath "C:\Users\YourName\Huawei\emulator\deployed\MyPhone"
```

**macOS/Linux:**
```bash
# 自动查找实例路径
python scripts/analyze_crash_log.py

# 指定实例路径
python scripts/analyze_crash_log.py --instance-path "/home/user/Huawei/emulator/deployed/MyPhone"
```

**详细说明**：参见 `scripts/README_MACOS.md` 和 `references/crash-log-analysis.md`

### 崩溃日志内容

| 文件名 | 说明 |
|--------|------|
| `details.txt` | 崩溃类型、PC系统信息、模拟器版本号、系统内存信息 |
| `Emulator.log` | 模拟器运行日志 |
| `qemu.log` | QEMU日志 |
| `kernel.log` | 模拟器内核日志 |
| `hilog_tmp_xxx/` | 系统日志文件夹（包含.gz压缩的SystemLog） |
| `.dmp` | 系统堆栈转储文件 |

---

## 日志导出（使用 -logZip 参数）

### 导出模拟器日志

使用 `-logZip` 参数从模拟器实例导出完整日志包（包含 .gz 压缩的 SystemLog）。

**重要说明**：
- **不需要模拟器正在运行**：此命令可以从已停止的模拟器实例中提取日志
- **实例必须存在**：确保模拟器实例已创建

### Windows

```powershell
# 方法1：在 emulator 目录下执行（推荐）
cd "$env:DEVECO_STUDIO_PATH/tools/emulator"
.\Emulator.exe -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"

# 方法2：使用完整路径
& "$env:DEVECO_STUDIO_PATH/tools/emulator/emulator.exe" -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"
```

### macOS/Linux

```bash
# 方法1：在 emulator 目录下执行（推荐）
cd "$DEVECO_STUDIO_PATH/tools/emulator"
./emulator -logZip "MyPhone" -logPath "/tmp/emulator_log.zip"
```

### 解压和分析

```powershell
# 1. 解压日志 zip
mkdir "$env:TEMP\emulator_log_extracted"
cd "$env:TEMP\emulator_log_extracted"
tar -xf "$env:TEMP\emulator_log.zip"

# 2. 解压 SystemLog 中的 .gz 文件
python scripts/extract_gz.py "$env:TEMP\emulator_log_extracted\SystemLog"

# 3. 分析应用日志
cd SystemLog
grep -i "com.example.myapplication" hilog.* | head -50
```

**详细说明**：参见 `references/log-export-analysis.md`

---

## 手动日志分析

### 查找手动保存的日志

用户可以通过DevEco Studio手动保存模拟器日志，日志位于：

**Windows:**
```
%LOCALAPPDATA%\Huawei\DevEcoStudio{版本}\log\
```

**macOS:**
```
~/Library/Huawei/DevEcoStudio{版本}/log/
```

### 自动分析

**Windows:**
```powershell
# 自动查找日志目录
.\scripts\analyze-manual-log.ps1

# 指定DevEco Studio版本
.\scripts\analyze-manual-log.ps1 -DevEcoVersion "7.0"
```

**macOS/Linux:**
```bash
# 自动查找日志目录
python scripts/analyze_manual_log.py

# 指定DevEco Studio版本
python scripts/analyze_manual_log.py --deveco-version "7.0"
```

**详细说明**：参见 `references/manual-log-analysis.md`

---

## hidumper堆栈转储分析

### 基础命令

```bash
hidumper -h              # 显示帮助信息
hidumper -lc             # 列出系统信息集群
hidumper -ls             # 列出系统能力
hidumper -e              # 获取崩溃历史记录
hidumper -p              # 查看进程信息
```

### 崩溃分析

```bash
# 获取崩溃历史记录
hidumper -e

# 导出崩溃日志
hdc file recv /data/log/faultlog/faultlogger/ {本地目录}
```

**详细参考**：参见 `references/hidumper.md`

---

## 检查清单

### Critical (必须完成)

- [ ] deveco-studio-emulator skill 已配置（`../deveco-studio-emulator/scripts/config.json` 存在）
- [ ] DevEco Studio 已正确安装（Windows/macOS/Linux）
- [ ] Python 3.x 已安装（用于 extract_gz.py 脚本）
- [ ] 模拟器实例已创建（日志分析需要实例路径）

### Warning (建议完成)

- [ ] hdc 工具可正常连接设备 (`hdc list targets`)
- [ ] 模拟器正在运行（实时日志查看需要）
- [ ] 目标应用已启动（应用日志查看需要进程ID）
- [ ] 已接受许可证协议（`emulator -license accept`）

### Info (可选改进)

- [ ] 检查崩溃报告目录是否存在（`Log/crash_report/`）
- [ ] 验证 .gz 文件解压脚本可用（`scripts/extract_gz.py`）
- [ ] 熟悉 hilog 命令参数（`references/hilog.md`）

---

## 决策树

### 日志查看决策树

用户需要查看什么日志？
├─ 应用日志 → 检查应用是否运行
│   ├─ 运行中 → 获取进程ID (`hdc shell aa dump -a`)
│   │   ├─ 成功 → 使用进程ID过滤 (`hilog -P {pid}`)
│   │   └─ 失败 → 提示应用未运行
│   └─ 未运行 → 提示先启动应用
├─ 错误日志 → 使用错误级别过滤 (`hilog -L E`)
│   └─ 有错误 → 分析错误原因，提供修复建议
│   └─ 无错误 → 提示系统正常
└─ 全量日志 → 实时查看或导出
    ├─ 实时查看 → `hilog`（阻塞模式）
    └─ 导出日志 → 使用 `-logZip` 参数

### 崩溃分析决策树

崩溃类型？
├─ 模拟器崩溃 → 查找崩溃报告目录
│   ├─ 存在 `Log/crash_report/` → 使用崩溃分析脚本
│   │   ├─ Windows: `.\scripts\analyze-crash-log.ps1 -AutoFind`
│   │   └─ macOS/Linux: `python scripts/analyze_crash_log.py`
│   └─ 不存在 → 提示模拟器未崩溃或崩溃报告已清理
├─ 应用崩溃 → 查看应用错误日志
│   ├─ 有崩溃信号 → 分析堆栈信息，定位崩溃代码
│   └─ 无明显崩溃 → 检查生命周期异常（onCreate/onForeground）
└─ 系统崩溃 → 使用 hidumper 工具
    ├─ `hidumper -e` 获取崩溃历史
    └─ `hdc file recv /data/log/faultlog/faultlogger/` 导出崩溃日志

### 日志导出决策树

导出目的？
├─ 分析崩溃 → 导出全量日志包 (`-logZip`)
│   ├─ 成功 → 解压 .gz 文件，分析 SystemLog
│   └─ 失败 → 检查实例名称和路径权限
├─ 手动保存日志 → 查找 DevEco Studio 日志目录
│   ├─ Windows: `%LOCALAPPDATA%\Huawei\DevEcoStudio{版本}\log\`
│   └─ macOS: `~/Library/Huawei/DevEcoStudio{版本}/log/`
│   └─ 使用手动日志分析脚本
└─ 备份日志 → 直接复制日志文件或使用 `-logZip`

---

## 完整工作流程

### 应用日志分析流程

```bash
# 1. 查看运行中的应用
hdc shell aa dump -a

# 2. 获取应用进程ID（如：pid #2869）

# 3. 查看应用日志
hdc shell hilog -P 2869              # 实时日志
hdc shell hilog -x -n 500 -P 2869    # 历史日志（500行）
hdc shell hilog -L E -P 2869         # 错误日志
```

### 崩溃日志分析流程

```powershell
# 1. 导出模拟器日志
cd "$env:DEVECO_STUDIO_PATH/tools/emulator"
.\Emulator.exe -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"

# 2. 解压日志
mkdir "$env:TEMP\emulator_log_extracted"
tar -xf "$env:TEMP\emulator_log.zip"

# 3. 解压 .gz 文件
python scripts/extract_gz.py "$env:TEMP\emulator_log_extracted\SystemLog"

# 4. 分析崩溃信息
# 查看 details.txt、Emulator.log、kernel.log
```

---

## 参考文档

### 官方文档

- [hilog工具](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hilog)
- [hidumper工具](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hidumper)
- [Emulator命令行](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-command-line)

---

## 常见问题

### 找不到配置文件

1. 确保已运行 `../deveco-studio-emulator/scripts/setup.py`
2. 检查 `../deveco-studio-emulator/scripts/config.json` 是否存在
3. 或设置环境变量 `DEVECO_STUDIO_PATH` 和 `HDC_PATH`

### hilog命令无输出

1. 确保设备已连接：`hdc list targets`
2. 确保应用正在运行或已运行过
3. 尝试清除buffer后重新查看：`hilog -r && hilog`

### 崩溃日志分析失败

1. 确保模拟器发生过崩溃
2. 检查实例路径下的 `Log/crash_report` 目录是否存在
3. 确保崩溃报告文件存在

### 日志导出失败

1. 检查实例名称是否正确：`emulator -list`
2. 检查实例是否存在：`emulator -list -details`
3. 检查输出路径权限：目录必须存在且可写

### .gz文件解压失败

1. 确保安装了 Python 3.x
2. 检查文件权限：确保有读取和写入权限
3. 使用提供的 `extract_gz.py` 脚本