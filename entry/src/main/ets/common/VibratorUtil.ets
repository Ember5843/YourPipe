import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('VibratorUtil');

class VibratorUtil {
  public isAvailable(): boolean {
    return canIUse('SystemCapability.Sensors.MiscDevice');
  }

  public vibratorTriggerOfHapticClockTimer(): void {
    try {
      if (!vibrator.isSupportEffectSync(vibrator.EffectId.EFFECT_CLOCK_TIMER)) {
        logger.info(`#vibratorTriggerOfHapticClockTimer#isSupportEffectSync('${vibrator.EffectId.EFFECT_CLOCK_TIMER}') result is false`);
        return;
      }
      vibrator.startVibration(
        {
          type: 'preset',
          effectId: vibrator.EffectId.EFFECT_CLOCK_TIMER,
          count: 1,
        },
        {
          usage: 'physicalFeedback'
        }
      );
    } catch (error) {
      const e: BusinessError = error as BusinessError;
      logger.error(`ERROR: #vibratorTriggerOfHapticClockTimer# Code: ${e.code}, message: ${e.message}`);
    }
  }
}

export const customVibrator = new VibratorUtil();
