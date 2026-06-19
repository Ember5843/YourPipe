# Scripts目录说明

## 配置依赖

本skill的脚本**依赖** `../deveco-studio-emulator/scripts/config.json` 配置文件。

### 配置优先级

1. `../deveco-studio-emulator/scripts/config.json`（最高优先级）
2. 环境变量
3. 自动查找（最低优先级）

### 初始化配置

如果配置文件不存在，需要先运行：

```bash
python ../deveco-studio-emulator/scripts/setup.py
```

---

## extract_gz.py
解压指定目录中的所有 .gz 文件（跨平台兼容）。

### 使用方法
```bash
python scripts/extract_gz.py <目录路径>
```

### 示例
```bash
# Windows
python scripts/extract_gz.py C:\Temp\emulator_log_extracted\SystemLog

# macOS/Linux
python3 scripts/extract_gz.py /tmp/emulator_log_extracted/SystemLog
```

---

## analyze_crash_log.py
自动解压和分析HarmonyOS模拟器崩溃日志（macOS/Linux版本）。

### 使用方法
```bash
# 自动查找实例路径
python scripts/analyze_crash_log.py

# 指定实例路径
python scripts/analyze_crash_log.py --instance-path "/home/user/Huawei/emulator/deployed/MyPhone"
```

### 参数说明
- `--instance-path`: 模拟器实例路径
- `--crash-report-path`: 指定崩溃报告文件名
- `--no-auto-find`: 禁用自动查找

---

## analyze-crash-log.ps1
自动解压和分析HarmonyOS模拟器崩溃日志（Windows PowerShell版本）。

### 使用方法
```powershell
# 自动查找实例路径（推荐）
.\scripts\analyze-crash-log.ps1 -AutoFind

# 指定实例路径
.\scripts\analyze-crash-log.ps1 -InstancePath "C:\Users\YourName\Huawei\emulator\deployed\MyPhone"
```

### 参数说明
- `-AutoFind`: 自动查找模拟器实例路径（默认启用）
- `-InstancePath`: 模拟器实例路径
- `-CrashReportPath`: 指定崩溃报告文件名

---

## analyze_manual_log.py
自动查找、解压和分析手动保存的日志（macOS/Linux版本）。

### 使用方法
```bash
# 自动查找日志目录
python scripts/analyze_manual_log.py

# 指定DevEco Studio版本
python scripts/analyze_manual_log.py --deveco-version "7.0"
```

### 参数说明
- `--deveco-version`: DevEco Studio版本
- `--bug-report-path`: 指定bugreport文件名

---

## analyze-manual-log.ps1
自动查找、解压和分析手动保存的日志（Windows PowerShell版本）。

### 使用方法
```powershell
# 自动查找日志目录
.\scripts\analyze-manual-log.ps1

# 指定DevEco Studio版本
.\scripts\analyze-manual-log.ps1 -DevEcoVersion "7.0"
```

### 参数说明
- `-DevEcoVersion`: DevEco Studio版本
- `-BugReportPath`: 指定bugreport文件名

---

## 常见问题

### 找不到配置文件

确保已运行：
```bash
python ../deveco-studio-emulator/scripts/setup.py
```

### PowerShell执行策略错误

```powershell
# 设置执行策略为RemoteSigned（推荐）
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### Python未安装

从以下地址下载安装：
https://www.python.org/

---

## 详细文档

- [崩溃日志分析详细说明](../references/crash-log-analysis.md)
- [手动日志分析详细说明](../references/manual-log-analysis.md)
- [macOS/Linux使用说明](README_MACOS.md)