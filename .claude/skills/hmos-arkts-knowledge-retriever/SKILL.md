---
name: hmos-arkts-knowledge-retriever
description: "检索 ArkTS 语言指南文档，为代码开发、审查和调试提供语法参考。当需要查找 ArkTS 语法规则、库使用方法或代码示例时使用。提供基于索引的高效检索和可追溯的文档引用。"
---
# ArkTS 知识检索工具

## 技能概述

本技能用于快速检索 ArkTS 语言指南文档，为 HarmonyOS 开发提供准确的语法参考。通过结构化索引实现高效检索，返回可追溯的文档引用，帮助开发者在编码、审查和调试时快速找到正确的语法规则。

## 使用场景

- ✅ 查找 ArkTS 语法规则和用法
- ✅ 检索 ArkTS 标准库和常用库的使用方法
- ✅ 获取 ArkTS 并发编程和运行时相关文档
- ✅ 查找 ArkTS 代码示例和最佳实践
- ✅ 代码审查时验证语法正确性
- ✅ 调试时查找错误原因和解决方案

## 工作流程

### 1. 分析查询意图

根据用户问题确定检索类型：

| 查询类型 | 关键词示例             | 目标文档范围             |
| -------- | ---------------------- | ------------------------ |
| 语法规则 | 类、函数、接口、泛型   | 02-Basic-Syntax          |
| 库使用   | JSON、XML、容器        | 03-Common-Library        |
| 并发编程 | TaskPool、Worker、线程 | 04-Concurrency           |
| 运行时   | 动态导入、模块加载     | 05-Runtime               |
| 工具链   | 编译、混淆、字节码     | 07-Compilation-Toolchain |
| 迁移     | TypeScript 转 ArkTS    | 09-Migration-Guide       |

### 2. 执行检索

使用检索脚本查询索引：

```bash
python3 scripts/search_docs.py --query "<查询内容>"
```

**检索参数**：

- `--query`: 查询字符串（必需）
- `--scope`: 限定范围（可选，如 `02-Basic-Syntax`）
- `--top-k`: 返回结果数量（默认 5）

### 3. 分析检索结果

检索结果包含以下信息：

```markdown
- Reference: <文档路径>
- Section: <章节路径>
- Why it matches: <匹配原因>
- Guidance: <简要指导>
- Verification: <验证级别>
```

**验证级别说明**：

- `snippet_validated`: 代码示例已通过验证
- `doc_only`: 仅文档说明，无代码验证

### 4. 返回结果

按照标准格式返回检索结果：

**单结果格式**：

```markdown
📚 **参考文档**: [classes.md](references/arkts-language-guide/02-basic-syntax/classes.md)

📍 **章节**: Declaring a Class

💡 **匹配原因**: 查询涉及类声明语法，该章节详细说明了 class 关键字的使用方法。

📖 **指导**: 使用 `class` 关键字定义类，字段必须在类体中声明。ArkTS 不支持类表达式，必须使用命名类声明。

✅ **验证状态**: snippet_validated
```

**多结果格式**：

```markdown
找到 3 个相关文档：

1. **类声明** - [classes.md](references/...)
   - 章节: Declaring a Class
   - 匹配: 类定义语法

2. **接口定义** - [interfaces.md](references/...)
   - 章节: Declaring an Interface
   - 匹配: 类型定义方式

3. **泛型使用** - [generics.md](references/...)
   - 章节: Generic Classes
   - 匹配: 泛型类语法
```

### 5. 深入阅读（可选）

如果检索结果不够详细，打开原文档：

```bash
# 读取完整文档
Read: references/arkts-language-guide/02-basic-syntax/classes.md
```

## 检查清单

### Critical（必须完成）

- [ ] 查询意图已正确识别
- [ ] 检索范围已合理限定
- [ ] 返回结果包含文档路径
- [ ] 结果格式符合规范

### Warning（建议完成）

- [ ] 提供了匹配原因说明
- [ ] 包含验证状态信息
- [ ] 多结果时按相关性排序
- [ ] 提供了进一步阅读建议

### Info（可选优化）

- [ ] 提供了代码示例
- [ ] 包含最佳实践提示
- [ ] 关联了相关文档

## 决策树

