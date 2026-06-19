# 图标小符号 (SymbolGlyph/SymbolSpan)

SymbolGlyph是图标小符号组件，便于使用精美的图标，如渲染多色图标和使用动效图标。SymbolSpan作为Text组件的子组件，可在文本中穿插显示图标小符号。具体用法请参考[SymbolGlyph](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md)和[SymbolSpan](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md)组件的文档。

## 创建图标

``` TypeScript
SymbolGlyph($r('sys.symbol.ohos_folder_badge_plus'))
  .fontSize(96)
  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
  .fontColor([Color.Black, Color.Green, Color.White])
```

## 添加到文本中

[SymbolSpan](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md)可作为[Text](../reference/apis-arkui/arkui-ts/ts-basic-components-text.md)的子组件用于显示图标小符号。可以在一个Text组件内添加多个SymbolSpan，从而展示一串连续的图标。  

- 创建SymbolSpan。

  SymbolSpan组件需嵌入在Text组件中才能显示，单独使用不会呈现任何内容。

  
  ``` TypeScript
  Text() {
    SymbolSpan($r('sys.symbol.ohos_trash'))
      .fontWeight(FontWeight.Normal)
      .fontSize(96)
  }
  ```

- 通过[fontSize](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md#fontsize)属性设置SymbolSpan的大小。

  
  ``` TypeScript
  Row() {
    Column() {
      Text('48')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(48)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.Black, Color.Green, Color.White])
      }
    }
  
    Column() {
      Text('72')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(72)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.Black, Color.Green, Color.White])
      }
    }
  
    Column() {
      Text('96')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.Black, Color.Green, Color.White])
      }
    }
  }
  ```

- 通过[fontWeight](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md#fontweight)属性设置SymbolSpan组件的粗细。

  
  ``` TypeScript
  Row() {
    Column() {
      Text('Light')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_trash'))
          .fontWeight(FontWeight.Lighter)
          .fontSize(96)
      }
    }
  
    Column() {
      Text('Normal')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_trash'))
          .fontWeight(FontWeight.Normal)
          .fontSize(96)
      }
    }
  
    Column() {
      Text('Bold')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_trash'))
          .fontWeight(FontWeight.Bold)
          .fontSize(96)
      }
    }
  }
  ```
  

- 通过[fontColor](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md#fontcolor)属性设置SymbolSpan的颜色。

  
  ``` TypeScript
  Row() {
    Column() {
      Text('Black')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .fontColor([Color.Black])
      }
    }
  
    Column() {
      Text('Green')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .fontColor([Color.Green])
      }
    }
  
    Column() {
      Text('Pink')
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .fontColor([Color.Pink])
      }
    }
  }
  ```

- 通过[renderingStrategy](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md#renderingstrategy)属性设置SymbolSpan的渲染策略。

  
  ``` TypeScript
  Row() {
    Column() {
      // 请将$r('app.string.single_color')替换为实际资源文件，在本示例中该资源文件的value值为"单色"
      Text($r('app.string.single_color'));
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([Color.Black, Color.Green, Color.White])
      }
    }
  
    Column() {
      // 请将$r('app.string.multi_color')替换为实际资源文件，在本示例中该资源文件的value值为"多色"
      Text($r('app.string.multi_color'));
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
          .fontColor([Color.Black, Color.Green, Color.White])
      }
    }
  
    Column() {
      // 请将$r('app.string.hierarchical')替换为实际资源文件，在本示例中该资源文件的value值为"分层"
      Text($r('app.string.hierarchical'));
      Text() {
        SymbolSpan($r('sys.symbol.ohos_folder_badge_plus'))
          .fontSize(96)
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
          .fontColor([Color.Black, Color.Green, Color.White])
      }
    }
  }
  ```

- 通过[effectStrategy](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolSpan.md#effectstrategy)属性设置SymbolSpan的动效策略。

  
  ``` TypeScript
  Row() {
    Column() {
      // 请将$r('app.string.no_action')替换为实际资源文件，在本示例中该资源文件的value值为"无动效"
      Text($r('app.string.no_action'));
      Text() {
        SymbolSpan($r('sys.symbol.ohos_wifi'))
          .fontSize(96)
          .effectStrategy(SymbolEffectStrategy.NONE)
      }
    }
  
    Column() {
      // 请将$r('app.string.overall_scaling_animation_effect')替换为实际资源文件，在本示例中该资源文件的value值为"整体缩放动效"
      Text($r('app.string.overall_scaling_animation_effect'));
      Text() {
        SymbolSpan($r('sys.symbol.ohos_wifi'))
          .fontSize(96)
          .effectStrategy(SymbolEffectStrategy.SCALE)
      }
    }
  
    Column() {
      // 请将$r('app.string.hierarchical_animation')替换为实际资源文件，在本示例中该资源文件的value值为"层级动效"
      Text($r('app.string.hierarchical_animation'));
      Text() {
        SymbolSpan($r('sys.symbol.ohos_wifi'))
          .fontSize(96)
          .effectStrategy(SymbolEffectStrategy.HIERARCHICAL)
      }
    }
  }
  ```

- SymbolSpan不支持通用事件。

## 自定义图标动效

相较于effectStrategy属性在启动时即触发动效，可以通过以下两种方式来控制动效的播放状态，以及选择更多样化的动效策略。

关于effectStrategy属性与symbolEffect属性的多种动态属性使用及生效原则，详情请参阅[SymbolGlyph.symbolEffect](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#symboleffect12-1)属性的说明。  

- 通过设置SymbolEffect属性，可以同时配置SymbolGlyph的动效策略和播放状态。

  
  ``` TypeScript
  @State isActive: boolean = true;
  ```

  
  ``` TypeScript
  Column() {
    // 请将$r('app.string.variable_color_animation')替换为实际资源文件，在本示例中该资源文件的value值为"可变颜色动效"
    Text($r('app.string.variable_color_animation'));
    SymbolGlyph($r('sys.symbol.ohos_wifi'))
      .fontSize(96)
      .symbolEffect(new HierarchicalSymbolEffect(EffectFillStyle.ITERATIVE), this.isActive)
    // 请将$r('app.string.off')替换为实际资源文件，在本示例中该资源文件的value值为"关闭"
    // 请将$r('app.string.on')替换为实际资源文件，在本示例中该资源文件的value值为"播放"
    Button(this.isActive ? $r('app.string.off') : $r('app.string.on')).onClick(() => {
      this.isActive = !this.isActive;
    })
  }
  ```

- 通过设置SymbolEffect属性，可以同时指定SymbolGlyph的动画效果策略及其播放触发条件。 

  
  ``` TypeScript
  @State triggerValueReplace: number = 0;
  ```

  
  ``` TypeScript
  Column() {
    // 请将$r('app.string.bounce_animation')替换为实际资源文件，在本示例中该资源文件的value值为"弹跳动效"
    Text($r('app.string.bounce_animation'));
    SymbolGlyph($r('sys.symbol.ellipsis_message_1'))
      .fontSize(96)
      .fontColor([Color.Gray])
      .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP),
                    this.triggerValueReplace)
    Button('trigger').onClick(() => {
      this.triggerValueReplace = this.triggerValueReplace + 1;
    })
  }
  ```

- 从API version 20开始，支持通过设置SymbolEffect属性为[ReplaceSymbolEffect](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#replacesymboleffect12)，设置[ReplaceEffectType](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#replaceeffecttype20枚举说明)为ReplaceEffectType.SLASH_OVERLAY，可以指定SymbolGlyph的禁用动画效果及其播放触发条件。

  
  ``` TypeScript
  @State triggerValueReplace: number = 0;
  replaceFlag: boolean = true;
  @State renderMode: number = 1;
  ```

  
  ``` TypeScript
  Column() {
    // 请将$r('app.string.disable_animation')替换为实际资源文件，在本示例中该资源文件的value值为"禁用动效"
    Text($r('app.string.disable_animation'));
    SymbolGlyph(this.replaceFlag ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
      .fontSize(96)
      .renderingStrategy(this.renderMode)
      .symbolEffect(new ReplaceSymbolEffect(EffectScope.LAYER, ReplaceEffectType.SLASH_OVERLAY),
                    this.triggerValueReplace)
    Button('trigger').onClick(() => {
      this.replaceFlag = !this.replaceFlag;
      this.triggerValueReplace = this.triggerValueReplace + 1;
    })
  }
  ```

- 从API version 20开始，支持通过设置SymbolEffect属性为[ReplaceSymbolEffect](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#replacesymboleffect12)，设置[ReplaceEffectType](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#replaceeffecttype20枚举说明)为ReplaceEffectType.CROSS_FADE，可以指定SymbolGlyph的快速替换动画效果及其播放触发条件。

  
  ``` TypeScript
  @State triggerValueReplace: number = 0;
  replaceFlag: boolean = true;
  ```

  
  ``` TypeScript
  Column() {
    // 请将$r('app.string.quick_replacement_animation')替换为实际资源文件，在本示例中该资源文件的value值为"快速替换动效"
    Text($r('app.string.quick_replacement_animation'));
    SymbolGlyph(this.replaceFlag ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.repeat_1'))
      .fontSize(96)
      .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE, ReplaceEffectType.CROSS_FADE),
                    this.triggerValueReplace)
    Button('trigger').onClick(() => {
      this.replaceFlag = !this.replaceFlag;
      this.triggerValueReplace = this.triggerValueReplace + 1;
    })
  }
  ```

## 设置阴影和渐变色

- 从API version 20开始，支持通过[symbolShadow](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#symbolshadow20)接口实现了symbolGlyph组件显示阴影效果。

  
  ``` TypeScript
  @State isActive: boolean = true;
  
  options: ShadowOptions = {
    radius: 10.0,
    color: Color.Blue,
    offsetX: 10,
    offsetY: 10,
  };
  ```

  
  ``` TypeScript
  Column() {
    // 请将$r('app.string.shadow_ability')替换为实际资源文件，在本示例中该资源文件的value值为"阴影能力"
    Text($r('app.string.shadow_ability'));
    SymbolGlyph($r('sys.symbol.ohos_wifi'))
      .fontSize(96)
      .symbolEffect(new HierarchicalSymbolEffect(EffectFillStyle.ITERATIVE), !this.isActive)
      .symbolShadow(this.options)
    // 请将$r('app.string.off')替换为实际资源文件，在本示例中该资源文件的value值为"关闭"
    // 请将$r('app.string.on')替换为实际资源文件，在本示例中该资源文件的value值为"播放"
    Button(!this.isActive ? $r('app.string.off') : $r('app.string.on')).onClick(() => {
      this.isActive = !this.isActive;
    })
  }
  ```

- 从API version 20开始，支持通过[shaderStyle](../reference/apis-arkui/arkui-ts/ts-basic-components-symbolGlyph.md#shaderstyle20)接口实现了symbolGlyph组件显示渐变色效果。 

  
  ``` TypeScript
  radialGradientOptions: RadialGradientOptions = {
    center: ['50%', '50%'],
    radius: '20%',
    colors: [[Color.Red, 0.0], [Color.Blue, 0.3], [Color.Green, 0.5]],
    repeating: true,
  };
  ```

  
  ``` TypeScript
  Column() {
    // 请将$r('app.string.radial_gradient')替换为实际资源文件，在本示例中该资源文件的value值为"径向渐变"
    Text($r('app.string.radial_gradient'))
      .fontSize(18)
      .fontColor(0xCCCCCC)
      .textAlign(TextAlign.Center)
    SymbolGlyph($r('sys.symbol.ohos_folder_badge_plus'))
      .fontSize(96)
      .shaderStyle([new RadialGradientStyle(this.radialGradientOptions)])
  }
  ```

## 添加事件

SymbolGlyph组件可以添加通用事件，例如绑定[onClick](../reference/apis-arkui/arkui-ts/ts-universal-events-click.md#onclick)、[onTouch](../reference/apis-arkui/arkui-ts/ts-universal-events-touch.md#ontouch)等事件来响应操作。

``` TypeScript
@State wifiColor: ResourceColor = Color.Black;
```

``` TypeScript
SymbolGlyph($r('sys.symbol.ohos_wifi'))
  .fontSize(96)
  .fontColor([this.wifiColor])
  .onClick(() => {
    this.wifiColor = Color.Gray;
  })
```

## 场景示例

该示例通过symbolEffect、fontSize、fontColor属性展示了播放列表的效果。

``` TypeScript
// resourceGetString封装工具，从资源中获取字符串
import resourceGetString from '../../common/resource';

@Entry
@Component
struct SymbolMusicDemo {
  @State triggerValueReplace: number = 0;
  @State symbolSources: Resource[] =
    [$r('sys.symbol.repeat'), $r('sys.symbol.repeat_1'), $r('sys.symbol.arrow_left_arrow_right')];
  @State symbolSourcesIndex: number = 0;
  @State symbolText: string[] = [
    // 请将$r('app.string.play_in_order')替换为实际资源文件，在本示例中该资源文件的value值为"顺序播放"
    this.getUIContext()
      .getHostContext()!.resourceManager.getStringSync($r('app.string.play_in_order').id),
    // 请将$r('app.string.play_in_single_repeat')替换为实际资源文件，在本示例中该资源文件的value值为"单曲循环"
    this.getUIContext()
      .getHostContext()!.resourceManager.getStringSync($r('app.string.play_in_single_repeat').id),
    // 请将$r('app.string.shuffle_play')替换为实际资源文件，在本示例中该资源文件的value值为"随机播放"
    this.getUIContext()
      .getHostContext()!.resourceManager.getStringSync($r('app.string.shuffle_play').id),
  ];
  @State symbolTextIndex: number = 0;
  @State fontColorValue: ResourceColor = Color.Grey;
  @State fontColorValue1: ResourceColor = '#E8E8E8';

  build() {
    Column({ space: 10 }) {
      Row() {
        Text() {
          // 请将$r('app.string.current_playlist')替换为实际资源文件，在本示例中该资源文件的value值为"当前播放列表"
          Span(this.getUIContext()
            .getHostContext()!.resourceManager.getStringSync($r('app.string.current_playlist').id))
            .fontSize(20)
            .fontWeight(FontWeight.Bolder)
          Span('（101）')
        }
      }

      Row() {
        Row({ space: 5 }) {
          SymbolGlyph(this.symbolSources[this.symbolSourcesIndex])
            .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), this.triggerValueReplace)
            .fontSize(20)
            .fontColor([this.fontColorValue])
          Text(this.symbolText[this.symbolTextIndex])
            .fontColor(this.fontColorValue)
        }
        .onClick(() => {
          this.symbolTextIndex++;
          this.symbolSourcesIndex++;
          this.triggerValueReplace++;
          if (this.symbolSourcesIndex > (this.symbolSources.length - 1)) {
            this.symbolSourcesIndex = 0;
            this.triggerValueReplace = 0;
          }
          if (this.symbolTextIndex > (this.symbolText.length - 1)) {
            this.symbolTextIndex = 0;
          }
        })
        .width('75%')

        Row({ space: 5 }) {
          Text() {
            SymbolSpan($r('sys.symbol.arrow_down_circle_badge_vip_circle_filled'))
              .fontColor([this.fontColorValue])
              .fontSize(20)
          }

          Text() {
            SymbolSpan($r('sys.symbol.heart_badge_plus'))
              .fontColor([this.fontColorValue])
              .fontSize(20)
          }

          Text() {
            SymbolSpan($r('sys.symbol.ohos_trash'))
              .fontColor([this.fontColorValue])
              .fontSize(20)
          }
        }
        .width('25%')
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.song')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲一"
          Text($r('app.string.song'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.song_again')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲二"
          Text($r('app.string.song_again'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.again_song')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲三"
          Text($r('app.string.again_song'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.song_repeat')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲四"
          Text($r('app.string.song_repeat'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.repeat_song')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲五"
          Text($r('app.string.repeat_song'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.song_play')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲六"
          Text($r('app.string.song_play'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Row() {
        Row() {
          // 请将$r('app.string.play_song')替换为实际资源文件，在本示例中该资源文件的value值为"歌曲七"
          Text($r('app.string.play_song'))
        }.width('82%')

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_arrow_triangle_2_circlepath'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
          SymbolGlyph($r('sys.symbol.trash'))
            .fontColor([this.fontColorValue])
            .fontSize(20)
        }
      }

      Divider().width(5).color(this.fontColorValue1).width('98%')
      Column() {
        // 请将$r('app.string.off')替换为实际资源文件，在本示例中该资源文件的value值为"关闭"
        Text($r('app.string.off'))
      }
      .alignItems(HorizontalAlign.Center)
      .width('98%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height(400)
    .padding({
      left: 10,
      top: 10
    })
  }
}
```

