# hilog日志工具完整参考

## hilog命令格式

```bash
hilog [选项] [参数]
```

## 参数说明

| 短选项 | 长选项 | 参数 | 说明 |
|--------|--------|------|------|
| -h | --help | - | 显示帮助信息 |
| -x | --exit | - | 非阻塞读日志，读完退出 |
| -g | - | - | 查询buffer大小 |
| -G | --buffer-size | size | 设置buffer大小（64K-16M） |
| -r | - | - | 清除buffer日志 |
| -k | - | - | Kernel日志读取开关 |
| -l | --level | level | 指定日志级别 (D/I/W/E/F) |
| -t | --type | type | 指定日志类型 (app/core/init/stats) |
| -T | --tag | tag | 按标签过滤 |
| -p | - | pid | 按PID过滤 |
| -s | - | regex | 按正则表达式过滤 |
| -n | - | count | 设置读取行数上限 |
| -w | - | - | 日志落盘控制 |

## 日志级别

| 级别 | 说明 |
|------|------|
| D | Debug |
| I | Info |
| W | Warning |
| E | Error |
| F | Fatal |

## 日志类型

| 类型 | 说明 |
|------|------|
| app | 应用日志 |
| core | 系统核心日志 |
| init | 初始化日志 |
| stats | 统计日志 |

## 应用日志查看

**重要**：查看应用日志推荐使用进程ID（-P）过滤，而非标签（-T）过滤。

### 为什么推荐进程ID过滤

1. **更全面**：进程ID过滤会显示该进程的所有日志，包括所有标签
2. **更可靠**：应用可能使用多个不同的标签，标签过滤可能遗漏部分日志
3. **更简单**：不需要知道应用使用的具体标签名称

### 完整流程

**步骤1：查找应用进程ID**
```bash
hdc shell aa dump -a

# 输出示例：
# AppRunningRecord ID #9
#   process name [com.example.myapplication]
#   pid #3820  uid #20020059
#   state #FOREGROUND
```

**步骤2：使用进程ID过滤日志**
```bash
hdc shell hilog -P 3820              # 实时日志
hdc shell hilog -x -n 200 -P 3820    # 历史日志（200行）
hdc shell hilog -L E -P 3820         # 错误日志
hdc shell hilog -T MyTag -P 3820     # 进程内按标签过滤
```

### 快速命令

**Windows PowerShell:**
```powershell
$pid = (hdc shell aa dump -a | Select-String "process name \[com.example.myapplication\]" -Context 0,2).Context.PostContext | Select-String "pid"; $pid -match "pid #(\d+)" | Out-Null; $match = $Matches[1]; hdc shell hilog -P $match
```

**macOS/Linux:**
```bash
hdc shell hilog -P $(hdc shell aa dump -a | grep -A 2 "process name \[com.example.myapplication\]" | grep "pid" | sed 's/.*pid #\([0-9]*\).*/\1/')
```

## 常用命令

### 基本日志查看
```bash
hilog                      # 实时查看日志（阻塞模式）
hilog -x                   # 非阻塞查看，读完退出
```

### 日志过滤
```bash
hilog -L E                 # 只显示Error级别
hilog -t app               # 只显示应用日志
hilog -T "MyTag"           # 按标签过滤
hilog -p 1234              # 按进程ID过滤
hilog -s "error|failed"     # 正则表达式过滤
```

### 日志保存
```bash
hilog > log.txt            # 保存到文件
hilog | tee log.txt        # 保存并实时显示
```

### 日志落盘
```bash
hilog -w start -n 1000    # 开启日志落盘，保存1000个文件
hilog -w start -t kmsg -n 100  # 开启kmsg日志落盘
hilog -w stop              # 停止日志落盘
hilog -w query             # 查询落盘状态
```

### Buffer管理
```bash
hilog -r                   # 清除buffer日志
hilog -g                   # 查询buffer大小
hilog -G 1M                # 设置buffer大小为1M
```

## 日志落盘规格

- 默认hilog落盘数量：1000个
- 默认kmsg落盘数量：100个
- 单个文件大小：4MB
- 日志保存路径：`/data/log/hilog/`
- 日志ID规则：从0开始，超过上限回绕到0

## 导出设备日志

```bash
# 导出所有hilog日志
hdc file recv /data/log/hilog/ {本地目录}

# 导出kmsg日志
hdc file recv /data/log/kmsg/ {本地目录}
```

## 使用hilogtool解析日志

hilogtool是用于解析hilog日志的工具，位于SDK的toolchains目录下。

### 解析命令
```bash
hilogtool parse -i {输入路径} -o {输出路径}
```

### 参数说明
| 选项 | 说明 |
|------|------|
| `-i` / `--input` | 指定输入路径（目录或文件） |
| `-o` / `--output` | 指定输出路径 |
| `-d` / `--dict` | 指定数据字典路径 |

### 使用示例
```bash
# 解析目录下所有hilog文件
hilogtool parse -i /path/to/hilog

# 解析到指定输出目录
hilogtool parse -i /path/to/hilog -o /path/to/output

# 使用数据字典解析
hilogtool parse -i /path/to/hilog -d /path/to/hilog_dict.zip
```

## 完整工作流程

```bash
# 1. 清除旧日志
hilog -r

# 2. 开启日志落盘
hilog -w start -n 1000

# 3. 执行测试操作...

# 4. 停止日志落盘
hilog -w stop

# 5. 导出日志到本地
hdc file recv /data/log/hilog/ /path/to/local/hilog

# 6. 解析日志
hilogtool parse -i /path/to/local/hilog -o /path/to/output
```

## 官方文档
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hilog-tool
