---
name: hmos-arkts-syntax-checker
description: "检查并修复 HarmonyOS 项目的 ArkTS 语法错误，自动化构建项目。当需要编译项目、修复编译错误、生成 HAP/App 产物时使用。提供静态语法检查、错误自动修复、循环构建直到成功的完整工作流程。支持错误优先级分类（P0/P1/P2）、最大重试机制、构建产物自动定位。"
---
# HarmonyOS 项目自动化构建

## 技能概述

本技能专门用于自动化构建 HarmonyOS 项目，通过静态语法检查、错误修复和循环构建的流程，确保项目能够成功编译并生成产物。

## 使用场景

- ✅ 需要编译 HarmonyOS 项目生成 HAP/App 产物
- ✅ 项目存在语法错误需要修复
- ✅ 自动化构建流程，减少手动干预
- ✅ 持续集成/持续部署（CI/CD）场景
- ✅ 项目初次构建或升级后构建

## 工作流程

### 核心流程图

```
开始
  │
  ├─→ 步骤0: 检查MCP工具依赖
  │     ├─→ MCP工具可用 → 继续执行
  │     └─→ MCP工具不可用 → 提示安装 → 终止
  │
  ├─→ 步骤1: 扫描项目源文件
  │     └─→ 获取所有 .ets 文件列表
  │
  ├─→ 步骤2: 静态语法检查
  │     └─→ mcp_codegenie-mcp_check_ets_files
  │
  ├─→ 步骤3: 分析诊断结果
  │     ├─→ 有错误 → 步骤4: 修复错误
  │     └─→ 无错误 → 步骤5: 构建项目
  │
  ├─→ 步骤4: 修复错误
  │     ├─→ 应用修复方案
  │     └─→ 返回步骤2（重新检查）
  │
  ├─→ 步骤5: 构建项目
  │     └─→ mcp_codegenie-mcp_build_project
  │
  ├─→ 步骤6: 检查构建结果
  │     ├─→ 构建失败 → 分析错误 → 步骤4
  │     └─→ 构建成功 → 步骤7
  │
  └─→ 步骤7: 输出构建产物
        └─→ 完成
```

### 详细执行步骤

#### 0. 检查MCP工具依赖

**⚠️ 重要提示：本技能依赖MCP工具**

在执行任何构建操作之前，必须先检查MCP工具是否可用：

**依赖的MCP工具**：

- `mcp_codegenie-mcp_check_ets_files` - ETS文件静态语法检查
- `mcp_codegenie-mcp_build_project` - 项目构建
- `mcp_codegenie-mcp_harmonyos_knowledge_search` - HarmonyOS知识搜索（可选）

**检查方法**：

```
尝试调用 mcp_codegenie-mcp_check_ets_files 或 mcp_codegenie-mcp_build_project
如果工具不可用，会收到错误提示
```

**如果MCP工具未安装**：

```
❌ MCP工具未安装或不可用

本技能需要依赖 CodeGenie MCP Server 工具才能正常工作。

📦 安装方式：

在 MCP 配置文件中添加以下配置：

{
  "mcpServers": {
    "codegenie-mcp": {
      "command": "npx",
      "args": [
        "-y",
        "@deveco-codegenie/mcp@beta",
        "--registry=https://registry.npmjs.org"
      ],
      "env": {
        "PROJECT_PATH": "${workspaceFolder}",
        "DEVECO_PATH": "path to deveco studio"
      }
    }
  }
}

📚 详细文档：
- GitHub: https://github.com/open-deveco/deveco-toolbox
- 飞书指导文档: https://my.feishu.cn/wiki/open-deveco/deveco-toolbox

💡 安装完成后，请重新使用本技能。
```

**验证成功后继续执行后续步骤**。

---

#### 1. 项目分析

首先分析项目结构和配置：

**关键配置文件**：

- `build-profile.json5` - 项目级构建配置
- `entry/build-profile.json5` - 模块级构建配置
- `module.json5` - 模块配置
- `oh-package.json5` - 依赖配置

