import { VideoItem } from 'youtube_core';
import { PlayerSession } from '../../common/PlayerSession';
import {
  PlayQueueManager,
  QueueSourceType
} from './PlayQueueManager';

const PAYLOAD_KEY = 'yourpipePlaybackContinuation';
const SCHEMA_VERSION = 1;
const MAX_QUEUE_ITEMS = 50;

export interface ContinuationVideoSnapshot {
  id: number;
  videoId: string;
  title: string;
  author: string;
  viewCount: string;
  thumbnailUrl: string;
  isLive: boolean;
  thumbnailColor: string;
  channelId: string;
  channelAvatarUrl: string;
  channelHandle: string;
  videoDescription: string;
}

export interface PlaybackContinuationQueuePayload {
  items: ContinuationVideoSnapshot[];
  currentIndex: number;
  sourceType: string;
  sourceId: string;
  sourceName: string;
}

export interface PlaybackContinuationPayload {
  schemaVersion: number;
  video: ContinuationVideoSnapshot;
  videoId: string;
  title: string;
  author: string;
  thumbnailUrl: string;
  durationSec: number;
  progressSec: number;
  wasPlaying: boolean;
  queue: PlaybackContinuationQueuePayload;
}

export interface PlaybackContinuationRestoreRequest {
  video: VideoItem;
  progressSec: number;
  wasPlaying: boolean;
  queue: PlaybackContinuationRestoreQueue;
}

export interface PlaybackContinuationRestoreQueue {
  items: VideoItem[];
  currentIndex: number;
  sourceType: QueueSourceType;
  sourceId: string;
  sourceName: string;
}

function safeString(value: string | undefined | null): string {
  return value || '';
}

function sanitizeNumber(value: number, fallback: number = 0): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

export class PlaybackContinuationService {
  static readonly WANT_PAYLOAD_KEY: string = PAYLOAD_KEY;
  static readonly APP_STORAGE_PENDING_KEY: string = 'pendingPlaybackContinuation';

  static buildPayload(): PlaybackContinuationPayload | null {
    const session = PlayerSession.getInstance();
    const currentVideo = session.currentVideo || PlayQueueManager.getInstance().getCurrent();
    if (!currentVideo || !currentVideo.videoId || session.isReleased) {
      return null;
    }

    const controller = session.controller;
    if (!controller.vm.isReady || controller.vm.errorMsg) {
      return null;
    }

    const queueSnapshot = PlayQueueManager.getInstance().exportSnapshot(MAX_QUEUE_ITEMS);
    const video = PlaybackContinuationService.toVideoSnapshot(currentVideo);
    const queue: PlaybackContinuationQueuePayload = {
      items: queueSnapshot.items.map((item: VideoItem) => PlaybackContinuationService.toVideoSnapshot(item)),
      currentIndex: queueSnapshot.currentIndex,
      sourceType: queueSnapshot.sourceType,
      sourceId: queueSnapshot.sourceId,
      sourceName: queueSnapshot.sourceName
    };
    const payload: PlaybackContinuationPayload = {
      schemaVersion: SCHEMA_VERSION,
      video: video,
      videoId: video.videoId,
      title: video.title,
      author: video.author,
      thumbnailUrl: video.thumbnailUrl,
      durationSec: sanitizeNumber(controller.vm.durationTime),
      progressSec: sanitizeNumber(controller.vm.currentTime),
      wasPlaying: controller.vm.isPlaying,
      queue: queue
    };
    return payload;
  }

  static writeWantParam(wantParam: Record<string, Object>): boolean {
    const payload = PlaybackContinuationService.buildPayload();
    if (!payload) {
      return false;
    }
    const json = JSON.stringify(payload);
    if (!PlaybackContinuationService.isPayloadSafe(json)) {
      return false;
    }
    wantParam[PAYLOAD_KEY] = json;
    return true;
  }

