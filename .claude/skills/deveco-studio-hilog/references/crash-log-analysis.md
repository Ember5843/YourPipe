# 崩溃日志完整分析指南

## 概述

当模拟器发生崩溃时，日志会自动保存在实例路径下的 `Log\crash_report` 目录。本指南详细说明如何获取、解压和分析崩溃日志。

## 获取崩溃日志

### 步骤1：获取实例路径

使用 `emulator -list -details` 命令获取实例的详细信息，包括 `instancePath` 字段。

```bash
emulator -list -details
```

输出示例：
```
instanceName: <你的实例名>
instancePath: <你的实例路径>
osVersion: HarmonyOS 6.0.2(22)
status: stopped
...
```

输出示例：
```
实例名称: <你的实例名>
实例路径: <你的实例路径>
osVersion: HarmonyOS 6.0.2(22)
status: running
...
```

### 步骤2：定位崩溃日志目录

崩溃日志位于实例路径下的 `Log\crash_report` 目录：

```
<你的实例路径>\Log\crash_report\
```

在该目录下，你会找到类似以下格式的崩溃报告文件：
```
crash_report-2026-03-16T123249.zip
crash_report-2026-03-16T143015.zip
...
```

## 自动解压和分析

### 使用PowerShell脚本（推荐）

本skill提供了自动分析脚本，可以一键完成解压和分析：

```powershell
# 方法1：自动查找实例路径（推荐）
.\scripts\analyze-crash-log.ps1 -AutoFind

# 方法2：指定实例路径
.\scripts\analyze-crash-log.ps1 -InstancePath "<你的实例路径>"

# 方法3：指定实例路径和崩溃报告文件
.\scripts\analyze-crash-log.ps1 -InstancePath "<你的实例路径>" -CrashReportPath "crash_report-2026-03-16T123249.zip"
```

脚本会自动：
1. 查找最新的崩溃报告文件
2. 解压崩溃报告
3. 解压hilog_tmp_xxx文件夹中的.gz日志
4. 显示崩溃摘要信息
5. 生成分析报告

### 脚本参数

```powershell
# 使用 -AutoFind 自动查找实例路径（推荐）
.\scripts\analyze-crash-log.ps1 -AutoFind

# 指定实例路径
.\scripts\analyze-crash-log.ps1 -InstancePath "C:\Users\YourName\Huawei\emulator\deployed\MyPhone" -CrashReportPath "crash_report-2026-03-16T123249.zip"
```

参数说明：
- `-AutoFind`: 自动查找模拟器实例路径（推荐）
- `-InstancePath`: 模拟器实例路径（可选，与 -AutoFind 二选一）
- `-CrashReportPath`: 指定崩溃报告文件名（可选，默认使用最新的）

**配置优先级**：
1. 环境变量 `EMULATOR_INSTANCE_PATH`
2. config.json 中的 `emulatorInstancePath`
3. 自动查找常见部署路径

## 手动解压步骤

### 步骤1：解压崩溃报告

```powershell
# 进入崩溃日志目录（使用环境变量或配置文件中的路径）
$instancePath = $env:EMULATOR_INSTANCE_PATH
if (-not $instancePath) {
    $instancePath = (Get-Content config.json | ConvertFrom-Json).emulatorInstancePath
}
cd "$instancePath\Log\crash_report"

# 解压崩溃报告
Expand-Archive -Path "crash_report-2026-03-16T123249.zip" -DestinationPath "crash_report_extracted"
```

### 步骤2：解压hilog日志（如果存在）

崩溃报告中可能包含 `hilog_tmp_xxx` 文件夹，其中包含.gz格式的日志文件。

```powershell
# 进入解压后的目录
cd "crash_report_extracted"

# 查找hilog_tmp_xxx文件夹
$hilogDirs = Get-ChildItem -Filter "hilog_tmp_*" -Directory

# 解压每个hilog_tmp_xxx文件夹中的.gz日志
foreach ($dir in $hilogDirs) {
    $hilogDir = $dir.FullName
    Get-ChildItem -Path $hilogDir -Filter "*.gz" | ForEach-Object {
        $gzipFile = $_.FullName
        # 使用7-Zip解压
        & "C:\Program Files\7-Zip\7z.exe" x $gzipFile -o$hilogDir
    }
}
```

## 崩溃日志内容说明

解压后的崩溃日志包含以下文件：

### 核心文件