#### 2. 获取源文件列表

使用 Glob 工具搜索项目中的 ETS 文件：

```bash
# 搜索所有 .ets 文件
**/*.ets

# 排除目录
- oh_modules/
- build/
- .preview/
```

#### 3. 执行静态语法检查

调用 MCP 工具进行 ArkTS 静态语法检查：

```
mcp_codegenie-mcp_check_ets_files
参数: files - ETS 文件路径列表
```

**诊断信息类型**：

| 错误码        | 类型        | 说明                 | 优先级 |
| ------------- | ----------- | -------------------- | ------ |
| 28007         | Warning     | 权限警告             | P2     |
| 6133          | Warning     | 未使用的变量/符号    | P2     |
| 6387          | Information | 使用了废弃的 API     | P1     |
| addTryCatch   | Warning     | 需要异常处理         | P2     |
| addAsyncCatch | Warning     | 异步函数需要异常处理 | P2     |
| 其他          | Error       | 语法错误/类型错误    | P0     |

#### 4. 错误修复策略

根据错误类型采取不同的修复策略：

**P0 - 必须修复（阻止编译）**：

- 语法错误：缺少分号、括号不匹配
- 类型错误：类型不匹配
- 未定义的变量/函数
- 导入错误

**P1 - 强烈建议修复**：

- 废弃 API：查找替代 API，应用迁移方案

**P2 - 可选优化**：

- 未使用变量：删除或使用下划线前缀
- 异常处理：添加 try-catch

**详细修复示例**: 参考 [error-fixing-examples.md](references/error-fixing-examples.md)

#### 5. 构建项目

使用 MCP 工具构建项目：

```
mcp_codegenie-mcp_build_project
参数:
  - buildTarget: "hap" 或 "app"
  - buildMode: "debug" 或 "release"
  - product: "default" (可选)
  - module: "entry@default" (可选)
```

**构建目标选择**：

- `hap` - 生成单个 HAP 包（用于测试/调试）
- `app` - 生成 APP 包（用于发布）

#### 6. 构建错误处理

如果构建失败，分析错误信息：

**常见构建错误**：

1. **依赖问题**: `Error: Cannot find module '@ohos/xxx'` → 安装依赖
2. **资源问题**: `Error: Resource not found` → 检查资源文件
3. **签名问题**: `Error: Signing failed` → 检查签名配置
4. **编译错误**: `Error: ArkTS compiler error` → 返回步骤2重新检查

#### 7. 输出构建产物

构建成功后，产物位置：

```
项目根目录/
├── entry/build/default/outputs/default/entry-default-signed.hap
└── build/outputs/default/{project-name}-default-signed.app
```

**输出示例**: 参考 [output-examples.md](references/output-examples.md)

## 循环修复机制

### 决策树

```
开始构建流程
│
├─ MCP工具可用？
│   ├─ 否 → 提示安装MCP工具 → 终止
│   └─ 是 → 继续
│
├─ 静态检查结果？
│   ├─ 有错误 → 错误类型？
│   │   ├─ P0 语法错误 → 必须修复 → 重新检查
│   │   ├─ P1 废弃 API → 建议修复 → 重新检查
│   │   └─ P2 代码质量 → 可选修复 → 继续构建
│   │
│   └─ 无错误 → 执行构建
│
├─ 构建结果？
│   ├─ 成功 → 输出产物路径 → 完成
│   │
│   └─ 失败 → 错误类型？
│       ├─ 依赖问题 → 安装依赖 → 重新构建
│       ├─ 签名问题 → 提示手动修复 → 终止
│       ├─ 资源问题 → 检查资源文件 → 重新构建
│       └─ 编译错误 → 返回静态检查
│
└─ 重试次数 > 5？
    ├─ 是 → 终止，输出失败报告
    └─ 否 → 继续循环
```

### 最大重试次数

为避免无限循环，设置最大重试次数：

