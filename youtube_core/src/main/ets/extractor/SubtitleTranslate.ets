import { SubtitleTrack } from './VideoInfo';

/**
 * YouTube timedtext 自动翻译（tlang）轨构造。
 * 参照 PipePipe YoutubeStreamExtractor.getSubtitles 的 auto-translate 逻辑：
 * 取第一条可翻译轨，在其 URL（提取时已清洗并追加 fmt=vtt）上追加
 * tlang=<目标语言>，由 YouTube 服务端返回机器翻译后的字幕内容。
 * 注意：自动翻译请求存在风控（PipePipe 会附加登录态头）；匿名请求失败时
 * 由下游字幕加载的重试/失败路径兜底。
 */

/** 将应用/Google 风格语言码映射为 YouTube timedtext tlang 码。 */
export function toYoutubeTlang(lang: string): string {
  const lower = lang.trim().toLowerCase();
  switch (lower) {
    case 'zh-cn':
    case 'zh-hans':
      return 'zh-Hans';
    case 'zh-hk':
    case 'zh-tw':
    case 'zh-hant':
      return 'zh-Hant';
    default:
      break;
  }
  if (lower.length === 0) {
    return '';
  }
  // 其余语言 YouTube 接受 ISO 639-1 主码（pt-BR→pt 等取主码即可）。
  const dash = lower.indexOf('-');
  return dash > 0 ? lower.substring(0, dash) : lower;
}

/** 语言码归一化：zh-CN/zh-HK/zh-TW 等变体折叠到 YouTube 轨使用的 zh-Hans/zh-Hant。 */
function normalizeLang(code: string): string {
  const lower = code.trim().toLowerCase();
  if (lower === 'zh-cn' || lower === 'zh-hans') {
    return 'zh-hans';
  }
  if (lower === 'zh-hk' || lower === 'zh-tw' || lower === 'zh-hant') {
    return 'zh-hant';
  }
  return lower;
}

/**
 * 构造自动翻译轨；不适用时返回 null：
 * - 目标语言为空；
 * - 已存在目标语言的原生轨（含前缀匹配，如 en / en-US）；
 * - 没有任何可翻译轨。
 */
export function buildAutoTranslatedTrack(tracks: SubtitleTrack[], targetLang: string): SubtitleTrack | null {
  const tlang = toYoutubeTlang(targetLang);
  if (!tlang) {
    return null;
  }
  const targetNorm = normalizeLang(tlang);
  const hasNative = tracks.some((t: SubtitleTrack) => {
    const code = normalizeLang(t.languageCode);
    return code.length > 0 && (code === targetNorm || code.startsWith(targetNorm) || targetNorm.startsWith(code));
  });
  if (hasNative) {
    return null;
  }
  const source = tracks.find((t: SubtitleTrack) => t.isTranslatable && t.url.length > 0);
  if (!source) {
    return null;
  }
  const sep = source.url.includes('?') ? '&' : '?';
  const url = `${source.url}${sep}tlang=${encodeURIComponent(tlang)}`;
  const track = new SubtitleTrack(url, tlang, '', undefined, false, false);
  track.isAutoTranslated = true;
  return track;
}
