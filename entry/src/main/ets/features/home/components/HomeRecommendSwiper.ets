import { VideoItem } from 'youtube_core';
import { ActionHub } from '../../../common/ActionHub';
import { MediaThumb } from '../../../common/components/MediaThumb';

@Component
struct HomeRecommendBannerPage {
  @Prop video: VideoItem = new VideoItem(0, '', '', '', '', '');
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

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      MediaThumb({
        imageUrl: this.video.thumbnailUrl || '',
        placeholderColor: this.video.thumbnailColor || '',
        fillParent: true,
        useAspectRatio: true,
        borderRadiusVp: 12
      })

      // 底部深色渐变：同时衬托标题与 Swiper 指示点，避免封面干扰
      Column()
        .width('100%')
        .height(88)
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
        .padding({ left: 12, right: 12, bottom: 30 })
    }
    .width('100%')
    .aspectRatio(16 / 9)
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
  @Prop videos: VideoItem[] = [];
  onOpenVideo?: (video: VideoItem) => void;

  build() {
    Swiper() {
      ForEach(this.videos, (video: VideoItem) => {
        HomeRecommendBannerPage({
          video: video,
          onOpenVideo: this.onOpenVideo
        })
      }, (video: VideoItem) => `banner_${video.videoId || video.id}`)
    }
    .width('100%')
    .loop(this.videos.length > 1)
    .autoPlay(this.videos.length > 1)
    .interval(4000)
    .indicator(
      Indicator.dot()
        .color('rgba(255,255,255,0.45)')
        .selectedColor(this.themePrimary)
        .itemWidth(6)
        .itemHeight(6)
        .selectedItemWidth(14)
        .selectedItemHeight(6)
    )
    .itemSpace(0)
    .borderRadius(12)
    .clip(true)
    .visibility(this.videos.length > 0 ? Visibility.Visible : Visibility.None)
  }
}
