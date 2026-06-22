import { LanguagePickerItem } from './LanguagePickerDialog';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildYourTubeTitleBar } from './HdsTitleBar';

@Component
export struct LanguagePickerPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Prop title: ResourceStr = '';
  @Prop items: LanguagePickerItem[] = [];
  @Prop selectedCode: string = '';
  onSelect: (code: string) => void = () => {};
  onBack: () => void = () => {};

  @State private searchQuery: string = '';
  @State private filteredItems: LanguagePickerItem[] = [];

  aboutToAppear(): void {
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

  @Builder
  SearchInputBar() {
    TextInput({ placeholder: $r('app.string.yt_placeholder_search') })
      .onChange((val: string) => {
        this.searchQuery = val;
        this.filterItems(val);
      })
      .height(38)
      .borderRadius(19)
      .fontSize(14)
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .margin({ left: 16, right: 16, bottom: 8 })
  }

  build() {
    HdsNavDestination() {
      Column() {
        List() {
          ForEach(this.filteredItems, (item: LanguagePickerItem) => {
            ListItem() {
              Row() {
                SymbolGlyph(this.selectedCode === item.code
                  ? $r('sys.symbol.checkmark_circle_fill')
                  : $r('sys.symbol.circle'))
                  .fontSize(20)
                  .fontColor([this.selectedCode === item.code
                    ? this.themePrimary
                    : $r('app.color.yourtube_text_quaternary')])
                  .width(28)
                  .flexShrink(0)
                  .margin({ right: 10 })

                Column() {
                  Text(item.nativeName)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.selectedCode === item.code
                      ? this.themePrimary
                      : $r('app.color.yourtube_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

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
                this.onSelect(item.code);
                this.onBack();
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
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: this.title,
      onBack: () => {
        this.onBack();
      },
      bottomBuilder: () => { this.SearchInputBar() },
      bottomHeight: 54
    }))
    .onBackPressed(() => {
      this.onBack();
      return true;
    })
  }
}
