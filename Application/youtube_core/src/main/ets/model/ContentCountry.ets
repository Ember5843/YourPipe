import { Localization } from './Localization'; // 假设 Localization 也在同一目录下

export class ContentCountry {
  // 对应 Java: public static final ContentCountry DEFAULT
  // 使用 Lazy loading 或者直接引用 Localization 的静态属性
  public static readonly DEFAULT: ContentCountry = new ContentCountry("GB");

  // 对应 Java: private final String countryCode
  private readonly countryCode: string;

  // 对应 Java: public ContentCountry(@Nonnull final String countryCode)
  constructor(countryCode: string) {
    this.countryCode = countryCode;
  }

  // 对应 Java: public static List<ContentCountry> listFrom(final String... countryCodeList)
  // 使用剩余参数 (...codes) 来模拟 Java 的可变参数
  public static listFrom(...countryCodeList: string[]): ContentCountry[] {
    return countryCodeList.map(code => new ContentCountry(code));
  }

  // 对应 Java: public String getCountryCode()
  public getCountryCode(): string {
    return this.countryCode;
  }

  // 对应 Java: toString()
  public toString(): string {
    return this.getCountryCode();
  }

  // 对应 Java: equals()
  // 在 TS/JS 中，对象比较通常需要显式调用方法，不能重载 == 操作符
  public equals(o: Object): boolean {
    if (this === o) {
      return true;
    }
    if (!(o instanceof ContentCountry)) {
      return false;
    }
    return this.countryCode === (o as ContentCountry).countryCode;
  }

  // 对应 Java: hashCode()
  // TS 没有内置的 hashCode 机制用于 Map/Set，但在某些算法中可能需要。
  // 这是一个简单的字符串 hash 实现。
  public hashCode(): number {
    let hash = 0;
    if (this.countryCode.length === 0) return hash;
    for (let i = 0; i < this.countryCode.length; i++) {
      const char = this.countryCode.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash |= 0; // Convert to 32bit integer
    }
    return hash;
  }
}
