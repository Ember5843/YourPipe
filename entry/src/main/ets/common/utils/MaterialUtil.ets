import { BusinessError } from '@kit.BasicServicesKit';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { AppLog } from '../AppLog';

const logger = AppLog.getInstance('MaterialUtil');
const HDS_SYSCAP = 'SystemCapability.UIDesign.HDSComponent.Core';

export class MaterialUtil {
  private static cached: boolean | null = null;

  /**
   * 检测当前设备是否支持沉浸光感材质（HarmonyOS 6.1 / API 23+ 设备能力）。
   * 判定条件：
   *   1. canIUse('SystemCapability.UIDesign.HDSComponent.Core') —— 旧设备无此 syscap
   *   2. hdsMaterial.getSystemMaterialTypes().length > 0 —— 设备能力白名单
   * 不支持时直接返回 false，让调用方走"不传 systemMaterialEffect"的降级路径，
   * 避免低端机 / 官方模拟器上出现"灰白实色玻璃"的反效果。
   */
  public static supportsImmersive(): boolean {
    if (MaterialUtil.cached !== null) {
      return MaterialUtil.cached;
    }
    let ok: boolean = false;
    try {
      const syscapOk: boolean = canIUse(HDS_SYSCAP);
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      ok = syscapOk && types.length > 0;
      logger.info(`supportsImmersive syscapOk=${syscapOk} types=${JSON.stringify(types)} -> ${ok}`);
    } catch (e) {
      const err = e as BusinessError;
      logger.warn(`supportsImmersive check failed: code=${err.code} msg=${err.message}`);
      ok = false;
    }
    MaterialUtil.cached = ok;
    return ok;
  }

  /**
   * 获取适合当前设备的 systemMaterialEffect。
   * 支持时返回 ADAPTIVE/ADAPTIVE；不支持时返回 undefined，让 HdsTabs / titleBar 走默认渲染。
   */
  public static getSystemMaterialEffect(): SystemMaterialParams | undefined {
    if (!MaterialUtil.supportsImmersive()) {
      return undefined;
    }
    return {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
    };
  }
}
