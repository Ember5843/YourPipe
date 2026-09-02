/**
 * Shared media thumbnail surface.
 * Uses ImageFit.Contain so portrait frames are not cropped.
 * On load failure for YouTube /vi/ stills, steps down: maxres → hq720 → sd → hq → mq.
 */
@Component
export struct MediaThumb {
  @Prop @Watch('onImageUrlPropChange') imageUrl: string = '';
  @Prop placeholderColor: string = '';
  @Prop thumbId: string = '';
  /** Fixed size mode (list rows). Ignored when fillParent is true. */
  @Prop widthVp: number = 160;
  @Prop heightVp: number = 90;
  /** Fill parent box (grid / banner). Pair with useAspectRatio for 16:9. */
  @Prop fillParent: boolean = false;
  @Prop useAspectRatio: boolean = false;
  /** Fill contain letterbox areas with a darkened cover copy of the thumbnail. */
  @Prop useCoverBackdrop: boolean = false;
  @Prop borderRadiusVp: number = 6;
  @Prop showLive: boolean = false;
  @Prop isLive: boolean = false;
  @Prop isPremium: boolean = false;
  @Prop requiresMembership: boolean = false;
  /** Optional string tag (e.g. "播放列表"). Resource labels should be resolved by caller. */
  @Prop typeLabel: string = '';
  @State private displayUrl: string = '';
  @State private fallbackIndex: number = 0;
  private fallbackUrls: string[] = [];

  aboutToAppear(): void {
    this.resetImageChain(this.imageUrl);
  }

  onImageUrlPropChange(): void {
    this.resetImageChain(this.imageUrl);
  }

  private bgColor(): ResourceColor {
    if (this.placeholderColor && this.placeholderColor.length > 0) {
      return this.placeholderColor;
    }
    return $r('app.color.yourtube_icon_hint');
  }

  private resetImageChain(url: string): void {
    this.fallbackUrls = MediaThumb.buildFallbackChain(url);
    this.fallbackIndex = 0;
    this.displayUrl = this.fallbackUrls.length > 0 ? this.fallbackUrls[0] : '';
  }

  /** 卡片首请求档 URL（五级回退链首项）；列表预取必须与 Image 首请求 URL 一致才能命中同一缓存 */
  static firstChoiceUrl(url: string): string {
    const chain: string[] = MediaThumb.buildFallbackChain(url);
    return chain.length > 0 ? chain[0] : '';
  }

  private static buildFallbackChain(url: string): string[] {
    const input = (url || '').trim();
    if (input.length === 0) {
      return [];
    }
    const match = /(?:^https?:\/\/)?(?:i\d*\.)?ytimg\.com\/vi(?:_webp)?\/([^/]+)\//i.exec(input);
    if (!match || !match[1]) {
      return [input];
    }
    const videoId = match[1];
    const chain: string[] = [
      `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`,
      `https://i.ytimg.com/vi/${videoId}/hq720.jpg`,
      `https://i.ytimg.com/vi/${videoId}/sddefault.jpg`,
      `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`,
      `https://i.ytimg.com/vi/${videoId}/mqdefault.jpg`
    ];
    // Prefer original first if it is already a high-quality non-standard path
    const normalized = input.startsWith('//') ? `https:${input}` :
      (input.startsWith('http://') ? `https://${input.slice('http://'.length)}` : input);
    if (chain.indexOf(normalized) < 0) {
      return [normalized].concat(chain);
    }
    // Start from the original tier so we don't re-request a known-bad higher tier forever
    const start = chain.indexOf(normalized);
    return chain.slice(start >= 0 ? start : 0);
  }

  private onImageError(): void {
    if (this.fallbackIndex + 1 < this.fallbackUrls.length) {
      this.fallbackIndex = this.fallbackIndex + 1;
      this.displayUrl = this.fallbackUrls[this.fallbackIndex];
    } else {
      this.displayUrl = '';
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.displayUrl && this.displayUrl.length > 0) {
        if (this.useCoverBackdrop) {
          Image(this.displayUrl)
            .width(this.fillParent ? '100%' : this.widthVp)
            .height(this.fillParent ? '100%' : this.heightVp)
            .objectFit(ImageFit.Cover)
            .borderRadius(this.borderRadiusVp)

          Rect()
            .width(this.fillParent ? '100%' : this.widthVp)
            .height(this.fillParent ? '100%' : this.heightVp)
            .fill('#73000000')
            .radius(this.borderRadiusVp)
        }

        if (this.thumbId.length > 0) {
          Image(this.displayUrl)
            .id(this.thumbId)
            .width(this.fillParent ? '100%' : this.widthVp)
            .height(this.fillParent ? '100%' : this.heightVp)
            .objectFit(ImageFit.Contain)
            .borderRadius(this.borderRadiusVp)
            .onError(() => {
              this.onImageError();
            })
        } else {
          Image(this.displayUrl)
            .width(this.fillParent ? '100%' : this.widthVp)
            .height(this.fillParent ? '100%' : this.heightVp)
            .objectFit(ImageFit.Contain)
            .borderRadius(this.borderRadiusVp)
            .onError(() => {
              this.onImageError();
            })
        }
      } else {
        Rect()
          .width(this.fillParent ? '100%' : this.widthVp)
          .height(this.fillParent ? '100%' : this.heightVp)
          .fill(this.bgColor())
          .radius(this.borderRadiusVp)
      }

      if (this.showLive && this.isLive) {
        // Reuse player LIVE style: red dot + LIVE label.
        Row({ space: 4 }) {
          Circle({ width: 6, height: 6 }).fill($r('app.color.yourtube_rec_indicator'))
          Text($r('app.string.yt_label_live'))
            .fontSize(8)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.yourtube_text_inverse'))
        }
        .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        .backgroundColor($r('app.color.yourtube_bg_live_tag'))
        .borderRadius({ topLeft: 4, bottomRight: 6 })
      }

      if (this.isPremium) {
        Text($r('app.string.yt_label_premium'))
          .fontSize(8)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor('#FFD700')
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 6, bottomRight: 6 })
          .position({ x: 0, y: 0 })
      }

      if (this.requiresMembership) {
        Text($r('app.string.yt_label_members_only'))
          .fontSize(8)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor('#1DB954')
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 4, bottomRight: 6 })
          .position({ x: 0, y: this.isPremium ? 20 : 0 })
      }

      if (this.typeLabel.length > 0) {
        Text(this.typeLabel)
          .fontSize(8)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor($r('app.color.yourtube_bg_tag'))
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 6, bottomRight: 6 })
          .position({ x: 0, y: 0 })
      }
    }
    .width(this.fillParent ? '100%' : this.widthVp)
    .height(this.fillParent && !this.useAspectRatio ? '100%' : (this.fillParent ? undefined : this.heightVp))
    .aspectRatio(this.fillParent && this.useAspectRatio ? (16 / 9) : undefined)
    .borderRadius(this.borderRadiusVp)
    .clip(true)
    .backgroundColor(this.bgColor())
  }
}
