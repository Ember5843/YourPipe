import { UIConfig } from '../../../common/AppState';
import { VideoItem } from 'youtube_core';
import { VideoCard } from '../../../common/components/VideoCard';
import { VideoCardGrid } from '../../../common/components/VideoCardGrid';
import { getWideListColumnCount } from '../../../common/utils/ListLayoutUtils';
import { resolveResourceStr } from '../../../common/utils/ResourceStrUtil';
import { customAnimationUtil } from '../../../common/AnimationUtil';

const GRID_SIDE_PADDING: number = 12;

/**
 * 频道页视频类 Tab（视频 / Shorts / 直播共用）：
 * 加载中 / 错误 / 空态 + grid / 宽屏多列 / 单列列表三种布局 + 触底加载更多。
 * 状态由父级 UserPage 通过 @Prop 单向注入，加载行为经 onLoadMore 回调。
 */
@Component
export struct ChannelVideoTab {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;

  @Prop list: VideoItem[] = [];
  @Prop isLoading: boolean = false;
  @Prop isLoadingMore: boolean = false;
  @Prop errorMessage: ResourceStr = '';
  @Prop emptyText: Resource = $r('app.string.yt_empty_no_videos');
  scroller: Scroller = new Scroller();
  onLoadMore: () => void = () => {};

  private getVideoGridColumnCount(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - GRID_SIDE_PADDING * 2);
    if (contentWidth >= 1440) {
      return 5;
    }
    if (contentWidth >= 1080) {
      return 4;
    }
    if (contentWidth >= 760) {
      return 3;
    }
    if (contentWidth >= 520) {
      return 2;
    }
    return 1;
  }

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - GRID_SIDE_PADDING * 2);
    return getWideListColumnCount(contentWidth);
  }

  @Builder
  LoadingMoreFooter() {
    Row() {
      LoadingProgress()
        .color(this.themePrimary)
        .width(26)
        .height(26)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  VideoGridCard(item: VideoItem) {
    VideoCardGrid({
      video: item,
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      showAuthor: false,
      useFavoriteToggle: true
    })
  }

  @Builder
  VideoListCard(item: VideoItem) {
    VideoCard({
      video: item,
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      showAuthor: false,
      useFavoriteToggle: true
    })
  }

  build() {
    Column() {
      if (this.isLoading) {
        Row() {
          LoadingProgress()
            .color(this.themePrimary)
            .width(30)
            .height(30)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 20 })
      } else if (resolveResourceStr(this.errorMessage).length > 0) {
        Text(resolveResourceStr(this.errorMessage))
          .fontSize(12)
          .fontColor(this.themePrimary)
          .margin({ left: 16, top: 12 })
      } else if (this.list.length === 0) {
        Text(this.emptyText)
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ top: 20 })
          .width('100%')
          .textAlign(TextAlign.Center)
      } else if (this.uiConfig.homeLayoutMode === 'grid') {
        Scroll() {
          Column() {
            GridRow({
              columns: this.getVideoGridColumnCount(),
              gutter: { x: 8, y: 8 }
            }) {
              ForEach(this.list, (item: VideoItem) => {
                GridCol({ span: 1 }) {
                  this.VideoGridCard(item)
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')

            if (this.isLoadingMore) {
              this.LoadingMoreFooter()
            }
          }
          .width('100%')
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .layoutWeight(1)
        .onReachEnd(() => {
          this.onLoadMore();
        })
      } else if (this.getWideListColumns() > 1) {
        Scroll() {
          Column() {
            GridRow({
              columns: this.getWideListColumns(),
              gutter: { x: 8, y: 4 }
            }) {
              ForEach(this.list, (item: VideoItem) => {
                GridCol({ span: 1 }) {
                  this.VideoListCard(item)
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')

            if (this.isLoadingMore) {
              this.LoadingMoreFooter()
            }
          }
          .width('100%')
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .layoutWeight(1)
        .onReachEnd(() => {
          this.onLoadMore();
        })
      } else {
        List({ space: 4, scroller: this.scroller }) {
          ForEach(this.list, (item: VideoItem) => {
            ListItem() {
              this.VideoListCard(item)
            }
            .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
          }, (item: VideoItem) => item.videoId || item.id.toString())

          if (this.isLoadingMore) {
            ListItem() {
              this.LoadingMoreFooter()
            }
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .layoutWeight(1)
        .onReachEnd(() => {
          this.onLoadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
