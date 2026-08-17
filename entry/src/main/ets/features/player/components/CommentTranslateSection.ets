import { AppLog } from '../../../common/AppLog';
import { TranslationService } from '../../../common/TranslationService';

const logger = AppLog.getInstance('CommentTranslate');

/** Shared per-comment translation UI state (keyed by commentId). */
@Observed
export class CommentTranslateUiState {
  commentText: string = '';
  translated: string = '';
  translating: boolean = false;
  failed: boolean = false;
  showOriginal: boolean = false;
}

export class CommentTranslateStateStore {
  private static states: Map<string, CommentTranslateUiState> = new Map();

  static get(commentId: string, commentText: string): CommentTranslateUiState {
    let state = CommentTranslateStateStore.states.get(commentId);
    if (!state || state.commentText !== commentText) {
      state = new CommentTranslateUiState();
      state.commentText = commentText;
      const cached = TranslationService.getCached(commentText);
      if (cached !== undefined) {
        state.translated = cached;
      }
      CommentTranslateStateStore.states.set(commentId, state);
    }
    return state;
  }
}

/** Translated text, rendered below the original comment text. */
@Component
export struct CommentTranslatedText {
  @ObjectLink state: CommentTranslateUiState;

  build() {
    if (this.state.translated && !this.state.showOriginal) {
      Text(this.state.translated)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .lineHeight(20)
        .textAlign(TextAlign.Start)
        .width('100%')
        .margin({ top: 6 })
    }
  }
}

/** Translate toggle button, rendered inline in the comment action row. */
@Component
export struct CommentTranslateButton {
  @ObjectLink state: CommentTranslateUiState;
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop commentId: string;

  private handleClick(): void {
    if (this.state.translating) {
      return;
    }
    if (this.state.translated) {
      this.state.showOriginal = !this.state.showOriginal;
      return;
    }
    this.state.translating = true;
    this.state.failed = false;
    TranslationService.translate(this.state.commentText)
      .then((result: string) => {
        this.state.translated = result;
        this.state.showOriginal = false;
        logger.info(`comment translated id=${this.commentId} len=${this.state.commentText.length}`);
      })
      .catch((e: Error) => {
        this.state.failed = true;
        logger.warn(`comment translate failed id=${this.commentId}: ${e.message || String(e)}`);
      })
      .finally(() => {
        this.state.translating = false;
      });
  }

  build() {
    Row() {
      if (this.state.translating) {
        LoadingProgress().width(14).height(14).color(this.themePrimary)
        Text($r('app.string.yt_translating'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ left: 4 })
      } else {
        SymbolGlyph($r('sys.symbol.translate'))
          .fontSize(14)
          .fontColor([this.state.failed ? $r('app.color.yourtube_text_quaternary') : this.themePrimary])
        Text(this.state.failed
          ? $r('app.string.yt_translate_failed')
          : (this.state.translated && !this.state.showOriginal
            ? $r('app.string.yt_show_original')
            : $r('app.string.yt_translate_action')))
          .fontSize(12)
          .fontColor(this.state.failed ? $r('app.color.yourtube_text_quaternary') : this.themePrimary)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 4 })
      }
    }
    .onClick(() => this.handleClick())
  }
}
