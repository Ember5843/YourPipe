/**
 * 把 YouTube 本地化的相对发布时间文本（publishedTimeText）解析为时间戳。
 * 覆盖英/中/日/韩/德/法/西/葡/意/俄/阿/土/印尼/越/泰等常见语言，
 * 无法识别时返回 0（调用方退化为 firstSeen 排序）。
 */

const SECOND_MS: number = 1000;
const MINUTE_MS: number = 60 * SECOND_MS;
const HOUR_MS: number = 60 * MINUTE_MS;
const DAY_MS: number = 24 * HOUR_MS;
const WEEK_MS: number = 7 * DAY_MS;
const MONTH_MS: number = 30 * DAY_MS;
const YEAR_MS: number = 365 * DAY_MS;

interface UnitPattern {
  unitMs: number;
  pattern: RegExp;
}

// 大单位在前，避免小单位关键词抢先命中（同一文本一般只含一个单位词）
const UNIT_PATTERNS: UnitPattern[] = [
  { unitMs: YEAR_MS, pattern: /years?|yrs?|años?|jahre?|ans?|années?|anni?|год|лет|سنو?[ةات]|عام|yıl|tahun|năm|ปี|年|년/ },
  { unitMs: MONTH_MS, pattern: /months?|mes(?:es)?|mois|monate?|mesi?|месяц|شهر|أشهر|ayl?ı?|bulan|tháng|เดือน|[个個]月|ヶ月|か月|カ月|개월/ },
  { unitMs: WEEK_MS, pattern: /weeks?|semanas?|semaines?|wochen?|settiman[ae]|недел|أسبوع|أسابيع|hafta|minggu|tuần|สัปดาห์|週間|周|週|주/ },
  { unitMs: DAY_MS, pattern: /days?|días?|jours?|tage?n?|giorn[oi]|д(?:ень|ня|ней)|يوم|أيام|gün|hari|ngày|วัน|日前|天|日|일/ },
  { unitMs: HOUR_MS, pattern: /hours?|hrs?|horas?|heures?|stunden?|or[ae]|час|ساع[ةات]|saat|jam|giờ|ชั่วโมง|小時|小时|時間/ },
  { unitMs: MINUTE_MS, pattern: /minutes?|mins?|minutos?|minuten?|minuti?|минут|دق(?:يقة|ائق)|dakika|menit|phút|นาที|分鐘|分钟|分|분/ },
  { unitMs: SECOND_MS, pattern: /seconds?|secs?|segundos?|secondes?|sekunden?|secondi?|секунд|ثان[يةي]|saniye|detik|giây|วินาที|秒|초/ }
];

export class RelativeTimeParser {
  /**
   * 解析相对时间文本为发布时间戳（ms）。无法识别返回 0。
   * 兼容 "3 days ago" / "3 天前" / "il y a 3 jours" / "hace 3 días" /
   * "vor 3 Tagen" / "3 дня назад" / "قبل 3 أيام" 等语序。
   */
  static parse(text: string, nowMs: number = Date.now()): number {
    if (!text || text.trim().length === 0) {
      return 0;
    }
    const normalized = text.toLowerCase();
    const numMatch = /(\d+(?:[.,]\d+)?)/.exec(normalized);
    if (!numMatch) {
      return 0;
    }
    const value = parseFloat(numMatch[1].replace(',', '.'));
    if (!Number.isFinite(value) || value < 0) {
      return 0;
    }
    for (const unit of UNIT_PATTERNS) {
      if (unit.pattern.test(normalized)) {
        const ms = Math.round(value * unit.unitMs);
        return nowMs - ms;
      }
    }
    return 0;
  }
}
