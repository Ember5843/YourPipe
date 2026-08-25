/*
 * UIAbilityContext 注入入口。
 *
 * 目的：遵守"仅 entry 层可读 AppStorage"的规则——mediaservice 不再直接
 * AppStorage.get('context')，而是由 entry 在启动时通过
 * ContextProvider.setProvider() 注入读取实现。
 * 采用惰性 getter（与 PlaybackPreferences 同模式），不持有 context 快照，
 * 因此对注入时机与 UIAbility context 就绪顺序无要求。
 */

import { common } from '@kit.AbilityKit';

export type UIAbilityContextProvider = () => common.UIAbilityContext | undefined;

export class ContextProvider {
  private static provider: UIAbilityContextProvider | undefined = undefined;

  /** 由 entry 层在启动时调用，注入 UIAbilityContext 读取函数。 */
  public static setProvider(provider: UIAbilityContextProvider | undefined): void {
    ContextProvider.provider = provider;
  }

  /** 由引擎层调用，拿到当前 UIAbilityContext；未注入或读取失败时返回 undefined。 */
  public static get(): common.UIAbilityContext | undefined {
    const provider = ContextProvider.provider;
    if (!provider) {
      return undefined;
    }
    try {
      return provider();
    } catch {
      return undefined;
    }
  }
}
