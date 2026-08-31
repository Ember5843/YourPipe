import { ConfigurationConstant } from '@kit.AbilityKit';
import common from '@ohos.app.ability.common';
import { UIConfig, YourtubeDarkMode } from './AppState';

export class ColorModeManager {
  static applyPersistedMode(context: common.UIAbilityContext): ConfigurationConstant.ColorMode {
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    const colorMode = ColorModeManager.resolveMode(uiConfig.darkMode);
    context.getApplicationContext().setColorMode(colorMode);
    AppStorage.setOrCreate('currentColorMode', colorMode);
    ColorModeManager.publishEffectiveColorMode(context, uiConfig.darkMode);
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

  /**
   * 返回实际生效的颜色模式。当用户选择跟随系统时，读取系统当前颜色模式；
   * 否则返回用户显式设置的模式。用于状态栏内容颜色等需要知道“当前到底是深是浅”的场景。
   */
  static getEffectiveColorMode(context: common.UIAbilityContext): ConfigurationConstant.ColorMode {
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    if (uiConfig.darkMode === YourtubeDarkMode.SYSTEM) {
      // context.config.colorMode 可能为 undefined，fallback 到浅色以避免状态栏内容不可见。
      return context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return ColorModeManager.resolveMode(uiConfig.darkMode);
  }

  static isEffectiveDarkMode(context: common.UIAbilityContext): boolean {
    return ColorModeManager.getEffectiveColorMode(context) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  static publishEffectiveColorMode(context: common.UIAbilityContext, mode: YourtubeDarkMode): void {
    const effective = mode === YourtubeDarkMode.SYSTEM
      ? (context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)
      : ColorModeManager.resolveMode(mode);
    AppStorage.setOrCreate('effectiveColorMode', effective);
  }
}
