@Component
export struct PlaybackToggleRow {
  @Prop title: ResourceStr;
  @Prop subtitle: ResourceStr = '';
  @Prop @Watch('onIsOnPropChange') isOn: boolean;
  @Prop themeColor: ResourceColor = '#E53935';
  @Prop transparentBackground: boolean = false;
  onChange?: (val: boolean) => void;

  /**
   * 开关状态由本组件**本地自持**（`$$` 双向绑定），父级只负责下发意图。
   *
   * <p>为什么不能直接用受控写法 `Toggle({ isOn: this.isOn })`：ArkUI 的 Toggle
   * 在 `isOn` 被父级**程序化**改写时同样会回调 `onChange`，于是形成
   * 「父级回写 → onChange → 父级再回写」的回路；受控写法下每次回写都会
   * 重启开关动画，用户点下去看到的就是「快速打开然后关闭」，配置也可能被
   * 回路里的旧值覆盖。
   *
   * <p>本地自持 + 只在父级值与本地值**真的不同**时才同步，动画就不会被
   * 程序化回写打断。
   */
  @State localOn: boolean = false;
  /** 用户最近一次的操作值：父级回写同一个值时不再驱动本地状态。 */
  private pendingValue: boolean = false;
  private hasPending: boolean = false;

  aboutToAppear() {
    this.localOn = this.isOn;
  }

  onIsOnPropChange(): void {
    if (this.isOn === this.localOn) {
      // 值没变（例如父级把同一个配置又写了一遍）——不动本地状态。
      return;
    }
    if (this.hasPending && this.isOn === this.pendingValue) {
      // 父级回写的就是用户刚选的值：保持本地状态，只清标记。
      this.hasPending = false;
      return;
    }
    this.hasPending = false;
    this.localOn = this.isOn;
  }

  build() {
    Row({ space: 12 }) {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_primary'))
        if (!(typeof this.subtitle === 'string' && this.subtitle.length === 0)) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: $$this.localOn })
        .selectedColor(this.themeColor)
        .onChange((val: boolean) => {
          this.localOn = val;
          this.pendingValue = val;
          this.hasPending = true;
          if (this.onChange) {
            this.onChange(val);
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(this.transparentBackground ? 0 : 16)
    .backgroundColor(this.transparentBackground ? Color.Transparent : $r('app.color.yourtube_bg_surface_muted'))
  }
}
