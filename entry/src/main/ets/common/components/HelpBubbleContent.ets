interface HelpBulletItem {
  lead: string;
  body: string;
}

interface ParsedHelpContent {
  title: string;
  items: HelpBulletItem[];
}

/**
 * HarmonyOS Popup speech-bubble content following ArkUI Popup specs:
 * - Fixed deterministic widths (288vp root -> 256vp rows -> 224vp/242vp text)
 *   so ArkUI's CustomPopupOptions measurement pass never overflows horizontally or vertically.
 * - Clear 2-level hierarchy: 16fp Bold title + concise 15fp bullets with accent-bold lead tags.
 */
@Component
export struct HelpBubbleContent {
  @Prop helpText: ResourceStr = '';
  @Prop accentColor: ResourceColor = '#E53935';
  onDismiss?: () => void;

  private resolveRawText(): string {
    if (typeof this.helpText === 'string') {
      return this.helpText;
    }
    try {
      return getContext(this).resourceManager.getStringSync(this.helpText.id);
    } catch (_) {
      return '';
    }
  }

  private parseContent(): ParsedHelpContent {
    const raw = this.resolveRawText().replace(/\r/g, '');
    const lines = raw.split('\n').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
    if (lines.length === 0) {
      return { title: '', items: [] };
    }
    if (lines.length === 1) {
      return {
        title: '',
        items: [this.splitBullet(lines[0])]
      };
    }
    const items: HelpBulletItem[] = [];
    for (let i = 1; i < lines.length; i++) {
      items.push(this.splitBullet(lines[i]));
    }
    return {
      title: lines[0],
      items: items
    };
  }

  private splitBullet(line: string): HelpBulletItem {
    const cleaned = line.replace(/^[•·\-]\s*/, '');
    const fullIdx = cleaned.indexOf('：');
    const asciiIdx = cleaned.indexOf(':');
    let splitIdx = -1;
    if (fullIdx > 0 && asciiIdx > 0) {
      splitIdx = Math.min(fullIdx, asciiIdx);
    } else if (fullIdx > 0) {
      splitIdx = fullIdx;
    } else if (asciiIdx > 0) {
      splitIdx = asciiIdx;
    }
    if (splitIdx > 0 && splitIdx <= 24) {
      const isAscii = cleaned.charAt(splitIdx) === ':';
      const lead = cleaned.substring(0, splitIdx + 1) + (isAscii ? ' ' : '');
      const body = cleaned.substring(splitIdx + 1).trimStart();
      return { lead: lead, body: body };
    }
    return { lead: '', body: cleaned };
  }

  build() {
    Column({ space: 10 }) {
      this.BubbleBody(this.parseContent())
    }
    .width(288)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      if (this.onDismiss) {
        this.onDismiss();
      }
    })
  }

  @Builder
  private BubbleBody(parsed: ParsedHelpContent) {
    if (parsed.title.length > 0) {
      Row({ space: 8 }) {
        Text(parsed.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .lineHeight(22)
          .fontColor($r('sys.color.font_primary'))
          .width(224)
          .wordBreak(WordBreak.BREAK_WORD)

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width(24)
        .height(24)
      }
      .width(256)
      .alignItems(VerticalAlign.Center)
    }

    Column({ space: 8 }) {
      ForEach(parsed.items, (item: HelpBulletItem) => {
        Row({ space: 8 }) {
          Circle({ width: 6, height: 6 })
            .fill(this.accentColor)
            .margin({ top: 8 })

          Text() {
            if (item.lead.length > 0) {
              Span(item.lead)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.accentColor)
            }
            Span(item.body)
              .fontSize(15)
              .fontWeight(FontWeight.Regular)
              .fontColor($r('sys.color.font_primary'))
          }
          .fontSize(15)
          .lineHeight(22)
          .width(242)
          .wordBreak(WordBreak.BREAK_WORD)
        }
        .width(256)
        .alignItems(VerticalAlign.Top)
      }, (_item: HelpBulletItem, index: number) => `${index}`)
    }
    .width(256)
  }
}
