/**
 * 把一段文本（视频简介 / 评论正文）切成 纯文本 / 链接 / 时间戳 段，
 * 供 Span 分段渲染 + 点击（打开链接 / seek 到时间戳）。
 * 简介与评论共用同一套识别规则，避免两份正则各自漂移。
 */

export enum SegmentKind {
  TEXT = 0,
  LINK = 1,
  TIMESTAMP = 2
}

export class RichTextSegment {
  text: string;
  kind: SegmentKind;
  target: string;
  seconds: number;

  constructor(text: string, kind: SegmentKind, target: string = '', seconds: number = 0) {
    this.text = text;
    this.kind = kind;
    this.target = target;
    this.seconds = seconds;
  }
}

/** '1:23' / '1:02:33' → 秒；不合法返回 -1。 */
export function parseTimestampText(value: string): number {
  const parts = value.split(':').map((part: string): number => Number(part));
  if ((parts.length !== 2 && parts.length !== 3)
    || parts.some((part: number): boolean => !Number.isInteger(part) || part < 0)) {
    return -1;
  }
  const seconds = parts[parts.length - 1];
  const minutes = parts[parts.length - 2];
  if (seconds >= 60 || minutes >= 60) {
    return -1;
  }
  return parts.length === 3
    ? parts[0] * 3600 + minutes * 60 + seconds
    : minutes * 60 + seconds;
}

export function buildRichTextSegments(text: string): RichTextSegment[] {
  const segments: RichTextSegment[] = [];
  const matcher = /https?:\/\/[^\s]+|www\.[^\s]+|\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b/gi;
  let cursor = 0;
  let match: RegExpExecArray | null = matcher.exec(text);
  while (match) {
    const start = match.index;
    const value = match[0];
    if (start > cursor) {
      segments.push(new RichTextSegment(text.substring(cursor, start), SegmentKind.TEXT));
    }

    if (/^(?:https?:\/\/|www\.)/i.test(value)) {
      const link = value.replace(/[\]\)}>.,!?;:，。！？；：、》】）]+$/g, '');
      if (link.length > 0) {
        segments.push(new RichTextSegment(link, SegmentKind.LINK, link));
      }
      if (link.length < value.length) {
        segments.push(new RichTextSegment(value.substring(link.length), SegmentKind.TEXT));
      }
    } else {
      const seconds = parseTimestampText(value);
      segments.push(new RichTextSegment(value,
        seconds >= 0 ? SegmentKind.TIMESTAMP : SegmentKind.TEXT,
        '', Math.max(0, seconds)));
    }

    cursor = matcher.lastIndex;
    match = matcher.exec(text);
  }
  if (cursor < text.length) {
    segments.push(new RichTextSegment(text.substring(cursor), SegmentKind.TEXT));
  }
  return segments;
}
