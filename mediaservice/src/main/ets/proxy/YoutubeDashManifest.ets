import { DashSession, StreamResource } from './SessionStore';

function xml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function durationIso(durationMs: number): string {
  const safe = Math.max(1, Math.floor(durationMs));
  const seconds = Math.floor(safe / 1000);
  const millis = String(safe % 1000).padStart(3, '0');
  return `PT${seconds}.${millis}S`;
}

function validRange(start: string, end: string): boolean {
  if (!start || !end) return false;
  const first = Number(start);
  const last = Number(end);
  return Number.isFinite(first) && Number.isFinite(last) && first >= 0 && last >= first;
}

export function hasYoutubeSegmentBase(resource: StreamResource): boolean {
  return !!resource.url
    && !resource.isOtf
    && validRange(resource.initRangeStart, resource.initRangeEnd)
    && validRange(resource.indexRangeStart, resource.indexRangeEnd);
}

/**
 * SABR-proven template shape: SegmentTemplate + SegmentTimeline.
 * FFmpeg dash demuxer seeks this far more reliably than SegmentList/SegmentBase.
 */
function segmentTemplate(resource: StreamResource): string {
  const segments = resource.dashSegments || [];
  if (segments.length === 0) return '';
  let timeline = '<SegmentTemplate timescale="1000" startNumber="1" '
    + 'initialization="init" media="$Number$"><SegmentTimeline>';
  for (const segment of segments) {
    timeline += `<S t="${segment.startMs}" d="${Math.max(1, segment.durationMs)}"/>`;
  }
  return timeline + '</SegmentTimeline></SegmentTemplate>';
}

function adaptation(kind: string, resource: StreamResource): string {
  const isAudio = kind === 'audio';
  const mime = resource.mimeType || (isAudio ? 'audio/mp4' : 'video/mp4');
  let representation = `<AdaptationSet id="${xml(resource.id || kind)}" contentType="${kind}" `
    + `mimeType="${xml(mime)}" segmentAlignment="true" startWithSAP="1">`
    + `<Representation id="${xml(resource.id || kind)}" bandwidth="${Math.max(1, resource.bitrate)}"`;
  if (resource.codecs) representation += ` codecs="${xml(resource.codecs)}"`;
  if (isAudio) {
    representation += ' audioSamplingRate="48000"';
  } else {
    if (resource.width > 0) representation += ` width="${resource.width}"`;
    if (resource.height > 0) representation += ` height="${resource.height}"`;
    if (resource.fps > 0) representation += ` frameRate="${resource.fps}"`;
  }
  const template = segmentTemplate(resource);
  if (!template) return '';
  // BaseURL ends with / so media="$Number$" resolves to video/0/1, matching LocalProxyServer route.
  representation += `><BaseURL>${kind}/0/</BaseURL>${template}</Representation></AdaptationSet>`;
  return representation;
}

/** Static on-demand MPD: requires preprocessed SIDX segments (exact byte ranges only). */
export function buildYoutubeDashManifest(session: DashSession): string {
  if (session.type !== 'youtube-dual' || !session.hasAudio
    || !session.video.dashSegments?.length || !session.audio.dashSegments?.length) {
    return '';
  }
  const videoPart = adaptation('video', session.video);
  const audioPart = adaptation('audio', session.audio);
  if (!videoPart || !audioPart) return '';
  const durationMs = Math.max(1, session.durationMs
    || session.video.approxDurationMs || session.audio.approxDurationMs);
  return '<?xml version="1.0" encoding="UTF-8"?>'
    + '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" '
    + 'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" minBufferTime="PT1.5S" '
    + `mediaPresentationDuration="${durationIso(durationMs)}">`
    + '<Period id="0" start="PT0S">'
    + videoPart
    + audioPart
    + '</Period></MPD>';
}
