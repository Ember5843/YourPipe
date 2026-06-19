//import { ParsingException } from '../exceptions/ParsingException';

// 1. 在文件顶部或外部定义这个类
class ParsingException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ParsingException';
  }
}
// 为了保持代码独立性，这里模拟一个简单的 Locale 接口，
// 在实际项目中，你可能需要一个更完整的 Locale 工具类。
export class Locale {
  private language: string;
  private country: string;

  constructor(language: string, country: string = "") {
    this.language = language;
    this.country = country;
  }

  public getLanguage(): string {
    return this.language;
  }

  public getCountry(): string {
    return this.country;
  }

  // 注意：在 JS/ArkTS 环境中，没有内置的 ISO 639-2 (3字母) 到 ISO 639-1 (2字母) 的完整映射表。
  // 如果需要此功能，通常需要引入第三方库 (如 'iso-639-1')。
  // 这里仅作为占位符，模拟 Java Locale 的行为。
  public getISO3Language(): string {
    // 这是一个极其简化的实现，实际需要查表
    return this.language.length === 3 ? this.language : this.language + "xx";
  }
}

export class Localization {
  public static readonly DEFAULT: Localization = new Localization("en", "GB");

  private readonly languageCode: string;
  private readonly countryCode: string | null;

  constructor(languageCode: string, countryCode: string | null = null) {
    this.languageCode = languageCode;
    this.countryCode = countryCode;
  }

  /**
   * @param localizationCodeList a list of localization code
   * @throws Error If any of the localizationCodeList is formatted incorrectly
   * @return list of Localization objects
   */
  public static listFrom(...localizationCodeList: string[]): Localization[] {
    const toReturn: Localization[] = [];
    for (const localizationCode of localizationCodeList) {
      const loc = Localization.fromLocalizationCode(localizationCode);
      if (loc) {
        toReturn.push(loc);
      } else {
        throw new Error("Not a localization code: " + localizationCode);
      }
    }
    return toReturn;
  }

  /**
   * @param localizationCode a localization code, formatted like "en-US" or "en"
   * @return A Localization, if the code was valid.
   */
  public static fromLocalizationCode(localizationCode: string): Localization | null {
    // 模拟 LocaleCompat.forLanguageTag 的逻辑
    // 处理 "en-US", "en_US", "en"
    if (!localizationCode) {
      return null;
    }

    // 将下划线替换为短横线以符合 IETF BCP 47 标准
    const normalized = localizationCode.replace('_', '-');
    const parts = normalized.split('-');

    if (parts.length > 0 && parts[0].length > 0) {
      const lang = parts[0];
      const country = parts.length > 1 ? parts[1] : null;
      // 这里我们直接创建 Localization，跳过了中间的 Locale 对象转换，
      // 因为在 Java 中 LocaleCompat 主要是为了处理旧版 Android 的兼容性。
      return new Localization(lang, country);
    }

    return null;
  }

  public getLanguageCode(): string {
    return this.languageCode;
  }

  public getCountryCode(): string {
    return this.countryCode === null ? "" : this.countryCode;
  }

  public static fromLocale(locale: Locale): Localization {
    return new Localization(locale.getLanguage(), locale.getCountry());
  }

  /**
   * Return a formatted string in the form of: {@code language-Country}, or
   * just {@code language} if country is {@code null}.
   *
   * @return A correctly formatted localizationCode for this localization.
   */
  public getLocalizationCode(): string {
    return this.languageCode + (this.countryCode === null ? "" : "-" + this.countryCode);
  }

  public toString(): string {
    return "Localization[" + this.getLocalizationCode() + "]";
  }

  public equals(o: Object): boolean {
    if (this === o) {
      return true;
    }
    if (!(o instanceof Localization)) {
      return false;
    }

    const that = o as Localization;

    return this.languageCode === that.languageCode
      && this.countryCode === that.countryCode;
  }

  public hashCode(): number {
    let result = this.stringHashCode(this.languageCode);
    // 31 * result + hashCode(countryCode)
    const countryHash = this.countryCode === null ? 0 : this.stringHashCode(this.countryCode);
    result = 31 * result + countryHash;
    return result | 0; // 强制转换为 32 位整数
  }

  // 辅助方法：计算字符串 HashCode
  private stringHashCode(str: string): number {
    let hash = 0;
    if (str.length === 0) return hash;
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash |= 0;
    }
    return hash;
  }

  /**
   * Converts a three letter language code (ISO 639-2/T) to a Locale
   * because limits of Java Locale class.
   *
   * @param code a three letter language code
   * @return the Locale corresponding
   */
  public static getLocaleFromThreeLetterCode(code: string): Locale {
    // 警告：Java 的 Locale.getISOLanguages() 返回一个巨大的内置列表。
    // 在 JS/ArkTS 中没有内置 API 可以直接完成 "3字母代码 -> 2字母代码 Locale" 的反向查找。
    //
    // 解决方案：
    // 1. 如果业务逻辑强依赖此功能，需要引入一个 ISO-639 JSON 映射表。
    // 2. 如果只是为了特定几个语言（如 chi, zho, eng），可以硬编码。
    //
    // 下面是一个基于常见情况的模拟实现：

    const threeToTwoMap: Record<string, string> = {
      'eng': 'en',
      'deu': 'de',
      'ger': 'de',
      'fra': 'fr',
      'fre': 'fr',
      'zho': 'zh',
      'chi': 'zh',
      'jpn': 'ja',
      'kor': 'ko',
      'spa': 'es',
      'rus': 'ru'
      // ... 更多映射需要根据需求添加
    };

    if (threeToTwoMap[code]) {
      return new Locale(threeToTwoMap[code]);
    }

    // 如果找不到映射，Java 代码会遍历所有 Locale 尝试匹配 ISO3Language。
    // 这里如果找不到，我们抛出异常，或者尝试直接使用该 code (如果它本身就是有效的)
    throw new ParsingException(
      "Could not get Locale from this three letter language code: " + code +
        ". (Note: Full ISO mapping requires a lookup table in ArkTS)"
    );
  }
}
