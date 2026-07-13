import { VideoItem } from 'youtube_core';
import { VideoMediaCard } from './VideoMediaCard';

/**
 * List-style video entry. Thin wrapper over VideoMediaCard.
 */
@Component
export struct VideoCard {
  @Prop video: VideoItem;
  @Prop actionLabel: ResourceStr = '';
  @Prop actionType: string = '';
  @Prop enableOpen: boolean = true;
  @Prop typeLabel: ResourceStr = '';
  @Prop showAuthor: boolean = true;
  @Prop showViewCount: boolean = true;
  @Prop showLiveTag: boolean = true;
  @Prop useFavoriteToggle: boolean = false;
  onOpenVideo?: (video: VideoItem) => void;

  build() {
    VideoMediaCard({
      video: this.video,
      layoutMode: 'list',
      actionLabel: this.actionLabel,
      actionType: this.actionType,
      enableOpen: this.enableOpen,
      typeLabel: this.typeLabel,
      showAuthor: this.showAuthor,
      showViewCount: this.showViewCount,
      showLiveTag: this.showLiveTag,
      useFavoriteToggle: this.useFavoriteToggle,
      onOpenVideo: this.onOpenVideo
    })
  }
}
