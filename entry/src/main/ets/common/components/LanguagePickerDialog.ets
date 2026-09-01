export class LanguagePickerItem {
  code: string;
  /** 用户当前UI语言显示的名称, e.g. "英语" */
  localizedName: string;
  /** 该语言/地区自身的名称, e.g. "English" */
  nativeName: string;

  constructor(code: string, localizedName: string, nativeName: string) {
    this.code = code;
    this.localizedName = localizedName;
    this.nativeName = nativeName;
  }
}

/**
 * 翻译目标语言列表：'default' 项（显示文本由调用方给）+ 应用支持的语言
 * （去掉 default）+ 额外的翻译目标语言（非应用 UI 语言）。
 */
export function buildExtendedLanguageItems(appLangItems: LanguagePickerItem[], defaultLabel: string): LanguagePickerItem[] {
  const items: LanguagePickerItem[] = [new LanguagePickerItem('default', defaultLabel, defaultLabel)];
  for (const item of appLangItems) {
    if (item.code !== 'default') {
      items.push(item);
    }
  }
  // Extra translation targets that are not app UI languages.
  items.push(new LanguagePickerItem('it', 'Italiano', 'Italiano'));
  return items;
}
