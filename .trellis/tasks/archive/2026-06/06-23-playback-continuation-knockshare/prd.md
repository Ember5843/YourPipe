# 播放时流转 + 碰一碰分享 YouTube 链接

## Goal

将应用流转从"全流程无条件可用"改为"仅播放会话期间启用"，并在播放页接入碰一碰分享，将当前 YouTube 视频链接通过卡片形式分享给对方。

## Requirements

### 需求1：流转按播放状态启用

- R1.1 移除 `EntryAbility.onForeground/onBackground` 里无条件的 `setMissionContinueState(ACTIVE/INACTIVE)` 切换
- R1.2 通过播放状态机监听器驱动流转状态：
  - `PLAYING / PAUSED / BUFFERING / READY` → `ACTIVE`（播放会话期间可流转）
  - `IDLE / RELEASED / COMPLETED / ERROR` → `INACTIVE`（非播放时不可流转）
- R1.3 监听器必须在 `resetSession()` 重建 controller 后重新注册（controller 被替换，旧监听器失效）
- R1.4 保留 `module.json5` 的 `continuable: true` / `continueType` 静态声明不变
- R1.5 保留 `onBackground` 的 `BackgroundTaskManager.startContinuousTask` 和 `AppStorage.setOrCreate('isAppBackground', true)`

### 需求2：播放时碰一碰分享

- R2.1 在播放页注册 `harmonyShare.on('knockShare')` 监听
- R2.2 碰一碰触发时，分享当前 YouTube 视频 URL（`HYPERLINK` 类型 + 卡片样式）
  - `content`: `https://www.youtube.com/watch?v={videoId}`
  - `title`: 视频标题
  - `description`: 频道名
  - `thumbnailUri`: 视频缩略图 URL
- R2.3 无可分享内容时（未加载视频），调 `sharableTarget.clarifyNonShare()` 终止本次分享
- R2.4 应用退后台时取消碰一碰监听（`harmonyShare.off`），回前台时恢复
- R2.5 修复 `VideoDetails.ets` 的 `shareVideo()` toast 存根，接入 `systemShare.ShareController.show()` 系统分享面板
- R2.6 手动分享按钮用 `PLAIN_TEXT`（纯文本含标题+URL），碰一碰用 `HYPERLINK`（链接卡片）

## Acceptance Criteria

- [ ] AC1 编译通过：`build_project` 无错误
- [ ] AC2 首页不播放时，流转入口不可用（状态为 INACTIVE）
- [ ] AC3 播放视频时，流转入口可用（状态为 ACTIVE）
- [ ] AC4 播放中暂停，流转仍可用（PAUSED → ACTIVE）
- [ ] AC5 播放结束(COMPLETED)，流转不可用
- [ ] AC6 连续播放两个不同视频（触发 resetSession），第二个视频流转仍正常
- [ ] AC7 播放页碰一碰触发，弹出分享卡片（含标题/缩略图/链接）
- [ ] AC8 未加载视频时碰一碰，调 clarifyNonShare 不报错
- [ ] AC9 播放页退后台，碰一碰不响应；回前台恢复
- [ ] AC10 点击 VideoDetails 分享按钮，弹出系统分享面板
- [ ] AC11 代码规范：V1 装饰器、无 any/as、@Track 完整

## Constraints

- ArkUI V1 only（无 V2 装饰器）
- 无 `any`/`as` 类型断言
- 不改动 mediaservice 模块内部代码
- 不新增权限/配置（碰一碰由 ShareKit 统一处理）
- YouTube URL 统一格式：`https://www.youtube.com/watch?v={videoId}`
