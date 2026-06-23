# Technical Design

## Architecture Overview

```
需求1：流转按播放状态启用
┌─────────────────────────────────────────────┐
│ PlayerSession (singleton, holds context)    │
│  └─ continueStateListener (StateChangeListener)│
│       └─ onStateChange(from, to)            │
│            └─ handleContinueStateChange(to) │
│                 └─ context.setMissionContinueState(ACTIVE/INACTIVE)│
│                                              │
│  注册点：                                    │
│   - constructor() 末尾                       │
│   - resetSession() 末尾（controller 重建后） │
└─────────────────────────────────────────────┘

EntryAbility:
  onForeground: 移除 setMissionContinueState(ACTIVE)
  onBackground: 移除 setMissionContinueState(INACTIVE)
  （保留 AppStorage + BackgroundTaskManager）

需求2：碰一碰分享
┌─────────────────────────────────────────────┐
│ PlayerPage (@Component)                     │
│  ├─ knockShareCallback (arrow fn)           │
│  │    └─ PlayerSession.currentVideo → URL   │
│  │    └─ sharableTarget.share(SharedData)   │
│  ├─ aboutToAppear: harmonyShare.on(...)     │
│  ├─ aboutToDisappear: harmonyShare.off(...) │
│  └─ @StorageProp('isAppBackground')@Watch   │
│       └─ 后台 off / 前台 on                 │
└─────────────────────────────────────────────┘

VideoDetails:
  shareVideo() 存根 → systemShare.ShareController.show()
```

## Key Design Decisions

### D1: 监听器在 PlayerSession 而非 EntryAbility 注册

理由：
- `PlayerSession` 是单例，持有 `this._context: common.UIAbilityContext`，可直接调 `setMissionContinueState`
- `PlayerSession` 拥有 `controller`，无需跨层引用
- `resetSession()` 在 PlayerSession 内部，可在重建 controller 后立即重新注册
- EntryAbility 的 `onForeground/onBackground` 只管前后台切换，不再耦合流转逻辑

### D2: 监听器为命名成员（非匿名函数）

```typescript
private continueStateListener: StateChangeListener = {
  onStateChange: (_from: PlayerState, to: PlayerState): void => {
    this.handleContinueStateChange(to);
  }
};
```

理由：`removeStateListener` 需要引用相等性匹配，匿名对象每次创建新引用，无法移除。命名成员保证 add/remove 配对。

### D3: 碰一碰监听在 PlayerPage 而非 VideoDetails

理由：
- `PlayerPage` 是播放页的根结构，有完整的 `aboutToAppear/aboutToDisappear` 生命周期
- `VideoDetails` 是播放详情子组件，可能随 Tab 切换而卸载/重建，不适合做监听生命周期管理
- 碰一碰需要在整个播放页活跃期间响应，不限于详情 Tab

### D4: 后台取消监听用 @StorageProp('isAppBackground') @Watch

理由：
- EntryAbility 已在 `onForeground/onBackground` 设置 `AppStorage.setOrCreate('isAppBackground', boolean)`
- 无需新增 eventHub 或自定义回调
- @Watch 响应式触发，符合项目 V1 状态管理模式

### D5: 手动分享与碰一碰的 UTD 类型区分

- 手动分享按钮（VideoDetails.shareVideo）：`PLAIN_TEXT`，内容 `${title}\n${url}`
- 碰一碰（knockShareCallback）：`HYPERLINK`，content 为纯 URL，配 title/description/thumbnailUri 生成卡片

理由：官方文档明确碰一碰卡片需 HYPERLINK + 独立字段；手动分享面板用 PLAIN_TEXT 更通用（粘贴到任意应用）。

### D6: clarifyNonShare 版本兼容

`sharableTarget.clarifyNonShare()` 是 6.0.2(22)+ API。项目 targetSdk 6.1.0(23) 满足，但为防御性编程，用 try/catch 包裹整个回调。

## State Transition Map (流转)

| PlayerState | ContinueState | 说明 |
|-------------|---------------|------|
| IDLE | INACTIVE | 初始/空闲 |
| INITIALIZING | INACTIVE | 准备中，未真正播放 |
| LOADING | INACTIVE | 加载中（短暂，保守处理） |
| READY | ACTIVE | 准备就绪，可流转 |
| PLAYING | ACTIVE | 播放中 |
| PAUSED | ACTIVE | 暂停，仍属播放会话 |
| BUFFERING | ACTIVE | 缓冲中，仍属播放会话 |
| COMPLETED | INACTIVE | 播放结束 |
| ERROR | INACTIVE | 出错 |
| RELEASED | INACTIVE | 已释放 |

> 注：LOADING 设为 INACTIVE 是保守选择——加载中流转可能拿到不完整 payload。READY 即 ACTIVE 是因为 `PlaybackContinuationService.buildPayload()` 已有 `vm.isReady` 门控。

## File Impact

| 文件 | 改动类型 | 说明 |
|------|----------|------|
| `entry/.../EntryAbility.ets` | 删除 | 移除 setMissionContinueState 调用 + setContinueState 方法 |
| `entry/.../PlayerSession.ets` | 新增 | continueStateListener + registerContinueStateListener + handleContinueStateChange |
| `entry/.../PlayerPage.ets` | 新增 | knockShareCallback + harmonyShare.on/off + isAppBackground @Watch |
| `entry/.../VideoDetails.ets` | 替换 | shareVideo() 存根 → systemShare 实现 |

## Compatibility

- 无 module.json5 变更
- 无权限变更（碰一碰由 ShareKit 处理，不需要 NFC_TAG 权限）
- 无资源变更
- `StateChangeListener` 已从 mediaservice/Index.ets:13 导出，可直接 import
