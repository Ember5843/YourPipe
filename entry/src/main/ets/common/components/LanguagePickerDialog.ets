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
