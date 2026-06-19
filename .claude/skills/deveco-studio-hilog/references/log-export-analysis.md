# 日志导出和分析完整指南

本文档详细说明如何使用 `Emulator.exe -logZip` 参数导出模拟器日志，以及如何分析应用日志。

## 概述

`-logZip` 参数允许从模拟器实例中导出完整的日志包，包含：
- SystemLog（系统日志，包含应用日志）
- Emulator.log（模拟器运行日志）
- qemu.log（QEMU 日志）
- kernel.log（内核日志）
- crash_server.log（崩溃监控日志）
- memInfo.log（内存信息）

**重要特性**：
- 不需要模拟器正在运行
- 可以从已停止的实例中提取日志
- SystemLog 中的日志文件以 .gz 格式压缩存储
- **这是最全面的日志分析方式**，比手动保存日志更完整

## 日志导出

### Windows

```powershell
# 方法1：在 emulator 目录下执行（推荐）
cd "$env:DEVECO_STUDIO_PATH\tools\emulator"
.\Emulator.exe -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"

# 方法2：使用完整路径
& "$env:DEVECO_STUDIO_PATH\tools\emulator\emulator.exe" -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"
```

### macOS/Linux

```bash
# 方法1：在 emulator 目录下执行（推荐）
cd "$DEVECO_STUDIO_PATH/tools/emulator"
./emulator -logZip "MyPhone" -logPath "/tmp/emulator_log.zip"

# 方法2：使用完整路径
"$DEVECO_STUDIO_PATH/tools/emulator/emulator" -logZip "MyPhone" -logPath "/tmp/emulator_log.zip"
```

### 命令参数说明

| 参数 | 说明 | 示例 |
|------|------|------|
| `-logZip {实例名称}` | 指定要导出日志的模拟器实例名称 | `MyPhone` |
| `-logPath {输出路径}` | 指定日志 zip 文件的保存路径（必须包含 .zip 后缀） | `$env:TEMP\emulator_log.zip` |

### 成功输出

```
HandleLogZip: log collection succeeded.
```

## 常见错误及解决

### 错误1：Unable to start emulator

**错误信息**：
```
HandleLogZip: log collection failed.
Unable to start emulator
```

**原因**：
1. 模拟器实例名称不正确（大小写敏感）
2. 模拟器实例不存在
3. 路径中包含特殊字符或空格未正确处理
4. 输出路径的父目录不存在
5. 输出路径没有写入权限

**解决方法**：

```bash
# 1. 检查实例名称是否正确（注意大小写）
emulator -list

# 2. 检查实例是否存在和详细信息
emulator -list -details

# 3. 检查输出路径的父目录是否存在
# Windows
mkdir $env:TEMP
icacls $env:TEMP

# macOS/Linux
mkdir -p /tmp/logs
ls -ld /tmp/logs

# 4. 检查路径格式
# 正确：D:\\logs\\emulator_log.zip 或 D:/logs/emulator_log.zip
# 错误：D:\logs\emulator_log.zip（单反斜杠在 PowerShell 中可能有问题）
```

### 错误2：找不到实例

**错误信息**：
```
HandleLogZip: log collection failed.
Can not find instance: [实例名称]
```

**解决方法**：

```bash
# 列出所有实例
emulator -list

# 如果实例不存在，需要先创建
emulator -create "MyPhone" -deviceType Phone -osVersion "HarmonyOS 6.0.2(22)"
```

### 错误3：权限不足

**错误信息**：
```
HandleLogZip: log collection failed.
Permission denied
```

**解决方法**：

```bash
# Windows：确保目录存在且可写
mkdir $env:TEMP
icacls $env:TEMP

# macOS/Linux：确保目录存在且可写
mkdir -p /tmp/logs
ls -ld /tmp/logs
```

### 错误4：文件已存在

**错误信息**：
```
HandleLogZip: log collection failed.
File already exists: [文件路径]
```

**解决方法**：

```bash
# 删除或重命名已存在的日志文件
# Windows
del "$env:TEMP\emulator_log.zip"

# macOS/Linux
rm /tmp/emulator_log.zip

# 或者使用不同的文件名（添加时间戳）
# Windows
emulator -logZip "MyPhone" -logPath "$env:TEMP\emulator_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"

# macOS/Linux
emulator -logZip "MyPhone" -logPath "/tmp/emulator_log_$(date +%Y%m%d_%H%M%S).zip"
```

