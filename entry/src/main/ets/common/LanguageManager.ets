import { i18n } from '@kit.LocalizationKit';
import { UIConfig } from './AppState';

export class LanguageManager {
  static readonly DEFAULT_LANGUAGE: string = 'default';
  static readonly LANGUAGE_ZH_HANS: string = 'zh-Hans';
  static readonly LANGUAGE_ZH_HK: string = 'zh-HK';
  static readonly LANGUAGE_ZH_TW: string = 'zh-TW';
  static readonly LANGUAGE_EN_LATN: string = 'en-Latn';

  static applyPersistedLanguage(): string {
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    const systemLanguage = LanguageManager.normalizeLanguageCode(i18n.System.getSystemLanguage());
    uiConfig.systemLanguage = systemLanguage;
    const appliedLanguage = LanguageManager.resolveAppliedLanguage(uiConfig);
    i18n.System.setAppPreferredLanguage(appliedLanguage);
    AppStorage.setOrCreate('uiConfig', uiConfig);
    return appliedLanguage;
  }

  static resolveAppliedLanguage(uiConfig: UIConfig): string {
    if (uiConfig.userLanguage && uiConfig.userLanguage !== LanguageManager.DEFAULT_LANGUAGE) {
      return uiConfig.userLanguage;
    }
    if (uiConfig.systemLanguage && uiConfig.systemLanguage.length > 0) {
      return uiConfig.systemLanguage;
    }
    return LanguageManager.LANGUAGE_EN_LATN;
  }

  static normalizeLanguageCode(languageCode: string): string {
    if (!languageCode) {
      return LanguageManager.LANGUAGE_EN_LATN;
    }
    if (languageCode.startsWith('zh-Hans')) {
      return LanguageManager.LANGUAGE_ZH_HANS;
    }
    if (languageCode.startsWith('zh-Hant-HK') || languageCode.startsWith('zh-HK')) {
      return LanguageManager.LANGUAGE_ZH_HK;
    }
    if (languageCode.startsWith('zh-Hant-TW') || languageCode.startsWith('zh-TW')) {
      return LanguageManager.LANGUAGE_ZH_TW;
    }
    if (languageCode.startsWith('en-Latn') || languageCode.startsWith('en-')) {
      return LanguageManager.LANGUAGE_EN_LATN;
    }
    return languageCode;
  }
}
