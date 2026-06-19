# hidumper堆栈转储分析工具完整参考

## hidumper命令格式

```bash
hidumper [选项] [参数]
```

## 基础命令

| 命令 | 说明 |
|------|------|
| `hidumper -h` | 显示帮助信息 |
| `hidumper -lc` | 列出系统信息集群 |
| `hidumper -ls` | 列出系统能力 |

## 系统能力查询

### 查看所有系统能力
```bash
hidumper -ls
```

### 获取系统能力详细信息
```bash
hidumper -s                          # 获取所有系统能力
hidumper -s [SA0 SA1]               # 获取指定系统能力
hidumper -s [SA] -a ["option"]       # 执行特定选项
```

### 常用系统能力示例
```bash
# 显示管理器
hidumper -s DisplayManagerService -a "-s -a"  # 查看所有屏幕
hidumper -s DisplayManagerService -a "-d -a"  # 查看所有显示

# 窗口管理器
hidumper -s WindowManagerService

# 进程信息
hidumper -p
```

## 系统信息集群

### 查看系统信息集群
```bash
hidumper -lc
```

### 获取集群详细信息
```bash
hidumper -c                          # 获取所有集群信息
hidumper -c base                     # 获取基础信息集群
hidumper -c system                   # 获取系统信息集群
```

## 崩溃分析

### 获取崩溃历史记录

```bash
hidumper -e
```

输出包含：
- 崩溃时间
- 进程信息
- 崩溃信号（SIGSEGV、SIGABRT等）
- 崩溃地址
- 堆栈信息
- 线程信息

### 崩溃类型说明

| 故障类型 | 英文名 | 说明 |
|----------|--------|------|
| C++崩溃 | CPP_CRASH | C/C++运行时崩溃 |
| JS崩溃 | JS_CRASH | JavaScript/ArkTS未处理异常 |
| 应用卡死 | APP_FREEZE | 主线程阻塞导致冻结 |

### 崩溃信号类型

| 信号值 | 信号名 | 触发原因 |
|--------|--------|----------|
| 4 | SIGILL | 非法指令 |
| 5 | SIGTRAP | 陷阱指令 |
| 6 | SIGABRT | abort()调用 |
| 811 | SIGFPE | 浮点异常 |
| 11 | SIGSEGV | 段错误（非法内存访问） |
| 12 | SIGSTKFLT | 协处理器栈错误 |
| 16 | SIGBUS | 总线错误 |

## 网络和存储信息

### 网络流量信息
```bash
hidumper --net              # 获取所有进程网络信息
hidumper --net 1234         # 获取指定进程网络信息
```

### 存储IO信息
```bash
hidumper --storage           # 获取所有进程IO信息
hidumper --storage 1234      # 获取指定进程IO信息
```

## 崩溃日志获取方式

### 方式一：通过DevEco Studio
DevEco Studio自动收集 `/data/log/faultlog/faultlogger/` 目录下的故障日志

### 方式二：通过hdc导出
```bash
hdc file recv /data/log/faultlog/faultlogger/ {本地目录}
```

### 方式三：通过hiAppEvent订阅
```typescript
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';

hiAppEvent.addWatcher({
  name: "watcher",
  appEventFilters: [
    {
      event: "crash",
      filter: {
        eventType: ["cppcrash", "jscrash", "appfreeze"]
      }
    }
  ],
  onReceive: (eventInfo) => {
    console.log("Crash event:", JSON.stringify(eventInfo));
  }
});
```

## 崩溃分析流程

```
1. 获取崩溃日志
   → hidumper -e
   → 或从 /data/log/faultlog/faultlogger/ 导出

2. 查看信号值
   → 判断崩溃类型（SIGSEGV、SIGABRT等）

3. 查看崩溃地址
   → 定位问题代码位置

4. 查看堆栈信息
   → 追踪完整调用链

5. 结合hilog日志
   → 分析崩溃前后上下文
```

## faultLogger API

```typescript
import faultLogger from '@ohos.faultLogger';

// 查询故障信息
let faultInfo = faultLogger.querySelfFaultLog(faultLogger.FaultType.CPP_CRASH);
console.log("Fault info:", JSON.stringify(faultInfo));
```

### 故障类型枚举

| 名称 | 值 | 说明 |
|------|-----|------|
| NO_SPECIFIC | 0 | 不区分故障类型 |
| CPP_CRASH | 2 | C++程序故障 |
| JS_CRASH | 3. | JS程序故障 |
| APP_FREEZE | 4 | 应用程序卡死 |

## 完整分析示例

```bash
# 1. 查看崩溃历史
hidumper -e

# 2. 如果有崩溃，导出日志
hdc file recv /data/log/faultlog/faultlogger/ /path/to/local/crash

# 3. 查看相关进程信息
hidumper -p

# 4. 查看系统信息
hidumper -c system

# 5. 结合hilog日志分析
hilog -L F -T "MyApp" > crash_context.log
```

## 官方文档
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hidumper
