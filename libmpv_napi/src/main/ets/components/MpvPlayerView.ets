import { MpvPlayerController } from '../controller/MpvPlayerController';

// How the video frame is fitted into the display area.
export enum VideoFit {
  Contain = 0, // aspect fit, letterbox (default)
  Cover = 1,   // aspect fill, crop top/bottom or sides (fill screen)
  Fill = 2,    // stretch to fill, ignore aspect ratio
}

// DORMANT: 产品渲染走 entry 内联 XComponent + surfaceId；启用条件：entry 切换到 MpvPlayerView/libraryname 路径
// This component is kept as a standby render path. The product player
// (mediaservice AvPlayerController + entry AVPlayer.ets) uses an inline
// XComponent (id 'PlayerXComponent', no libraryname) and routes the surface
// via controller.setVideoSurfaceId()/setVideoSurfaceSize(), so the
// libraryname-driven native surface callbacks never fire in production.
@Component
export struct MpvPlayerView {
  controller: MpvPlayerController = new MpvPlayerController();
  playerBgColor: ResourceColor = Color.Black;
  // Fit mode for mapping the native-resolution video into the display area.
  @Prop videoFit: VideoFit = VideoFit.Contain;

  private xComponentController: XComponentController = new XComponentController();

  // Render-area decoupling strategy:
  //   The XComponent is laid out at the video's NATIVE resolution, so its
  //   surface buffer is the native size and mpv renders 1:1 into it. The
  //   component size never changes when the display area changes (fullscreen
  //   toggle, rotation); instead we apply a compositor-side .scale() transform
  //   to fit it into the area. A scale is a GPU transform — it does NOT resize
  //   the surface, so mpv is never reconfigured (the slow path) and size
  //   changes are instant.
  @State private videoW: number = 0;   // native video width  (px)
  @State private videoH: number = 0;   // native video height (px)
  @State private areaW: number = 0;    // display area width   (px)
  @State private areaH: number = 0;    // display area height  (px)
  private sized: boolean = false;
  private sizeTimer: number = -1;

  // Scale factor mapping the native-size component onto the display area.
  private fitScale(): number {
    if (this.videoW <= 0 || this.videoH <= 0 || this.areaW <= 0 || this.areaH <= 0) {
      return 1.0;
    }
    const sx = this.areaW / this.videoW;
    const sy = this.areaH / this.videoH;
    switch (this.videoFit) {
      case VideoFit.Cover:
        return Math.max(sx, sy);
      case VideoFit.Contain:
      default:
        return Math.min(sx, sy);
    }
  }

  private fitScaleX(): number {
    if (this.videoFit === VideoFit.Fill && this.videoW > 0 && this.areaW > 0) {
      return this.areaW / this.videoW;
    }
    return this.fitScale();
  }

  private fitScaleY(): number {
    if (this.videoFit === VideoFit.Fill && this.videoH > 0 && this.areaH > 0) {
      return this.areaH / this.videoH;
    }
    return this.fitScale();
  }

  // Poll getMediaInfo until the decoder reports a valid video resolution, then
  // lock the component to that native size once. Polling (not an event) keeps
  // this component self-contained and avoids touching the single native event
  // callback the app layer uses.
  private tryFixVideoSize(): void {
    if (this.sized) {
      return;
    }
    const info = this.controller.getMediaInfo();
    const v = info && info.video && info.video.length > 0 ? info.video[0] : undefined;
    const w = v ? v.width : 0;
    const h = v ? v.height : 0;
    if (w > 0 && h > 0) {
      this.videoW = w;
      this.videoH = h;
      this.sized = true;
      if (this.sizeTimer !== -1) {
        clearInterval(this.sizeTimer);
        this.sizeTimer = -1;
      }
    }
  }

  private startSizePolling(): void {
    if (this.sized || this.sizeTimer !== -1) {
      return;
    }
    this.tryFixVideoSize();
    if (!this.sized) {
      this.sizeTimer = setInterval(() => this.tryFixVideoSize(), 100);
    }
  }

  aboutToDisappear(): void {
    if (this.sizeTimer !== -1) {
      clearInterval(this.sizeTimer);
      this.sizeTimer = -1;
    }
  }

  build() {
    Stack() {
      XComponent({
        id: this.controller.playerId,
        type: XComponentType.SURFACE,
        libraryname: 'mpv_napi',
        controller: this.xComponentController
      })
        .onLoad(() => {
          this.controller.setVideoSurfaceId(this.xComponentController.getXComponentSurfaceId());
          this.startSizePolling();
        })
        // Until the native resolution is known, fill the area (normal first
        // frames). Once known, lock to native px size so surface = native and
        // the only thing that changes on resize is the scale transform.
        .width(this.sized ? px2vp(this.videoW) : '100%')
        .height(this.sized ? px2vp(this.videoH) : '100%')
        .scale(this.sized
          ? { x: this.fitScaleX(), y: this.fitScaleY(), centerX: '50%', centerY: '50%' }
          : { x: 1.0, y: 1.0 })
        .backgroundColor(this.playerBgColor)
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .alignContent(Alignment.Center)
    .onAreaChange((_old, area) => {
      const pw = vp2px(area.width as number);
      const ph = vp2px(area.height as number);
      if (pw > 0 && ph > 0) {
        this.areaW = pw;
        this.areaH = ph;
      }
    })
  }
}
