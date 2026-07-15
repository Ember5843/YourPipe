#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
from pathlib import Path

ROOT = Path('entry/src/main/resources')
LOCS = ['base', 'zh_CN', 'en_US', 'zh_HK', 'zh_TW', 'de_DE', 'es_ES', 'fr_FR', 'ru_RU', 'ar_SA']

ZH = {
    1: '完善本地 JS 签名解密与磁盘缓存，冷启动预热并支持失败回退，减少依赖远程解密时的等待与失败',
    2: '补齐 DASH 音轨元数据（xtags/acont），按内容语言与原声轨偏好自动选择默认音轨，减少多语言片误选配音',
    3: '播放页新增睡眠定时器，到时停止播放并退出；点赞/播放量按语言本地化显示，并优化信息区配色',
    4: '对齐全部界面语言文案键，修复设置项与关于页出现 [object Object] 的问题，补全简体中文资源',
    5: '默认主题色改为红色，并新增播放页控制区/信息区背景色以提升对比度',
    6: '首页支持下拉刷新；清理全部数据时同步清理鉴权偏好、缩略图缓存与解密缓存（保留已下载媒体）',
    7: '完善网络请求日志与提取链路诊断信息，便于定位加载失败与鉴权相关问题',
    8: '同步更新 MPV 运行库，并修复播放与界面相关的多处稳定性问题',
}

EN = {
    1: 'Improved local JS signature decryption with disk cache, cold-start prewarm, and failure fallback, reducing waits and failures when remote decryption is needed',
    2: 'Filled DASH audio-track metadata (xtags/acont) and auto-select default tracks by content language / original preference, reducing wrong-dub picks on multi-language videos',
    3: 'Added a sleep timer on the player page that stops playback and exits when due; localized like/view counts by language and refined info-area colors',
    4: 'Aligned UI string keys across all locales, fixed [object Object] labels in settings and About, and completed Simplified Chinese resources',
    5: 'Changed the default theme accent to red and added player control/info background colors for better contrast',
    6: 'Added pull-to-refresh on Home; clearing all app data also clears auth preferences, thumbnail cache, and cipher cache while preserving downloads',
    7: 'Improved network request logging and extraction diagnostics to help locate load failures and auth-related issues',
    8: 'Updated the vendored MPV runtime and fixed multiple playback and UI stability issues',
}

ZH_HANT = {
    1: '完善本地 JS 簽名解密與磁碟快取，冷啟動預熱並支援失敗回退，減少依賴遠端解密時的等待與失敗',
    2: '補齊 DASH 音軌中繼資料（xtags/acont），依內容語言與原聲軌偏好自動選擇預設音軌，減少多語言片誤選配音',
    3: '播放頁新增睡眠定時器，到時停止播放並退出；按讚/播放量依語言在地化顯示，並優化資訊區配色',
    4: '對齊全部介面語言文案鍵，修復設定項與關於頁出現 [object Object] 的問題，補全簡體中文資源',
    5: '預設主題色改為紅色，並新增播放頁控制區/資訊區背景色以提升對比度',
    6: '首頁支援下拉重新整理；清除全部資料時同步清理鑑權偏好、縮圖快取與解密快取（保留已下載媒體）',
    7: '完善網路請求日誌與擷取鏈路診斷資訊，便於定位載入失敗與鑑權相關問題',
    8: '同步更新 MPV 執行庫，並修復播放與介面相關的多處穩定性問題',
}


def values_for(loc: str):
    if loc in ('base', 'zh_CN'):
        return ZH
    if loc in ('zh_HK', 'zh_TW'):
        return ZH_HANT
    return EN


def main() -> None:
    for loc in LOCS:
        path = ROOT / loc / 'element' / 'string.json'
        with open(path, 'r', encoding='utf-8-sig') as f:
            data = json.load(f)
        existing = {item['name'] for item in data['string']}
        vals = values_for(loc)
        added = 0
        for i in range(1, 9):
            key = f'yt_changelog_0_5_4_{i}'
            if key in existing:
                for item in data['string']:
                    if item['name'] == key:
                        item['value'] = vals[i]
                        break
            else:
                data['string'].append({'name': key, 'value': vals[i]})
                added += 1
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            f.write('\n')
        print(f'{loc}: added {added}')


if __name__ == '__main__':
    main()
