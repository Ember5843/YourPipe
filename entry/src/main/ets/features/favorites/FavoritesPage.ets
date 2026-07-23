import { AppLog } from '../../common/AppLog';
import { VideoItem } from 'youtube_core';
import { PlaylistItem, StoredLocalQueue } from '../../common/PlaylistModel';
import { SearchPlaylistItem } from 'youtube_core';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { PlaylistCard } from '../../features/playlist/components/PlaylistCard';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';


const logger = AppLog.getInstance('FavoritesPage');

@Component
export struct FavoritesPage {
  @StorageLink('favorites') favorites: VideoItem[] = [];
  @StorageLink('playlists') playlists: PlaylistItem[] = [];
  @StorageLink('localQueues') localQueues: StoredLocalQueue[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State overviewMap: Record<string, SearchPlaylistItem> = {};
  @State isLoading: boolean = false;
  private readonly GRID_SIDE_PADDING: number = 12;


  aboutToAppear(): void {
    this.loadOverviews();
  }

  aboutToShow(): void {
    this.loadOverviews();
  }

  private getVideoGridColumnCount(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
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

  private buildPlaceholder(item: PlaylistItem, index: number): SearchPlaylistItem {
    return new SearchPlaylistItem(
      index,
      item.playlistId,
      item.title || item.playlistId,
      '',
      '',
      item.coverUrl || '',
      '',
      '#CCCCCC'
    );
  }

  /** 把本地播放列表快照转成 PlaylistCard 可渲染的 SearchPlaylistItem，封面取首个视频缩略图。 */
  private buildLocalPlaylistItem(queue: StoredLocalQueue, index: number): SearchPlaylistItem {
    const cover = queue.videos.length > 0 ? (queue.videos[0].thumbnailUrl || '') : '';
    const ctx = this.getUIContext().getHostContext();
    const countText = ctx
      ? `${queue.videos.length} ${ctx.resourceManager.getStringSync($r('app.string.yt_label_favorites_videos'))}`
      : '';
    return new SearchPlaylistItem(
      index,
      queue.id,
      queue.name || '',
      '',
      countText,
      cover,
      '',
      '#CCCCCC'
    );
  }

  private async fetchOverview(item: PlaylistItem, index: number): Promise<SearchPlaylistItem> {
    const placeholder = this.buildPlaceholder(item, index);
    const playlistId = (item.playlistId || '').trim();
    if (!playlistId) {
      return placeholder;
    }
    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const result = await service.fetchPlaylistOverview(playlistId);
      const countText = result && result.videoCountText && result.videoCountText.length > 0
        ? result.videoCountText
        : '';
      const coverUrl = result && result.coverUrl && result.coverUrl.length > 0
        ? result.coverUrl
        : (item.coverUrl || '');
      return new SearchPlaylistItem(
        index,
        playlistId,
        item.title || playlistId,
        '',
        countText,
        coverUrl,
        '',
        '#CCCCCC'
      );
    } catch (err) {
      logger.error('fetchOverview failed:', JSON.stringify(err));
      return placeholder;
    }
  }

  private async loadOverviews(): Promise<void> {
    if (this.playlists.length === 0) {
      return;
    }
    this.isLoading = true;
    try {
      const tasks = this.playlists.map((item, index) => this.fetchOverview(item, index));
      const results = await Promise.all(tasks);
      const next: Record<string, SearchPlaylistItem> = {};
      results.forEach((item) => {
        if (item.playlistId) {
          next[item.playlistId] = item;
        }
      });
      this.overviewMap = next;
    } catch (err) {
      logger.error('loadOverviews failed:', JSON.stringify(err));
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    List({ space: 4 }) {
      // 收藏的视频部分
      ListItem() {
        Text($r('app.string.yt_fav_videos_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.favorites || this.favorites.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_fav_videos'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        if (this.uiConfig.homeLayoutMode === 'grid') {
          ListItem() {
            GridRow({
              columns: this.getVideoGridColumnCount(),
              gutter: { x: 8, y: 8 }
            }) {
              ForEach(this.favorites, (item: VideoItem) => {
                GridCol({ span: 1 }) {
                  VideoCardGrid({
                    video: item,
                    actionLabel: $r('app.string.yt_action_unfavorite'),
                    actionType: 'remove',
                    showViewCount: false,
                    showLiveTag: false
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')
          }
        } else {
          ForEach(this.favorites, (item: VideoItem) => {
            ListItem() {
              VideoCard({
                video: item,
                actionLabel: $r('app.string.yt_action_unfavorite'),
                actionType: 'remove',
                showViewCount: false,
                showLiveTag: false
              })
            }
            .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
          }, (item: VideoItem) => item.videoId || item.id.toString())
        }
      }

      // 收藏的播放列表部分
      ListItem() {
        Text($r('app.string.yt_fav_playlists_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 24, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.playlists || this.playlists.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_fav_playlists'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
            Text($r('app.string.yt_empty_fav_playlists_hint'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        ForEach(this.playlists, (item: PlaylistItem, index: number) => {
          ListItem() {
            PlaylistCard({
              playlist: this.overviewMap[item.playlistId]
                ? this.overviewMap[item.playlistId]
                : this.buildPlaceholder(item, index),
              typeLabel: $r('app.string.yt_filter_playlists'),
              forceActionLabel: $r('app.string.yt_action_unfavorite')
            })
          }
          .transition(customAnimationUtil.isScaleTran(item.playlistId, this.uiConfig))
        }, (item: PlaylistItem) => item.playlistId)
      }

      // 本地播放列表部分
      ListItem() {
        Text($r('app.string.yt_local_playlists_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 24, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.localQueues || this.localQueues.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_local_playlists'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
            Text($r('app.string.yt_empty_local_playlists_hint'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        ForEach(this.localQueues, (queue: StoredLocalQueue, index: number) => {
          ListItem() {
            PlaylistCard({
              playlist: this.buildLocalPlaylistItem(queue, index),
              typeLabel: $r('app.string.yt_local_playlists_tag')
            })
          }
          .transition(customAnimationUtil.isScaleTran(queue.id, this.uiConfig))
        }, (queue: StoredLocalQueue) => queue.id + queue.videos.length)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.safeAreaTop + 56, bottom: this.safeAreaBottom + 72 })
    .edgeEffect(EdgeEffect.Spring)
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
