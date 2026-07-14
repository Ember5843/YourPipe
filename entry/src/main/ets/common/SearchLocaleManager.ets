import { i18n } from '@kit.LocalizationKit';
import { LocaleBundle } from './LocaleBundle';
import { LanguageManager } from './LanguageManager';
import { UIConfig, YourtubeDarkMode } from './AppState';
import { Localization } from 'youtube_core';
import { ContentCountry } from 'youtube_core';

export class SearchLocaleManager {
  static readonly DEFAULT_SEARCH_LANGUAGE: string = 'default';
  static readonly DEFAULT_SEARCH_COUNTRY: string = 'default';
  private static readonly FALLBACK_LANGUAGE: string = 'en';
  private static readonly FALLBACK_COUNTRY: string = 'GB';

  static getSearchLocaleBundle(uiConfig?: UIConfig): LocaleBundle {
    const language = SearchLocaleManager.resolveSearchLanguage(uiConfig);
    const country = SearchLocaleManager.resolveSearchCountry(uiConfig);
    // PipePipe: Localization.fromLocale(appLocale) + ContentCountry(contentCountry)
    // YouTube hl accepts codes like "zh-CN" / "en-GB"; gl is ISO-3166 alpha-2.
    return new LocaleBundle(new Localization(language, country), new ContentCountry(country));
  }

  /**
   * Content language for InnerTube `hl` / Accept-Language.
   * Explicit setting wins; otherwise map app UI language → YouTube language code
   * (PipePipe getPreferredLocalization uses app locale).
   */
  static resolveSearchLanguage(uiConfig?: UIConfig): string {
    const config = SearchLocaleManager.getConfig(uiConfig);
    const selected = SearchLocaleManager.normalizeLanguageSelection(config.searchLanguage || '');
    if (selected !== SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE) {
      return SearchLocaleManager.normalizeLanguageForRequest(selected);
    }
    return SearchLocaleManager.normalizeLanguageForRequest(LanguageManager.resolveAppliedLanguage(config));
  }

  /**
   * Content country for InnerTube `gl`.
   * Explicit setting wins; otherwise system region (PipePipe Locale.getDefault().getCountry()).
   */
  static resolveSearchCountry(uiConfig?: UIConfig): string {
    const config = SearchLocaleManager.getConfig(uiConfig);
    const selected = SearchLocaleManager.normalizeCountrySelection(config.searchCountry || '');
    if (selected !== SearchLocaleManager.DEFAULT_SEARCH_COUNTRY) {
      return selected;
    }
    return SearchLocaleManager.resolveSystemCountry();
  }

  /** System region as ISO-3166 alpha-2; fallback GB when unavailable. */
  static resolveSystemCountry(): string {
    try {
      const region = (i18n.System.getSystemRegion() || '').trim().toUpperCase();
      if (/^[A-Z]{2}$/.test(region)) {
        return region;
      }
    } catch (_e) {
      // ignore
    }
    // Some devices only expose region via language tag (e.g. zh-Hans-CN / en-US).
    // Only use the trailing 2-letter region; never treat primary language (zh/en) as country.
    try {
      const sysLang = (i18n.System.getSystemLanguage() || '').replace(/_/g, '-');
      const parts = sysLang.split('-').filter((p) => p.length > 0);
      if (parts.length >= 2) {
        const last = parts[parts.length - 1].toUpperCase();
        if (/^[A-Z]{2}$/.test(last)) {
          return last;
        }
      }
    } catch (_e2) {
      // ignore
    }
    return SearchLocaleManager.FALLBACK_COUNTRY;
  }

  static setSearchLanguage(languageCode: string): void {
    const config = SearchLocaleManager.getConfig();
    const next = SearchLocaleManager.cloneConfig(config);
    next.searchLanguage = SearchLocaleManager.normalizeLanguageSelection(languageCode);
    AppStorage.setOrCreate('uiConfig', next);
  }

  static setSearchCountry(countryCode: string): void {
    const config = SearchLocaleManager.getConfig();
    const next = SearchLocaleManager.cloneConfig(config);
    next.searchCountry = SearchLocaleManager.normalizeCountrySelection(countryCode);
    AppStorage.setOrCreate('uiConfig', next);
  }

  static setSearchLocale(languageCode: string, countryCode: string): void {
    const config = SearchLocaleManager.getConfig();
    const next = SearchLocaleManager.cloneConfig(config);
    next.searchLanguage = SearchLocaleManager.normalizeLanguageSelection(languageCode);
    next.searchCountry = SearchLocaleManager.normalizeCountrySelection(countryCode);
    AppStorage.setOrCreate('uiConfig', next);
  }

  static resetSearchLocale(): void {
    const config = SearchLocaleManager.getConfig();
    const next = SearchLocaleManager.cloneConfig(config);
    next.searchLanguage = SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE;
    next.searchCountry = SearchLocaleManager.DEFAULT_SEARCH_COUNTRY;
    AppStorage.setOrCreate('uiConfig', next);
  }

