# 测试提示词

本文档包含验证 deveco-studio-hilog skill 功能的测试提示词。

---

## 一、基础功能测试

### 测试场景 1：查看应用日志

**提示词**：
```
查看 myapp 的日志
```

**预期输出**：
- 查询运行中的应用（hdc shell aa dump -a）
- 获取应用的进程 ID（如 pid #2869）
- 使用进程 ID 过滤日志（hdc shell hilog -P {进程ID}）
- 获取历史日志（hdc shell hilog -x -n 200 -P {进程ID}）
- 显示日志内容
- 如果无输出，检查应用状态

---

### 测试场景 2：分析应用日志诊断问题

**提示词**：
```
分析 myapp 的日志，看看有什么问题
```

**预期输出**：
- 步骤1：获取应用进程 ID
- 步骤2：获取应用历史日志（hilog -x -n 500 -P {pid}）
- 步骤3：获取错误级别日志（hilog -L E -P {pid}）
- 步骤4：分析日志内容
- 识别常见问题类型：
  - 生命周期问题（onCreate/onForeground/onBackground）
  - QoS 任务调度错误（errno = 4）
  - 资源加载失败
  - 网络请求错误
  - 崩溃信号
- 步骤5：生成分析报告
- 总结：报告发现的问题及建议

---

### 测试场景 3：查看错误日志

**提示词**：
```
查看 myapp 的错误日志
```

**预期输出**：
- 获取应用进程 ID
- 使用错误级别过滤（hilog -L E -P {pid}）
- 显示错误日志内容
- 分析每个错误的原因
- 提供解决建议

---

### 测试场景 4：导出模拟器全量日志

**提示词**：
```
导出 MyPhone 模拟器的日志
```

**预期输出**：
- 检查配置文件获取 DevEco Studio 路径
- 检查模拟器实例是否存在（emulator -list）
- 在 emulator 目录下执行导出命令
- Windows: cd "$env:DEVECO_STUDIO_PATH/tools/emulator"
- 执行: Emulator.exe -logZip "MyPhone" -logPath "$env:TEMP\emulator_log.zip"
- 等待导出完成
- 验证导出结果（HandleLogZip: log collection succeeded）
- 报告导出路径

---

### 测试场景 5：解析导出的日志

**提示词**：
```
解析刚才导出的日志
```

**预期输出**：
- 步骤1：解压日志 zip 文件
- 步骤2：解压 SystemLog 中的 .gz 文件（使用 scripts/extract_gz.py）
- 步骤3：列出解压后的文件
- 步骤4：分析日志内容
- 步骤5：生成分析报告
- 总结：报告日志内容摘要和发现的问题

---

### 测试场景 6：导出并分析应用日志

**提示词**：
```
导出日志并分析 myapp 的日志
```

**预期输出**：
- 步骤1：导出模拟器日志（-logZip）
- 步骤2：解压日志 zip
- 步骤3：解压 SystemLog 中的 .gz 文件
- 步骤4：在 SystemLog 中搜索应用日志
- 步骤5：分析应用生命周期
- 步骤6：识别错误和异常
- 步骤7：生成分析报告
- 总结：报告应用日志分析结果

---

## 二、边界条件测试

### 测试场景 7：查看特定标签日志

**提示词**：
```
查看标签为 testTag 的日志
```

**预期输出**：
- 获取应用进程 ID
- 使用标签过滤（hilog -T testTag -P {pid}）
- 显示日志内容
- 说明进程 ID + 标签组合过滤的优势

---

### 测试场景 8：实时监控应用日志

**提示词**：
```
实时监控 myapp 的日志
```

**预期输出**：
- 获取应用进程 ID
- 启动实时日志监控（hilog -P {pid}）
- 说明实时日志的特性（阻塞模式）
- 提示用户操作完成后按 Ctrl+C 退出

---

### 测试场景 9：导出日志到指定路径

**提示词**：
```
导出日志到 D:\logs\emulator_log.zip
```

**预期输出**：
- 检查目标目录是否存在
- 如果不存在，创建目录
- 使用指定路径执行导出
- 验证导出结果

---

### 测试场景 10：分析崩溃日志

**提示词**：
```
模拟器崩溃了，分析崩溃日志
```

**预期输出**：
- 步骤1：获取实例路径（emulator -list -details）
- 步骤2：检查 Log/crash_report 目录
- 步骤3：运行崩溃分析脚本
  - Windows: .\scripts\analyze-crash-log.ps1 -AutoFind
  - Linux: python scripts/analyze_crash_log.py
- 步骤4：解压崩溃报告
- 步骤5：读取关键文件
  - details.txt - 崩溃类型
  - reproductionsteps.txt - 操作步骤
  - Emulator.log - 模拟器日志
- 步骤6：分析崩溃原因
- 步骤7：生成崩溃分析报告

---

## 三、错误处理测试

### 测试场景 11：应用无日志输出

**提示词**：
```
查看日志但没有输出
```

**预期输出**：
- 检查设备连接状态（hdc list targets）
- 检查应用是否正在运行（hdc shell aa dump -a）
- 清除 buffer 后重新查看（hilog -r && hilog）
- 检查日志 buffer 大小（hilog -g）
- 如果应用未运行，建议先启动应用

---

### 测试场景 12：导出失败-实例不存在

**提示词**：
```
导出日志失败，提示找不到实例
```

**预期输出**：
- 识别错误：Can not find instance
- 列出可用实例（emulator -list）
- 检查实例名称是否正确
- 建议使用正确的实例名称
- 或创建新实例

---

### 测试场景 13：解压.gz文件失败

**提示词**：
```
解压 .gz 文件报错
```

**预期输出**：
- 检查 Python 是否安装
- 检查文件权限
- 使用 scripts/extract_gz.py 脚本
- 提供 Python 安装链接
- 或使用 gzip 命令手动解压

---

### 测试场景 14：找不到配置文件

**提示词**：
```
找不到 deveco-studio-emulator 的配置文件
```

**预期输出**：
- 说明配置依赖：../deveco-studio-emulator/scripts/config.json
- 建议运行 python ../deveco-studio-emulator/scripts/setup.py
- 或设置环境变量 DEVECO_STUDIO_PATH 和 HDC_PATH
- 提供具体的配置方法

---

## 四、hidumper工具测试

### 测试场景 15：获取崩溃历史记录

**提示词**：
```
查看模拟器的崩溃历史记录
```

**预期输出**：
- 执行 hidumper -e 命令
- 显示崩溃历史记录
- 分析崩溃类型和时间
- 提供进一步分析建议

---

### 测试场景 16：导出崩溃日志文件

**提示词**：
```
导出设备上的崩溃日志文件
```

**预期输出**：
- 执行 hdc file recv /data/log/faultlog/faultlogger/ {本地目录}
- 解压和分析导出的崩溃日志
- 识别崩溃类型
- 提供修复建议