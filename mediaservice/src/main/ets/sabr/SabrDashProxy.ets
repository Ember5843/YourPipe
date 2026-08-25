import { socket } from '@kit.NetworkKit';
import { DashSession, StreamResource } from '../proxy/SessionStore';
import { encodeUtf8 } from '../proxy/ProxyEncoding';
import { SabrTrackBuffer } from './SabrTrackBuffer';
import Logger from '../utils/Logger';

const TAG = '[SabrDashProxy]';

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

function segmentTimeline(buffer: SabrTrackBuffer, durationMs: number,
  fallbackDurationMs: number): string {
  const end = buffer.getEndSegment();
  if (end <= 0 || durationMs <= 0) {
    Logger.warn(TAG, `fallback timeline itag=${buffer.getItag()} end=${end} durationMs=${durationMs} `
      + `segmentDurationMs=${fallbackDurationMs}`);
    return `<SegmentTemplate timescale="1000" startNumber="1" duration="${fallbackDurationMs}" `
      + 'initialization="init" media="$Number$"/>';
  }

  // Long videos routinely exceed 10,000 video segments. Falling back to a fixed duration here
  // makes DASH choose a sequence from the synthetic duration instead of the real SIDX timeline;
  // the error accumulates into hours near the end of a 24-hour video. Preserve the exact SIDX
  // mapping and compress only truly contiguous, equal-duration runs with DASH's r attribute.
  const entries: string[] = [];
  let runStartMs = 0;
  let runDurationMs = 0;
  let runRepeat = 0;
  let expectedNextStartMs = 0;
  const flushRun = (): void => {
    if (runDurationMs <= 0) return;
    entries.push(`<S t="${runStartMs}" d="${runDurationMs}"`
      + (runRepeat > 0 ? ` r="${runRepeat}"` : '') + '/>');
  };
  for (let sequence = 1; sequence <= end; sequence++) {
    const startMs = Math.max(0, buffer.getSegmentStartMs(sequence));
    const endMs = buffer.getSegmentEndMs(sequence);
    const segmentDurationMs = Math.max(1, endMs - startMs);
    if (sequence > 1 && startMs === expectedNextStartMs
      && segmentDurationMs === runDurationMs) {
      runRepeat++;
    } else {
      flushRun();
      runStartMs = startMs;
      runDurationMs = segmentDurationMs;
      runRepeat = 0;
    }
    expectedNextStartMs = startMs + segmentDurationMs;
  }
  flushRun();
  Logger.info(TAG, `exact timeline itag=${buffer.getItag()} segments=${end} runs=${entries.length}`);
  return '<SegmentTemplate timescale="1000" startNumber="1" '
    + 'initialization="init" media="$Number$"><SegmentTimeline>'
    + entries.join('') + '</SegmentTimeline></SegmentTemplate>';
}

function adaptation(kind: string, resource: StreamResource, buffer: SabrTrackBuffer,
  durationMs: number): string {
  const isAudio = kind === 'audio';
  const mime = resource.mimeType || (isAudio ? 'audio/mp4' : 'video/mp4');
  let representation = `<AdaptationSet id="${buffer.getItag()}" contentType="${kind}" `
    + `mimeType="${xml(mime)}" segmentAlignment="true" startWithSAP="1">`
    + `<Representation id="${buffer.getItag()}" bandwidth="${Math.max(1, resource.bitrate)}"`;
  if (resource.codecs) {
    representation += ` codecs="${xml(resource.codecs)}"`;
  }
  if (isAudio) {
    representation += ' audioSamplingRate="48000"';
  } else {
    representation += ` width="${Math.max(1, resource.width)}" height="${Math.max(1, resource.height)}"`;
    if (resource.fps > 0) {
      representation += ` frameRate="${resource.fps}"`;
    }
  }
  representation += `><BaseURL>sabr/${kind}/</BaseURL>`
    + segmentTimeline(buffer, durationMs, isAudio ? 10000 : 5000)
    + '</Representation></AdaptationSet>';
  return representation;
}

export function buildSabrDashManifest(session: DashSession): string {
  if (!session.sabrVideoBuffer || !session.sabrAudioBuffer) {
    return '';
  }
  const durationMs = Math.max(1, session.durationMs);
  return '<?xml version="1.0" encoding="UTF-8"?>'
    + '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" '
    + 'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" minBufferTime="PT1.5S" '
    + `mediaPresentationDuration="${durationIso(durationMs)}">`
    + '<Period id="0" start="PT0S">'
    + adaptation('video', session.video, session.sabrVideoBuffer, durationMs)
    + adaptation('audio', session.audio, session.sabrAudioBuffer, durationMs)
    + '</Period></MPD>';
}

export async function serveSabrDashSegment(conn: socket.TCPSocketConnection,
  buffer: SabrTrackBuffer, segmentName: string, mimeType: string, headOnly: boolean): Promise<void> {
  const init = segmentName === 'init';
  const sequence = init ? -1 : parseInt(segmentName, 10);
  if (!init && (!Number.isFinite(sequence) || sequence <= 0)) {
    await conn.send({ data: encodeUtf8('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n') });
    return;
  }
  const data = await buffer.readSegment(init, sequence);
  if (!data) {
    Logger.info(TAG, `EOF itag=${buffer.getItag()} seq=${sequence} end=${buffer.getEndSegment()}`);
    await conn.send({ data: encodeUtf8('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n') });
    return;
  }
  const header = 'HTTP/1.1 200 OK\r\n'
    + `Content-Type: ${mimeType || 'application/octet-stream'}\r\n`
    + `Content-Length: ${data.length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`;
  await conn.send({ data: encodeUtf8(header) });
  if (!headOnly && data.length > 0) {
    await conn.send({ data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer });
  }
}