```javascript
const MAX_RETRY_COUNT = 5;
let retryCount = 0;

while (retryCount < MAX_RETRY_COUNT) {
  // 1. 静态检查
  const diagnostics = await checkEtsFiles(files);
  
  // 2. 分析错误
  const errors = filterErrors(diagnostics);
  
  if (errors.length === 0) {
    // 3. 构建项目
    const buildResult = await buildProject();
  
    if (buildResult.success) {
      return { success: true, output: buildResult.output };
    }
  } else {
    // 4. 修复错误
    await fixErrors(errors);
  }
  
  retryCount++;
}

return { success: false, error: 'Max retry count exceeded' };
```

### 错误修复优先级

每次循环按以下优先级修复：

1. **P0 错误** - 必须修复，否则无法编译
2. **P1 错误** - 强烈建议修复，可能影响功能
3. **P2 错误** - 可选优化，不影响编译

### 跳过策略

某些错误可以跳过：

- 权限警告（已正确配置权限）
- 未使用变量（不影响编译）
- 异常处理建议（可选优化）

## 执行清单

### 预检查

- [ ] **验证MCP工具可用性（必需）**
- [ ] 确认项目路径正确
- [ ] 检查 build-profile.json5 配置
- [ ] 确认 SDK 版本兼容性
- [ ] 检查依赖是否安装

### 构建流程

- [ ] 获取所有 ETS 文件列表
- [ ] 执行静态语法检查
- [ ] 分析并修复错误
- [ ] 执行构建命令
- [ ] 验证构建结果
- [ ] 输出构建产物路径

### 后处理

- [ ] 记录构建日志
- [ ] 统计修复的问题数量
- [ ] 提供构建产物信息

## 工具命令参考

### MCP 工具

| 工具名称                                         | 用途                    | 必需参数                  |
| ------------------------------------------------ | ----------------------- | ------------------------- |
| `mcp_codegenie-mcp_check_ets_files`            | ETS 文件静态语法检查    | files: string[]           |
| `mcp_codegenie-mcp_build_project`              | 构建项目                | buildTarget: "hap"\|"app" |
| `mcp_codegenie-mcp_harmonyos_knowledge_search` | 搜索 HarmonyOS 开发文档 | keywords: string[]        |

### 辅助工具

| 工具名称          | 用途         |
| ----------------- | ------------ |
| `Glob`          | 搜索文件     |
| `Read`          | 读取文件内容 |
| `Write`         | 写入文件内容 |
| `SearchReplace` | 编辑文件     |

## 最佳实践

### ✅ 推荐做法

1. **增量构建**：优先使用增量构建提高速度
2. **并行检查**：并行检查多个文件提高效率
3. **错误分类**：按优先级修复错误
4. **日志记录**：记录每次修复的内容
5. **版本控制**：修复前创建备份或提交

### ❌ 避免做法

1. 不要忽略 P0 级别错误
2. 不要无限重试（设置上限）
3. 不要跳过静态检查直接构建
4. 不要在构建过程中修改代码
5. 不要忽略构建警告

## 注意事项

- ⚠️ **本技能依赖 CodeGenie MCP Server 工具，使用前请确保已安装并配置 MCP 服务**
  - 安装方式：https://github.com/open-deveco/deveco-toolbox
- ⚠️ 确保项目路径正确，避免构建错误的项目
- ⚠️ 构建前建议提交代码，以便回滚
- ⚠️ 某些错误需要手动修复，无法自动处理
- ⚠️ 构建时间取决于项目规模和复杂度
- ⚠️ 签名配置需要提前准备好证书文件

## 相关资源

### 参考文档

- [错误修复示例](references/error-fixing-examples.md) - 详细的错误修复代码示例
- [输出示例](references/output-examples.md) - 构建成功和失败的输出示例

### 外部资源

- [CodeGenie MCP Server 安装指南](https://github.com/open-deveco/deveco-toolbox)
- [飞书指导文档](https://my.feishu.cn/wiki/open-deveco/deveco-toolbox)
- [HarmonyOS 构建指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-build-app)
- [ArkTS 编译器](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-get-started)
- [HAP 包结构](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hap-package)
- [应用签名配置](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)
