import { ConfigurationConstant } from '@kit.AbilityKit';
import common from '@ohos.app.ability.common';
import { UIConfig, YourtubeDarkMode } from './AppState';

export class ColorModeManager {
  static applyPersistedMode(context: common.UIAbilityContext): ConfigurationConstant.ColorMode {
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    const colorMode = ColorModeManager.resolveMode(uiConfig.darkMode);
    context.getApplicationContext().setColorMode(colorMode);
    AppStorage.setOrCreate('currentColorMode', colorMode);
    return colorMode;
  }

  static resolveMode(mode: YourtubeDarkMode): ConfigurationConstant.ColorMode {
    switch (mode) {
      case YourtubeDarkMode.DARK:
        return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      case YourtubeDarkMode.LIGHT:
        return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      case YourtubeDarkMode.SYSTEM:
      default:
        return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
  }
}
