/**
 * Media format constants
 * Ported from org.schabi.newpipe.extractor.MediaFormat
 */
export enum MediaFormat {
  // Video and audio combined formats
  MPEG_4 = 0x0,
  v3GPP = 0x10,
  WEBM = 0x20,
  // Audio formats
  M4A = 0x100,
  WEBMA = 0x200,
  MP3 = 0x300,
  OPUS = 0x400,
  OGG = 0x500,
  WEBMA_OPUS = 0x200,
  // Subtitle formats
  VTT = 0x1000,
  TTML = 0x2000,
  TRANSCRIPT1 = 0x3000,
  TRANSCRIPT2 = 0x4000,
  TRANSCRIPT3 = 0x5000,
  SRT = 0x6000,
}

export interface MediaFormatMeta {
  name: string;
  suffix: string;
  mimeType: string;
}

const MEDIA_FORMAT_META: Map<MediaFormat, MediaFormatMeta> = new Map([
  [MediaFormat.MPEG_4, { name: 'MPEG-4', suffix: 'mp4', mimeType: 'video/mp4' } as MediaFormatMeta],
  [MediaFormat.v3GPP, { name: '3GPP', suffix: '3gp', mimeType: 'video/3gpp' } as MediaFormatMeta],
  [MediaFormat.WEBM, { name: 'WebM', suffix: 'webm', mimeType: 'video/webm' } as MediaFormatMeta],
  [MediaFormat.M4A, { name: 'm4a', suffix: 'm4a', mimeType: 'audio/mp4' } as MediaFormatMeta],
  [MediaFormat.WEBMA, { name: 'WebM', suffix: 'webm', mimeType: 'audio/webm' } as MediaFormatMeta],
  [MediaFormat.MP3, { name: 'MP3', suffix: 'mp3', mimeType: 'audio/mpeg' } as MediaFormatMeta],
  [MediaFormat.OPUS, { name: 'opus', suffix: 'opus', mimeType: 'audio/opus' } as MediaFormatMeta],
  [MediaFormat.OGG, { name: 'ogg', suffix: 'ogg', mimeType: 'audio/ogg' } as MediaFormatMeta],
  [MediaFormat.WEBMA_OPUS, { name: 'WebM Opus', suffix: 'webm', mimeType: 'audio/webm' } as MediaFormatMeta],
  [MediaFormat.VTT, { name: 'WebVTT', suffix: 'vtt', mimeType: 'text/vtt' } as MediaFormatMeta],
  [MediaFormat.TTML, { name: 'Timed Text Markup Language', suffix: 'ttml', mimeType: 'application/ttml+xml' } as MediaFormatMeta],
  [MediaFormat.TRANSCRIPT1, { name: 'TranScript v1', suffix: 'srv1', mimeType: 'text/xml' } as MediaFormatMeta],
  [MediaFormat.TRANSCRIPT2, { name: 'TranScript v2', suffix: 'srv2', mimeType: 'text/xml' } as MediaFormatMeta],
  [MediaFormat.TRANSCRIPT3, { name: 'TranScript v3', suffix: 'srv3', mimeType: 'text/xml' } as MediaFormatMeta],
  [MediaFormat.SRT, { name: 'SubRip file format', suffix: 'srt', mimeType: 'application/x-subrip' } as MediaFormatMeta],
]);

export function getMediaFormatName(format: MediaFormat): string {
  return MEDIA_FORMAT_META.get(format)?.name ?? '';
}

export function getMediaFormatSuffix(format: MediaFormat): string {
  return MEDIA_FORMAT_META.get(format)?.suffix ?? '';
}

export function getMediaFormatMimeType(format: MediaFormat): string {
  return MEDIA_FORMAT_META.get(format)?.mimeType ?? '';
}

export function getMediaFormatFromMimeType(mimeType: string): MediaFormat | undefined {
  const entries = MEDIA_FORMAT_META.entries();
  let next = entries.next();
  while (!next.done) {
    const format = next.value[0];
    const meta = next.value[1];
    if (meta.mimeType === mimeType) {
      return format;
    }
    next = entries.next();
  }
  return undefined;
}