```
用户查询
│
├─ 查询类型？
│   ├─ 语法规则 → 检索 02-Basic-Syntax
│   ├─ 库使用 → 检索 03-Common-Library
│   ├─ 并发编程 → 检索 04-Concurrency
│   ├─ 运行时 → 检索 05-Runtime
│   ├─ 工具链 → 检索 07-Compilation-Toolchain
│   └─ 迁移 → 检索 09-Migration-Guide
│
├─ 检索结果数量？
│   ├─ 0 个 → 扩大检索范围或建议用户重新描述
│   ├─ 1 个 → 返回详细结果
│   └─ 多个 → 按相关性排序，返回前 N 个
│
├─ 结果验证状态？
│   ├─ snippet_validated → 标注已验证，可信度高
│   └─ doc_only → 标注仅文档，建议用户验证
│
└─ 用户需要更多？
    ├─ 是 → 打开原文档，提供完整内容
    └─ 否 → 结束检索
```

## 索引文件说明

### doc_index.json

文档索引，包含所有语言指南的元数据：

```json
{
  "documents": [
    {
      "path": "02-Basic-Syntax/classes.md",
      "title": "Classes",
      "sections": ["Declaring a Class", "Fields", "Methods"],
      "keywords": ["class", "field", "method", "constructor"],
      "verification_level": "snippet_validated"
    }
  ]
}
```

### snippet_index.json

代码片段索引，包含已验证的代码示例：

```json
{
  "snippets": [
    {
      "file": "02-Basic-Syntax/classes.md",
      "line": 15,
      "code": "class User { name: string = ''; }",
      "validated": true
    }
  ]
}
```

### topic_aliases.json

主题别名映射，用于查询扩展：

```json
{
  "aliases": {
    "类": ["class", "classes", "类型定义"],
    "函数": ["function", "functions", "方法"],
    "并发": ["concurrency", "thread", "worker", "taskpool"]
  }
}
```

## 检索策略

### 精确匹配

当查询包含明确的技术术语时：

```bash
# 查询: "ArkTS 如何定义类"
python3 scripts/search_docs.py --query "class declaration" --scope "02-Basic-Syntax"
```

### 模糊匹配

当查询描述较为模糊时：

```bash
# 查询: "如何处理异步任务"
python3 scripts/search_docs.py --query "async task concurrency"
```

### 关联检索

当需要查找相关内容时：

```bash
# 先检索主要主题
python3 scripts/search_docs.py --query "generic class"

# 再检索关联主题
python3 scripts/search_docs.py --query "interface generic"
```

## 输出格式规范

### 标准输出

```markdown
📚 **参考文档**: <文档名称>
📍 **章节**: <章节路径>
💡 **匹配原因**: <一句话说明>
📖 **指导**: <一两句基于文档的指导>
✅ **验证状态**: <snippet_validated/doc_only>
```

### 简洁输出

```markdown
参考: [classes.md](references/...) - 类声明语法
```

### 详细输出

```markdown
📚 **参考文档**: [classes.md](references/arkts-language-guide/02-basic-syntax/classes.md)

📍 **章节路径**: Classes > Declaring a Class

💡 **匹配原因**: 查询涉及类声明语法，该章节详细说明了 class 关键字的使用方法、字段声明和实例创建。

📖 **指导**: 
- 使用 `class` 关键字定义类
- 字段必须在类体中声明，不能动态添加
- ArkTS 不支持类表达式，必须使用命名类声明
- 使用 `new` 关键字创建实例

📝 **代码示例**:
```typescript
class User {
  name: string = '';
  age: number = 0;
}

let user: User = new User();
user.name = 'Alice';
```

✅ **验证状态**: snippet_validated（代码示例已通过验证）

🔗 **相关文档**:

- [interfaces.md](references/...) - 接口定义
- [inheritance.md](references/...) - 类继承
- [generics.md](references/...) - 泛型类

```

## 注意事项

- ⚠️ 检索结果基于索引文件，如果文档更新需要重建索引
- ⚠️ 某些文档可能只有英文版本，检索时需使用英文关键词
- ⚠️ 代码示例的验证状态表示是否通过 arkts-cli 验证
- ⚠️ 对于复杂查询，建议多次检索并综合结果

## 相关资源

- [ArkTS 官方文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-get-started)
- [ArkTS API 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/)
- [HarmonyOS 开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/)
```
