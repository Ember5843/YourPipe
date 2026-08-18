import { StreamInfo, StreamRange } from './StreamInfo';
import { DeliveryMethod } from '../model/DeliveryType';
import { YTCoreLogger } from '../common/YTCoreLogger';

const logger = YTCoreLogger.getInstance('HlsManifestParser');

/**
 * Parse HLS master manifest into StreamInfo arrays.
 * Ported from org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor.parseHlsMasterManifest
 */
export interface HlsManifestResult {
  videoStreams: StreamInfo[];
  audioStreams: StreamInfo[];
}

/** Single constructor for HLS audio StreamInfo (was two drifted copies). */
function buildHlsAudioStream(
  url: string,
  language: string | undefined,
  trackId: string | undefined,
  trackName: string | undefined
): StreamInfo {
  return {
    url: url,
    itag: undefined,
    mimeType: 'audio/mp4',
    qualityLabel: undefined,
    audioQuality: undefined,
    bitrate: undefined,
    contentLength: undefined,
    hasVideo: false,
    hasAudio: true,
    deliveryMethod: DeliveryMethod.HLS,
    kind: 'audio_only',
    sourceClient: 'hls',
    container: 'm4a',
    codecs: undefined,
    initRange: undefined,
    indexRange: undefined,
    approxDurationMs: undefined,
    durationMs: undefined,
    isLive: undefined,
    isOtf: undefined,
    audioLanguage: language,
    audioTrackId: trackId,
    audioTrackName: trackName,
    audioTrackType: undefined,
    audioChannels: undefined,
    audioSampleRate: undefined,
    videoFps: undefined,
    codec: undefined,
    width: undefined,
    height: undefined,
  };
}

