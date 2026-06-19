# hilog日志工具高级功能

## 进程和正则过滤

### 查看指定进程日志

**重要**：推荐使用 `-P`（大写）按进程ID过滤应用日志。

```bash
# 查看指定进程ID的日志（推荐）
hdc shell hilog -P {进程ID}

# 查看指定进程ID的Error级别日志
hdc shell hilog -P {进程ID} -L E

# 查看指定进程ID并按标签过滤
hdc shell hilog -P {进程ID} -T {标签}

# 查看指定进程ID并使用正则表达式过滤
hdc shell hilog -P {进程ID} -x {正则表达式}
```

### 查看符合正则匹配关键字的日志

```bash
# 使用正则表达式过滤日志
hdc shell hilog -x {正则表达式}

# 示例：查找包含"error"或"failed"的日志
hdc shell hilog -x "error|failed"

# 示例：查找包含特定错误码的日志
hdc shell hilog -x "ERROR_CODE_[0-9]+"

# 组合使用：按标签和正则匹配
hdc shell hilog -T {标签} -x {正则表达式}

# 组合使用：按进程ID和正则匹配
hdc shell hilog -p {进程ID} -x {正则表达式}
```

## 缓冲区行数控制

### 查看缓冲区前n行日志

```bash
# 查看缓冲区前100行日志
hdc shell hilog -n 100

# 查看缓冲区前50行Error级别日志
hdc shell hilog -n 50 -L E

# 查看缓冲区前n行并按标签过滤
hdc shell hilog -n {行数} -T {标签}
```

### 查看缓冲区后n行日志

```bash
# 查看缓冲区后100行日志
hdc shell hilog -t 100

# 查看缓冲区后50行Error级别日志
hdc shell hilog -t 50 -L E

# 查看缓冲区后n行并按标签过滤
hdc shell hilog -t {行数} -T {标签}
```

## 高级组合过滤

### 多条件组合过滤

```bash
# 按标签、级别和正则表达式组合过滤
hdc shell hilog -T {标签} -L E -x {正则表达式}

# 按进程ID、标签和行数组合过滤
hdc shell hilog -p {进程ID} -T {标签} -n {行数}

# 按域名和正则表达式组合过滤
hdc shell hilog -D {域名} -x {正则表达式}

# 按类型和级别组合过滤
hdc shell hilog -t app -L E
```

### 复杂正则表达式示例

```bash
# 查找包含特定IP地址的日志
hdc shell hilog -x "\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"

# 查找包含时间戳的日志
hdc shell hilog -x "\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"

# 查找包含特定错误信息的日志
hdc shell hilog -x "(NullPointerException|IndexOutOfBoundsException)"

# 查找包含HTTP状态码的日志
hdc shell hilog -x "HTTP/[0-9.]+ [0-9]{3}"
```

## 日志输出格式控制

### 指定输出格式

```bash
# brief格式（默认，简洁输出）
hdc shell hilog -v brief

# process格式（包含进程信息）
hdc shell hilog -v process

# time格式（包含时间戳）
hdc shell hilog -v time

# thread格式（包含线程信息）
hdc shell hilog -v thread

# raw格式（原始格式）
hdc shell hilog -v raw
```

### 日志缓冲区管理

```bash
# 清空日志缓冲区
hdc shell hilog -r

# 查询buffer大小
hdc shell hilog -g

# 设置buffer大小（64K-16M）
hdc shell hilog -G 1M
hdc shell hilog -G 4M
hdc shell hilog -G 16M
```

## 日志类型过滤

### 按日志类型过滤

```bash
# 只显示应用日志
hdc shell hilog -t app

# 只显示系统核心日志
hdc shell hilog -t core

# 只显示初始化日志
hdc shell hilog -t init

# 只显示统计日志
hdc shell hilog -t stats
```

**日志类型说明**：
- **app**: 应用日志
- **core**: 系统核心日志
- **init**: 初始化日志
- **stats**: 统计日志

## 实用示例

### 调试应用崩溃

```bash
# 1. 查看所有Error和Fatal级别日志
hdc shell hilog -L E
hdc shell hilog -L F

# 2. 查看特定应用的错误日志
hdc shell hilog -T MyAppTag -L E

# 3. 查看包含异常关键字的日志
hdc shell hilog -x "Exception|Error|Crash"

# 4. 查看最近的错误日志（后100行）
hdc shell hilog -t 100 -L E
```

### 监控特定进程

**注意**：推荐使用 `hdc shell aa dump -a` 获取应用进程ID，而不是 `hdc shell ps`，因为 `aa dump -a` 提供更详细的应用信息。

```bash
# 1. 获取应用进程ID
hdc shell aa dump -a

# 输出示例：
# AppRunningRecord ID #9
#   process name [com.example.myapplication]
#   pid #3820  uid #20020059
#   state #FOREGROUND

# 2. 监控该进程的实时日志（推荐使用 -P）
hdc shell hilog -P 3820

# 3. 监控该进程的错误日志
hdc shell hilog -P 3820 -L E

# 4. 监控该进程最近100行历史日志
hdc shell hilog -x -n 100 -P 3820
```

### 网络请求调试

```bash
# 查找包含HTTP请求的日志
hdc shell hilog -x "http://|https://"

# 查找包含特定URL的日志
hdc shell hilog -x "api\.example\.com"

# 查找包含网络错误的日志
hdc shell hilog -x "NetworkError|Timeout|ConnectionFailed"
```

## 官方文档

详细文档请参考：
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hilog
