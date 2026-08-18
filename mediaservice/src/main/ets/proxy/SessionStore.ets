import { SabrTrackBuffer } from '../sabr/SabrTrackBuffer';
import { YoutubeDashSegment } from './YoutubeDashIndex';

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
  dashSegments?: YoutubeDashSegment[];
}

export type SessionType = 'single' | 'youtube-dual' | 'sabr-dual';

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
  stale: boolean;
  cancel?: () => void;
  /** SABR lease key for session store release. */
  sabrLeaseKey?: string;
  sabrVideoBuffer?: SabrTrackBuffer;
  sabrAudioBuffer?: SabrTrackBuffer;
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
    sourceClient: '',
  };
}

export function makeEmptySession(id: string): DashSession {
  return {
    id, type: 'youtube-dual', durationMs: 0,
    single: emptyResource(), video: emptyResource(), audio: emptyResource(),
    videos: [], audios: [], hasAudio: false,
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

  ids(): string[] {
    return Array.from(this.sessions.keys());
  }
}

export const sessionStore = new SessionStore();
