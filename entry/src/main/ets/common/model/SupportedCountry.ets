import {Localization } from 'youtube_core'; // 引用 Common 层
import { ContentCountry } from 'youtube_core';

export class YoutubeData {

  // 对应 Java 中的 SUPPORTED_LANGUAGES
  // 这里保留了你提供的注释掉的部分，只开启了 en-GB，你可以根据需要解开注释
  public static readonly SUPPORTED_LANGUAGES: Localization[] = Localization.listFrom(
    "en-GB", "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "da", "de",
    "el", "en", "es", "es-419", "es-US", "et", "eu", "fa", "fi", "fil", "fr",
    "fr-CA", "gl", "gu", "hi", "hr", "hu", "hy", "id", "is", "it", "iw", "ja",
    "ka", "kk", "km", "kn", "ko", "ky", "lo", "lt", "lv", "mk", "ml", "mn",
    "mr", "ms", "my", "ne", "nl", "no", "pa", "pl", "pt", "pt-PT", "ro", "ru",
    "si", "sk", "sl", "sq", "sr", "sr-Latn", "sv", "sw", "ta", "te", "th", "tr",
    "uk", "ur", "uz", "vi", "zh-CN", "zh-HK", "zh-TW", "zu"
  );

  // 对应 Java 中的 SUPPORTED_COUNTRIES
  // https://www.youtube.com/picker_ajax?action_country_json=1
  public static readonly SUPPORTED_COUNTRIES: ContentCountry[] = ContentCountry.listFrom(
    "DZ", "AR", "AU", "AT", "AZ", "BH", "BD", "BY", "BE", "BO", "BA", "BR", "BG", "KH",
    "CA", "CL", "CO", "CR", "HR", "CY", "CZ", "DK", "DO", "EC", "EG", "SV", "EE", "FI",
    "FR", "GE", "DE", "GH", "GR", "GT", "HN", "HK", "HU", "IS", "IN", "ID", "IQ", "IE",
    "IL", "IT", "JM", "JP", "JO", "KZ", "KE", "KW", "LA", "LV", "LB", "LY", "LI", "LT",
    "LU", "MY", "MT", "MX", "ME", "MA", "NP", "NL", "NZ", "NI", "NG", "MK", "NO", "OM",
    "PK", "PA", "PG", "PY", "PE", "PH", "PL", "PT", "PR", "QA", "RO", "RU", "SA", "SN",
    "RS", "SG", "SK", "SI", "ZA", "KR", "ES", "LK", "SE", "CH", "TW", "TZ", "TH", "TN",
    "TR", "UG", "UA", "AE", "GB", "US", "UY", "VE", "VN", "YE", "ZW"
  );
}
