import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { YTCoreLogger } from '../common/YTCoreLogger';

const logger = YTCoreLogger.getInstance('SapisidHashUtil');

export class SapisidHashUtil {
  static async generate(sapisid: string, origin: string = 'https://www.youtube.com'): Promise<string> {
    const timestamp = Math.floor(Date.now() / 1000);
    const input = `${timestamp} ${sapisid} ${origin}`;
    const hash = await SapisidHashUtil.sha1(input);
    if (hash.length === 0) {
      // sha1 失败时不拼畸形头（'SAPISIDHASH ts_'），调用方按空值跳过注入
      return '';
    }
    return `SAPISIDHASH ${timestamp}_${hash}`;
  }

  private static async sha1(input: string): Promise<string> {
    try {
      const md = cryptoFramework.createMd('SHA1');
      const inputBlob: cryptoFramework.DataBlob = {
        data: new Uint8Array(buffer.from(input, 'utf-8').buffer)
      };
      await md.update(inputBlob);
      const digest = await md.digest();
      return SapisidHashUtil.bytesToHex(digest.data);
    } catch (e) {
      logger.error('SHA1 computation failed');
      return '';
    }
  }

  private static bytesToHex(bytes: Uint8Array): string {
    const hexChars: string[] = [];
    for (let i = 0; i < bytes.length; i++) {
      const byte = bytes[i];
      hexChars.push(SapisidHashUtil.byteToHex(byte));
    }
    return hexChars.join('');
  }

  private static byteToHex(byte: number): string {
    const hi = (byte >> 4) & 0x0F;
    const lo = byte & 0x0F;
    return SapisidHashUtil.nibbleToChar(hi) + SapisidHashUtil.nibbleToChar(lo);
  }

  private static nibbleToChar(nibble: number): string {
    if (nibble < 10) {
      return String.fromCharCode(48 + nibble);
    }
    return String.fromCharCode(97 + nibble - 10);
  }
}
