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
    const language = SearchLocaleManager.resolveSearchLanguage();
    const country = SearchLocaleManager.resolveSearchCountry();
    return new LocaleBundle(new Localization(language, country), new ContentCountry(country));
  }

  static resolveSearchLanguage(uiConfig?: UIConfig): string {
    const config = SearchLocaleManager.getConfig(uiConfig);
    const selected = SearchLocaleManager.normalizeLanguageSelection(config.searchLanguage || '');
    if (selected !== SearchLocaleManager.DEFAULT_SEARCH_LANGUAGE) {
      return selected;
    }
    // Fallback to app language
    return SearchLocaleManager.normalizeLanguageForRequest(LanguageManager.resolveAppliedLanguage(config));
  }

  static resolveSearchCountry(uiConfig?: UIConfig): string {
    const config = SearchLocaleManager.getConfig(uiConfig);
    const selected = SearchLocaleManager.normalizeCountrySelection(config.searchCountry || '');
    if (selected !== SearchLocaleManager.DEFAULT_SEARCH_COUNTRY) {
      return selected;
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

  private static normalizeLanguageForRequest(languageCode: string): string {
    const normalized = LanguageManager.normalizeLanguageCode((languageCode || '').trim());
    if (!normalized) {
      return SearchLocaleManager.FALLBACK_LANGUAGE;
    }
    if (normalized.startsWith('zh')) {
      return 'zh';
    }
    if (normalized.startsWith('en')) {
      return 'en';
    }
    const primary = normalized.replace(/_/g, '-').split('-')[0].toLowerCase();
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