| 文件名 | 说明 | 重要性 |
|--------|------|--------|
| **details.txt** | 崩溃类型、PC系统信息、模拟器版本号、系统内存信息 | ⭐⭐⭐ |
| **reproductionsteps.txt** | 崩溃前的操作步骤 | ⭐⭐⭐ |
| **Emulator.log** | 模拟器运行日志 | ⭐⭐⭐ |
| **qemu.log** | QEMU日志 | ⭐⭐ |
| **kernel.log** | 模拟器内核日志 | ⭐⭐ |
| **crash_server.log** | 异常监控日志 | ⭐⭐ |
| **memInfo.log** | 模拟器系统内存详细信息 | ⭐ |
| **.dmp** | 模拟器崩溃时的系统堆栈转储文件 | ⭐⭐⭐ |
| **hilog_tmp_xxx/** | 系统日志文件夹（包含.gz压缩的SystemLog） | ⭐⭐ |

### 文件详细说明

#### details.txt

包含崩溃的详细信息：
- 崩溃类型（如：SIGSEGV、SIGABRT等）
- PC系统信息
  - 操作系统版本
  - CPU架构
  - GPU版本
- 模拟器版本号
- 模拟器系统内存信息

#### reproductionsteps.txt

记录崩溃前的操作步骤，对于重现问题非常重要。

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

#### .dmp

系统堆栈转储文件，可以使用调试工具（如WinDbg）进行详细分析。

#### hilog_tmp_xxx/

系统日志文件夹，包含：
- 应用打印日志
- 应用崩溃时的堆栈
- 系统事件日志

## 查看崩溃日志

### 查看崩溃详情

```powershell
# 查看崩溃详情
Get-Content "crash_report_extracted\details.txt"

# 查看崩溃前的操作步骤
Get-Content "crash_report_extracted\reproductionsteps.txt"

# 查看模拟器运行日志
Get-Content "crash_report_extracted\Emulator.log"
```

### 查看特定类型的日志

```powershell
# 查看内核日志
Get-Content "crash_report_extracted\kernel.log"

# 查看QEMU日志
Get-Content "crash_report_extracted\qemu.log"

# 查看异常监控日志
Get-Content "crash_report_extracted\crash_server.log"

# 查看内存信息
Get-Content "crash_report_extracted\memInfo.log"
```

### 查看hilog日志

```powershell
# 查看hilog_tmp_xxx文件夹中的日志
$hilogDirs = Get-ChildItem -Filter "hilog_tmp_*" -Directory
foreach ($dir in $hilogDirs) {
    Write-Host "Hilog日志目录: $($dir.FullName)"
    Get-ChildItem -Path $dir.FullName -Filter "*.log" | ForEach-Object {
        Write-Host "  文件: $($_.Name)"
        Get-Content $_.FullName | Select-Object -First 20
    }
}
```

## 常见崩溃类型

### SIGSEGV（段错误）

**原因**：访问了无效的内存地址

**排查方向**：
1. 检查空指针解引用
2. 检查数组越界访问
3. 检查野指针问题

### SIGABRT（程序中止）

**原因**：程序主动调用abort()或断言失败

**排查方向**：
1. 检查断言失败信息
2. 检查是否有主动调用abort()的代码
3. 检查内存分配失败

### SIGFPE（浮点异常）

**原因**：除零错误或浮点运算异常

**排查方向**：
1. 检查除数为零的情况
2. 检查浮点运算的边界条件

### SIGILL（非法指令）

**原因**：执行了无效的机器指令

**排查方向**：
1. 检查代码段损坏
2. 检查函数指针错误
3. 检查JIT编译问题

## 崩溃分析流程

### 快速定位崩溃原因

1. **查看details.txt**：了解崩溃类型和基本信息
2. **查看reproductionsteps.txt**：了解崩溃前的操作
3. **查看.dmp文件**：使用调试工具分析堆栈
4. **查看Emulator.log**：查找相关错误信息
5. **查看hilog日志**：查找应用层的错误信息

### 详细分析步骤

```powershell
# 1. 查看崩溃详情
Write-Host "=== 崩溃详情 ===" -ForegroundColor Yellow
Get-Content "crash_report_extracted\details.txt"

# 2. 查看崩溃前的操作
Write-Host "=== 崩溃前的操作 ===" -ForegroundColor Yellow
Get-Content "crash_report_extracted\reproductionsteps.txt"

# 3. 查看模拟器日志中的错误
Write-Host "=== 模拟器日志错误 ===" -ForegroundColor Yellow
Get-Content "crash_report_extracted\Emulator.log" | Select-String -Pattern "Error|error|ERROR"

# 4. 查看内核日志中的错误
Write-Host "=== 内核日志错误 ===" -ForegroundColor Yellow
Get-Content "crash_report_extracted\kernel.log" | Select-String -Pattern "Error|error|ERROR"

# 5. 查看hilog日志
Write-Host "=== Hilog日志 ===" -ForegroundColor Yellow
$hilogDirs = Get-ChildItem -Filter "hilog_tmp_*" -Directory
foreach ($dir in $hilogDirs) {
    Get-ChildItem -Path $dir.FullName -Filter "*.log" | ForEach-Object {
        Write-Host "文件: $($_.Name)" -ForegroundColor Cyan
        Get-Content $_.FullName | Select-String -Pattern "Error|error|ERROR|Exception"
    }
}
```

## 常见问题

### 找不到崩溃日志

1. 检查实例路径是否正确
2. 检查 `Log\crash_report` 目录是否存在
3. 检查是否有崩溃报告文件

### 解压失败

1. 确保安装了7-Zip：用于解压.gz文件
2. 检查文件权限：确保有读取和写入权限
3. 检查文件完整性：确保崩溃报告文件未损坏

### .dmp文件无法打开

1. 确保安装了调试工具（如WinDbg）
2. 检查.dmp文件是否完整
3. 检查符号文件是否可用

## 官方文档

详细文档请参考：
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-command-line
