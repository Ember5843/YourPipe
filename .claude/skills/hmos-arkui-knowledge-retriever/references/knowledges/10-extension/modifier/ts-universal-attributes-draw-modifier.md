# 自定义绘制设置

当某些组件本身的绘制内容不满足需求时，可使用自定义组件绘制功能，在原有组件基础上部分绘制、或者全部自行绘制，以达到预期效果。例如：独特的按钮形状、文字和图像混合的图标等。自定义组件绘制提供了自定义绘制修改器，来实现更自由地组件绘制。

> **说明：**
>
> 从API version 12开始支持。后续版本如有新增内容，则采用上角标单独标记该内容的起始版本。

## drawModifier

drawModifier(modifier: DrawModifier | undefined): T

设置组件的自定义绘制修改器。

> **说明：**
>
> 该接口不支持在[attributeModifier](../../17-api-reference/attribute/ts-universal-attributes-attribute-modifier.md#attributemodifier)中调用。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**组件支持范围:**

[AlphabetIndexer](../../03-layout/other/ts-container-alphabet-indexer.md)、[Badge](../../03-layout/other/ts-container-badge.md)、[Blank](../../04-components/basic/ts-basic-components-blank.md)、[Button](../../04-components/basic/ts-basic-components-button.md)、[CalendarPicker](../../04-components/display/ts-basic-components-calendarpicker.md)、[Checkbox](../../04-components/basic/ts-basic-components-checkbox.md)、[CheckboxGroup](../../04-components/basic/ts-basic-components-checkboxgroup.md)、[Circle](../../04-components/drawing/ts-drawing-components-circle.md)、[Column](../../03-layout/linear/ts-container-column.md)、ColumnSplit、[Counter](../../03-layout/other/ts-container-counter.md)、[DataPanel](../../04-components/display/ts-basic-components-datapanel.md)、[DatePicker](../../04-components/picker/ts-basic-components-datepicker.md)、[Ellipse](../../04-components/drawing/ts-drawing-components-ellipse.md)、[Flex](../../03-layout/linear/ts-container-flex.md)、[FlowItem](../../03-layout/grid-list/ts-container-flowitem.md)、[FolderStack](../../03-layout/other/ts-container-folderstack.md)、[FormLink](../../15-advanced/component/ts-container-formlink.md)、[Gauge](../../04-components/display/ts-basic-components-gauge.md)、[Grid](../../03-layout/grid-list/ts-container-grid.md)、[GridCol](../../03-layout/grid-list/ts-container-gridcol.md)、GridItem、[GridRow](../../03-layout/grid-list/ts-container-gridrow.md)、[Hyperlink](../../03-layout/other/ts-container-hyperlink.md)、[Image](../../04-components/basic/ts-basic-components-image.md)、[ImageAnimator](../../04-components/media/ts-basic-components-imageanimator.md)、[ImageSpan](../../04-components/basic/ts-basic-components-imagespan.md)、[Line](../../04-components/drawing/ts-drawing-components-line.md)、[List](../../03-layout/grid-list/ts-container-list.md)、[ListItem](../../03-layout/grid-list/ts-container-listitem.md)、[ListItemGroup](../../03-layout/grid-list/ts-container-listitemgroup.md)、[LoadingProgress](../../04-components/basic/ts-basic-components-loadingprogress.md)、[Marquee](../../04-components/basic/ts-basic-components-marquee.md)、[Menu](../../08-dialog-menu/menu/ts-basic-components-menu.md)、[MenuItem](../../08-dialog-menu/menu/ts-basic-components-menuitem.md)、[MenuItemGroup](../../08-dialog-menu/menu/ts-basic-components-menuitemgroup.md)、[NavDestination](../../07-navigation/navigation/ts-basic-components-navdestination.md)、[Navigation](../../07-navigation/navigation/ts-basic-components-navigation.md)、[Navigator](../../03-layout/other/ts-container-navigator.md)、[NavRouter](../../07-navigation/navigation/ts-basic-components-navrouter.md)、[NodeContainer](../../03-layout/other/ts-basic-components-nodecontainer.md)、[Path](../../04-components/drawing/ts-drawing-components-path.md)、[PatternLock](../../04-components/picker/ts-basic-components-patternlock.md)、[Polygon](../../04-components/drawing/ts-drawing-components-polygon.md)、[Polyline](../../04-components/drawing/ts-drawing-components-polyline.md)、[Progress](../../04-components/basic/ts-basic-components-progress.md)、[QRCode](../../04-components/display/ts-basic-components-qrcode.md)、[Radio](../../04-components/basic/ts-basic-components-radio.md)、[Rating](../../04-components/basic/ts-basic-components-rating.md)、[Rect](../../04-components/drawing/ts-drawing-components-rect.md)、[Refresh](../../03-layout/other/ts-container-refresh.md)、[RelativeContainer](../../03-layout/other/ts-container-relativecontainer.md)、[RichEditor](../../04-components/advanced/ts-basic-components-richeditor.md)、[Row](../../03-layout/linear/ts-container-row.md)、RowSplit、[Scroll](../../03-layout/other/ts-container-scroll.md)、ScrollBar、[Search](../../04-components/basic/ts-basic-components-search.md)、[Select](../../04-components/basic/ts-basic-components-select.md)、[Shape](../../04-components/drawing/ts-drawing-components-shape.md)、[SideBarContainer](../../03-layout/other/ts-container-sidebarcontainer.md)、[Slider](../../04-components/basic/ts-basic-components-slider.md)、[Stack](../../03-layout/other/ts-container-stack.md)、[Stepper](../../04-components/picker/ts-basic-components-stepper.md)、[StepperItem](../../04-components/picker/ts-basic-components-stepperitem.md)、[Swiper](../../03-layout/other/ts-container-swiper.md)、[SymbolGlyph](../../04-components/basic/ts-basic-components-symbolGlyph.md)、[TabContent](../../03-layout/other/ts-container-tabcontent.md)、[Tabs](../../03-layout/other/ts-container-tabs.md)、[Text](../../04-components/basic/ts-basic-components-text.md)、[TextArea](../../04-components/basic/ts-basic-components-textarea.md)、[TextClock](../../04-components/display/ts-basic-components-textclock.md)、[TextInput](../../04-components/basic/ts-basic-components-textinput.md)、[TextPicker](../../04-components/picker/ts-basic-components-textpicker.md)、[TextTimer](../../04-components/display/ts-basic-components-texttimer.md)、[TimePicker](../../04-components/picker/ts-basic-components-timepicker.md)、[Toggle](../../04-components/basic/ts-basic-components-toggle.md)、[WaterFlow](../../03-layout/grid-list/ts-container-waterflow.md)、[XComponent](../../04-components/advanced/ts-basic-components-xcomponent.md)

**参数：** 

| 参数名 | 类型                                                 | 必填 | 说明                                                         |
| ------ | ---------------------------------------------------- | ---- | ------------------------------------------------------------ |
| modifier  | &nbsp;[DrawModifier](#drawmodifier-1)&nbsp;\|&nbsp;undefined | 是   | 自定义绘制修改器，其中定义了自定义绘制的逻辑。 <br> 默认值：undefined <br/>**说明：** <br/> 每个自定义修改器只对当前绑定组件的FrameNode生效，对其子节点不生效。 |

**返回值：**

| 类型 | 说明 |
| --- | --- |
| T | 返回当前组件。 |

## DrawModifier

DrawModifier可设置前景(drawForeground)、内容前景(drawFront)、内容(drawContent)和内容背景(drawBehind)的绘制方法，还提供主动触发重绘的方法[invalidate](#invalidate)。每个DrawModifier实例只能设置到一个组件上，禁止进行重复设置。

自定义层级示例图

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

### drawFront

drawFront?(drawContext: DrawContext): void

自定义绘制内容前景的接口，若重载该方法则可进行内容前景的自定义绘制。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名  | 类型                                                   | 必填 | 说明             |
| ------- | ------------------------------------------------------ | ---- | ---------------- |
| drawContext | [DrawContext](#drawcontext) | 是   | 图形绘制上下文。 |

**示例：**

请参考[示例1（通过DrawModifier进行自定义绘制）](#示例1通过drawmodifier进行自定义绘制)。

### drawContent

drawContent?(drawContext: DrawContext): void

自定义绘制内容的接口，若重载该方法则可进行内容的自定义绘制，会替换组件原本的内容绘制函数。
该接口的DrawContext中的Canvas是用于记录指令的临时Canvas，并非节点的真实Canvas。使用请参见调整自定义绘制Canvas的变换矩阵。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名  | 类型                                                   | 必填 | 说明             |
| ------- | ------------------------------------------------------ | ---- | ---------------- |
| drawContext | [DrawContext](#drawcontext) | 是   | 图形绘制上下文。 |

**示例：**

请参考[示例1（通过DrawModifier进行自定义绘制）](#示例1通过drawmodifier进行自定义绘制)。

### drawBehind

drawBehind?(drawContext: DrawContext): void

自定义绘制背景的接口，若重载该方法则可进行背景的自定义绘制。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名  | 类型                                                   | 必填 | 说明             |
| ------- | ------------------------------------------------------ | ---- | ---------------- |
| drawContext | [DrawContext](#drawcontext) | 是   | 图形绘制上下文。 |

**示例：**

请参考[示例1（通过DrawModifier进行自定义绘制）](#示例1通过drawmodifier进行自定义绘制)。

### drawForeground<sup>20+</sup>

drawForeground(drawContext: DrawContext): void

自定义绘制前景的接口，若重载该方法则可进行前景的自定义绘制。需要对其组件的前景层进行绘制时重载该方法。

**原子化服务API：** 从API version 20开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名  | 类型                                                   | 必填 | 说明             |
| ------- | ------------------------------------------------------ | ---- | ---------------- |
| drawContext | [DrawContext](#drawcontext) | 是   | 图形绘制上下文。 |

**示例：**

请参考[示例2（通过DrawModifier对容器的前景进行自定义绘制）](#示例2通过drawmodifier对容器的前景进行自定义绘制)。

### invalidate

invalidate(): void

主动触发重绘的接口，开发者无需也无法重载，调用会触发所绑定组件的重绘。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**示例：**

请参考[示例1（通过DrawModifier进行自定义绘制）](#示例1通过drawmodifier进行自定义绘制)。

### DrawContext

type DrawContext = DrawContext

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

| 类型                                                      | 说明                    |
| --------------------------------------------------------- | ----------------------- |
| DrawContext | 图形绘制上下文。 |

## 示例

### 示例1（通过DrawModifier进行自定义绘制）

通过DrawModifier对[Text](../../04-components/basic/ts-basic-components-text.md)组件进行自定义绘制。

```ts
// xxx.ets
import { drawing } from '@kit.ArkGraphics2D';
import { AnimatorResult } from '@kit.ArkUI';

// 继承DrawModifier实现自定义绘制控制器
class MyFullDrawModifier extends DrawModifier {
  public scaleX: number = 1;
  public scaleY: number = 1;
  uiContext: UIContext;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  // 重载drawBehind方法，自定义绘制背景  
  drawBehind(context: DrawContext): void {
    const brush = new drawing.Brush();
    brush.setColor({
      alpha: 255,
      red: 255,
      green: 0,
      blue: 0
    });
    context.canvas.attachBrush(brush);
    const halfWidth = context.size.width / 2;
    const halfHeight = context.size.height / 2;
    context.canvas.drawRect({
      left: this.uiContext.vp2px(halfWidth - 50 * this.scaleX),
      top: this.uiContext.vp2px(halfHeight - 50 * this.scaleY),
      right: this.uiContext.vp2px(halfWidth + 50 * this.scaleX),
      bottom: this.uiContext.vp2px(halfHeight + 50 * this.scaleY)
    });
  }

  // 重载drawContent方法，自定义绘制内容
  drawContent(context: DrawContext): void {
    const brush = new drawing.Brush();
    brush.setColor({
      alpha: 255,
      red: 0,
      green: 255,
      blue: 0
    });
    context.canvas.attachBrush(brush);
    const halfWidth = context.size.width / 2;
    const halfHeight = context.size.height / 2;
    context.canvas.drawRect({
      left: this.uiContext.vp2px(halfWidth - 30 * this.scaleX),
      top: this.uiContext.vp2px(halfHeight - 30 * this.scaleY),
      right: this.uiContext.vp2px(halfWidth + 30 * this.scaleX),
      bottom: this.uiContext.vp2px(halfHeight + 30 * this.scaleY)
    });
  }

  // 重载drawFront方法，自定义绘制内容前景
  drawFront(context: DrawContext): void {
    const brush = new drawing.Brush();
    brush.setColor({
      alpha: 255,
      red: 0,
      green: 0,
      blue: 255
    });
    context.canvas.attachBrush(brush);
    const halfWidth = context.size.width / 2;
    const halfHeight = context.size.height / 2;
    const radiusScale = (this.scaleX + this.scaleY) / 2;
    context.canvas.drawCircle(this.uiContext.vp2px(halfWidth), this.uiContext.vp2px(halfHeight), this.uiContext.vp2px(20 * radiusScale));
  }
}

// 继承DrawModifier实现自定义绘制控制器，仅支持自定义绘制内容前景
class MyFrontDrawModifier extends DrawModifier {
  public scaleX: number = 1;
  public scaleY: number = 1;
  uiContext: UIContext;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  drawFront(context: DrawContext): void {
    const brush = new drawing.Brush();
    brush.setColor({
      alpha: 255,
      red: 0,
      green: 0,
      blue: 255
    });
    context.canvas.attachBrush(brush);
    const halfWidth = context.size.width / 2;
    const halfHeight = context.size.height / 2;
    const radiusScale = (this.scaleX + this.scaleY) / 2;
    context.canvas.drawCircle(this.uiContext.vp2px(halfWidth), this.uiContext.vp2px(halfHeight), this.uiContext.vp2px(20 * radiusScale));
  }
}

@Entry
@Component
struct DrawModifierExample {
  private fullModifier: MyFullDrawModifier = new MyFullDrawModifier(this.getUIContext());
  private frontModifier: MyFrontDrawModifier = new MyFrontDrawModifier(this.getUIContext());
  private drawAnimator: AnimatorResult | undefined = undefined;
  @State modifier: DrawModifier = new MyFrontDrawModifier(this.getUIContext());
  private count = 0;

  // 创建Animator对象并设置动画
  create() {
    let self = this;
    this.drawAnimator = this.getUIContext().createAnimator({
      duration: 1000,
      easing: 'ease',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 2
    });
    this.drawAnimator.onFrame = (value: number) => {
      console.info('frame value =', value);
      const tempModifier = self.modifier as MyFullDrawModifier | MyFrontDrawModifier;
      tempModifier.scaleX = Math.abs(value - 1);
      tempModifier.scaleY = Math.abs(value - 1);
      // 主动触发重绘
      self.modifier.invalidate();
    };
  }

  build() {
    Column() {
      Row() {
        Text('test text')
          .width(100)
          .height(100)
          .margin(10)
          .backgroundColor(Color.Gray)
          .onClick(() => {
            const tempModifier = this.modifier as MyFullDrawModifier | MyFrontDrawModifier;
            tempModifier.scaleX -= 0.1;
            tempModifier.scaleY -= 0.1;
          })
          .drawModifier(this.modifier)
      }

      Row() {
        Button('create')
          .width(100)
          .height(100)
          .borderRadius(50)
          .margin(10)
          .onClick(() => {
            this.create();
          })
        Button('play')
          .width(100)
          .height(100)
          .borderRadius(50)
          .margin(10)
          .onClick(() => {
            if (this.drawAnimator) {
              this.drawAnimator.play();
            }
          })
        Button('changeModifier')
          .width(100)
          .height(100)
          .borderRadius(50)
          .margin(10)
          .onClick(() => {
            this.count += 1;
            if (this.count % 2 === 1) {
              console.info('change to full modifier');
              this.modifier = this.fullModifier;
            } else {
              console.info('change to front modifier');
              this.modifier = this.frontModifier;
            }
          })
      }
    }
    .width('100%')
    .height('100%')
  }
}
```

### 示例2（通过DrawModifier对容器的前景进行自定义绘制）

通过DrawModifier对[Column](../../03-layout/linear/ts-container-column.md)容器的前景进行自定义绘制。

```ts
// xxx.ets
import { drawing } from '@kit.ArkGraphics2D';

class MyForegroundDrawModifier extends DrawModifier {
  public scaleX: number = 3;
  public scaleY: number = 3;
  uiContext: UIContext;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  // 重载drawForeground方法，实现自定义绘制前景
  drawForeground(context: DrawContext): void {
    const brush = new drawing.Brush();
    brush.setColor({
      alpha: 255,
      red: 0,
      green: 50,
      blue: 100
    });
    context.canvas.attachBrush(brush);
    const halfWidth = context.size.width / 2;
    const halfHeight = context.size.height / 2;
    context.canvas.drawRect({
      left: this.uiContext.vp2px(halfWidth - 30 * this.scaleX),
      top: this.uiContext.vp2px(halfHeight - 30 * this.scaleY),
      right: this.uiContext.vp2px(halfWidth + 30 * this.scaleX),
      bottom: this.uiContext.vp2px(halfHeight + 30 * this.scaleY)
    });
  }
}

@Entry
@Component
struct DrawModifierExample {
  // 将自定义绘制前景的类实例化，传入UIContext实例
  private foregroundModifier: MyForegroundDrawModifier = new MyForegroundDrawModifier(this.getUIContext());

  build() {
    Column() {
      Text('此文本是子节点')
        .fontSize(36)
        .width('100%')
        .height('100%')
        .textAlign(TextAlign.Center)
    }
    .margin(50)
    .width(280)
    .height(300)
    .backgroundColor(0x87CEEB)
    // 调用此接口并传入自定义绘制前景的类实例，即可实现自定义绘制前景
    .drawModifier(this.foregroundModifier)
  }
}

```
