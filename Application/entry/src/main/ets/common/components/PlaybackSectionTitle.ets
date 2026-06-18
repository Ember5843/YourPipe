@Component
export struct PlaybackSectionTitle {
  @Prop title: ResourceStr;

  build() {
    Text(this.title)
      .fontSize(13)
      .fontColor($r('app.color.yourtube_text_hint'))
      .fontWeight(FontWeight.Medium)
      .margin({ left: 8, top: 16, bottom: 6 })
      .width('100%')
  }
}
