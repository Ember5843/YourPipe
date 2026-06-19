---
name: hmos-arkui-knowledge-retriever
description: ArkUI 知识检索层，提供基于本地知识库的精准检索能力，不涉及代码生成或修改。触发场景：(1) 用户查询 ArkUI API 用法、参数细节或版本支持 (2) 用户需要验证某个组件/装饰器的正确用法 (3) 用户排查 ArkUI 编译错误码或运行时异常 (4) 用户询问状态管理 V1/V2 差异或迁移细节 (5) 其他 skill 需要调用检索能力获取 API 证据。
---

# ArkUI Knowledge Retriever

## 使用场景

| 场景 | 用户输入特征 | 示例 |
|------|------------|------|
| API 用法查询 | 询问特定 API 的参数、类型、版本 | "@Local 装饰器怎么用"、"Navigation 页面跳转参数" |
| 用法验证 | 已有代码需确认 API 正确性 | "ForEach 的第三个参数是什么"、"@Param 能不能装饰组件内变量" |
| 错误排查 | 编译错误码或运行时异常 | "错误码 100060 是什么意思"、"LazyForEach 数据源报错" |
| 方案对比 | 多个技术方案需要选型 | "V1 和 V2 状态管理有什么区别"、"Navigation 和 Router 哪个好" |
| 被其他 skill 调用 | develop-skill 在方案设计后调检索验证 | 开发流程中 Step 2 的针对性检索环节 |

## 核心原则

2. **来源标注**：每个关键结论标注知识库来源路径
3. **版本敏感**：关注 API version 标注和废弃标记

## 工作流程

### Step 1: 理解查询意图

分析用户问题，确定检索目标和关键词提取策略：

| 查询类型 | 关键词提取策略 | 示例 |
|---------|--------------|------|
| 具体 API 查询 | 提取 API 名称 + 所属领域 | "@Local 装饰器" → `@Local 组件内状态` |
| 概念性问题 | 提取核心概念词 | "V1 V2 有什么区别" → `V1 V2 状态管理 迁移` |
| 错误排查 | 提取错误码或异常关键词 | "报错 100005" → `错误码 100005` |
| 用法验证 | 提取待验证的 API + 用法描述 | "ForEach 第三个参数" → `ForEach keyGenerator` |
| 被其他 skill 调用 | 直接使用调用方提供的关键词 | 开发流程中的针对性检索 |

### Step 2: 执行检索

```bash
# 精准查询（默认 compact 模式，提取代码块+接口签名）
python {skill_dir}/scripts/run.py query "LazyForEach IDataSource" --top-k 3 --include-code --format json

# 需要更多上下文
python {skill_dir}/scripts/run.py query "Navigation 页面跳转" --top-k 5 --max-content-chars 2000 --max-total-chars 16000 --include-code --format json

# 按分类精确过滤
python {skill_dir}/scripts/run.py query "@Local 装饰器" --category 02-state-management --include-code --format json

# 完整文档（关闭 compact 和去重）
python {skill_dir}/scripts/run.py query "Navigation 页面跳转" --full-content --no-compact --no-dedup --include-code --format json
```

**检索策略**：优先检索目标 API 的接口定义 → 再检索用法示例 → 最后检索已知限制和注意事项。

### Step 3: 组织检索结果

将检索到的内容按用户问题的结构组织回答：

1. **直接回答**：用检索结果中的权威文档回答问题
2. **接口签名**：附上完整的 API 接口定义（参数名、类型、顺序）
3. **代码示例**：附上知识库中的用法示例
4. **来源标注**：标注每条关键信息的知识库路径

## 知识库覆盖范围

```
01-basics/          → 自定义组件、声明式UI、生命周期、基础概念 (12篇)
02-state-management/ → V1(@State/@Prop/@Link等) + V2(@Local/@Param等) + 迁移指南 (74篇)
03-layout/          → Flex/Grid/List/Scroll/RelativeContainer 等布局 (54篇)
04-components/      → 各类组件 + 组件公共接口 (118篇)
05-animation/       → 属性动画/显式动画/转场动画 (27篇)
06-interaction/     → 手势/触摸/按键/拖拽/焦点/事件系统 (51篇)
07-navigation/      → Navigation/NavDestination/路由 (41篇)
08-dialog-menu/     → 弹窗/菜单/下拉选择 (30篇)
09-rendering/       → ForEach/LazyForEach/Repeat/条件渲染 (25篇)
10-extension/       → RenderNode/自定义节点/Builder (20篇)
11-theme-style/     → 主题/样式系统 + @Extend/@Styles (18篇)
12-i18n/            → 国际化 (1篇)
13-accessibility/   → 无障碍 (4篇)
14-performance/     → 性能优化 (7篇)
15-advanced/        → 高级特性 (13篇)
16-window/          → 窗口管理 (7篇)
17-error-code/      → 错误码 (25篇)
```

## 检索结果可信度判断

1. **API version 标注**：文档中明确标注 "从 API version X 开始支持" → 高可信
2. **废弃标记**：文档中有 "从 API version X 开始废弃" → 必须遵循，提示用户不可用
3. **V1/V2 标记**：文档在 `v1/` 或 `v2/` 目录下 → 明确版本归属
4. **无版本标注**：视为不确定，建议用户额外确认
