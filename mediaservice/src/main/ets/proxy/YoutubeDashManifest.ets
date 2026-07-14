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
  representation += `><BaseURL>${kind}/0</BaseURL>`
    + `<SegmentBase indexRange="${resource.indexRangeStart}-${resource.indexRangeEnd}" indexRangeExact="true">`
    + `<Initialization range="${resource.initRangeStart}-${resource.initRangeEnd}"/>`
    + '</SegmentBase></Representation></AdaptationSet>';
  return representation;
}

/** Build a static on-demand MPD over the stable local range-proxy URLs. */
export function buildYoutubeDashManifest(session: DashSession): string {
  if (session.type !== 'youtube-dual' || !session.hasAudio
    || !hasYoutubeSegmentBase(session.video) || !hasYoutubeSegmentBase(session.audio)) {
    return '';
  }
  const durationMs = Math.max(1, session.durationMs
    || session.video.approxDurationMs || session.audio.approxDurationMs);
  return '<?xml version="1.0" encoding="UTF-8"?>'
    + '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" '
    + 'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" minBufferTime="PT1.5S" '
    + `mediaPresentationDuration="${durationIso(durationMs)}">`
    + '<Period id="0" start="PT0S">'
    + adaptation('video', session.video)
    + adaptation('audio', session.audio)
    + '</Period></MPD>';
}
