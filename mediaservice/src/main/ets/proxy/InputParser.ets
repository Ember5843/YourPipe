import { DashSession, StreamResource, makeEmptySession } from './SessionStore';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerLog][InputParser]';

interface RawResource {
  id?: string;
  url?: string;
  mimeType?: string;
  codecs?: string;
  initRangeStart?: number;
  initRangeEnd?: number;
  indexRangeStart?: number;
  indexRangeEnd?: number;
  contentLength?: number;
  bitrate?: number;
  width?: number;
  height?: number;
  fps?: number;
  approxDurationMs?: number;
  itag?: number;
  isOtf?: boolean;
  userAgent?: string;
  referer?: string;
  sourceClient?: string;
}

interface RawInput {
  type?: string;
  durationMs?: number;
  userAgent?: string;
  resource?: RawResource;
  videos?: RawResource[];
  audios?: RawResource[];
}

function isYoutubeUrl(url: string): boolean {
  return url.includes('googlevideo.com') || url.includes('youtube.com/videoplayback');
}

function toResource(raw: RawResource, isAudio: boolean, fallbackUa: string): StreamResource {
  const url = raw.url ?? '';
  return {
    id: raw.itag !== undefined ? String(raw.itag) : (raw.id ?? (isAudio ? 'audio' : 'video')),
    url,
    mimeType: raw.mimeType ?? '',
    codecs: raw.codecs ?? '',
    initRangeStart: raw.initRangeStart !== undefined ? String(raw.initRangeStart) : '',
    initRangeEnd: raw.initRangeEnd !== undefined ? String(raw.initRangeEnd) : '',
    indexRangeStart: raw.indexRangeStart !== undefined ? String(raw.indexRangeStart) : '',
    indexRangeEnd: raw.indexRangeEnd !== undefined ? String(raw.indexRangeEnd) : '',
    userAgent: raw.userAgent ?? fallbackUa,
    referer: raw.referer ?? '',
    contentLength: raw.contentLength ?? 0,
    bitrate: raw.bitrate ?? 0,
    width: raw.width ?? 0,
    height: raw.height ?? 0,
    fps: raw.fps ?? 0,
    approxDurationMs: raw.approxDurationMs ?? 0,
    isAudio,
    isYoutubePlayback: isYoutubeUrl(url),
    isOtf: raw.isOtf ?? false,
    sourceClient: raw.sourceClient ?? '',
  };
}

export function parseInputJson(inputJson: string): DashSession {
  let raw: RawInput;
  try {
    raw = JSON.parse(inputJson) as RawInput;
  } catch (e) {
    Logger.error(TAG, `parseInputJson failed: ${e}`);
    return makeEmptySession('');
  }

  const session = makeEmptySession('');
  const ua = raw.userAgent ?? '';

  if (raw.type === 'single' && raw.resource) {
    session.type = 'single';
    session.single = toResource(raw.resource, false, ua);
    session.durationMs = raw.durationMs ?? 0;
    return session;
  }

  session.type = 'youtube-dual';
  session.durationMs = raw.durationMs ?? 0;

  if (raw.videos && raw.videos.length > 0) {
    session.videos = raw.videos.map(v => toResource(v, false, ua));
    session.video = session.videos[0];
  }
  if (raw.audios && raw.audios.length > 0) {
    session.audios = raw.audios.map(a => toResource(a, true, ua));
    session.audio = session.audios[0];
    session.hasAudio = true;
  }
  return session;
}
