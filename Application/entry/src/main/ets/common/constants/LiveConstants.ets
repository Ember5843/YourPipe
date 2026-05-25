/*
 *   Copyright (c) 2024 Huawei Device Co., Ltd.
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 */

const uiContext: UIContext | undefined = AppStorage.get('uiContext');

export class LiveConstants {
  /**
   * Live product image list.
   */
  static readonly LIVE_PRODUCT_IMAGE_LIST: Resource[] = [$r('app.media.live_product_1'), $r('app.media.live_product_2'),
    $r('app.media.live_product_3'), $r('app.media.live_product_4'), $r('app.media.live_product_5'),
    $r('app.media.live_product_6'), $r('app.media.live_product_7'), $r('app.media.live_product_8')];
  /**
   * Live product name list.
   */
  static readonly LIVE_PRODUCT_NAME_LIST: string[] =
    ['HUAWEI Mate 60 Pro', 'HUAWEI Mate Pad', 'XXXXXXXXXXX', 'XXXXXXXXXXX',
      'XXXXXXXXXXX', 'XXXXXXXXXXX', 'XXXXXXXXXXX', 'XXXXXXXXXXX'];
  /**
   * Live product price list.
   */
  static readonly LIVE_PRODUCT_PRICE_LIST: string[] =
    ['￥ 6999', '￥ 10999', 'XXXX', 'XXXX', 'XXXX', 'XXXX', 'XXXX', 'XXXX'];
  /**
   * Live product index list.
   */
  static readonly LIVE_PRODUCT_INDEX_LIST: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8];
  /**
   * Shop car product image list.
   */
  static readonly SHOP_CAR_PRODUCT_IMAGE_LIST: Resource[] = [$r('app.media.live_bag_product_1'),
    $r('app.media.live_bag_product_2'), $r('app.media.live_bag_product_3'), $r('app.media.live_bag_product_4')];
  /**
   * Shop car product name list.
   */
  static readonly SHOP_CAR_PRODUCT_NAME_LIST: string[] = ['HUAWEI Mate 60 Pro', 'Mate Xs 2', 'MateBook E Go',
    'HUAWEI Mate 50'];
  /**
   * Shop car product remark list.
   */
  static readonly SHOP_CAR_PRODUCT_REMARK_LIST: string[] = ['北斗卫星消息｜低电量应急模式', '超轻薄｜超平整｜超可靠',
    '2.5K高刷护眼屏｜轻薄长续航', '北斗卫星消息｜低电量应急模式'];
  /**
   * Shop car product discounts list.
   */
  static readonly SHOP_CAR_PRODUCT_DISCOUNTS_LIST: string[][] = [['赠积分', '新一代直屏旗舰机'], ['新一代直屏旗舰机'],
    ['性能版新品预定立省200'], ['赠积分', '新一代直屏旗舰机']];
  /**
   * Shop car product price list.
   */
  static readonly SHOP_CAR_PRODUCT_PRICE_LIST: number[] = [6999, 9999, 4899, 4999];
  /**
   * Shop car icon names.
   */
  static readonly SHOP_CAR_ICON_NAMES: string[] = ['购物袋', '搜索', '订单'];
  /**
   * Shop car tab list.
   */
  static readonly SHOP_CAR_TABS: string[] = ['全部', '手机', '平板', '笔记本', '手表', '耳机'];
  /**
   * Live Comments.
   */
  static readonly LIVE_COMMENTS_LIST: string[] = ['华为Mate60 Pro系列新品发布精彩回顾。'];
  /**
   * Comments layout weight.
   */
  static readonly COMMENTS_WIDTH: string[] = ['228vp', '400vp', '290vp'];
  /**
   * Shopping list interval.
   */
  static readonly SHOPPING_LIST_SPACE: string[] = ['12vp', '10vp'];
  /**
   * Currency symbol.
   */
  static readonly CURRENCY_SYMBOL: string = '￥ ';
  /**
   * Eight.
   */
  static readonly EIGHT: number = 8;
  /**
   * Ninety percent.
   */
  static readonly NINETY_PERCENT: string = '90%';
  /**
   * Pay button text.
   */
  static readonly PAY_BUTTON_TEXT: string = '立即购买';
  /**
   * X component params.
   */
  static readonly X_COMPONENT_PARAMS: string[] = ['live', 'surface'];
  /**
   * X component aspect ratio.
   */
  static readonly X_COMPONENT_ASPECT_RATIO: number = 0.56;
  /**
   * Live comments image list.
   */
  static readonly LIVE_COMMENTS_AVATAR: Resource[] =
    [$r('app.media.live_comments_avatar_1'), $r('app.media.live_comments_avatar_2'),
      $r('app.media.live_comments_avatar_3'), $r('app.media.live_comments_avatar_4'),
      $r('app.media.live_comments_avatar_5'), $r('app.media.live_comments_avatar_1'),
      $r('app.media.live_comments_avatar_2'), $r('app.media.live_comments_avatar_3'),
      $r('app.media.live_comments_avatar_4'), $r('app.media.live_comments_avatar_5')];
  /**
   * Live comments userName.
   */
  static readonly LIVE_COMMENTS_USERNAME: string[] =
    ['口袋里有糖', '落尘', '岁月静好', '菲拉', '平安健康', '口袋里有糖', '落尘', '岁月静好', '菲拉', '平安健康'];
  /**
   * Live comments commentContent.
   */
  static readonly LIVE_COMMENTS_CONTENT: string[] = ['你好，想问现在海鸥多吗，想从广州过去，怕白跑一趟', '感谢分享，拿走啦',
    '你好，想问现在海鸥多吗，想从广州过去，怕白跑一趟', '感谢分享，拿走啦', '你好，想问现在海鸥多吗，想从广州过去，怕白跑一趟',
    '你好，想问现在海鸥多吗，想从广州过去，怕白跑一趟', '感谢分享，拿走啦',
    '你好，想问现在海鸥多吗，想从广州过去，怕白跑一趟', '感谢分享，拿走啦',
    '你好，想问现在海鸥多吗，想从广州过去，怕白跑一趟'];
  /**
   * Live comments likeIcon.
   */
  static readonly LIVE_COMMENTS_LIKE_ICON: Resource = $r('app.media.icon_like_2');
  /**
   * Live comments likeNum.
   */
  static readonly LIVE_COMMENTS_LIKE_NUM: number[] = [2, 5, 6, 4, 3, 2, 5, 6, 4, 3];
  /**
   * Live comments title left text.
   */
  static readonly LIVING_LEFT_TEXT: string =
    uiContext!.getHostContext()!.resourceManager.getStringSync($r('app.string.LIVING_LEFT_TEXT').id);
  /**
   * Live comments title left text.
   */
  static readonly LIVING_RIGHT_TEXT: string =
    uiContext!.getHostContext()!.resourceManager.getStringSync($r('app.string.LIVING_RIGHT_TEXT').id);
  /**
   * Live comments title left text.
   */
  static readonly LIVING_WRITE: string =
    uiContext!.getHostContext()!.resourceManager.getStringSync($r('app.string.LIVING_WRITE').id);
  /**
   * Live title top.
   */
  static readonly LIVING_TITLE_TOP: string =
    uiContext!.getHostContext()!.resourceManager.getStringSync($r('app.string.store_name').id);
  /**
   * Live title bottom.
   */
  static readonly LIVING_TITLE_BOTTOM: string =
    uiContext!.getHostContext()!.resourceManager.getStringSync($r('app.string.number_of_viewers').id);
}