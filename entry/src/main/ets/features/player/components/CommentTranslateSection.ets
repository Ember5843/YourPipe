import { AppLog } from '../../../common/AppLog';
import { TranslationService } from '../../../common/TranslationService';

const logger = AppLog.getInstance('CommentTranslate');

/** Shared per-comment translation UI state (keyed by commentId). */
@Observed
export class CommentTranslateUiState {
  commentText: string = '';
  translated: string = '';
  /** translated 对应的目标语言；App 语言切换后旧译文失效 */
  language: string = '';
  context: string = '';
  requestGeneration: number = 0;
  translating: boolean = false;
  failed: boolean = false;
  showOriginal: boolean = false;
}

export class CommentTranslateStateStore {
  private static states: Map<string, CommentTranslateUiState> = new Map();
  /** 上限：浏览大量评论时状态对象不再无限累积（插入序近似 LRU 淘汰） */
  private static readonly MAX_STATES: number = 500;

  static refreshContext(state: CommentTranslateUiState): void {
    const context = TranslationService.contextKey();
    if (state.context === context) return;
    state.requestGeneration++;
    state.context = context;
    state.language = TranslationService.targetLanguage();
    state.translating = false;
    state.failed = false;
    state.showOriginal = false;
    state.translated = TranslationService.getCached(state.commentText) ?? '';
  }

  static get(commentId: string, commentText: string): CommentTranslateUiState {
    const lang = TranslationService.targetLanguage();
    const context = TranslationService.contextKey();
    let state = CommentTranslateStateStore.states.get(commentId);
    if (!state || state.commentText !== commentText) {
      state = new CommentTranslateUiState();
      state.commentText = commentText;
      state.language = lang;
      state.context = context;
      const cached = TranslationService.getCached(commentText);
      if (cached !== undefined) {
        state.translated = cached;
      }
      CommentTranslateStateStore.states.set(commentId, state);
      if (CommentTranslateStateStore.states.size > CommentTranslateStateStore.MAX_STATES) {
        const oldest = CommentTranslateStateStore.states.keys().next();
        if (!oldest.done) {
          CommentTranslateStateStore.states.delete(oldest.value);
        }
      }
    } else if (state.context !== context) {
      state.requestGeneration++;
      state.context = context;
      state.translating = false;
      // 目标语言已切换：旧译文失效，改用新语言缓存（没有则回到未翻译态）。
      state.translated = '';
      state.failed = false;
      state.showOriginal = false;
      const cached = TranslationService.getCached(commentText);
      if (cached !== undefined) {
        state.translated = cached;
      }
      state.language = lang;
    }
    return state;
  }

  /** 翻译完成后记录结果所用的目标语言（供语言切换失效判断）。 */
  static markTranslated(state: CommentTranslateUiState): void {
    state.language = TranslationService.targetLanguage();
  }
}

/** Translated text, rendered below the original comment text. */
@Component
export struct CommentTranslatedText {
  @ObjectLink state: CommentTranslateUiState;
  @StorageProp('translationContextRevision') @Watch('onContextChanged') private translationContextRevision: number = 0;

  private onContextChanged(): void { CommentTranslateStateStore.refreshContext(this.state); }

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
  @StorageProp('translationContextRevision') @Watch('onContextChanged') private translationContextRevision: number = 0;
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop commentId: string;

  private onContextChanged(): void { CommentTranslateStateStore.refreshContext(this.state); }

  private handleClick(): void {
    CommentTranslateStateStore.refreshContext(this.state);
    if (this.state.translating) {
      return;
    }
    if (this.state.translated) {
      this.state.showOriginal = !this.state.showOriginal;
      return;
    }
    this.state.translating = true;
    this.state.failed = false;
    const state = this.state;
    const context = TranslationService.contextKey();
    const language = TranslationService.targetLanguage();
    const generation = ++state.requestGeneration;
    TranslationService.translate(state.commentText)
      .then((result: string) => {
        if (generation !== state.requestGeneration || context !== TranslationService.contextKey()) return;
        state.translated = result;
        state.showOriginal = false;
        state.language = language;
        state.context = context;
        logger.info(`comment translated id=${this.commentId} len=${this.state.commentText.length}`);
      })
      .catch((e: Error) => {
        if (generation !== state.requestGeneration || context !== TranslationService.contextKey()) return;
        state.failed = true;
        logger.warn(`comment translate failed id=${this.commentId}: ${e.message || String(e)}`);
      })
      .finally(() => {
        if (generation === state.requestGeneration) state.translating = false;
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
