import { VideoItem } from 'youtube_core';
import { ActionHub } from '../../../common/ActionHub';
import { MediaThumb } from '../../../common/components/MediaThumb';

/**
 * Multi-card banner strategy:
 * - phone: 1 card (full width)
 * - tablet / 2in1: displayCount = 2 or 3 so one row shows more recommendations
 * - optional side peeks only when displayCount >= 2 (partial neighbor cards)
 *
 * Swiper.prevMargin/nextMargin alone can only expose one neighbor each side;
 * displayCount is what actually increases visible card count.
 */
/** Phone banner follows the same horizontal inset as the home video list. */
const BANNER_PHONE_OUTER_PAD_VP: number = 12;
/** Preferred card width when packing multiple into one viewport. */
const BANNER_CARD_TARGET_VP: number = 300;
const BANNER_CARD_MIN_VP: number = 220;
const BANNER_ITEM_SPACE_VP: number = 10;
/** Side peek of previous/next group (only with multi displayCount on wide). */
const BANNER_PEEK_VP: number = 28;
const BANNER_MAX_HEIGHT_VP: number = 220;
const BANNER_MAX_DISPLAY_COUNT: number = 3;

@Component
struct HomeRecommendBannerPage {
  @Prop video: VideoItem = new VideoItem(0, '', '', '', '', '');
  @Prop bannerHeightVp: number = 200;
  onOpenVideo?: (video: VideoItem) => void;
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();

  private handleOpen(): void {
    if (this.onOpenVideo) {
      this.onOpenVideo(this.video);
      return;
    }
    this.actionHub.openVideo(this.video);
  }

  private getTitle(): string {
    const title = (this.video.title || '').trim();
    return title.length > 0 ? title : 'Untitled';
  }

  private getGradientHeight(): number {
    return Math.min(88, Math.max(56, Math.round(this.bannerHeightVp * 0.28)));
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      MediaThumb({
        imageUrl: this.video.thumbnailUrl || '',
        placeholderColor: this.video.thumbnailColor || '',
        fillParent: true,
        useAspectRatio: false,
        borderRadiusVp: 12
      })

      Column()
        .width('100%')
        .height(this.getGradientHeight())
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#99000000', 0.45], ['#E6000000', 1.0]]
        })

      Text(this.getTitle())
        .width('100%')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 12, right: 12, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .borderRadius(12)
    .clip(true)
    .onClick(() => {
      this.handleOpen();
    })
  }
}

@Component
export struct HomeRecommendSwiper {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageProp('deviceWidth') deviceWidthPx: number = 0;
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm';
  @Prop videos: VideoItem[] = [];
  onOpenVideo?: (video: VideoItem) => void;

  private getDeviceWidthVp(): number {
    const ui = this.getUIContext();
    return this.deviceWidthPx > 0 ? ui.px2vp(this.deviceWidthPx) : 360;
  }

  private getContentWidthVp(): number {
    return Math.max(200, this.getDeviceWidthVp() - this.getOuterPadVp() * 2);
  }

  private getOuterPadVp(): number {
    return this.currentBreakpoint === 'sm' ? BANNER_PHONE_OUTER_PAD_VP : 0;
  }

  /**
   * How many full cards fit in one viewport.
   * 1 on phone; 2/3 on tablet so one row shows more recommendations.
   */
  private getDisplayCount(): number {
    const videoCount = this.videos.length;
    if (videoCount <= 1) {
      return 1;
    }
    const contentW = this.getContentWidthVp();
    // Reserve room for side peeks when multi-card so neighbors still show a sliver.
    const usable = contentW - BANNER_PEEK_VP * 2;
    let count = Math.floor((usable + BANNER_ITEM_SPACE_VP) / (BANNER_CARD_TARGET_VP + BANNER_ITEM_SPACE_VP));
    if (count < 1) {
      count = 1;
    }
    if (count > BANNER_MAX_DISPLAY_COUNT) {
      count = BANNER_MAX_DISPLAY_COUNT;
    }
    // Don't ask Swiper for more columns than we have items.
    if (count > videoCount) {
      count = videoCount;
    }
    // Ensure each card stays above min width.
    while (count > 1) {
      const gaps = BANNER_ITEM_SPACE_VP * (count - 1);
      const peeks = BANNER_PEEK_VP * 2;
      const cardW = (contentW - peeks - gaps) / count;
      if (cardW >= BANNER_CARD_MIN_VP) {
        break;
      }
      count -= 1;
    }
    return count;
  }

  private getItemSpaceVp(): number {
    // Keep adjacent cards visually separated during a phone swipe as well.
    return this.videos.length > 1 ? BANNER_ITEM_SPACE_VP : 0;
  }

  private getPeekVp(): number {
    // Only multi-card mode peeks partial neighbors (extra cards beyond displayCount).
    return this.getDisplayCount() > 1 ? BANNER_PEEK_VP : 0;
  }

  private getBannerHeightVp(): number {
    const contentW = this.getContentWidthVp();
    const count = this.getDisplayCount();
    const gaps = this.getItemSpaceVp() * Math.max(0, count - 1);
    const peeks = this.getPeekVp() * 2;
    const cardW = Math.max(BANNER_CARD_MIN_VP, (contentW - peeks - gaps) / count);
    return Math.min(BANNER_MAX_HEIGHT_VP, Math.round(cardW * 9 / 16));
  }

  build() {
    Row() {
      Swiper() {
        ForEach(this.videos, (video: VideoItem) => {
          HomeRecommendBannerPage({
            video: video,
            bannerHeightVp: this.getBannerHeightVp(),
            onOpenVideo: this.onOpenVideo
          })
        }, (video: VideoItem) => `banner_${video.videoId || video.id}`)
      }
      .width('100%')
      .height(this.getBannerHeightVp())
      // Multi-card: one viewport shows N full recommendations (plus optional side peeks).
      .displayCount(this.getDisplayCount())
      .loop(this.videos.length > this.getDisplayCount())
      .autoPlay(this.videos.length > this.getDisplayCount())
      .interval(4000)
      .itemSpace(this.getItemSpaceVp())
      .prevMargin(this.getPeekVp())
      .nextMargin(this.getPeekVp())
      .indicator(
        Indicator.dot()
          .color('rgba(255,255,255,0.45)')
          .selectedColor(this.themePrimary)
          .itemWidth(6)
          .itemHeight(6)
          .selectedItemWidth(14)
          .selectedItemHeight(6)
      )
      .borderRadius(this.getDisplayCount() > 1 || this.getOuterPadVp() > 0 ? 12 : 0)
      .clip(false)
    }
    .width('100%')
    .height(this.getBannerHeightVp())
    .padding({ left: this.getOuterPadVp(), right: this.getOuterPadVp() })
    .visibility(this.videos.length > 0 ? Visibility.Visible : Visibility.None)
  }
}
