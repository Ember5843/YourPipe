/**
 * 等价于 Java: org.schabi.newpipe.extractor.services.youtube.ClientsConstants
 *
 * 全局不可实例化常数类，用于保存不同 YouTube 客户端参数
 * （WEB、MOBILE、IOS、ANDROID、TVHTML5 等）
 */

export class ClientsConstants {
  private constructor() {} // 禁止实例化（与 Java 的 private 构造器等价）

  // =====================
  // Common client fields
  // =====================
  static readonly DESKTOP_CLIENT_PLATFORM: string = "DESKTOP";
  static readonly MOBILE_CLIENT_PLATFORM: string = "MOBILE";
  static readonly WATCH_CLIENT_SCREEN: string = "WATCH";
  static readonly EMBED_CLIENT_SCREEN: string = "EMBED";

  // =====================
  // WEB (YouTube desktop)
  // =====================
  static readonly WEB_CLIENT_ID: string = "1";
  static readonly WEB_CLIENT_NAME: string = "WEB";

  /**
   * The fallback hardcoded version for web client
   */
  static readonly WEB_HARDCODED_CLIENT_VERSION: string = "2.20250122.04.00";

  // =====================
  // WEB_REMIX (YouTube Music)
  // =====================
  static readonly WEB_REMIX_CLIENT_ID: string = "67";
  static readonly WEB_REMIX_CLIENT_NAME: string = "WEB_REMIX";
  static readonly WEB_REMIX_HARDCODED_CLIENT_VERSION: string = "1.20250122.01.00";

  // =====================
  // TVHTML5 (YouTube on Smart TVs & Consoles)
  // =====================
  static readonly TVHTML5_CLIENT_ID: string = "7";
  static readonly TVHTML5_CLIENT_NAME: string = "TVHTML5";
  static readonly TVHTML5_CLIENT_VERSION: string = "7.20250122.15.00";
  static readonly TVHTML5_CLIENT_PLATFORM: string = "GAME_CONSOLE";
  static readonly TVHTML5_DEVICE_MAKE: string = "Sony";
  static readonly TVHTML5_DEVICE_MODEL_AND_OS_NAME: string = "PlayStation 4";

  static readonly TVHTML5_USER_AGENT: string =
    "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) " +
      "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
      "Version/15.4 Safari/605.1.15";

  // =====================
  // WEB_EMBEDDED_PLAYER (YouTube embeds)
  // =====================
  static readonly WEB_EMBEDDED_CLIENT_ID: string = "56";
  static readonly WEB_EMBEDDED_CLIENT_NAME: string = "WEB_EMBEDDED_PLAYER";
  static readonly WEB_EMBEDDED_CLIENT_VERSION: string = "1.20250121.00.00";
  static readonly WEB_EMBEDDED_CLIENT_PLATFORM: string = "DESKTOP";
  static readonly WEB_EMBEDDED_USER_AGENT: string =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

  // =====================
  // WEB_MUSIC_ANALYTICS (YouTube charts)
  // =====================
  static readonly WEB_MUSIC_ANALYTICS_CLIENT_ID: string = "31";
  static readonly WEB_MUSIC_ANALYTICS_CLIENT_NAME: string = "WEB_MUSIC_ANALYTICS";
  static readonly WEB_MUSIC_ANALYTICS_CLIENT_VERSION: string = "2.0";

  // =====================
  // IOS (YouTube iOS App)
  // =====================
  static readonly IOS_CLIENT_ID: string = "5";
  static readonly IOS_CLIENT_NAME: string = "IOS";
  static readonly IOS_CLIENT_VERSION: string = "20.03.02";
  static readonly IOS_DEVICE_MODEL: string = "iPhone16,2";
  static readonly IOS_OS_VERSION: string = "18.2.1.22C161";
  static readonly IOS_USER_AGENT_VERSION: string = "18_2_1";

  // =====================
  // ANDROID (YouTube Android App)
  // =====================
  static readonly ANDROID_CLIENT_ID: string = "3";
  static readonly ANDROID_CLIENT_NAME: string = "ANDROID";
  static readonly ANDROID_CLIENT_VERSION: string = "21.03.36";
  static readonly ANDROID_OS_VERSION: string = "16";
  static readonly ANDROID_SDK_VERSION: string = "36";
  static readonly ANDROID_USER_AGENT: string =
    "com.google.android.youtube/21.03.36 (Linux; U; Android 16; GB) gzip";

  // =====================
  // ANDROID_VR (Android VR / Oculus Quest 3) — PipePipe 5.1.1
  // =====================
  static readonly ANDROID_VR_CLIENT_ID: string = "28";
  static readonly ANDROID_VR_CLIENT_NAME: string = "ANDROID_VR";
  static readonly ANDROID_VR_CLIENT_VERSION: string = "1.65.10";
  static readonly ANDROID_VR_DEVICE_MAKE: string = "Oculus";
  static readonly ANDROID_VR_DEVICE_MODEL: string = "Quest 3";
  static readonly ANDROID_VR_OS_VERSION: string = "12L";
  static readonly ANDROID_VR_SDK_VERSION: string = "32";
  static readonly ANDROID_VR_USER_AGENT: string =
    "com.google.android.apps.youtube.vr.oculus/" + "1.65.10" +
    " (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
  static readonly ANDROID_VR_YOUTUBE_KEY: string = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w";

  // =====================
  // Safari (WEB client with Safari UA) - aligned with PipePipe
  // =====================
  static readonly SAFARI_CLIENT_NAME: string = "WEB";
  static readonly SAFARI_CLIENT_VERSION: string = "2.20260114.08.00";
  static readonly SAFARI_USER_AGENT: string =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)";
  static readonly SAFARI_CLIENT_ID: string = "1";

  // =====================
  // TVHTML5 Embed (for age-restricted / fallback)
  // =====================
  static readonly TVHTML5_EMBED_CLIENT_VERSION: string = "7.20250923.13.00";

  // =====================
  // IOS User Agent
  // =====================
  static readonly IOS_USER_AGENT: string =
    "com.google.ios.youtube/20.03.02(iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X; GB)";

  // =====================
  // YouTube API URLs
  // =====================
  static readonly YOUTUBEI_V1_URL: string = "https://www.youtube.com/youtubei/v1/";
  static readonly YOUTUBEI_GAPIS_URL: string = "https://youtubei.googleapis.com/youtubei/v1/player";
  static readonly INNERTUBE_API_KEY: string = "AIzaSyBw-K-P3oV_O6m13v7C-C0p8n5v9m6o7p4";
}
