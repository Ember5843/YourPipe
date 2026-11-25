import { VideoItem } from 'youtube_core';

/** Persist product metadata explicitly; enrichment flags are recomputed after restore. */
export class VideoItemPersistence {
  static restore(record: Record<string, Object>): VideoItem {
    const text = (key: string): string => typeof record[key] === 'string' ? record[key] as string : '';
    const video = new VideoItem(typeof record['id'] === 'number' ? record['id'] as number : 0,
      text('videoId'), text('title'), text('author'), text('viewCount'), text('thumbnailUrl'),
      record['isLive'] === true, text('thumbnailColor') || '#CCCCCC', text('channelId'),
      text('channelAvatarUrl'), text('channelHandle'), text('videoDescription'),
      text('videoDescriptionError') || null, record['isPremium'] === true, record['requiresMembership'] === true);
    video.originalThumbnailUrl = text('originalThumbnailUrl');
    video.publishedTimeText = text('publishedTimeText');
    video.durationText = text('durationText');
    video.viewCountExact = text('viewCountExact');
    video.uploaderVerified = record['uploaderVerified'] === true;
    video.isShort = record['isShort'] === true;
    video.localMediaPath = text('localMediaPath') || undefined;
    return video;
  }

  static record(video: VideoItem): Record<string, Object> {
    return {
      'id': video.id, 'videoId': video.videoId, 'title': video.title, 'author': video.author,
      'viewCount': video.viewCount, 'thumbnailUrl': video.thumbnailUrl,
      'originalThumbnailUrl': video.originalThumbnailUrl || '', 'thumbnailColor': video.thumbnailColor,
      'isLive': video.isLive, 'isPremium': video.isPremium, 'requiresMembership': video.requiresMembership,
      'channelId': video.channelId, 'channelAvatarUrl': video.channelAvatarUrl, 'channelHandle': video.channelHandle,
      'videoDescription': video.videoDescription, 'videoDescriptionError': video.videoDescriptionError || '',
      'publishedTimeText': video.publishedTimeText || '', 'durationText': video.durationText || '',
      'viewCountExact': video.viewCountExact || '', 'uploaderVerified': video.uploaderVerified === true,
      'isShort': video.isShort === true, 'localMediaPath': video.localMediaPath || ''
    };
  }
}
