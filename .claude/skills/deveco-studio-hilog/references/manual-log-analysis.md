# 手动保存日志完整分析指南

## 概述

用户可以通过DevEco Studio手动保存模拟器日志。本指南详细说明如何查找、解压和分析手动保存的日志。

## 查找手动保存的日志

### 日志目录位置

手动保存的日志位于DevEco Studio的log目录，路径格式如下：

**Windows**:
```
%LOCALAPPDATA%\Huawei\DevEcoStudio{版本}\log\
```

**常见版本**：
- DevEcoStudio6.1
- DevEcoStudio7.0
- DevEcoStudio（通用）

**示例**：
```
%LOCALAPPDATA%\Huawei\DevEcoStudio6.1\log\
%LOCALAPPDATA%\Huawei\DevEcoStudio7.0\log\
%LOCALAPPDATA%\Huawei\DevEcoStudio\log\
```

### 自动查找日志目录

使用以下PowerShell脚本自动查找日志目录：

```powershell
# 方法1：使用环境变量（推荐）
$logDir = Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio6.1\log"

# 方法2：自动查找版本
$logDirs = @(
    Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio7.0\log",
    Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio6.1\log",
    Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio\log"
)

$existingLogDir = $logDirs | Where-Object { Test-Path $_ } | Select-Object -First 1
Write-Host "找到日志目录: $existingLogDir"
```
%LOCALAPPDATA%\Huawei\DevEcoStudio{版本}\log\
```

常见版本：
- DevEcoStudio6.1
- DevEcoStudio7.0
- DevEcoStudio（通用）

### 自动查找日志目录

使用以下PowerShell脚本自动查找日志目录（支持6.1、7.0等版本）：

```powershell
# 方法1：使用环境变量（推荐）
$logDir = Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio6.1\log"

# 方法2：自动查找版本
$logDirs = @(
    Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio7.0\log",
    Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio6.1\log",
    Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio\log"
)

$existingLogDir = $logDirs | Where-Object { Test-Path $_ } | Select-Object -First 1
Write-Host "找到日志目录: $existingLogDir"
```

### 查看日志文件

```powershell
# 进入日志目录
cd $existingLogDir

# 列出所有bugreport文件
Get-ChildItem -Filter "bugreport-*.zip" | Sort-Object LastWriteTime -Descending
```

输出示例：
```
Name                          LastWriteTime
----                          -------------
bugreport-2026-03-16T231455.zip  2026-03-16 23:14:55
bugreport-2026-03-15T182030.zip  2026-03-15 18:20:30
bugreport-2026-03-14T101545.zip  2026-03-14 10:15:45
```

## 自动解压和分析

### 使用PowerShell脚本（推荐）

本skill提供了自动分析脚本，可以一键完成查找、解压和分析：

```powershell
# 使用脚本自动分析手动保存的日志
.\scripts\analyze-manual-log.ps1
```

脚本会自动：
1. 查找DevEco Studio日志目录
2. 查找最新的bugreport文件
3. 解压bugreport文件
4. 解压SystemLog文件夹中的.gz日志
5. 显示日志摘要信息
6. 生成分析报告

### 脚本参数

```powershell
# 指定DevEco Studio版本
.\scripts\analyze-manual-log.ps1 -DevEcoVersion "7.0"

# 指定特定的bugreport文件
.\scripts\analyze-manual-log.ps1 -BugReportPath "bugreport-2026-03-16T231455.zip"
```

参数说明：
- `-DevEcoVersion`: DevEco Studio版本（可选，默认自动查找）
- `-BugReportPath`: 指定bugreport文件名（可选，默认使用最新的）

## 手动解压步骤

### 步骤1：解压bugreport文件

```powershell
# 进入日志目录
cd $existingLogDir

# 查找最新的bugreport文件
$latestBugreport = Get-ChildItem -Filter "bugreport-*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# 解压bugreport文件
Expand-Archive -Path $latestBugreport.FullName -DestinationPath "bugreport_extracted"
```

### 步骤2：解压SystemLog（.gz格式）

如果解压后的目录中包含 `SystemLog` 文件夹，需要解压其中的.gz日志文件。

```powershell
# 进入解压后的目录
cd "bugreport_extracted"

