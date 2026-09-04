/**
 * 卡片长按「下载」的提取等待弹窗：流提取（extractForDownload）期间显示，
 * 成功/失败后由调用方 close，再弹 DownloadDialog 或 toast。
 */
@CustomDialog
export struct DownloadPrepareDialog {
  controller: CustomDialogController;
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

  build() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(this.themePrimary)
      Text($r('app.string.yt_stream_loading'))
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
    }
    .padding({ left: 28, right: 28, top: 20, bottom: 20 })
    .borderRadius(16)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
  }
}
