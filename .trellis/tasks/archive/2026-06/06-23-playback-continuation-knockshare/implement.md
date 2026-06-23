# Implementation Plan

## Execution Order

按依赖顺序执行，需求1先于需求2（流转逻辑独立，碰一碰依赖播放页结构）。

### Step 1: EntryAbility 移除无条件流转切换

文件：`entry/src/main/ets/entryability/EntryAbility.ets`

- [ ] 1.1 移除 `onForeground()` (line 144) 的 `this.setContinueState(AbilityConstant.ContinueState.ACTIVE)`
- [ ] 1.2 移除 `onBackground()` (line 151) 的 `this.setContinueState(AbilityConstant.ContinueState.INACTIVE)`
- [ ] 1.3 删除 `setContinueState` 私有方法 (lines 169-175)
- [ ] 1.4 保留 `onBackground` 的 `BackgroundTaskManager.startContinuousTask(this.context)` 和 `AppStorage.setOrCreate('isAppBackground', true)`
- [ ] 1.5 确认 `AbilityConstant` import 仍被 `onCreate` 签名使用（`AbilityConstant.LaunchParam`），保留 import

验证：`check_ets_files EntryAbility.ets`

### Step 2: PlayerSession 注册状态监听器驱动流转

文件：`entry/src/main/ets/common/PlayerSession.ets`

- [ ] 2.1 import `AbilityConstant` from `@kit.AbilityKit`
- [ ] 2.2 import `StateChangeListener` from `mediaservice`（`PlayerState` 已 import）
- [ ] 2.3 新增 `continueStateListener` 成员（StateChangeListener 接口实现）
- [ ] 2.4 新增 `registerContinueStateListener()` 方法：addStateListener + 初始 handleContinueStateChange
- [ ] 2.5 新增 `handleContinueStateChange(to: PlayerState)` 方法：状态映射 + setMissionContinueState + try/catch
- [ ] 2.6 构造函数末尾（line 79 `logger.debug` 之后）调用 `this.registerContinueStateListener()`
- [ ] 2.7 `resetSession()` 末尾（line 454 `logger.debug('Session reset')` 之后）调用 `this.registerContinueStateListener()`

验证：`check_ets_files PlayerSession.ets`

### Step 3: PlayerPage 注册碰一碰监听

文件：`entry/src/main/ets/features/player/PlayerPage.ets`

- [ ] 3.1 import `harmonyShare, systemShare` from `@kit.ShareKit`
- [ ] 3.2 import `uniformTypeDescriptor as utd` from `@kit.ArkData`
- [ ] 3.3 import `PlayerSession`（若未 import）
- [ ] 3.4 新增 `knockShareCallback` 箭头函数成员
- [ ] 3.5 `aboutToAppear` (line 145) 末尾添加 `harmonyShare.on('knockShare', this.knockShareCallback)`
- [ ] 3.6 `aboutToDisappear` (line 280) 添加 `harmonyShare.off('knockShare', this.knockShareCallback)`
- [ ] 3.7 新增 `@StorageProp('isAppBackground') @Watch('onAppBackgroundChange') isAppBackground: boolean = false`
- [ ] 3.8 新增 `onAppBackgroundChange()` 方法：后台 off / 前台 on

验证：`check_ets_files PlayerPage.ets`

### Step 4: VideoDetails 修复分享按钮存根

文件：`entry/src/main/ets/features/player/components/VideoDetails.ets`

- [ ] 4.1 import `systemShare` from `@kit.ShareKit`
- [ ] 4.2 import `uniformTypeDescriptor as utd` from `@kit.ArkData`
- [ ] 4.3 import `common` from `@kit.AbilityKit`（若未 import）
- [ ] 4.4 替换 `shareVideo()` 方法体 (lines 547-550) 为 systemShare.ShareController.show 实现
- [ ] 4.5 URL 统一为 `https://www.youtube.com/watch?v=${videoId}`

验证：`check_ets_files VideoDetails.ets`

### Step 5: 全量编译验证

- [ ] 5.1 `check_ets_files` 检查所有4个文件
- [ ] 5.2 `build_project` 编译通过
- [ ] 5.3 确认无 V2 装饰器、无 any/as

## Validation Commands

```bash
# 静态检查
check_ets_files [
  "entry/src/main/ets/entryability/EntryAbility.ets",
  "entry/src/main/ets/common/PlayerSession.ets",
  "entry/src/main/ets/features/player/PlayerPage.ets",
  "entry/src/main/ets/features/player/components/VideoDetails.ets"
]

# 编译
build_project (module: entry@default)
```

## Rollback Points

- 每个 Step 完成后 check_ets_files，失败则立即修复
- Step 5 build_project 失败：加载 arkts-error-fixes skill 修复
- 全部回滚：`git checkout HEAD -- <4个文件>`
