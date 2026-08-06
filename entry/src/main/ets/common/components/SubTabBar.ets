/**
 * Shared sub-tab bar item builder (Local / Player / Channel pages).
 * Unified spec: bar height 48vp, label 16fp,
 * selected = FontWeight.Medium + theme color,
 * unselected = FontWeight.Normal + yourtube_text_secondary,
 * indicator = Divider 36vp wide, strokeWidth 2, theme color (opacity toggle).
 */
@Builder
export function SubTabBarItem(label: ResourceStr, selected: boolean, themePrimary: ResourceColor) {
  Column() {
    Text(label)
      .fontSize(16)
      .fontColor(selected ? themePrimary : $r('app.color.yourtube_text_secondary'))
      .fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
      .margin({ top: 12, bottom: 6 })
      .maxLines(1)
    Divider()
      .width(36)
      .strokeWidth(2)
      .color(themePrimary)
      .opacity(selected ? 1 : 0)
  }
  .width('100%')
}
