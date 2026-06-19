# 输出示例

本文档包含构建流程的输出示例，用于理解构建结果和错误处理。

## 成功构建输出

```
✅ HarmonyOS 项目构建成功
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 构建统计：
  - 检查文件数：26 个
  - 修复错误数：3 个
  - 重试次数：2 次
  - 构建耗时：45 秒

📦 构建产物：
  - HAP 路径：entry/build/default/outputs/default/entry-default-signed.hap
  - APP 路径：build/outputs/default/CustomCamera-default-signed.app
  - 文件大小：12.5 MB

📋 修复详情：
  1. [P0] 修复类型错误 - Index.ets:53
  2. [P1] 迁移废弃 API - CameraManager.ets:76
  3. [P2] 删除未使用变量 - VideoManager.ets:99

🎯 下一步：
  - 可以使用 start_app 工具安装并运行应用
  - 或手动将 HAP 包安装到设备
```

---

## 失败输出

### 场景 1: 达到最大重试次数

```
❌ HarmonyOS 项目构建失败
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 构建统计：
  - 检查文件数：26 个
  - 发现错误数：5 个
  - 重试次数：5 次（已达上限）

🔴 无法自动修复的错误：

1. 签名配置错误
   📍 配置文件：build-profile.json5
   ⚠️  问题：证书文件不存在
   💡 建议：检查签名配置路径是否正确

2. 依赖缺失
   📍 模块：entry
   ⚠️  问题：找不到模块 '@ohos/xxx'
   💡 建议：运行 ohpm install 安装依赖

🔧 手动修复建议：
  1. 检查签名配置并更新证书
  2. 安装缺失的依赖包
  3. 重新运行构建命令
```

---

### 场景 2: MCP 工具未安装

```
❌ MCP工具未安装或不可用

本技能需要依赖 DevEco MCP Server 工具才能正常工作。

📦 安装方式（二选一）：

方式一：使用 npx 安装（推荐）
在 MCP 配置文件中添加以下配置：

{
  "mcpServers": {
    "deveco-mcp": {
      "command": "npx",
      "args": [
        "-y",
        "deveco-mcp-server"
      ],
      "env": {
        "PROJECT_PATH": "${workspaceFolder}",
        "DEVECO_PATH": "path to deveco studio"
      }
    }
  }
}

注意：如果使用国内 npm 镜像源导致安装失败，请在 args 中添加：
"--registry=https://registry.npmjs.org"

方式二：下载二进制安装包
1. 访问 https://github.com/open-deveco/deveco-toolbox
2. 下载对应平台的安装包（MacOS/Windows）
3. 安装并配置 MCP 服务

📚 详细文档：
- GitHub: https://github.com/open-deveco/deveco-toolbox
- 飞书指导文档: https://my.feishu.cn/wiki/open-deveco/deveco-toolbox

💡 安装完成后，请重新使用本技能。
```

---

### 场景 3: 项目配置错误

```
❌ 项目配置检查失败
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📍 问题：build-profile.json5 配置错误

⚠️  错误详情：
  - compileSdkVersion 未设置
  - compatibleSdkVersion 未设置
  - 产品配置缺失

💡 修复建议：
  1. 打开 build-profile.json5
  2. 添加必要的 SDK 版本配置
  3. 检查 products 配置项

📝 配置示例：
{
  "app": {
    "products": [
      {
        "name": "default",
        "signingConfig": "default"
      }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": ["default"]
        }
      ]
    }
  ]
}
```

---

## 构建产物位置

### HAP 包

```
项目根目录/
└── entry/
    └── build/
        └── default/
            └── outputs/
                └── default/
                    └── entry-default-signed.hap
```

### APP 包

```
项目根目录/
└── build/
    └── outputs/
        └── default/
            └── {project-name}-default-signed.app
```

---

## 错误类型统计

构建完成后，会输出错误类型统计：

```
📊 错误类型统计：

P0 错误（必须修复）：
  - 类型错误：2 个
  - 语法错误：1 个
  - 导入错误：0 个

P1 错误（建议修复）：
  - 废弃 API：3 个
  - 版本兼容：1 个

P2 错误（可选优化）：
  - 未使用变量：5 个
  - 缺少异常处理：2 个
  - 权限警告：1 个

总计：15 个问题
已修复：12 个
跳过：3 个（P2 级别）
```

---

## 构建日志示例

```
[2026-03-24 10:30:15] 开始构建流程
[2026-03-24 10:30:15] 检查 MCP 工具依赖... ✓
[2026-03-24 10:30:16] 扫描项目源文件... 找到 26 个 .ets 文件
[2026-03-24 10:30:18] 执行静态语法检查...
[2026-03-24 10:30:20] 发现 3 个错误
[2026-03-24 10:30:20] 修复 P0 错误: Index.ets:53 类型错误
[2026-03-24 10:30:21] 修复 P1 错误: CameraManager.ets:76 废弃 API
[2026-03-24 10:30:22] 修复 P2 错误: VideoManager.ets:99 未使用变量
[2026-03-24 10:30:23] 重新检查... ✓ 无错误
[2026-03-24 10:30:25] 开始构建项目...
[2026-03-24 10:31:10] 构建完成 ✓
[2026-03-24 10:31:10] 生成产物: entry-default-signed.hap (12.5 MB)
[2026-03-24 10:31:10] 构建流程完成
```

---

## 相关资源

- [HarmonyOS 构建指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-build-app)
- [HAP 包结构](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hap-package)
- [应用签名配置](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)
