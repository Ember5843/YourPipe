const DEFAULT_PRIMARY_COLOR = '#F1680D';

export class ThemeColorUtil {
  static withAlpha(color: string, alpha: string): string {
    const normalized = color.trim();
    if (/^#[0-9A-Fa-f]{6}$/.test(normalized) && /^[0-9A-Fa-f]{2}$/.test(alpha)) {
      return `#${alpha}${normalized.substring(1)}`;
    }
    return `#${alpha}${DEFAULT_PRIMARY_COLOR.substring(1)}`;
  }

  static selectedBackground(primaryColor: string): string {
    return ThemeColorUtil.withAlpha(primaryColor, '29');
  }
}
