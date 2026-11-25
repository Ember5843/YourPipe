import common from '@ohos.app.ability.common';
import { UIConfig } from './AppState';
import { PlaybackConfig } from './PlaybackConfig';
import { ExperimentalConfig } from './experimental/ExperimentalConfig';
import { NetworkProxyConfig } from './NetworkProxyConfig';
import { PreferencesStore } from './PreferencesStore';
import { AuthStateHelper } from './AuthStateHelper';
import { LlmTranslateConfig } from './LlmTranslateConfig';
import { TranslationService } from './TranslationService';
import { ThemeManager } from './ThemeManager';
import { LanguageManager } from './LanguageManager';
import { ColorModeManager } from './ColorModeManager';

/** Shared completion boundary for defaults and restored settings. */
export class SettingsRuntime {
  static async applyPersisted(): Promise<void> {
    await PreferencesStore.flushPending();
    const ui = UIConfig.loadFromPreferences();
    const playback = PlaybackConfig.loadFromPreferences();
    AppStorage.setOrCreate('uiConfig', ui);
    AppStorage.setOrCreate('playbackConfig', playback);
    AppStorage.setOrCreate('experimentalConfig', ExperimentalConfig.loadFromPreferences());
    AppStorage.setOrCreate('autoPlayQueue', playback.autoPlayNext);
    AuthStateHelper.applyPlayerClientConfig(playback.guestPlayerClient, playback.authPlayerClient);
    LlmTranslateConfig.reload();
    TranslationService.clearCache();
    ThemeManager.initFromConfig(ui.colorPreset);
    LanguageManager.applyPersistedLanguage();
    const context = AppStorage.get<common.UIAbilityContext>('context');
    if (context) ColorModeManager.applyPersistedMode(context);
    AuthStateHelper.refresh();
    const proxy = NetworkProxyConfig.load();
    AppStorage.setOrCreate('networkProxyConfig', proxy);
    await NetworkProxyConfig.applySystemAndProviders(proxy);
  }
}
