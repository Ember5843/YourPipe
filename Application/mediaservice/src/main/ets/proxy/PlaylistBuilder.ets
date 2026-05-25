import { DashSession, StreamResource } from './SessionStore';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][Playlist]';

function escapeXml(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function adaptationMime(stream: StreamResource): string {
  if (!stream.mimeType) {
    return stream.isAudio ? 'audio/mp4' : 'video/mp4';
  }
  const semi = stream.mimeType.indexOf(';');
  return semi >= 0 ? stream.mimeType.substring(0, semi) : stream.mimeType;
}

function buildRepresentation(stream: StreamResource, baseUrl: string): string {
  let rep = `      <Representation id="${stream.id}" bandwidth="${stream.bitrate}"`;
  if (stream.codecs) rep += ` codecs="${escapeXml(stream.codecs)}"`;
  if (!stream.isAudio) {
    if (stream.width > 0 && stream.height > 0) {
      rep += ` width="${stream.width}" height="${stream.height}"`;
    }
    if (stream.fps > 0) rep += ` frameRate="${stream.fps}"`;
  }
  rep += '>\n';
  rep += `        <BaseURL>${escapeXml(baseUrl)}</BaseURL>\n`;

  const initRange = stream.initRangeStart && stream.initRangeEnd
    ? `${stream.initRangeStart}-${stream.initRangeEnd}` : '';
  const indexRange = stream.indexRangeStart && stream.indexRangeEnd
    ? `${stream.indexRangeStart}-${stream.indexRangeEnd}` : '';

  if (indexRange && initRange) {
    rep += `        <SegmentBase indexRangeExact="true" indexRange="${indexRange}">\n`;
    rep += `          <Initialization range="${initRange}"/>\n`;
    rep += `        </SegmentBase>\n`;
  }
  rep += '      </Representation>\n';
  return rep;
}

export function buildDashManifest(session: DashSession, port: number): string {
  let durationMs = session.durationMs;
  if (durationMs <= 0) durationMs = session.video.approxDurationMs;
  if (durationMs <= 0 && session.hasAudio) durationMs = session.audio.approxDurationMs;
  if (durationMs <= 0) durationMs = 86400000;

  const durationSec = (durationMs / 1000).toFixed(3);
  const base = `http://127.0.0.1:${port}/session/${session.id}`;
  const video = session.video;
  const audio = session.audio;

  let mpd = '<?xml version="1.0" encoding="UTF-8"?>\n';
  mpd += '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" ';
  mpd += 'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" ';
  mpd += `type="static" mediaPresentationDuration="PT${durationSec}S" minBufferTime="PT5S">\n`;
  mpd += '  <Period>\n';

  mpd += `    <AdaptationSet mimeType="${escapeXml(adaptationMime(video))}" contentType="video" subsegmentAlignment="true" subsegmentStartsWithSAP="1">\n`;
  mpd += buildRepresentation(video, `${base}/video/0`);
  mpd += '    </AdaptationSet>\n';

  if (session.hasAudio) {
    mpd += `    <AdaptationSet mimeType="${escapeXml(adaptationMime(audio))}" contentType="audio" subsegmentAlignment="true" subsegmentStartsWithSAP="1">\n`;
    mpd += buildRepresentation(audio, `${base}/audio/0`);
    mpd += '    </AdaptationSet>\n';
  }

  mpd += '  </Period>\n';
  mpd += '</MPD>\n';

  Logger.info(TAG, `buildDashManifest: session=${session.id} duration=${durationSec}s video=${video.id} audio=${audio.id}`);
  return mpd;
}