export function parseHlsMasterManifest(manifestContent: string, videoId: string): HlsManifestResult {
  const lines = manifestContent.split('\n');
  const videoStreams: StreamInfo[] = [];
  const audioStreams: StreamInfo[] = [];

  const audioTrackUrls = new Map<string, string>();
  const audioTrackNames = new Map<string, string>();
  const audioTrackLocales = new Map<string, string>();
  const audioTrackAconts = new Map<string, string>();

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) {
      continue;
    }
    if (i + 1 >= lines.length) {
      break;
    }
    const streamUrl = lines[i + 1].trim();
    if (streamUrl.length === 0 || streamUrl.startsWith('#')) {
      continue;
    }

    const resolution = extractHlsStringAttribute(line, 'RESOLUTION');
    const codecs = extractHlsStringAttribute(line, 'CODECS');
    const frameRate = extractHlsAttribute(line, 'FRAME-RATE');
    const audioContentId = extractHlsStringAttribute(line, 'YT-EXT-AUDIO-CONTENT-ID');

    let videoCodec: string | undefined;
    if (codecs) {
      for (const c of codecs.split(',')) {
        const trimmed = c.trim();
        if (!trimmed.startsWith('mp4a') && !trimmed.startsWith('opus')
          && !trimmed.startsWith('ac-3') && !trimmed.startsWith('ec-3')) {
          videoCodec = trimmed;
          break;
        }
      }
    }

    const acont = extractHlsXtagsValue(streamUrl, 'acont');

    if (resolution && resolution.length > 0) {
      const resParts = resolution.split('x');
      const height = resParts.length === 2 ? resParts[1] + 'p' : resolution;
      const resString = frameRate > 30 ? height + frameRate : height;

      let audioTrackId: string | undefined;
      let audioLocale: string | undefined;
      let audioTrackName: string | undefined;
      if (audioContentId && audioContentId.length > 0) {
        audioTrackId = audioContentId;
        const langPart = audioContentId.split('.')[0];
        audioLocale = langPart.split('-')[0];
        // Raw id only — no synthesized "(original)" label.
        audioTrackName = audioContentId;

        if (!audioTrackUrls.has(audioTrackId) || acont === 'original') {
          audioTrackUrls.set(audioTrackId, streamUrl);
        }
        audioTrackNames.set(audioTrackId, audioTrackName);
        audioTrackLocales.set(audioTrackId, audioLocale);
        if (acont) {
          audioTrackAconts.set(audioTrackId, acont);
        }
      }

      const streamId = 'hls-' + videoId + '-' + resString + (audioTrackId ? '-' + audioTrackId : '');

      const stream: StreamInfo = {
        url: streamUrl,
        itag: undefined,
        mimeType: 'video/mp2t',
        qualityLabel: resString,
        audioQuality: undefined,
        bitrate: undefined,
        contentLength: undefined,
        hasVideo: true,
        hasAudio: audioTrackId !== undefined,
        deliveryMethod: DeliveryMethod.HLS,
        kind: audioTrackId !== undefined ? 'progressive' : 'video_only',
        sourceClient: 'hls',
        container: 'mpeg-ts',
        codecs: videoCodec,
        initRange: undefined,
        indexRange: undefined,
        approxDurationMs: undefined,
        durationMs: undefined,
        isLive: undefined,
        isOtf: undefined,
        audioLanguage: audioLocale,
        audioTrackId: audioTrackId,
        audioTrackName: audioTrackName,
        audioTrackType: acont,
        audioChannels: undefined,
        audioSampleRate: undefined,
        videoFps: frameRate > 0 ? frameRate : undefined,
        codec: videoCodec,
        width: resParts.length === 2 ? parseInt(resParts[0], 10) : undefined,
        height: resParts.length === 2 ? parseInt(resParts[1], 10) : undefined,
      };

      videoStreams.push(stream);
    }
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('#EXT-X-MEDIA:') || !line.includes('TYPE=AUDIO')) {
      continue;
    }
    const uri = extractHlsStringAttribute(line, 'URI');
    if (!uri || uri.length === 0) {
      continue;
    }

    const groupId = extractHlsStringAttribute(line, 'GROUP-ID');
    const name = extractHlsStringAttribute(line, 'NAME');
    const language = extractHlsStringAttribute(line, 'LANGUAGE');

    audioStreams.push(buildHlsAudioStream(uri, language, groupId || language, name));
  }

  if (audioStreams.length === 0 && audioTrackUrls.size > 0) {
    const trackEntries = audioTrackUrls.entries();
    let trackNext = trackEntries.next();
    while (!trackNext.done) {
      const trackId = trackNext.value[0];
      const url = trackNext.value[1];
      const trackName = audioTrackNames.get(trackId);
      const locale = audioTrackLocales.get(trackId);

      audioStreams.push(buildHlsAudioStream(url, locale, trackId, trackName));
      trackNext = trackEntries.next();
    }
  }

  return { videoStreams: videoStreams, audioStreams: audioStreams } as HlsManifestResult;
}

function extractHlsAttribute(line: string, attribute: string): number {
  const matcher = new RegExp(attribute + '=(\\d+)');
  const match = matcher.exec(line);
  if (match) {
    try {
      return parseInt(match[1], 10);
    } catch (ignored) {
    }
  }
  return -1;
}

function extractHlsStringAttribute(line: string, attribute: string): string | undefined {
  let matcher = new RegExp(attribute + '="([^"]+)"');
  let match = matcher.exec(line);
  if (match) {
    return match[1];
  }
  matcher = new RegExp(attribute + '=([^,\\s]+)');
  match = matcher.exec(line);
  if (match) {
    return match[1];
  }
  return undefined;
}

function extractHlsXtagsValue(url: string, key: string): string | undefined {
  try {
    const decoded = decodeURIComponent(url);
    const matcher = /xtags=([^/]+)/.exec(decoded);
    if (matcher) {
      const xtags = matcher[1];
      for (const part of xtags.split(':')) {
        const kv = part.split('=', 2);
        if (kv.length === 2 && kv[0] === key) {
          return kv[1];
        }
      }
    }
  } catch (ignored) {
  }
  return undefined;
}
