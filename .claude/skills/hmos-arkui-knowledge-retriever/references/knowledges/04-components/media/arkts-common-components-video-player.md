# 视频播放 (Video)

Video组件用于播放视频文件并控制其播放状态，常用于短视频和应用内部视频的列表页面。当视频完整出现时会自动播放，用户点击视频区域则会暂停播放，同时显示播放进度条，通过拖动播放进度条指定视频播放到具体位置。具体用法请参考[Video](../reference/apis-arkui/arkui-ts/ts-media-components-video.md)。

## 创建视频组件

Video通过调用接口来创建，接口调用形式如下：

`Video(value: VideoOptions)`

## 加载视频资源

Video组件支持加载本地视频和网络视频。具体的数据源配置请参考[VideoOptions对象说明](../reference/apis-arkui/arkui-ts/ts-media-components-video.md#videooptions对象说明)。

### 加载本地视频

- 普通本地视频。

  加载本地视频时，首先在本地rawfile目录指定对应的文件，如下图所示。

  再使用资源访问符$rawfile()引用视频资源。

  
  ``` TypeScript
  // xxx.ets
  // ···
  @Component
  export struct LocalVideo {
    private controller: VideoController = new VideoController();
    private previewUris: Resource = $r('app.media.preview');
    private innerResource: Resource = $rawfile('videoTest.mp4');
  
    build() {
      Column() {
        Video({
          src: this.innerResource,  // 设置视频源
          previewUri: this.previewUris, // 设置预览图
          controller: this.controller //设置视频控制器，可以控制视频的播放状态
        })
      }
    }
  }
  ```

- [Data Ability](../application-models/dataability-overview.md)提供的视频路径带有dataability://前缀，使用时确保对应视频资源存在。

  
  ``` TypeScript
  // xxx.ets
  // ···
  @Component
  export struct LocalVideoTwo {
    private controller: VideoController = new VideoController();
    private previewUris: Resource = $r('app.media.preview');
    private videoSrc: string = 'dataability://device_id/com.domainname.dataability.videodata/video/10';
  
    build() {
      Column() {
        Video({
          src: this.videoSrc,
          previewUri: this.previewUris,
          controller: this.controller
        })
      }
    }
  }
  ```

### 加载沙箱路径视频

支持file://路径前缀的字符串，用于读取应用沙箱路径内的资源，需要确保应用沙箱目录路径下的文件存在并且有可读权限。

``` TypeScript
// xxx.ets
// ···
@Component
export struct Sandbox {
  private controller: VideoController = new VideoController();
  private videoSrc: string = 'file:///data/storage/el2/base/haps/entry/files/show.mp4';

  build() {
    Column() {
      Video({
        src: this.videoSrc,
        controller: this.controller
      })
    }
  }
}
```

### 加载网络视频

加载网络视频时，需要申请ohos.permission.INTERNET权限，具体申请方式请参考[声明权限](../security/AccessToken/declare-permissions.md)。此时，Video的src属性为网络视频的链接。

``` TypeScript
// xxx.ets
// ···
@Component
export struct OnlineVideo {
  private controller: VideoController = new VideoController();
  private previewUris: Resource = $r('app.media.preview');
  private videoSrc: string = 'www.example.com/example.mp4'; // 使用时请替换为实际视频加载网址

  build() {
    Column() {
      Video({
        src: this.videoSrc,
        previewUri: this.previewUris,
        controller: this.controller
      })
    }
  }
}
```

## 添加属性

Video组件[属性](../reference/apis-arkui/arkui-ts/ts-media-components-video.md#属性)主要用于设置视频的播放形式。例如设置视频播放是否静音、播放是否显示控制条等。

``` TypeScript
// xxx.ets
// ···
@Component
export struct AttributeVideo {
  private controller: VideoController = new VideoController();

  build() {
    Column() {
      Video({
        controller: this.controller
      })
        .muted(false) // 设置是否静音
        .controls(false) // 设置是否显示默认控制条
        .autoPlay(false) // 设置是否自动播放
        .loop(false) // 设置是否循环播放
        .objectFit(ImageFit.Contain) // 设置视频填充模式
    }
  }
}
```

## 事件调用

  Video组件回调事件主要包括播放开始、播放暂停、播放结束、播放失败、播放停止、视频准备和操作进度条等事件，除此之外，Video组件也支持通用事件的调用，如点击、触摸等事件的调用。详细事件请参考[事件说明](../reference/apis-arkui/arkui-ts/ts-media-components-video.md#事件)。

``` TypeScript
// xxx.ets
@Entry
@Component
struct EventCall {
  private controller: VideoController = new VideoController();
  private previewUris: Resource = $r('app.media.preview');
  private innerResource: Resource = $rawfile('videoTest.mp4');

  build() {
    Column() {
      Video({
        src: this.innerResource,
        previewUri: this.previewUris,
        controller: this.controller
      })
        .onUpdate((event) => { // 更新事件回调
        })
        .onPrepared((event) => { // 准备事件回调
        })
        .onError(() => { // 失败事件回调
        })
        .onStop(() => { // 停止事件回调
        })
    }
  }
}
```

## Video控制器使用

Video控制器主要用于控制视频的状态，包括播放、暂停、停止以及设置进度等，详细使用请参考[VideoController使用说明](../reference/apis-arkui/arkui-ts/ts-media-components-video.md#videocontroller)。

- 默认控制器

  默认的控制器支持视频的开始、暂停、进度调整、全屏显示四项基本功能。

  
  ``` TypeScript
  // xxx.ets
  @Entry
  @Component
  struct VideoGuide {
    @State videoSrc: Resource = $rawfile('videoTest.mp4');
    @State previewUri: string = 'common/videoIcon.png';
    @State curRate: PlaybackSpeed = PlaybackSpeed.Speed_Forward_1_00_X;
  
    build() {
      Row() {
        Column() {
          Video({
            src: this.videoSrc,
            previewUri: this.previewUri,
            currentProgressRate: this.curRate // 设置视频播放倍速
          })
        }
        .width('100%')
      }
      .height('100%')
    }
  }
  ```

- 自定义控制器

  使用自定义的控制器，先关闭默认控制器，然后使用[Button](../reference/apis-arkui/arkui-ts/ts-basic-components-button.md)以及[Slider](../reference/apis-arkui/arkui-ts/ts-basic-components-slider.md)等组件进行自定义的控制与显示，适合自定义较强的场景下使用。

  ``` TypeScript
  // xxx.ets
  @Entry
  @Component
  struct CustomizedControl {
    @State videoSrc: Resource = $rawfile('videoTest.mp4');
    @State previewUri: string = 'common/videoIcon.png';
    @State curRate: PlaybackSpeed = PlaybackSpeed.Speed_Forward_1_00_X;
    // 初始化当前时间为0
    @State currentTime: number = 0;
    // 初始化持续时间为0
    @State durationTime: number = 0;
    controller: VideoController = new VideoController();

    build() {
      Row() {
        Column() {
          Video({
            src: this.videoSrc,
            previewUri: this.previewUri,
            currentProgressRate: this.curRate,
            controller: this.controller
          })
            .controls(false)
            .autoPlay(true)
            .onPrepared((event) => {
              if (event) {
                this.durationTime = event.duration
              }
            })
            .onUpdate((event) => {
              if (event) {
                this.currentTime = event.time
              }
            })
          Row() {
            Text(JSON.stringify(this.currentTime) + 's')
            Slider({
              value: this.currentTime,
              min: 0,
              max: this.durationTime
            })
              .onChange((value: number, mode: SliderChangeMode) => {
                this.controller.setCurrentTime(value); // 设置视频播放的进度跳转到value处
              })
              .width('90%')
            Text(JSON.stringify(this.durationTime) + 's')
          }
          .opacity(0.8)
          .width('100%')
        }
        .width('100%')
      }
      .height('40%')
    }
  }
  ```

## 其他说明

Video组件已经封装好了视频播放的基础能力，开发者无需进行视频实例的创建，视频信息的设置获取，只需要设置数据源以及基础信息即可播放视频，相对扩展能力较弱。如果开发者想自定义视频播放，请使用AVPlayer，下面是一个使用AVPlayer进行播放视频的简单示例，如果需要更详细信息或更复杂功能请参考视频播放。

  ``` TypeScript
  // xxx.ets
  import { window } from '@kit.ArkUI';
  import { AVPlayerController } from '../avplayertool/AVPlayerController';
  import { emitter } from '@kit.BasicServicesKit';
  import { CommonConstants, VideoDataType } from  '../common/constants/CommonConstants';
  import { VideoData } from '../model/VideoData'
  import { common } from '@kit.AbilityKit'

  class VideoXComponentController extends XComponentController {
    private avPlayerController: AVPlayerController;

    constructor(avPlayerController: AVPlayerController) {
      super();
      this.avPlayerController = avPlayerController;
    }

    onSurfaceCreated(surfaceId: string): void {
      let source: VideoData = {
        type: VideoDataType.RAW_FILE,
        videoSrc: 'videoTest.mp4'
      };
      // 将surfaceId和视频源信息传递给AVPlayer
      this.avPlayerController.initAVPlayer(source, surfaceId);
    }
  }

  const MINUTE_UNIT = 60000;
  const SECOND_UNIT = 1000;
  const SECOND_TEN = 10;
  function timeCover(time: number): string {
    let min: number = Math.floor(time / MINUTE_UNIT);
    let second: string = ((time % MINUTE_UNIT) / SECOND_UNIT).toFixed(0);
    return `${min}:${(Number(second) < SECOND_TEN ? '0' : '') + second}`;
  }

  @Entry
  @Component
  struct XComponentAVPlayer {
    // 设置视频控制器，可以控制视频的播放状态。
    @State avPlayerController: AVPlayerController = new AVPlayerController(this.getUIContext().getHostContext()!);
    // 视频的总时长。
    @State durationTime: number = 0;
    // 视频当前进度。
    @State currentTime: number = 0;
    // 判断视频是否暂停播放。
    @State isPause: boolean = true;
    // 判断视频是否全屏播放。
    @State isLayoutFullScreen: boolean = false;
    // 设置XComponent组件控制器。
    private videoXComponentController: XComponentController = new VideoXComponentController(this.avPlayerController);
    // 判断窗口是否横屏。
    @State isLandScape: boolean = false;
    // 系统导航栏的标识。
    private WINDOW_SYSTEM_BAR: Array<'status' | 'navigation'> = ['navigation', 'status'];
    // 窗口宽度。
    @State windowWidth:number = 0;
    // 窗口高度。
    @State windowHeight: number = 0;
    // 窗口实例。
    private windowClass: window.Window | null = null;

    // 获取窗口实例。
    getWindow(): window.Window {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.windowStage!.getMainWindowSync();
    }

    aboutToAppear(): void {
      this.windowClass = this.getWindow();
      let properties = this.windowClass.getWindowProperties();
      let context = this.getUIContext();
      this.windowWidth = context.px2vp(properties.windowRect.width);
      this.windowHeight = context.px2vp(properties.windowRect.height);
      // 获取窗口横竖屏状态及其尺寸。
      this.windowClass.on('windowSizeChange', (size: window.Size) => {
        this.isLandScape = size.width > size.height;
        this.windowWidth = context.px2vp(size.width);
        this.windowHeight = context.px2vp(size.height);
      })
      emitter.on(CommonConstants.AVPLAYER_PREPARED, (res) => {
        if (res.data) {
          this.durationTime = this.avPlayerController.durationTime;
          // 更新视频进度时间。
          setInterval(() => {
            this.currentTime = this.avPlayerController.currentTime;
          }, 1000);
        }
      });
    }

    // 设置沉浸式窗口。
    setFullScreen(isLayoutFullScreen: boolean) {
      window.getLastWindow(this.getUIContext().getHostContext()).then((win) => {
        if (isLayoutFullScreen) {
          // 设置窗口全屏模式时导航栏、状态栏的可见模式。
          win.setWindowSystemBarEnable([]);
        } else {
          // 设置窗口非全屏模式时导航栏、状态栏的可见模式。
          win.setWindowSystemBarEnable(this.WINDOW_SYSTEM_BAR);
        }
      }).catch((err: string) => {
        console.error(`setFullScreen failed, message is ${err}`);
      });
    }

    build() {
      Column() {
        Stack() {
          XComponent({ type: XComponentType.SURFACE, controller: this.videoXComponentController })
          Column() {
            Blank()
            Column() {
              Column() {
                Row() {
                  Row() {
                    // 设置视频播放或暂停的按钮。
                    SymbolGlyph(this.isPause ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
                      .fontSize(30)
                      .fontWeight(FontWeight.Bolder)
                      .fontColor([Color.White])
                      .onClick(() => {
                        if (this.isPause) {
                          this.avPlayerController.videoPause();
                        } else {
                          this.avPlayerController.videoPlay();
                        }
                        this.isPause = !this.isPause;
                      })
                    // 视频当前进度。
                    Text(timeCover(this.currentTime))
                      .fontColor(Color.White)
                      .textAlign(TextAlign.End)
                      .fontWeight(FontWeight.Regular)
                      .margin({ left: 5 })
                  }
                  Row() {
                    // 视频进度条。
                    Slider({
                      value: this.currentTime,
                      min: 0,
                      max: this.durationTime,
                      style: SliderStyle.OutSet
                    })
                      .id('Slider')
                      .blockColor(Color.White)
                      .trackColor(Color.Gray)
                      .selectedColor('#317af7')
                      .showTips(false)
                      .onChange((value: number, mode: SliderChangeMode) => {
                        if (mode === SliderChangeMode.Begin) {
                          this.avPlayerController.videoPause();
                        }
                        this.avPlayerController.videoSeek(value);
                        this.currentTime = value;
                        if (mode === SliderChangeMode.End) {
                          this.isPause = true;
                          this.avPlayerController.videoPlay();
                        }
                      })
                  }
                  .layoutWeight(1)
                  Row() {
                    // 视频的总时长。
                    Text(timeCover(this.durationTime))
                      .fontColor(Color.White)
                      .fontWeight(FontWeight.Regular)
                      .margin({ right: 5 })
                  }
                  Row() {
                    // 设置是否全屏播放的按钮。
                    SymbolGlyph(this.isLayoutFullScreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') : $r('sys.symbol.arrow_up_left_and_arrow_down_right'))
                      .fontSize(30)
                      .fontWeight(FontWeight.Bolder)
                      .fontColor([Color.White])
                      .onClick(()=> {
                        this.isLayoutFullScreen = !this.isLayoutFullScreen;
                        this.setFullScreen(this.isLayoutFullScreen);
                      })
                  }
                }
                .justifyContent(FlexAlign.Center)
                .padding({ left: 12, right: 20, bottom: 28 })
                .width('100%')
              }
              .backgroundColor(Color.Black)
            }
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height('100%')
        }
        .height(this.isLayoutFullScreen ? this.windowHeight : 300)
        .width(this.isLayoutFullScreen ? this.windowWidth : 300)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
  }
  ```

## 相关实例

针对Video组件开发，有以下相关实例可供参考：

- [ 媒体库视频（ArkTS）（API9）](https://gitcode.com/openharmony/applications_app_samples/tree/master/code/BasicFeature/Media/VideoShow)

- [简易视频播放器（ArkTS）（API9）](https://gitcode.com/openharmony/codelabs/tree/master/Media/SimpleVideo)
