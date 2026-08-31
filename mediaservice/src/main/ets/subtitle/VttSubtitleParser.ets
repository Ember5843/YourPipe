/*
 * WebVTT subtitle parsing + active-cue lookup for the ArkUI overlay renderer.
 * Deliberately small: cue timing + text (inline tags stripped) + basic entity
 * decoding. VTT cue settings (line/position/align) are currently not honored —
 * overlay placement is app-configured instead.
 */

export interface SubtitleCue {
  startMs: number;
  endMs: number;
  text: string;
}

const VTT_TIMESTAMP: string = '(\\d{2,}):(\\d{2}):(\\d{2})[.,](\\d{3})';

function parseTimestampMs(h: string, m: string, s: string, ms: string): number {
  return parseInt(h, 10) * 3600000 + parseInt(m, 10) * 60000 + parseInt(s, 10) * 1000 + parseInt(ms, 10);
}

/** Strip VTT inline tags (<c>, <i>, <b>, timestamps tags <00:00:00.000>) and decode common entities. */
function cleanCueText(raw: string): string {
  let text = raw.replace(/<[^>]*>/g, '');
  const entities: string[][] = [
    ['&amp;', '&'], ['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'], ['&#39;', '\''], ['&nbsp;', ' ']
  ];
  for (const pair of entities) {
    text = text.split(pair[0]).join(pair[1]);
  }
  return text.trim();
}

/**
 * Parse WebVTT content into cues sorted by startMs. Non-VTT input (or SRT,
 * which shares the timestamp shape minus the header) parses through the same
 * block loop — the WEBVTT header line is just skipped as a non-cue block.
 */
export function parseVttSubtitles(content: string): SubtitleCue[] {
  const cues: SubtitleCue[] = [];
  const timingRe = new RegExp('^' + VTT_TIMESTAMP + '\\s+-->\\s+' + VTT_TIMESTAMP);
  const lines = content.replace(/^\uFEFF/, '').split(/\r?\n/);
  let i = 0;
  while (i < lines.length) {
    const line = lines[i].trim();
    const match = timingRe.exec(line);
    if (!match) {
      i++;
      continue;
    }
    const startMs = parseTimestampMs(match[1], match[2], match[3], match[4]);
    const endMs = parseTimestampMs(match[5], match[6], match[7], match[8]);
    i++;
    const textLines: string[] = [];
    while (i < lines.length && lines[i].trim().length > 0) {
      textLines.push(lines[i]);
      i++;
    }
    const text = cleanCueText(textLines.join('\n'));
    if (text.length > 0 && endMs > startMs) {
      cues.push({ startMs: startMs, endMs: endMs, text: text });
    }
  }
  cues.sort((a, b) => a.startMs - b.startMs);
  return cues;
}

/** Cues rarely outlast this; bounds the backward scan in the active lookup.
 *  必须覆盖最长 cue 的显示时长（片头长句/歌词可远超 15s），回扫成本与窗口无关。 */
const MAX_CUE_LOOKBACK_MS: number = 60000;

/**
 * Active cue text at positionMs. YouTube auto captions use rolling windows
 * where consecutive cues repeat the same sentence — identical adjacent lines
 * are collapsed so the overlay never doubles a line.
 */
export function findActiveSubtitleText(cues: SubtitleCue[], positionMs: number): string {
  if (cues.length === 0) {
    return '';
  }
  // Binary search: last cue with startMs <= positionMs.
  let lo = 0;
  let hi = cues.length - 1;
  let idx = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (cues[mid].startMs <= positionMs) {
      idx = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (idx < 0) {
    return '';
  }
  const out: string[] = [];
  let j = idx;
  while (j >= 0 && cues[j].startMs > positionMs - MAX_CUE_LOOKBACK_MS) {
    const cue = cues[j];
    if (cue.endMs > positionMs) {
      const cueLines = cue.text.split('\n');
      for (let k = cueLines.length - 1; k >= 0; k--) {
        const text = cueLines[k];
        if (out.length === 0 || out[0] !== text) {
          out.unshift(text);
        }
      }
    }
    j--;
  }
  return out.join('\n');
}
