@Component
export struct ExperimentalComingSoonPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

  build() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.clock'))
        .fontSize(40)
        .fontColor([this.themePrimary])
      Text($r('app.string.yt_exp_coming_soon'))
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_quaternary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32, bottom: 48 })
  }
}
