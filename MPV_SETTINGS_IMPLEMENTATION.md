# MPV 播放器设置项实现文档

## 概述

为 YourPipe 应用的 MPV 播放器添加了用户可配置的设置项，包括硬件解码、缓冲配置和 GPU 渲染选项。

## 新增设置项

### 1. 硬件解码 (hwdecEnabled)
- **类型**: 布尔开关
- **默认值**: `true` (启用)
- **说明**: 启用硬件加速解码，降低 CPU 占用和功耗，提升播放性能
- **MPV 参数**: `hwdec` = 'auto' | 'no'

### 2. GPU 渲染 (gpuApi)
- **类型**: 下拉选择
- **选项**: 
  - `auto` - 自动选择 (默认)
  - `opengl` - OpenGL
  - `vulkan` - Vulkan
- **说明**: 选择 GPU 渲染后端，auto 让系统自动选择最佳方案
- **MPV 参数**: `gpu-api`

### 3. 内存缓存 (cacheSecs)
- **类型**: 下拉选择
- **选项**: 5秒 / 10秒 / 20秒 / 30秒 / 60秒
- **默认值**: `10` 秒
- **说明**: 内存缓存时长，更大的缓存可以改善网络波动容忍度，但占用更多内存
- **MPV 参数**: `cache-secs`
- **特殊处理**: HLS 流自动使用 2 倍值

### 4. 预读缓冲 (demuxerReadaheadSecs)
- **类型**: 下拉选择
- **选项**: 5秒 / 8秒 / 15秒 / 30秒 / 60秒
- **默认值**: `8` 秒
- **说明**: 预先下载的数据量，影响播放流畅度和启动速度
- **MPV 参数**: `demuxer-readahead-secs`
- **特殊处理**: HLS 流自动使用 3 倍值

### 5. 缓冲区大小 (demuxerMaxBytes)
- **类型**: 下拉选择
- **选项**: 10MB / 20MB / 50MB / 100MB
- **默认值**: `20` MB
- **说明**: 解封装器最大缓冲区，过大可能触发 YouTube SABR 限速
- **MPV 参数**: `demuxer-max-bytes`
- **注意**: 与 RangeProxy 的 10MB chunk 限制配合使用

## 技术实现

### 架构设计

采用配置提供者模式，避免 mediaservice 层直接依赖 entry 层：

```
Entry Layer (PlaybackConfig)
    ↓ (通过 EngineConfig Provider)
MediaService Layer (AvPlayerController)
    ↓ (传递 EngineConfig)
Engine Layer (MpvPlaybackEngine)
    ↓ (应用到 MPV)
```

### 文件修改清单

1. **PlaybackConfig.ets** (entry/common)
   - 添加 5 个配置字段和类型定义
   - 添加显示标签映射
   - 扩展 `loadFromPreferences()` 和 `saveToPreferences()`
   - 扩展 `clone()` 方法

2. **PlaybackEngine.ets** (mediaservice/engine)
   - 在 `EngineConfig` 接口中添加 5 个 MPV 专用字段

3. **MpvPlaybackEngine.ets** (mediaservice/engine)
   - 添加 `engineConfig` 实例变量
   - 修改 `initialize()` 方法读取并应用配置
   - 修改 `load()` 方法中的 HLS 特殊处理

4. **AvPlayerController.ets** (mediaservice/controller)
   - 添加静态配置提供者机制
   - 修改 `initialize()` 调用传递配置

5. **EntryAbility.ets** (entry/entryability)
   - 注册 MPV 引擎配置提供者
   - 在 `onCreate()` 中初始化

6. **Index.ets** (entry/product)
   - 添加导入新的配置类型和常量
   - 在 `OptionsPlaybackPage` 中添加 UI 控件
   - 更新 `StateObserver` 的 key 触发重渲染

### 配置流程

1. **启动时**: `EntryAbility.onCreate()` 注册配置提供者
2. **初始化播放器**: `AvPlayerController.initPlaybackEngine()` 调用提供者获取配置
3. **应用配置**: `MpvPlaybackEngine.initialize()` 将配置转换为 MPV 属性
4. **加载视频**: `MpvPlaybackEngine.load()` 根据流类型调整缓冲参数

### UI 布局

播放设置页面结构：
```
播放设置
├── 视频
│   ├── 默认画质
│   └── 显示高分辨率
├── 播放器 (新增)
│   ├── 硬件解码: [开关]
│   └── GPU 渲染: [自动 ▼]
├── 缓冲与网络 (新增)
│   ├── 内存缓存: [10秒 ▼]
│   ├── 预读缓冲: [8秒 ▼]
│   └── 缓冲区大小: [20MB ▼]
├── 画中画
├── 下载
└── 缓存 (磁盘缓存)
```

## 使用说明

### 用户操作

1. 打开应用设置
2. 进入"播放"设置页面
3. 根据需要调整各项配置
4. 配置会自动保存并在下次播放时生效

### 推荐配置

**标准配置（默认）**:
- 硬件解码: 启用
- GPU 渲染: 自动
- 内存缓存: 10秒
- 预读缓冲: 8秒
- 缓冲区大小: 20MB

**流畅优先（网络较差）**:
- 硬件解码: 启用
- GPU 渲染: 自动
- 内存缓存: 30秒
- 预读缓冲: 30秒
- 缓冲区大小: 50MB

**省内存（低端设备）**:
- 硬件解码: 启用
- GPU 渲染: 自动
- 内存缓存: 5秒
- 预读缓冲: 5秒
- 缓冲区大小: 10MB

## 注意事项

1. **YouTube 限速**: 缓冲区大小不建议超过 50MB，可能触发 SABR 限速
2. **内存占用**: 高缓存设置会增加内存占用，低端设备需注意
3. **HLS 流**: 系统会自动为 HLS 流使用更大的缓冲（2-3倍）
4. **配置生效**: 修改配置后需要重新播放视频才会生效，正在播放的视频不受影响

## 测试建议

1. **功能测试**:
   - 修改各项设置并验证保存
   - 播放视频验证配置生效
   - 检查日志输出确认参数正确

2. **性能测试**:
   - 不同配置下的播放流畅度
   - 内存占用情况
   - CPU/GPU 占用率

3. **兼容性测试**:
   - 不同视频格式（DASH, HLS, 直播）
   - 不同画质（144p - 4K）
   - 不同网络条件

## 相关文档

- MPV 手册: https://mpv.io/manual/stable/
- libmdk 文档: https://github.com/wang-bin/mdk-sdk
- YouTube SABR 限速分析: `MPV_YOUTUBE_THROTTLING_FIX.md`
- PiP 实现方案: `PiP_MPV_XCOMPONENT_DECISION.md`

## 维护日志

- **2026-06-17**: 初始实现，添加 5 个 MPV 配置项