## 日志解压

### 解压日志 zip 文件

**Windows**：

```powershell
# 创建解压目录
mkdir "$env:TEMP\emulator_log_extracted"
cd "$env:TEMP\emulator_log_extracted"

# 解压 zip 文件
tar -xf "$env:TEMP\emulator_log.zip"
```

**macOS/Linux**：

```bash
# 创建解压目录
mkdir -p /tmp/emulator_log_extracted
cd /tmp/emulator_log_extracted

# 解压 zip 文件
unzip /tmp/emulator_log.zip
```

### 解压 SystemLog 中的 .gz 文件

SystemLog 目录中的日志文件以 .gz 格式压缩存储，需要进一步解压。

**Python 脚本（跨平台）**：

```python
import gzip
import shutil
from pathlib import Path

def decompress_gz_files(source_dir):
    """
    解压指定目录下的所有 .gz 文件
    
    Args:
        source_dir: 包含 .gz 文件的目录路径
    """
    source_path = Path(source_dir)
    
    if not source_path.exists():
        print(f"错误: 目录不存在: {source_path}")
        return
    
    if not source_path.is_dir():
        print(f"错误: 不是目录: {source_path}")
        return
    
    gz_files = list(source_path.glob("*.gz"))
    
    if not gz_files:
        print(f"未找到 .gz 文件在: {source_path}")
        return
    
    print(f"找到 {len(gz_files)} 个 .gz 文件")
    print("-" * 60)
    
    success_count = 0
    fail_count = 0
    
    for gz_file in gz_files:
        # 生成输出文件名（去掉 .gz 后后缀）
        output_file = gz_file.with_suffix('')
        try:
            print(f"解压: {gz_file.name}")
            
            # 打开压缩文件并写入解压内容

            original_size = gz_file.stat().st_size
            with gzip.open(gz_file, 'rb') as f_in:
                with open(output_file, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)
            
            print(f"  ✓ 成功 -> {output_file.name}")
            print(f"  压缩大小: {original_size:,} 字节")
            print(f"  解压后大小: {output_file.stat().st_size:,} 字节")
            success_count += 1
            
        except Exception as e:
            print(f"  ✗ 失败: {e}")
            fail_count += 1
        
        print()
    
    print("-" * 60)
    print(f"完成: 成功 {success_count} 个, 失败 {fail_count} 个")

if __name__ == "__main__":
    # Windows
    decompress_gz_files(r"$env:TEMP\emulator_log_extracted\SystemLog")
    
    # macOS/Linux
    # decompress_gz_files("/tmp/emulator_log_extracted/SystemLog")
```

**使用方法**：

```bash
# Windows
python decompress_gz.py

# macOS/Linux
python3 decompress_gz.py
```

## 应用日志分析

### 查找应用相关日志

**方法1：使用 bundleName 过滤**

```bash
# 查找所有包含 com.example.myapplication 的日志
grep -i "com.example.myapplication" SystemLog/hilog.* | head -50

# 统计匹配的总行数
grep -i "com.example.myapplication" SystemLog/hilog.* | wc -l
```

**方法2：使用应用进程 PID 过滤（推荐）**

```bash
# 步骤1：查找应用进程 ID
hdc shell aa dump -a

# 输出示例：
# AppRunningRecord ID #11
#   process name [com.example.myapplication]
#   pid #7077  uid #20020059
#   state #FOREGROUND

# 步骤2：使用进程 ID 过滤日志
hdc shell hilog -P 7077              # 实时日志
hdc shell hilog -x -n 200 -P 7077    # 历史日志（200行）
hdc shell hilog -L E -P 7077         # 错误日志
```

### 应用生命周期分析

**正常的应用启动流程**：

```
I AppKit: [MAINTHD3066]mainthread start, pid:7077
I AppKit: [MAINTHD425]attach
I AppKit: [MAINTHD819]ScheduleLaunchAbility called, ability EntryAbility
I ArkCompiler: start to execute module buffer
I UIAbility: [JUA348]called
I UIAbility: [JUA393]End
I UIAbility: [ui_ability_thread169]Lifecycle:Attach
I AppKit: [MAINTHD2710]called
```

**关键生命周期事件**：