  /** 克隆 UIConfig，确保 AppStorage 得到新的对象引用，触发 @StorageLink 响应更新 */
  private static cloneConfig(src: UIConfig): UIConfig {
    return src.clone();
  }

  private static getConfig(uiConfig?: UIConfig): UIConfig {
    if (uiConfig) {
      return uiConfig;
    }
    const stored: UIConfig | undefined = AppStorage.get<UIConfig>('uiConfig');
    if (stored) {
      return stored;
    }
    const next: UIConfig = new UIConfig();
    next.systemLanguage = LanguageManager.normalizeLanguageCode(i18n.System.getSystemLanguage());
    AppStorage.setOrCreate('uiConfig', next);
    return next;
  }

  private static resolveLanguageSource(uiConfig: UIConfig): string {
    const selected = SearchLocaleManager.normalizeLanguageSelection(uiConfig.searchLanguage || '');
    if (selected !== SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE) {
      return selected;
    }
    return LanguageManager.resolveAppliedLanguage(uiConfig);
  }

  private static normalizeLanguageSelection(languageCode: string): string {
    const trimmed = (languageCode || '').trim().replace(/_/g, '-');
    if (!trimmed || trimmed === SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE) {
      return SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE;
    }
    return trimmed;
  }

  /**
   * Map UI / system language tags to YouTube content-language codes.
   * Keep regional Chinese variants (zh-CN / zh-HK / zh-TW); do not collapse to "zh".
   */
  private static normalizeLanguageForRequest(languageCode: string): string {
    const raw = (languageCode || '').trim().replace(/_/g, '-');
    if (!raw || raw === SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE) {
      return SearchLocaleManager.FALLBACK_LANGUAGE;
    }

    const lower = raw.toLowerCase();
    // App UI tags
    if (lower === 'zh-hans' || lower.startsWith('zh-hans-') || lower === 'zh-cn') {
      return 'zh-CN';
    }
    if (lower === 'zh-hk' || lower.startsWith('zh-hant-hk') || lower === 'zh-hant-hk') {
      return 'zh-HK';
    }
    if (lower === 'zh-tw' || lower.startsWith('zh-hant-tw') || lower === 'zh-hant' || lower.startsWith('zh-hant-')) {
      return 'zh-TW';
    }
    if (lower.startsWith('zh')) {
      // Generic Chinese → simplified (YouTube default for zh)
      return 'zh-CN';
    }
    if (lower === 'en-latn' || lower.startsWith('en-latn') || lower === 'en-gb') {
      return lower === 'en-gb' ? 'en-GB' : 'en';
    }
    if (lower.startsWith('en-')) {
      // en-US etc. — YouTube accepts "en" or full tag; prefer primary for stream clients
      if (lower === 'en-us') {
        return 'en';
      }
      const rest = raw.substring(3);
      if (/^[A-Za-z]{2}$/.test(rest)) {
        return `en-${rest.toUpperCase()}`;
      }
      return 'en';
    }

    // Already a YouTube-supported code like "pt-PT", "es-419", "sr-Latn"
    if (/^[a-z]{2,3}(-[A-Za-z0-9]+)*$/.test(raw)) {
      // Preserve casing style of known multi-part tags
      const parts = raw.split('-');
      if (parts.length === 1) {
        return parts[0].toLowerCase();
      }
      const head = parts[0].toLowerCase();
      const tail = parts.slice(1).map((p) => {
        if (p.length === 2 && p.toUpperCase() === p.toUpperCase()) {
          // region
          return p.toUpperCase();
        }
        if (p.toLowerCase() === 'latn' || p.toLowerCase() === 'hans' || p.toLowerCase() === 'hant') {
          return p.charAt(0).toUpperCase() + p.slice(1).toLowerCase();
        }
        // es-419 style
        if (/^\d+$/.test(p)) {
          return p;
        }
        return p.length <= 3 ? p.toUpperCase() : p;
      });
      return [head].concat(tail).join('-');
    }

    const primary = lower.split('-')[0];
    if (/^[a-z]{2,3}$/.test(primary)) {
      return primary;
    }
    return SearchLocaleManager.FALLBACK_LANGUAGE;
  }

  private static normalizeCountrySelection(countryCode: string): string {
    const trimmed = (countryCode || '').trim();
    if (!trimmed || trimmed === SearchLocaleManager.DEFAULT_SEARCH_COUNTRY) {
      return SearchLocaleManager.DEFAULT_SEARCH_COUNTRY;
    }
    const upper = trimmed.toUpperCase();
    if (/^[A-Z]{2}$/.test(upper)) {
      return upper;
    }
    return SearchLocaleManager.DEFAULT_SEARCH_COUNTRY;
  }
}
