export interface OtfSegmentTimelineEntry {
  durationMs: number;
  repeat: number;
}

export interface StreamResource {
  id: string;
  url: string;
  mimeType: string;
  codecs: string;
  initRangeStart: string;
  initRangeEnd: string;
  indexRangeStart: string;
  indexRangeEnd: string;
  userAgent: string;
  referer: string;
  contentLength: number;
  bitrate: number;
  width: number;
  height: number;
  fps: number;
  approxDurationMs: number;
  isAudio: boolean;
  isYoutubePlayback: boolean;
  isOtf: boolean;
  sourceClient: string;
  otfPrepared: boolean;
  otfDurationMs: number;
  otfSegmentTimeline: OtfSegmentTimelineEntry[];
}

export interface SidxSegment {
  offset: number;
  size: number;
  duration: number;
}

export interface HlsCache {
  fetched: boolean;
  valid: boolean;
  segments: SidxSegment[];
  initOffset: number;
  initSize: number;
  targetDuration: number;
  cachedPlaylist: string;
}

export type SessionType = 'single' | 'youtube-dual';

export interface DashSession {
  id: string;
  type: SessionType;
  durationMs: number;
  single: StreamResource;
  video: StreamResource;
  audio: StreamResource;
  videos: StreamResource[];
  audios: StreamResource[];
  hasAudio: boolean;
  videoHls: HlsCache;
  audioHls: HlsCache;
  stale: boolean;
  cancel?: () => void;
  refreshUrls?: () => Promise<boolean>;  // 当 URL 过期(411)时调用此回调刷新
}

function emptyResource(): StreamResource {
  return {
    id: '', url: '', mimeType: '', codecs: '',
    initRangeStart: '', initRangeEnd: '',
    indexRangeStart: '', indexRangeEnd: '',
    userAgent: '', referer: '',
    contentLength: 0, bitrate: 0,
    width: 0, height: 0, fps: 0, approxDurationMs: 0,
    isAudio: false, isYoutubePlayback: false, isOtf: false,
    sourceClient: '', otfPrepared: false, otfDurationMs: 0, otfSegmentTimeline: [],
  };
}

function emptyHlsCache(): HlsCache {
  return { fetched: false, valid: false, segments: [], initOffset: 0, initSize: 0, targetDuration: 0, cachedPlaylist: '' };
}

export function makeEmptySession(id: string): DashSession {
  return {
    id, type: 'youtube-dual', durationMs: 0,
    single: emptyResource(), video: emptyResource(), audio: emptyResource(),
    videos: [], audios: [], hasAudio: false,
    videoHls: emptyHlsCache(), audioHls: emptyHlsCache(),
    stale: false,
  };
}

class SessionStore {
  private sessions: Map<string, DashSession> = new Map();
  private nextId: number = 1;

  makeId(): string {
    return `s${Date.now()}_${this.nextId++}`;
  }

  add(session: DashSession): string {
    if (!session.id) {
      session.id = this.makeId();
    }
    this.sessions.set(session.id, session);
    return session.id;
  }

  get(id: string): DashSession | undefined {
    return this.sessions.get(id);
  }

  remove(id: string): boolean {
    return this.sessions.delete(id);
  }

  clear(): void {
    this.sessions.clear();
  }
}

export const sessionStore = new SessionStore();
