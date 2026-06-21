/**
 * API 配置 — 控制解密服务地址切换
 *
 * USE_LOCAL_API = true  → 使用本地 yt-dlp 解密服务（通过 USB hdc reverse 或 WiFi 局域网）
 * USE_LOCAL_API = false → 使用远程 PipePipe API
 *
 * USB 反向代理设置步骤：
 *   hdc reverse tcp:8899 tcp:8899
 *   应用通过 http://127.0.0.1:8899 访问电脑上的解密服务
 */

export class ApiConfig {
  /** 是否使用本地解密服务 */
  static readonly USE_LOCAL_API: boolean = true;

  /** 本地解密服务地址（USB hdc reverse 模式） */
  static readonly LOCAL_DECODE_URL: string = 'http://127.0.0.1:8899';

  /** 远程 PipePipe API 地址 */
  static readonly REMOTE_DECODE_URL: string = 'https://api.pipepipe.dev';

  /**
   * 获取当前生效的解密服务基础 URL
   * @returns 基础 URL（不含路径，如 'http://127.0.0.1:8899'）
   */
  static getDecodeBaseUrl(): string {
    return ApiConfig.USE_LOCAL_API
      ? ApiConfig.LOCAL_DECODE_URL
      : ApiConfig.REMOTE_DECODE_URL;
  }

  /**
   * 获取 decode 端点完整 URL
   * @returns 完整 URL（如 'http://127.0.0.1:8899/decoder/decode'）
   */
  static getDecodeUrl(): string {
    return ApiConfig.getDecodeBaseUrl() + '/decoder/decode';
  }

  /**
   * 获取 latest-player 端点完整 URL
   * @returns 完整 URL
   */
  static getLatestPlayerUrl(): string {
    return ApiConfig.getDecodeBaseUrl() + '/decoder/latest-player';
  }

  /**
   * 是否正在使用本地 API
   * @returns boolean
   */
  static isUsingLocalApi(): boolean {
    return ApiConfig.USE_LOCAL_API;
  }
}
