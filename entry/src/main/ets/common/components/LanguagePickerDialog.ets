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

@CustomDialog
export struct LanguagePickerDialog {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  controller: CustomDialogController = new CustomDialogController({ builder: LanguagePickerDialog({}) });
  title: ResourceStr = '';
  items: LanguagePickerItem[] = [];
  selectedCode: string = '';
  onSelect: (code: string) => void = (_code: string) => {};

  @State private searchQuery: string = '';
  @State private filteredItems: LanguagePickerItem[] = [];
  @State private localSelectedCode: string = '';

  aboutToAppear(): void {
    this.localSelectedCode = this.selectedCode;
    this.filteredItems = this.items.slice();
  }

  private filterItems(query: string): void {
    const q = query.trim().toLowerCase();
    if (q.length === 0) {
      this.filteredItems = this.items.slice();
    } else {
      this.filteredItems = this.items.filter((item: LanguagePickerItem): boolean =>
        item.code.toLowerCase().includes(q) ||
        item.localizedName.toLowerCase().includes(q) ||
        item.nativeName.toLowerCase().includes(q)
      );
    }
  }

  build() {
    Column() {
      // ── 标题栏 ──────────────────────────────────────────────
      Row() {
        Text(this.title as ResourceStr)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.yourtube_text_primary'))
          .layoutWeight(1)

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('app.color.yourtube_text_quaternary')])
        }
        .width(32)
        .height(32)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .onClick(() => { this.controller.close(); })
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 18, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      // ── 搜索框 ──────────────────────────────────────────────
      TextInput({ placeholder: $r('app.string.yt_placeholder_search') })
        .onChange((val: string) => {
          this.searchQuery = val;
          this.filterItems(val);
        })
        .height(38)
        .borderRadius(10)
        .fontSize(14)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .margin({ left: 16, right: 16, bottom: 6 })

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.yourtube_divider'))

      // ── 列表 ──────────────────────────────────────────────
      List() {
        ForEach(this.filteredItems, (item: LanguagePickerItem) => {
          ListItem() {
            Row() {
              // 选中标记
              SymbolGlyph(this.localSelectedCode === item.code
                ? $r('sys.symbol.checkmark_circle_fill')
                : $r('sys.symbol.circle'))
                .fontSize(20)
                .fontColor([this.localSelectedCode === item.code
                  ? this.themePrimary
                  : $r('app.color.yourtube_text_quaternary')])
                .width(28)
                .flexShrink(0)
                .margin({ right: 10 })

              // 双行文本
              Column() {
                // 主行：目标语言自己的写法 (native)
                Text(item.nativeName)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.localSelectedCode === item.code
                    ? this.themePrimary
                    : $r('app.color.yourtube_text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                // 副行：当前UI语言下的名称（与主行不同时才显示）
                if (item.nativeName !== item.localizedName) {
                  Text(item.localizedName)
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_quaternary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 1 })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              // 右侧语言代码 badge
              Text(item.code)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
                .borderRadius(4)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .flexShrink(0)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 9, bottom: 9 })
            .onClick(() => {
              this.localSelectedCode = item.code;
              this.onSelect(item.code);
              this.controller.close();
            })
          }
        }, (item: LanguagePickerItem) => item.code)
      }
      .width('100%')
      .layoutWeight(1)
      .divider({
        strokeWidth: 0.5,
        color: $r('app.color.yourtube_divider'),
        startMargin: 54
      })
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('85%')
    .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
    .borderRadius({ topLeft: 20, topRight: 20 })
    .clip(true)
  }
}

@CustomDialog
export struct UIPickerLanguageDialog {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  controller: CustomDialogController = new CustomDialogController({ builder: UIPickerLanguageDialog({}) });
  title: ResourceStr = '';
  items: LanguagePickerItem[] = [];
  selectedCode: string = '';
  onConfirm: (code: string) => void = () => {};

  @State private selectedIndex: number = 0;

  aboutToAppear(): void {
    this.selectedIndex = Math.max(0, this.items.findIndex(it => it.code === this.selectedCode));
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button($r('app.string.yt_action_cancel'))
          .fontSize(16)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .onClick(() => {
            this.controller.close();
          })

        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Button($r('app.string.yt_action_confirm'))
          .fontSize(16)
          .backgroundColor(Color.Transparent)
          .fontColor(this.themePrimary)
          .onClick(() => {
            const code = this.items[this.selectedIndex].code;
            this.onConfirm(code);
            this.controller.close();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .justifyContent(FlexAlign.SpaceBetween)

      Divider()
        .color($r('app.color.yourtube_divider'))

      // 滚轮选择器
      UIPickerComponent({ selectedIndex: this.selectedIndex }) {
        ForEach(this.items, (item: LanguagePickerItem) => {
          Text(item.localizedName)
            .fontSize(18)
        })
      }
      .width('100%')
      .height(240)
      .canLoop(false)
      .onChange((selectedIndex: number) => {
        this.selectedIndex = selectedIndex;
      })
      .onScrollStop((selectedIndex: number) => {
        this.selectedIndex = selectedIndex;
      })
    }
    .width('85%')
    .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
    .borderRadius(20)
  }
}
