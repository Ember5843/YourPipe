import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildTitleMenu, buildYourTubeTitleBar } from '../../common/components/HdsTitleBar';
import { MediaThumb } from '../../common/components/MediaThumb';

@Component
export struct VideoDetailPage {
  @Prop video: VideoItem | null = null;
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @StorageLink('favorites') favorites: VideoItem[] = [];

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  private readonly HEADER_HEIGHT: number = 56;

  private isFavorited(): boolean {
    if (!this.video) {
      return false;
    }
    const videoId = (this.video.videoId || '').trim();
    if (!videoId) {
      return false;
    }
    return this.favorites.some((item) => item.videoId === videoId);
  }

  private handleFavorite(): void {
    if (!this.video) {
      return;
    }
    const videoId = (this.video.videoId || '').trim();
    if (!videoId) {
      return;
    }
    if (this.isFavorited()) {
      this.actionHub.removeFavorite(videoId);
    } else {
      this.actionHub.addFavorite(this.video);
    }
  }

  aboutToAppear() {

  }

  build() {
    HdsNavDestination() {
      Column() {
      if (!this.video) {
        Text($r('app.string.yt_error_invalid_video'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .margin({ top: 20 })
      } else {
        Column() {
          Text(this.video.title)
            .fontSize(18)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
          Text(this.video.author)
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .margin({ top: 6 })
          MediaThumb({
            imageUrl: this.video.thumbnailUrl || '',
            placeholderColor: this.video.thumbnailColor || '',
            fillParent: true,
            useAspectRatio: true,
            borderRadiusVp: 8,
            showLive: true,
            isLive: this.video.isLive,
            isPremium: this.video.isPremium,
            requiresMembership: this.video.requiresMembership
          })
            .margin({ top: 12 })
        }
        .padding({ left: 16, right: 16, top: 16 })

        Text($r('app.string.yt_notice_direct_link_removed'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ top: 16, left: 16, right: 16, bottom: 24 })
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: $r('app.string.yt_video_details'),
      onBack: () => {
        this.actionHub.closePage();
      },
      menus: this.video ? [
        buildTitleMenu(
          this.isFavorited() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
          this.isFavorited() ? $r('app.string.yt_action_unfavorite') : $r('app.string.yt_action_favorite'),
          () => {
            this.handleFavorite();
          }
        )
      ] : []
    }))
    .onBackPressed(() => {
      this.actionHub.closePage();
      return true;
    })
  }
}
