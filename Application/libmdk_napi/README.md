# libmdk-napi

基于 [libmdk](https://github.com/wang-bin/mdk-sdk) 的鸿蒙音视频播放接口。

## 功能
- 基础播放能力
- 广泛的编码格式、协议、容器格式支持(通过 FFmpeg)
- 硬件解码和 0 拷贝高性能渲染
- HDR 直通
- 杜比视界渲染，包括 profile 5
- 标准透明视频解码和渲染，包括 vp8、vp9、hevc alpha
- 字幕渲染

## 使用
导入SDK: `ohpm install @mediadevkit/libmdk-napi`

示例代码:

```ts
import { MdkPlayerController, MdkPlayerView } from '@mediadevkit/libmdk-napi';

@Entry
@Component
struct DemoPage {
  private controller: MdkPlayerController = new MdkPlayerController();

  aboutToAppear(): void {
    this.controller.setMedia('https://example.com/video.mp4');
    this.controller.play();
  }

  aboutToDisappear(): void {
    this.controller.dispose();
  }

  build() {
    Column({ space: 12 }) {
      MdkPlayerView({controller: this.controller})
        .width('100%')
        .height('100%')

      Button('Pause').onClick(() => this.controller.pause())
    }
  }
}
```