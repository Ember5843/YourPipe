import { DashSession, StreamResource, SidxSegment } from './SessionStore';
import { fetchOtfInitialization } from './RangeProxy';
import { fetchAndParseSidx } from './SidxParser';
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

function buildSegmentListXml(segments: SidxSegment[], baseUrl: string, initSize: number): string {
  let xml = `        <BaseURL>${escapeXml(baseUrl)}</BaseURL>\n`;
  xml += '        <SegmentList timescale="1000">\n';
  xml += `          <Initialization range="0-${initSize > 0 ? initSize - 1 : 0}"/>\n`;
  xml += '          <SegmentTimeline>\n';
  for (let i = 0; i < segments.length; i++) {
    const d = Math.round(segments[i].duration * 1000);
    xml += `            <S d="${d}"${i === 0 ? ' t="0"' : ''}/>\n`;
  }
  xml += '          </SegmentTimeline>\n';
  for (const seg of segments) {
    const end = seg.offset + seg.size - 1;
    xml += `          <SegmentURL mediaRange="${seg.offset}-${end}"/>\n`;
  }
  xml += '        </SegmentList>\n';
  return xml;
}

async function buildRepresentation(stream: StreamResource, baseUrl: string): Promise<string> {
  let rep = `      <Representation id="${stream.id}" bandwidth="${stream.bitrate}"`;
  if (stream.codecs) rep += ` codecs="${escapeXml(stream.codecs)}"`;
  if (!stream.isAudio) {
    if (stream.width > 0 && stream.height > 0) {
      rep += ` width="${stream.width}" height="${stream.height}"`;
    }
    if (stream.fps > 0) rep += ` frameRate="${stream.fps}"`;
  }
  rep += '>\n';

  if (stream.isOtf) {
    const prepared = await fetchOtfInitialization(stream);
    if (prepared && stream.otfSegmentTimeline.length > 0) {
      rep += `        <BaseURL>${escapeXml(baseUrl)}</BaseURL>\n`;
      rep += `        <SegmentTemplate startNumber="1" timescale="1000" initialization="${escapeXml(`${baseUrl}/sq/0`)}" media="${escapeXml(`${baseUrl}/sq/$Number$`)}">\n`;
      rep += '          <SegmentTimeline>\n';
      for (const entry of stream.otfSegmentTimeline) {
        rep += `            <S d="${entry.durationMs}"`;
        if (entry.repeat > 0) rep += ` r="${entry.repeat}"`;
        rep += '/>\n';
      }
      rep += '          </SegmentTimeline>\n';
      rep += '        </SegmentTemplate>\n';
      Logger.info(TAG, `buildRepresentation: OTF SegmentTemplate resource=${stream.id} segments=${stream.otfSegmentTimeline.length}`);
    } else {
      Logger.error(TAG, `buildRepresentation: OTF preparation failed for resource=${stream.id}`);
      throw new Error(`OTF init failed for stream ${stream.id}: cannot generate segmented manifest`);
    }
  } else {
    const sidx = await fetchAndParseSidx(stream);
    if (!sidx || sidx.segments.length === 0) {
      Logger.error(TAG, `buildRepresentation: SIDX parse failed for resource=${stream.id}`);
      throw new Error(`SIDX parse failed for stream ${stream.id}: cannot generate segmented manifest`);
    }
    Logger.info(TAG, `buildRepresentation: SegmentList resource=${stream.id} segments=${sidx.segments.length}`);
    rep += buildSegmentListXml(sidx.segments, baseUrl, sidx.initSize);
  }

  rep += '      </Representation>\n';
  return rep;
}

export async function buildDashManifest(session: DashSession, port: number): Promise<string> {
  let durationMs = session.durationMs;
  if (durationMs <= 0) durationMs = session.video.otfDurationMs;
  if (durationMs <= 0 && session.hasAudio) durationMs = session.audio.otfDurationMs;
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
  mpd += await buildRepresentation(video, `${base}/video/0`);
  mpd += '    </AdaptationSet>\n';

  if (session.hasAudio) {
    mpd += `    <AdaptationSet mimeType="${escapeXml(adaptationMime(audio))}" contentType="audio" subsegmentAlignment="true" subsegmentStartsWithSAP="1">\n`;
    mpd += await buildRepresentation(audio, `${base}/audio/0`);
    mpd += '    </AdaptationSet>\n';
  }

  mpd += '  </Period>\n';
  mpd += '</MPD>\n';

  Logger.info(TAG, `buildDashManifest: session=${session.id} duration=${durationSec}s video=${video.id} audio=${audio.id}\n${mpd.substring(0, 600)}`);
  return mpd;
}