| 事件 | 说明 |
|------|------|
| `mainthread start` | 主线程启动 |
| `ScheduleLaunchAbility` | 调度 Ability |
| `start to execute module` | 开始执行模块 |
| `UIAbility called` | UI Ability 创建 |
| `Lifecycle:Attach` | 生命周期附加 |

### 常见问题分析

#### 1. 日志级别错误

**问题现象**：
```
E TimerLog: 定时错误日志 - 计数器: 1, 时间戳: 2026-03-28T12:04:34.860Z
E TimerLog: 定时错误日志 - 计数器: 2, 时间戳: 2026-03-28T12:04:35.860Z
E TimerLog: 定时错误日志 - 计数器: 3, 时间戳: 2026-03-28T12:04:36.865Z
```

**问题分析**：
- 日志级别为 ERROR，但实际是正常功能
- 每秒输出一次，占用大量日志空间
- 日志内容误导（"定时错误日志"）

**解决方法**：

```typescript
// 修改前
hilog.error("TimerLog", `定时错误日志 - 计数器: ${counter}, 时间戳: ${timestamp}`);

// 修改后
hilog.info("TimerLog", `定时日志 - 计数器: ${counter}, 时间戳: ${timestamp}`);
```

#### 2. 资源加载失败

**常见错误**：

| 错误 | 说明 | 影响 |
|------|------|------|
| `LoadThemesRes failed` | 主题资源加载失败 | 低 - 可选功能 |
| `auth_enable failed` | 认证启用失败 | 低 - 可选功能 |
| `apply qos failed, errno = 4` | QoS 设置失败 | 低 - 性能优化 |

#### 3. 应用崩溃

**崩溃日志特征**：

```bash
# 查找崩溃相关日志
grep -i "crash\|exception\|fatal\|abort" SystemLog/hilog.* | grep "com.example.myapplication"

# 查找 ANR（Application Not Responding）
grep -i "ANR\|timeout" SystemLog/hilog.* | grep "com.example.myapplication"
```

## 完整工作流程示例

### Windows 完整流程

```powershell
# 1. 导出日志（使用环境变量）
cd "$env:DEVECO_STUDIO_PATH\tools\emulator"
.\Emulator.exe -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"

# 2. 解压日志 zip
mkdir "$env:TEMP\emulator_log_extracted"
cd "$env:TEMP\emulator_log_extracted"
tar -xf "$env:TEMP\emulator_log.zip"

# 3. 解压 .gz 文件
python decompress_gz.py

# 4. 分析应用日志
cd SystemLog
grep -i "com.example.myapplication" hilog.* | head

# 5. 使用 hdc 获取实时日志
hdc shell aa dump -a | findstr "com.example.myapplication"
hdc shell hilog -P 7077
```

### macOS/Linux 完整流程

```bash
# 1. 导出日志（使用环境变量）
cd "$DEVECO_STUDIO_PATH/tools/emulator"
./emulator -logZip "MyPhone" -logPath "/tmp/emulator_log.zip"

# 2. 解压日志 zip
mkdir -p /tmp/emulator_log_extracted
cd /tmp/emulator_log_extracted
unzip /tmp/emulator_log.zip

# 3. 解压 .gz 文件
python3 decompress_gz.py

# 4. 分析应用日志
cd SystemLog
grep -i "com.example.myapplication" hilog.* | head -50

# 5. 使用 hdc 获取实时日志
hdc shell aa dump -a | grep "com.example.myapplication"
hdc shell hilog -P 7077
```

## 最佳实践

1. **使用 -logZip 导出日志**：这是最全面的日志分析方式，比手动保存日志更完整
2. **定期导出日志**：在测试完成后及时导出日志
3. **使用进程 ID 过滤**：比标签过滤更准确
4. **关注日志级别**：ERROR 级别日志需要重点关注
5. **保存解压脚本**：将 decompress_gz.py 保存为常用工具
6. **跨平台兼容**：使用 Python 脚本确保跨平台支持
7. **路径规范化**：使用环境变量或双反斜杠/正斜杠，避免硬编码路径
8. **实例名称大小写**：确保实例名称与 `emulator -list` 输出完全一致

## 相关文档

- [emulator.md](emulator.md) - Emulator 命令行工具详细参考
- [hilog.md](hilog.md) - hilog 日志工具基础参考
- [hilog-advanced.md](hilog-advanced.md) - hilog 日志工具高级功能
- [crash-log-analysis.md](crash-log-analysis.md) - 崩溃日志分析指南
