/*
 * WebVTT & YouTube json3 subtitle parsing + active-cue lookup for the ArkUI overlay renderer.
 * Supports fmt=json3 (preferred for YouTube timedtext — avoids ASR rolling duplication and
 * 10ms flash frames) and hardened WebVTT/SRT fallback (MM:SS.mmm + HH:MM:SS.mmm timestamps,
 * numeric HTML entity decoding, <=20ms placeholder filtering, and parse-time cross-cue
 * rolling-line deduplication).
 */

export interface SubtitleCue {
  startMs: number;
  endMs: number;
  text: string;
}

interface Json3Segment {
  utf8?: string;
  tOffsetMs?: number;
}

interface Json3Event {
  tStartMs?: number;
  dDurationMs?: number;
  aAppend?: number;
  wWinId?: number;
  segs?: Json3Segment[];
}

interface Json3Payload {
  events?: Json3Event[];
}

/** Drop <=20ms flash/transition placeholder cues emitted by YouTube ASR tracks. */
const MIN_CUE_DURATION_MS: number = 20;

/** Supports both HH:MM:SS.mmm and standard WebVTT MM:SS.mmm (as well as SRT ',' separator). */
const VTT_TIMESTAMP: string = '(?:(\\d{1,}):)?(\\d{2}):(\\d{2})[.,](\\d{3})';

function parseTimestampMs(h: string, m: string, s: string, ms: string): number {
  const hours = h.length > 0 ? parseInt(h, 10) : 0;
  return hours * 3600000 + parseInt(m, 10) * 60000 + parseInt(s, 10) * 1000 + parseInt(ms, 10);
}

