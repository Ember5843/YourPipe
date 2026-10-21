import { AppLog } from '../../../common/AppLog';
import { PlayerSession } from '../../../common/PlayerSession';

const logger = AppLog.getInstance('ShortsSurface');
const TAG = '[Shorts]';

/**
 * Shorts 页唯一的视频渲染面。
 *
 * 与长视频播放页的关键差异：本组件在 Shorts 页生命周期内**常驻**，
 * Swiper 只在其上覆盖/淡出封面，因此换条时 surfaceId 不变、MPV 不重绑，
 * 不会出现每次滑动都重建 NativeWindow 的黑帧。
 */
@Component
export struct ShortsSurface {
  private session: PlayerSession = PlayerSession.getInstance();
  private xController: XComponentController = new XComponentController();
  @Prop active: boolean = true;

  build() {
    XComponent({
      id: 'ShortsXComponent',
      type: XComponentType.SURFACE,
      controller: this.xController
    })
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .onLoad(() => {
        const surfaceId = this.xController.getXComponentSurfaceId();
        logger.info(`${TAG} surface_load id=${surfaceId ? surfaceId.substring(0, 12) : 'none'} active=${this.active}`);
        if (surfaceId && this.active) {
          // 记录到 AppStorage：Shorts 页首次进入时 controller 可能已被 release，
          // playShorts 会重建 controller，页面据此把同一个 surface 重新绑到新 controller。
          AppStorage.setOrCreate('shortsSurfaceId', surfaceId);
          this.session.controller.setSurfaceID(surfaceId);
        }
      })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const pxWidth = Math.round(this.getUIContext().vp2px(Number(newArea.width)));
        const pxHeight = Math.round(this.getUIContext().vp2px(Number(newArea.height)));
        if (pxWidth > 0 && pxHeight > 0) {
          this.session.controller.resizeSurface(pxWidth, pxHeight);
        }
      })
  }
}
