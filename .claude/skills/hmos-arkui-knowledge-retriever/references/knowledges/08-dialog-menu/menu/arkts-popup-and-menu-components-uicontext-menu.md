# 不依赖UI组件的全局菜单 (openMenu)

[菜单控制 (Menu)](arkts-popup-and-menu-components-menu.md)在使用时依赖绑定UI组件，否则无法使用。从API version 18开始，可以通过使用全局接口[openMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#openmenu18)的方式，在无UI组件的场景下直接或封装使用，例如在事件回调中使用或封装后对外提供能力。

## 弹出菜单

通过[openMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#openmenu18)可以弹出菜单。
   
 
 ``` TypeScript
 this.getUIContext().getPromptAction()
   .openMenu(this.contentNode, { id: targetId }, {
     enableArrow: true
   })
   .then(() => {
     hilog.info(0xFF00, 'globalOpenMenu', 'openMenu success');
   })
   .catch((err: BusinessError) => {
     hilog.error(0xFF00, 'globalOpenMenu', 'openMenu error: ' + err.code + ' ' + err.message);
   });
 ```
 

### 创建ComponentContent
   
   通过调用openMenu接口弹出菜单，需要定义ComponentContent，以提供自定义弹出框的内容。详细规格可参考[ComponentContent](../reference/apis-arkui/js-apis-arkui-ComponentContent.md)说明。
   
  
  ``` TypeScript
  private contentNode: ComponentContent<Object> =
    new ComponentContent(this.getUIContext(), wrapBuilder(buildText), this.message);
  ```
   
   如果在wrapBuilder中包含其他组件（例如：[Popup](../reference/apis-arkui/arkui-ts/ohos-arkui-advanced-Popup.md)、[Chip](../reference/apis-arkui/arkui-ts/ohos-arkui-advanced-Chip.md)组件），则应在创建ComponentContent时设置[nestingBuilderSupported](../reference/apis-arkui/js-apis-arkui-builderNode.md#buildoptions12)属性为true。
   
 
 ``` TypeScript
 @Builder
 export function buildText(params: Params) {
   Popup({
     // 类型设置图标内容
     icon: {
       // 请将$r('app.media.app_icon')替换为实际资源文件
       image: $r('app.media.app_icon'),
       width: 32,
       height: 32,
       fillColor: Color.White,
       borderRadius: 10
     } as PopupIconOptions,
     // 设置文字内容
     title: {
       text: `This is a Popup title 1`,
       fontSize: 20,
       fontColor: Color.Black,
       fontWeight: FontWeight.Normal
     } as PopupTextOptions,
     // 设置文字内容
     message: {
       text: `This is a Popup message 1`,
       fontSize: 15,
       fontColor: Color.Black
     } as PopupTextOptions,
     // 设置按钮内容
     buttons: [{
       text: 'confirm',
       action: () => {
         hilog.info(0xFF00, 'globalOpenMenu', 'confirm button click');
       },
       fontSize: 15,
       fontColor: Color.Black,
     },
       {
         text: 'cancel',
         action: () => {
           hilog.info(0xFF00, 'globalOpenMenu', 'cancel button click');
         },
         fontSize: 15,
         fontColor: Color.Black
       },] as [PopupButtonOptions?, PopupButtonOptions?]
   })
 }
 
 let contentNode: ComponentContent<Object> =
   new ComponentContent(uiContext, wrapBuilder(buildText), message, { nestingBuilderSupported: true });
 ```
 
 

### 绑定组件信息
   
   通过调用openMenu接口弹出菜单，需要提供绑定组件的信息[TargetInfo](../reference/apis-arkui/arkts-apis-uicontext-i.md#targetinfo18)。若未传入有效的target，菜单将无法弹出。
   
   目前有两种设置target的方式。
   
- target的id属性设置为number类型，此时需要将id设置为对应组件的UniqueID，组件的UniqueID由系统保证唯一性。
   
   
   ``` TypeScript
   let frameNode: FrameNode | null = this.getUIContext().getFrameNodeByUniqueId(this.getUniqueId());
   let targetId = frameNode?.getChild(0)?.getUniqueId();
   ```
   
- target的id属性设置为string类型，此时需要将id设置为对应组件的通用属性[id](../reference/apis-arkui/arkui-ts/ts-universal-attributes-component-id.md#id)值。当无法保证id的唯一性时，如多团队开发或者复用自定义组件，可以通过设置componentId属性明确指定此id的范围来精确指定target，此时componentId属性可以设置为对应组件的父组件或者所在自定义组件的UniqueID。
   
   
   ``` TypeScript
   build() {
     NavDestination() {
       Column() {
         Row() {
           Button('button1')
             .id(this.targetIdString)
         }
   
         Row() {
           Button('button2')
             .id(this.targetIdString)
         }
   
         Button('openMenu')
           .onClick(() => {
             let frameNode: FrameNode | null = this.uiContext.getFrameNodeByUniqueId(this.getUniqueId());
             let componentId = frameNode?.getChild(1)?.getChild(0)?.getChild(1)?.getUniqueId();
             if (componentId == undefined) {
               this.componentId = 0;
             } else {
               this.componentId = componentId;
             }
             this.promptAction.openMenu(this.contentNode, { id: this.targetIdString, componentId: this.componentId }, {
               enableArrow: true
             })
               .then(() => {
                 hilog.info(0x0000, 'openMenuWithTargetIdString', 'openMenu success');
               })
               .catch((err: BusinessError) => {
                 hilog.error(0x0000, 'openMenuWithTargetIdString', 'openMenu error: ' + err.code + ' ' + err.message);
               });
           })
       }
     }
   }
   ```
   

### 设置弹出菜单样式
   
   通过调用openMenu接口弹出菜单，可以设置[MenuOptions](../reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md#menuoptions10)中的属性调整菜单样式。title属性不生效。preview参数仅支持设置[MenuPreviewMode](../reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md#menupreviewmode11)类型。
   
  
  ``` TypeScript
  private options: MenuOptions = { enableArrow: true, placement: Placement.Bottom };
  ```

## 更新菜单样式

从API version 18开始，通过[updateMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#updatemenu18)可以更新菜单的样式。支持全量更新和增量更新其菜单样式，不支持更新[MenuOptions](../reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md#menuoptions10)中的showInSubWindow、preview、previewAnimationOptions、transition、onAppear、aboutToAppear、onDisappear、aboutToDisappear、onWillAppear、onDidAppear、onWillDisappear和onDidDisappear属性。
   

``` TypeScript
this.getUIContext().getPromptAction()
  .updateMenu(this.contentNode, {
    enableArrow: false
  }, true)
  .then(() => {
    hilog.info(0xFF00, 'globalOpenMenu', 'updateMenu success');
  })
  .catch((err: BusinessError) => {
    hilog.error(0xFF00, 'globalOpenMenu', 'updateMenu error: ' + err.code + ' ' + err.message);
  });
```
   

## 关闭菜单

从API version 18开始，通过调用[closeMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#closemenu18)可以关闭菜单。
   

``` TypeScript
this.getUIContext().getPromptAction()
  .closeMenu(this.contentNode)
  .then(() => {
    hilog.info(0xFF00, 'globalOpenMenu', 'closeMenu success');
  })
  .catch((err: BusinessError) => {
    hilog.error(0xFF00, 'globalOpenMenu', 'closeMenu error: ' + err.code + ' ' + err.message);
  });
```
   

> **说明：**
>
> 由于[updateMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#updatemenu18)和[closeMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#closemenu18)依赖content来更新或者关闭指定的菜单，开发者需自行维护传入的content。

## 在HAR包中使用全局菜单

可以通过[HAR](../quick-start/har-package.md)包封装一个Menu，从而对外提供菜单的弹出、更新和关闭能力。

具体调用方式参考[在HAR包中使用全局气泡提示](./arkts-popup-and-menu-components-uicontext-popup.md#在har包中使用全局气泡提示)。