/** Decode named and numeric (decimal/hex) HTML entities in a single pass. */
function decodeHtmlEntities(input: string): string {
  if (!input.includes('&')) {
    return input;
  }
  return input.replace(/&(?:#\d+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);/g, (entity: string): string => {
    if (entity.startsWith('&#x') || entity.startsWith('&#X')) {
      const code = parseInt(entity.substring(3, entity.length - 1), 16);
      return Number.isFinite(code) && code > 0 && code <= 0x10FFFF ? String.fromCodePoint(code) : entity;
    }
    if (entity.startsWith('&#')) {
      const code = parseInt(entity.substring(2, entity.length - 1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10FFFF ? String.fromCodePoint(code) : entity;
    }
    switch (entity) {
      case '&amp;': return '&';
      case '&lt;': return '<';
      case '&gt;': return '>';
      case '&quot;': return '"';
      case '&apos;': return '\'';
      case '&nbsp;': return ' ';
      default: return entity;
    }
  });
}

/** Normalize line breaks, trim lines, drop empty lines, and collapse identical adjacent lines. */
function normalizeCueLines(raw: string): string {
  const normalized = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const rawLines = normalized.split('\n');
  const kept: string[] = [];
  for (let i = 0; i < rawLines.length; i++) {
    const trimmed = rawLines[i].replace(/\u200B/g, '').trim();
    if (trimmed.length === 0) {
      continue;
    }
    if (kept.length === 0 || kept[kept.length - 1] !== trimmed) {
      kept.push(trimmed);
    }
  }
  return kept.join('\n');
}

/** Strip VTT inline tags (<c>, <i>, <b>, timestamp tags <00:00:00.000>) and decode HTML entities. */
function cleanCueText(raw: string): string {
  const stripped = raw.replace(/<[^>]*>/g, '');
  const decoded = decodeHtmlEntities(stripped);
  return normalizeCueLines(decoded);
}

/**
 * Parse-time cross-cue rolling-line deduplication for YouTube ASR VTT.
 * YouTube ASR VTT emits rolling 2-line windows where cue N+1 repeats the last line
 * (or pinned top line) of cue N on line 1 while advancing line 2 word-by-word.
 * Stripping the repeated top line once at parse time removes screen jumping and echo
 * without affecting ordinary manual VTT cues.
 */
function deduplicateRollingVttCues(sortedCues: SubtitleCue[]): SubtitleCue[] {
  if (sortedCues.length <= 1) {
    return sortedCues;
  }
  const result: SubtitleCue[] = [];
  let prevLastOrigLine = '';
  let prevFirstOrigLine = '';
  let prevEndMs = -1;

  for (let i = 0; i < sortedCues.length; i++) {
    const cue = sortedCues[i];
    const origLines = cue.text.split('\n');
    const gapMs = prevEndMs >= 0 ? cue.startMs - prevEndMs : Number.MAX_SAFE_INTEGER;
    const isContiguous = prevEndMs >= 0 && gapMs <= 1000;

    if (isContiguous && origLines.length === 1 && origLines[0] === prevLastOrigLine && gapMs <= 100 && result.length > 0) {
      // Short linger cue repeating the exact previous line: extend previous cue instead of duplicating.
      const prev = result[result.length - 1];
      if (cue.endMs > prev.endMs) {
        prev.endMs = cue.endMs;
      }
      prevEndMs = Math.max(prevEndMs, cue.endMs);
      continue;
    }

    let keptLines: string[] = origLines;
    if (isContiguous && origLines.length >= 2) {
      const topLine = origLines[0];
      if (topLine === prevLastOrigLine || (prevFirstOrigLine.length > 0 && topLine === prevFirstOrigLine)) {
        keptLines = origLines.slice(1);
      }
    }

    const nextText = keptLines.join('\n').trim();
    if (nextText.length > 0) {
      result.push({
        startMs: cue.startMs,
        endMs: cue.endMs,
        text: nextText
      });
    }

    prevFirstOrigLine = origLines.length >= 2 ? origLines[0] : '';
    prevLastOrigLine = origLines[origLines.length - 1];
    prevEndMs = Math.max(prevEndMs, cue.endMs);
  }

  return result;
}

/**
 * Parse YouTube `fmt=json3` timedtext JSON into cues sorted by startMs.
 * Handles `events[].tStartMs`, `dDurationMs`, `segs[].utf8`, and `aAppend` merges;
 * decodes HTML entities, skips empty whitespace-only events, and drops <=20ms flash cues.
 */
export function parseJson3Subtitles(raw: string): SubtitleCue[] {
  if (!raw || raw.trim().length === 0) {
    return [];
  }
  let payload: Json3Payload | undefined = undefined;
  try {
    payload = JSON.parse(raw) as Json3Payload;
  } catch {
    return [];
  }
  if (!payload || !Array.isArray(payload.events) || payload.events.length === 0) {
    return [];
  }

  const cues: SubtitleCue[] = [];
  const missingDurationFlags: boolean[] = [];

  for (let i = 0; i < payload.events.length; i++) {
    const ev = payload.events[i];
    if (!ev || typeof ev.tStartMs !== 'number' || !Number.isFinite(ev.tStartMs) || ev.tStartMs < 0) {
      continue;
    }
    const segs = ev.segs;
    if (!segs || segs.length === 0) {
      continue;
    }
    const parts: string[] = [];
    for (let s = 0; s < segs.length; s++) {
      const utf8 = segs[s]?.utf8;
      if (typeof utf8 === 'string' && utf8.length > 0) {
        parts.push(utf8);
      }
    }
    const rawJoined = decodeHtmlEntities(parts.join(''));
    const cleaned = normalizeCueLines(rawJoined);
    if (cleaned.length === 0) {
      // Skips empty whitespace-only events including aAppend "\n" scroll markers.
      continue;
    }

    const startMs = Math.round(ev.tStartMs);
    const hasExplicitDuration = typeof ev.dDurationMs === 'number' && Number.isFinite(ev.dDurationMs);
    const durationMs = hasExplicitDuration ? Math.round(ev.dDurationMs as number) : 0;

    if (ev.aAppend === 1 && cues.length > 0) {
      const prev = cues[cues.length - 1];
      const prevLines = prev.text.split('\n');
      const lastPrevLine = prevLines[prevLines.length - 1];
      if (lastPrevLine !== cleaned && !prev.text.endsWith(cleaned)) {
        const startsWithNewline = rawJoined.startsWith('\n') || rawJoined.startsWith('\r');
        const joiner = startsWithNewline ? '\n' : ' ';
        prev.text = normalizeCueLines(`${prev.text}${joiner}${cleaned}`);
      }
      if (hasExplicitDuration && durationMs > 0) {
        const candidateEnd = startMs + durationMs;
        if (candidateEnd > prev.endMs) {
          prev.endMs = candidateEnd;
        }
      }
      continue;
    }

    if (hasExplicitDuration && durationMs <= MIN_CUE_DURATION_MS) {
      continue;
    }

    cues.push({
      startMs: startMs,
      endMs: hasExplicitDuration ? startMs + durationMs : startMs,
      text: cleaned
    });
    missingDurationFlags.push(!hasExplicitDuration);
  }

  // Fill missing dDurationMs (seen on some live/auto tracks) using the next cue startMs.
  for (let i = 0; i < cues.length; i++) {
    if (!missingDurationFlags[i]) {
      continue;
    }
    const cue = cues[i];
    const nextStart = i + 1 < cues.length ? cues[i + 1].startMs : -1;
    if (nextStart > cue.startMs + MIN_CUE_DURATION_MS) {
      cue.endMs = Math.min(nextStart, cue.startMs + 6000);
    } else {
      cue.endMs = cue.startMs + 3000;
    }
  }

  cues.sort((a: SubtitleCue, b: SubtitleCue): number => a.startMs - b.startMs);
  return cues.filter((c: SubtitleCue): boolean => c.endMs - c.startMs > MIN_CUE_DURATION_MS && c.text.length > 0);
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
    const startMs = parseTimestampMs(match[1] ?? '', match[2], match[3], match[4]);
    const endMs = parseTimestampMs(match[5] ?? '', match[6], match[7], match[8]);
    i++;
    const textLines: string[] = [];
    while (i < lines.length && lines[i].trim().length > 0) {
      textLines.push(lines[i]);
      i++;
    }
    const text = cleanCueText(textLines.join('\n'));
    if (text.length > 0 && endMs - startMs > MIN_CUE_DURATION_MS) {
      cues.push({ startMs: startMs, endMs: endMs, text: text });
    }
  }
  cues.sort((a: SubtitleCue, b: SubtitleCue): number => a.startMs - b.startMs);
  return deduplicateRollingVttCues(cues);
}

/** Cues rarely outlast this; bounds the backward scan in the active lookup.
 *  必须覆盖最长 cue 的显示时长（片头长句/歌词可远超 15s），回扫成本与窗口无关。 */
const MAX_CUE_LOOKBACK_MS: number = 60000;

/**
 * Active cue text at positionMs. Identical adjacent lines across overlapping cues
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