  static extractFromWantParameters(parameters?: Record<string, Object>): PlaybackContinuationPayload | null {
    if (!parameters) {
      return null;
    }
    const raw = parameters[PAYLOAD_KEY];
    if (typeof raw !== 'string') {
      return null;
    }
    return PlaybackContinuationService.parsePayload(raw);
  }

  static parsePayload(raw: string): PlaybackContinuationPayload | null {
    if (!raw || !PlaybackContinuationService.isPayloadSafe(raw)) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as PlaybackContinuationPayload;
      if (parsed.schemaVersion !== SCHEMA_VERSION || !parsed.videoId || !parsed.video?.videoId) {
        return null;
      }
      return parsed;
    } catch (_e) {
      return null;
    }
  }

  static toRestoreRequest(payload: PlaybackContinuationPayload): PlaybackContinuationRestoreRequest | null {
    const video = PlaybackContinuationService.fromVideoSnapshot(payload.video);
    if (!video) {
      return null;
    }

    const queueItems: VideoItem[] = [];
    const rawItems = payload.queue?.items || [];
    for (const item of rawItems) {
      const video = PlaybackContinuationService.fromVideoSnapshot(item);
      if (video) {
        queueItems.push(video);
      }
    }
    const fallbackItems = queueItems.length > 0 ? queueItems : [video];
    const sourceType = PlaybackContinuationService.parseQueueSourceType(payload.queue?.sourceType);

    const queue: PlaybackContinuationRestoreQueue = {
      items: fallbackItems,
      currentIndex: payload.queue?.currentIndex ?? 0,
      sourceType: sourceType,
      sourceId: safeString(payload.queue?.sourceId),
      sourceName: safeString(payload.queue?.sourceName)
    };
    const request: PlaybackContinuationRestoreRequest = {
      video: video,
      progressSec: sanitizeNumber(payload.progressSec),
      wasPlaying: payload.wasPlaying === true,
      queue: queue
    };
    return request;
  }

  private static toVideoSnapshot(video: VideoItem): ContinuationVideoSnapshot {
    return {
      id: video.id || 0,
      videoId: safeString(video.videoId),
      title: safeString(video.title),
      author: safeString(video.author),
      viewCount: safeString(video.viewCount),
      thumbnailUrl: safeString(video.thumbnailUrl),
      isLive: video.isLive === true,
      thumbnailColor: safeString(video.thumbnailColor) || '#CCCCCC',
      channelId: safeString(video.channelId),
      channelAvatarUrl: safeString(video.channelAvatarUrl),
      channelHandle: safeString(video.channelHandle),
      videoDescription: safeString(video.videoDescription)
    };
  }

  private static fromVideoSnapshot(snapshot: ContinuationVideoSnapshot | undefined): VideoItem | null {
    if (!snapshot || !snapshot.videoId) {
      return null;
    }
    return new VideoItem(
      snapshot.id || 0,
      snapshot.videoId,
      safeString(snapshot.title),
      safeString(snapshot.author),
      safeString(snapshot.viewCount),
      safeString(snapshot.thumbnailUrl),
      snapshot.isLive === true,
      safeString(snapshot.thumbnailColor) || '#CCCCCC',
      safeString(snapshot.channelId),
      safeString(snapshot.channelAvatarUrl),
      safeString(snapshot.channelHandle),
      safeString(snapshot.videoDescription),
      null
    );
  }

  private static parseQueueSourceType(value: string | undefined): QueueSourceType {
    switch (value) {
      case QueueSourceType.REMOTE:
        return QueueSourceType.REMOTE;
      case QueueSourceType.LOCAL:
        return QueueSourceType.LOCAL;
      case QueueSourceType.ADHOC:
        return QueueSourceType.ADHOC;
      default:
        return QueueSourceType.ADHOC;
    }
  }

  private static isPayloadSafe(raw: string): boolean {
    const lower = raw.toLowerCase();
    return !lower.includes('cookie')
      && !lower.includes('headers')
      && !lower.includes('http://127.0.0.1')
      && !lower.includes('http://localhost')
      && !lower.includes('signaturecipher')
      && !lower.includes('"url"');
  }
}