# 查找SystemLog文件夹
if (Test-Path "SystemLog") {
    # 解压SystemLog文件夹中的.gz日志
    Get-ChildItem -Path "SystemLog" -Filter "*.gz" | ForEach-Object {
         $gzipFile = $_.FullName
         $outputFile = $gzipFile -replace '\.gz$', ''
         # 使用 Python 解压 .gz 文件
         $pythonScript = Join-Path $PSScriptRoot "extract_gz.py"
         python $pythonScript $systemLogDir
    }
}
```

## 手动保存日志内容说明

解压后的日志包含以下文件：

### 核心文件

| 文件名 | 说明 | 重要性 |
|--------|------|--------|
| **details.json** | 问题描述、模拟器版本信息、PC操作系统版本信息 | ⭐⭐⭐ |
| **Emulator.log** | 模拟器运行日志 | ⭐⭐⭐ |
| **qemu.log** | QEMU日志 | ⭐⭐ |
| **kernel.log** | 模拟器内核日志 | ⭐⭐ |
| **crash_server.log** | 异常监控日志 | ⭐⭐ |
| **screenshot.png** | 模拟器系统截图（可能包含应用截图） | ⭐ |
| **SystemLog/** | 模拟器系统日志（包括应用打印日志以及应用崩溃时的堆栈） | ⭐⭐⭐ |
| **crash_report/** | 历史崩溃日志目录 | ⭐⭐ |

### 文件详细说明

#### details.json

包含日志的详细信息（JSON格式）：
- 问题描述
- 模拟器版本信息
- PC操作系统版本信息
- 日志保存时间

#### Emulator.log

模拟器的运行日志，包含：
- 模拟器启动过程
- 运行时的状态变化
- 错误和警告信息

#### qemu.log

QEMU虚拟机的日志，包含：
- 虚拟机启动过程
- 硬件模拟信息
- 底层错误信息

#### kernel.log

模拟器内核日志，包含：
- 内核启动信息
- 内核错误和警告
- 系统调用信息

#### crash_server.log

异常监控日志，包含：
- 崩溃事件记录
- 异常堆栈信息
- 错误代码

#### screenshot.png

模拟器系统截图，可能包含：
- 模拟器界面截图
- 应用界面截图
- 错误提示截图

#### SystemLog/

模拟器系统日志文件夹，包含：
- 应用打印日志
- 应用崩溃时的堆栈
- 系统事件日志
- 性能监控日志

#### crash_report/

历史崩溃日志目录，包含：
- 历史崩溃报告
- 崩溃堆栈文件
- 崩溃时的系统状态

## 查看手动保存的日志

### 查看基本信息

```powershell
# 查看详情（JSON格式）
Get-Content "bugreport_extracted\details.json" | ConvertFrom-Json | Format-List

# 查看模拟器运行日志
Get-Content "bugreport_extracted\Emulator.log"

# 查看内核日志
Get-Content "bugreport_extracted\kernel.log"
```

### 查看特定类型的日志

```powershell
# 查看QEMU日志
Get-Content "bugreport_extracted\qemu.log"

# 查看异常监控日志
Get-Content "bugreport_extracted\crash_server.log"

# 查看SystemLog
Get-ChildItem -Path "bugreport_extracted\SystemLog" -Filter "*.log" | ForEach-Object {
    Write-Host "文件: $($_.Name)"
    Get-Content $_.FullName | Select-Object -First 20
}
```

### 查看截图

```powershell
# 查看截图文件
if (Test-Path "bugreport_extracted\screenshot.png") {
    # 使用默认图片查看器打开
    Start-Process "bugreport_extracted\screenshot.png"
}
```

### 查看历史崩溃报告

```powershell
# 查看crash_report目录
if (Test-Path "bugreport_extracted\crash_report") {
    Get-ChildItem -Path "bugreport_extracted\crash_report" -Recurse
}
```

## 日志分析流程

### 快速定位问题

1. **查看details.json**：了解基本信息
2. **查看screenshot.png**：查看截图，了解问题现象
3. **查看SystemLog**：查找应用层的错误信息
4. **查看Emulator.log**：查找模拟器层的错误信息
5. **查看crash_report**：查看历史崩溃信息

### 详细分析步骤

```powershell
# 1. 查看基本信息
Write-Host "=== 基本信息 ===" -ForegroundColor Yellow
Get-Content "bugreport_extracted\details.json" | ConvertFrom-Json | Format-List

# 2. 查看模拟器日志中的错误
Write-Host "=== 模拟器日志错误 ===" -ForegroundColor Yellow
Get-Content "bugreport_extracted\Emulator.log" | Select-String -Pattern "Error|error|ERROR"

# 3. 查看内核日志中的错误
Write-Host "=== 内核日志错误 ===" -ForegroundColor Yellow
Get-Content "bugreport_extracted\kernel.log" | Select-String -Pattern "Error|error|ERROR"

# 4. 查看SystemLog中的错误
Write-Host "=== SystemLog错误 ===" -ForegroundColor Yellow
Get-ChildItem -Path "bugreport_extracted\SystemLog" -Filter "*.log" | ForEach-Object {
    Write-Host "文件: $($_.Name)" -ForegroundColor Cyan
    Get-Content $_.FullName | Select-String -Pattern "Error|error|ERROR|Exception"
}

# 5. 查看异常监控日志
Write-Host "=== 异常监控日志 ===" -ForegroundColor Yellow
Get-Content "bugreport_extracted\crash_server.log"

# 6. 查看截图
if (Test-Path "bugreport_extracted\screenshot.png") {
    Write-Host "=== 截图 ===" -ForegroundColor Yellow
    Write-Host "截图文件: bugreport_extracted\screenshot.png"
}
```

## 常见问题

### 找不到日志目录

1. 检查DevEco Studio是否正确安装
2. 检查DevEco Studio版本是否正确
3. 检查是否手动保存过日志

### 找不到bugreport文件

1. 检查是否手动保存过日志
2. 检查日志目录中是否有其他格式的日志文件
3. 检查日志文件是否被移动或删除

### 解压失败

1. 确保安装了7-Zip：用于解压.gz文件
2. 检查文件权限：确保有读取和写入权限
3. 检查文件完整性：确保bugreport文件未损坏

### details.json无法解析

1. 检查文件格式是否正确
2. 检查JSON语法是否正确
3. 检查文件编码是否正确

## 官方文档

详细文档请参考：
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-command-line
