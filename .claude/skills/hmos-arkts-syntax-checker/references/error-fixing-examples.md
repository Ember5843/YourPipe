# 错误修复示例

本文档包含 ArkTS 语法错误的详细修复示例，用于指导自动化修复流程。

## P0 - 必须修复（阻止编译）

### 1. 类型错误

**错误代码**:
```typescript
let value: string = 123;
```

**修复后**:
```typescript
let value: string = "123";
```

**修复说明**: 类型不匹配，需要将数字转换为字符串或修改类型声明。

---

### 2. 未定义的变量

**错误代码**:
```typescript
function calculate() {
  return undefinedVar + 10;
}
```

**修复后**:
```typescript
function calculate() {
  let undefinedVar: number = 0;
  return undefinedVar + 10;
}
```

**修复说明**: 变量未定义，需要先声明变量。

---

### 3. 导入错误

**错误代码**:
```typescript
import { NonExistentClass } from './utils';
```

**修复后**:
```typescript
import { ExistingClass } from './utils';
```

**修复说明**: 导入的类不存在，需要检查导出名称或路径。

---

### 4. 括号不匹配

**错误代码**:
```typescript
function test( {
  return 0;
}
```

**修复后**:
```typescript
function test() {
  return 0;
}
```

**修复说明**: 函数声明括号不匹配，需要补全括号。

---

## P1 - 强烈建议修复

### 1. 废弃 API 迁移

**旧代码**:
```typescript
import fileio from '@ohos.fileio';

fileio.openSync(path, 0);
```

**新代码**:
```typescript
import fs from '@ohos.file.fs';

let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
```

**迁移说明**: 
- `@ohos.fileio` 已废弃，使用 `@ohos.file.fs` 替代
- API 接口有变化，需要调整参数

---

### 2. 废弃方法替换

**旧代码**:
```typescript
let context = getContext(this) as common.AbilityContext;
```

**新代码**:
```typescript
let context = getContext(this) as common.UIAbilityContext;
```

**迁移说明**: `AbilityContext` 已废弃，使用 `UIAbilityContext` 替代。

---

## P2 - 可选优化

### 1. 未使用变量

**问题代码**:
```typescript
function test() {
  let unusedVar = 10;
  return 20;
}
```

**修复方案 1 - 删除变量**:
```typescript
function test() {
  return 20;
}
```

**修复方案 2 - 使用下划线前缀**:
```typescript
function test() {
  let _unusedVar = 10;
  return 20;
}
```

---

### 2. 缺少异常处理

**问题代码**:
```typescript
async function fetchData() {
  const response = await fetch(url);
  return response.json();
}
```

**修复后**:
```typescript
async function fetchData() {
  try {
    const response = await fetch(url);
    return response.json();
  } catch (error) {
    console.error('Fetch failed:', error);
    return null;
  }
}
```

---

### 3. 异步函数缺少异常处理

**问题代码**:
```typescript
async function processData() {
  const data = await loadData();
  processData(data);
}
```

**修复后**:
```typescript
async function processData() {
  try {
    const data = await loadData();
    processData(data);
  } catch (error) {
    console.error('Process failed:', error);
  }
}
```

---

## 常见构建错误修复

### 1. 依赖问题

**错误信息**:
```
Error: Cannot find module '@ohos/xxx'
```

**修复步骤**:
1. 检查 `oh-package.json5` 中的依赖配置
2. 运行 `ohpm install` 安装依赖
3. 如果依赖不存在，检查模块名称是否正确

---

### 2. 资源问题

**错误信息**:
```
Error: Resource not found
```

**修复步骤**:
1. 检查 `resources/` 目录结构
2. 确保资源文件存在
3. 检查资源引用路径是否正确

---

### 3. 签名问题

**错误信息**:
```
Error: Signing failed
```

**修复步骤**:
1. 检查 `build-profile.json5` 中的签名配置
2. 确保证书文件存在且有效
3. 检查证书密码是否正确

---

## 修复优先级说明

| 优先级 | 类型 | 是否阻止编译 | 修复策略 |
|--------|------|--------------|----------|
| P0 | 语法错误/类型错误 | 是 | 必须立即修复 |
| P1 | 废弃 API | 否（但影响功能） | 强烈建议修复 |
| P2 | 代码质量 | 否 | 可选优化 |

---

## 相关资源

- [ArkTS 语法指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-get-started)
- [API 参考文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/)
- [废弃 API 列表](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/)
