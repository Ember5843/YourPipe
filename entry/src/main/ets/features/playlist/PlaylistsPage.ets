import { AppLog } from '../../common/AppLog';
import { PlaylistItem } from '../../common/PlaylistModel';
import { SearchPlaylistItem } from 'youtube_core';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { PlaylistCard } from '../../features/playlist/components/PlaylistCard';
import { UIConfig } from '../../common/AppState';

import {customAnimationUtil } from '../../common/AnimationUtil';

const logger = AppLog.getInstance('PlaylistsPage');

@Component
export struct PlaylistsPage {
  @StorageLink('playlists') playlists: PlaylistItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State overviewMap: Record<string, SearchPlaylistItem> = {};
  @State isLoading: boolean = false;
  @State errorMessage: string = '';


  aboutToAppear(): void {
    this.loadOverviews();
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
    this.isLoading = true;
    this.errorMessage = '';
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
      this.errorMessage = getContext().resourceManager.getStringSync($r('app.string.yt_error_load_playlists').id);
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    List({ space: 4 }) {
      ListItem() {
        Text($r('app.string.yt_tab_playlists'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (!this.playlists || this.playlists.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_playlists'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
            Text($r('app.string.yt_empty_playlists_hint'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      }
      else {
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
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 12 })
    .edgeEffect(EdgeEffect.Spring)
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
    //.chainAnimation(true)
  }
}
