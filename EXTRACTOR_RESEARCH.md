# YourPipe vs PipePipe — YouTube 流提取器深度对比调研报告

生成日期：2026-05-23（最后更新：2026-05-23）  
调研范围：从 YouTube 视频 ID 到可播放 URL 的完整提取链路

---

## 〇、已确认修复项

### ✅ Bug 已修复：n-param 替换格式错误

**文件**：`youtube_core/src/main/ets/extractor/YouTubeExtractor.ets` 约第 1822 行  
**修复内容**：

```typescript
// 修复前（错误）：
updatedUrl = updatedUrl.replace('/n/' + info.throttlingParam, '/n/' + deobfuscatedParam);

// 修复后（正确，与 PipePipe 对齐）：
updatedUrl = updatedUrl.replace(info.throttlingParam, deobfuscatedParam);
```

**原因**：YouTube 流 URL 的 n-param 是查询参数 `&n=VALUE`，不是路径段 `/n/VALUE`。
注意：`deobfuscateManifestUrl` 方法（L1961）处理的是 HLS manifest URL，其 n-param **确实**在路径段中（`/n/VALUE`），该方法的路径段替换是**正确的，不需要修改**。两种格式不同，不要混淆。

---

## 一、整体流程

两个项目的提取流程结构相同，分为五个阶段：

```
视频ID
  ↓
① 获取 Watch 页面 HTML（ytInitialPlayerResponse）
  ↓
② 调用 InnerTube API（Android 或 Safari 客户端，二选一）获取 streamingData
  ↓
③ 解析 formats / adaptiveFormats，构建初始 URL（含 SIGNATURE_PLACEHOLDER）
  ↓
④ 批量调用 PipePipe API 解密 sig 和 n-param
  ↓
⑤ 将解密结果写回 URL，返回流清单
```

---

## 二、各阶段详细对比

### 阶段②：InnerTube 客户端选择

两者逻辑完全一致：

```
未登录 → Android 客户端（reel/reel_item_watch 端点）
已登录（Cookie）→ Safari 客户端（player 端点，需要 signatureTimestamp）
```

**重要**：`fetchInnertubePlayer` 内部是严格的 `if/else`，Safari 和 Android **互斥**，每次只请求一个客户端。iOS、TV、WebEmbedded 客户端的代码虽然存在，但**从未被调用**，`result` 里对应字段始终是 `undefined`。

---

### 阶段⑤：流数量 — 看似差异实为等价

**表面差异**：
- PipePipe：`ensureStreamsAreCached` 遍历三个客户端（safari + android + tvHtml5）合并流
- YourPipe：只用 `primarySd = safariSd ?? androidSd` 一个客户端

**实际等价**：YourPipe 的 `fetchInnertubePlayer` 只发起一个客户端请求，`iosStreamingData` 和 `tvHtml5StreamingData` 在 `ensureStreamsAreCached` 开头被强制设为 `undefined`（L622-623）。遍历多个客户端或只用一个，结果完全相同——**不存在流数量差异**。

不要因为 PipePipe 遍历三个客户端就认为 YourPipe 丢失了流，YourPipe 根本就没有请求那两个客户端。

---

### 阶段④：批量解密对比

#### n-param 提取（两者一致）

```typescript
// YourPipe (L1836)
url.match(/[&?]n=([^&]+)/)

// PipePipe
Pattern.compile("[&?]n=([^&]+)")
```

#### n-param 替换（已修复，现在一致）

```typescript
// YourPipe（修复后）
updatedUrl = updatedUrl.replace(info.throttlingParam, deobfuscatedParam);

// PipePipe
updatedUrl = updatedUrl.replace(info.throttlingParam, deobfuscatedParam);
```

#### sig 替换（两者一致）

```typescript
updatedUrl = updatedUrl.replace('SIGNATURE_PLACEHOLDER', deobfuscatedSig);
```

#### cipher 字段优先级（两者一致）

```typescript
// YourPipe (L1676)：cipher 优先于 signatureCipher
const cipherString = formatData.cipher || formatData.signatureCipher || '';

// PipePipe：同样 cipher 优先
formatData.getString(CIPHER, formatData.getString(SIGNATURE_CIPHER))
```

---

## 三、真实存在的差异（不影响可用性）

| 差异点 | PipePipe | YourPipe | 实际影响 |
|--------|----------|----------|----------|
| DASH manifest URL | 追加 `?mpd_version=7` | 无此参数 | 低（主流场景不走 DASH manifest） |
| `getDashMpdUrl` 方法 | 有 | 无 | 低 |
| HLS manifest 来源 | 只查 safariStreamingData | 查 safari + ios，但 ios 始终 undefined | 等价 |
| 客户端流合并 | 代码遍历三个 | 代码只取一个 | **等价**（另两个未被请求） |

---

## 四、各方法 n-param 替换格式说明（防止混淆）

| 方法 | URL 类型 | n-param 位置 | 替换格式 | 是否正确 |
|------|----------|-------------|---------|---------|
| `batchDeobfuscateItagUrls` | 流媒体 URL（videoplayback） | 查询参数 `&n=VALUE` | `replace(value, decoded)` | ✅ 已修复 |
| `deobfuscateManifestUrl` | HLS manifest URL | 路径段 `/n/VALUE` | `replace('/n/'+enc, '/n/'+dec)` | ✅ 本来就正确 |

---

## 五、文件索引

| 文件 | 职责 |
|------|------|
| `youtube_core/src/main/ets/extractor/YouTubeExtractor.ets` | 主提取器：`ensureStreamsAreCached` / `batchDeobfuscateItagUrls` / `buildAndAddItagInfoToList` |
| `youtube_core/src/main/ets/extractor/cipher/YoutubeJavaScriptPlayerManager.ets` | 解密管理器，调用 PipePipe API |
| `youtube_core/src/main/ets/extractor/cipher/PipePipeApiDecoder.ets` | PipePipe API 客户端（latest-player + decode） |
| `youtube_core/src/main/ets/extractor/clients/AndroidPlayerClient.ets` | Android InnerTube 客户端（reel_item_watch 端点） |
| `youtube_core/src/main/ets/extractor/clients/SafariPlayerClient.ets` | Safari InnerTube 客户端（player 端点） |
| `youtube_core/src/main/ets/model/ClientsConstants.ets` | 客户端版本常量 |

---

## 六、PipePipe API 交互格式

```
GET https://api.pipepipe.dev/decoder/latest-player
→ { "player": "abc12345", "signatureTimestamp": 19950 }

GET https://api.pipepipe.dev/decoder/decode?player={id}&n={n1,n2}&sig={s1,s2}
→ {
    "type": "result",
    "responses": [
      { "type": "result", "data": { "encN": "decN" } },    // index 0: n-params
      { "type": "result", "data": { "encSig": "decSig" } } // index 1: signatures
    ]
  }
```

响应顺序固定：n-params 在前（index 0），signatures 在后（index 1）。
