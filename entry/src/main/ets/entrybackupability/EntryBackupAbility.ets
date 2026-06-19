import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { AppLog } from '../common/AppLog';

const logger = AppLog.getInstance('EntryBackupAbility');

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup() {
    logger.info('onBackup ok');
    await Promise.resolve();
  }

  async onRestore(bundleVersion: BundleVersion) {
    logger.info(`onRestore ok ${JSON.stringify(bundleVersion)}`);
    await Promise.resolve();
  }
}