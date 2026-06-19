# macOS/Linux 日志分析脚本使用指南

本目录包含两个 Python 脚本，用于在 macOS/Linux 上分析 HarmonyOS 模拟器日志。

## 配置依赖

本skill的脚本**依赖** `../deveco-studio-emulator/scripts/config.json` 配置文件。

如果配置文件不存在，请先运行：
```bash
python ../deveco-studio-emulator/scripts/setup.py
```

## 脚本列表

1. **analyze_crash_log.py** - 崩溃日志分析
2. **analyze_manual_log.py** - 手动保存日志分析

## 系统要求

- Python 3.6 或更高版本

## 使用方法

### 崩溃日志分析

```bash
# 自动查找实例路径
python scripts/analyze_crash_log.py

# 指定实例路径
python scripts/analyze_crash_log.py --instance-path "$HOME/Huawei/emulator/deployed/MyPhone"

# 指定崩溃报告文件
python scripts/analyze_crash_log.py --instance-path "$HOME/Huawei/emulator/deployed/MyPhone" --crash-report-path "crash_report-2026-03-16T123249.zip"
```

### 手动日志分析

```bash
# 自动查找日志目录
python scripts/analyze_manual_log.py

# 指定 DevEco Studio 版版本
python scripts/analyze_manual_log.py --deveco-version "7.0"

# 指定 bugreport 文件
python scripts/analyze_manual_log.py --bug-report-path "bugreport-2026-03-16T231455.zip"
```

## 常见问题

### 找不到模拟器实例路径

```bash
# 方法1：设置环境变量
export EMULATOR_INSTANCE_PATH="$HOME/Huawei/emulator/deployed/MyPhone"
python scripts/analyze_crash_log.py

# 方法2：使用 --instance-path 参数
python scripts/analyze_crash_log.py --instance-path "$HOME/Huawei/emulator/deployed/MyPhone"
```

### 找不到 DevEco Studio 日志目录

```bash
# 检查日志目录
ls -la "$HOME/Library/Huawei/DevEcoStudio*/log"

# 或指定版本
python scripts/analyze_manual_log.py --deveco-version "7.0"
```

## 详细文档

- [崩溃日志分析详细说明](../references/crash-log-analysis.md)
- [手动日志分析详细说明](../references/manual-log-analysis.md)
