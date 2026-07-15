#!/usr/bin/env python3
"""Add all changelog entries to locale files."""
import json, os

RES_DIR = os.path.join('entry', 'src', 'main', 'resources')

# Changelog entries: (key, [zh_HK, zh_TW, de_DE, es_ES, fr_FR, ru_RU, ar_SA, en_US])
# base (zh_CN) is the source - we use the original Chinese text for base
CHANGELOG = {
    '0.5.4': [
        ('yt_changelog_0_5_4_1', '完善本地 JS 签名解密与磁盘缓存，冷启动预热并支持失败回退，减少依赖远程解密时的等待与失败'),
        ('yt_changelog_0_5_4_2', '补齐 DASH 音轨元数据（xtags/acont），按内容语言与原声轨偏好自动选择默认音轨，减少多语言片误选配音'),
        ('yt_changelog_0_5_4_3', '播放页新增睡眠定时器，到时停止播放并退出；点赞/播放量按语言本地化显示，并优化信息区配色'),
        ('yt_changelog_0_5_4_4', '对齐全部界面语言文案键，修复设置项与关于页出现 [object Object] 的问题，补全简体中文资源'),
        ('yt_changelog_0_5_4_5', '默认主题色改为红色，并新增播放页控制区/信息区背景色以提升对比度'),
        ('yt_changelog_0_5_4_6', '首页支持下拉刷新；清理全部数据时同步清理鉴权偏好、缩略图缓存与解密缓存（保留已下载媒体）'),
        ('yt_changelog_0_5_4_7', '完善网络请求日志与提取链路诊断信息，便于定位加载失败与鉴权相关问题'),
        ('yt_changelog_0_5_4_8', '同步更新 MPV 运行库，并修复播放与界面相关的多处稳定性问题'),
    ],
    '0.5.3': [
        ('yt_changelog_0_5_3_1', '新增 YouTube SABR/UMP 流媒体播放支持，提升新格式视频、高画质视频及受限播放场景的兼容性'),
        ('yt_changelog_0_5_3_2', '重构视频解析与客户端选择流程，对齐 PipePipe 请求行为并恢复远程签名解密服务，减少重复提取和启动等待'),
        ('yt_changelog_0_5_3_3', '完善本地 DASH 媒体代理，支持音视频分轨、分段缓存、精确拖动、断流恢复与播放结束处理'),
        ('yt_changelog_0_5_3_4', '加入 SABR PoToken 支持，优化签名参数、请求头与二进制响应处理，减少 403、无法播放和加载失败'),
        ('yt_changelog_0_5_3_5', '优化播放器状态同步、清晰度与音轨切换，修复画面已播放仍持续转圈、拖动错位及音轨菜单异常'),
        ('yt_changelog_0_5_3_6', '升级播放列表解析与翻页机制，兼容新版列表结构、锁定内容和 continuation，改善列表加载与连续播放'),
        ('yt_changelog_0_5_3_7', '整理账号与数据管理入口，改进登录状态、观看记录、本地页面、下载选项及播放偏好之间的联动'),
        ('yt_changelog_0_5_3_8', '优化首页推荐、视频卡片、主题色、画中画和系统媒体会话体验，并修复多处界面与播放稳定性问题'),
    ],
    '0.5.2': [
        ('yt_changelog_0_5_2_1', '播放页新增「仅音频」：关视频听声音，封面替代画面，进度与播控仍可用'),
        ('yt_changelog_0_5_2_2', '仅音频时不进画中画；回前台保持仅音频，需手动恢复视频'),
        ('yt_changelog_0_5_2_3', '后台可延迟关闭视频以省电（播放设置可调）'),
        ('yt_changelog_0_5_2_4', '修复系统播报打断：正确 duck 降音且避免二次压音导致静音'),
        ('yt_changelog_0_5_2_5', '横竖屏、全屏与窗口播放更顺滑，减少闪黑与画面模糊'),
        ('yt_changelog_0_5_2_6', '登录后主页更贴合账号状态，可同步云端观看记录与订阅'),
        ('yt_changelog_0_5_2_7', '视频卡片、直播角标与页面安全区显示更清晰'),
        ('yt_changelog_0_5_2_8', '支持应用流转与碰一碰分享视频链接'),
    ],
    '0.5.1': [
        ('yt_changelog_0_5_1_1', '修复部分已知bug'),
        ('yt_changelog_0_5_1_2', '对齐PipePipe问题'),
        ('yt_changelog_0_5_1_3', '修复登录后无法观看的bug'),
        ('yt_changelog_0_5_1_4', '修复横屏模式信息栏不当弹出的问题'),
        ('yt_changelog_0_5_1_5', '优化设置页面UI'),
        ('yt_changelog_0_5_1_6', '完成本地解密逻辑验证，准备实装'),
    ],
    '0.5.0': [
        ('yt_changelog_0_5_0_1', '更换系统播放引擎与第三方FFMpeg至MPVPlayer'),
        ('yt_changelog_0_5_0_2', '恢复高分辨率播放和字幕功能'),
        ('yt_changelog_0_5_0_3', '支持HEVC/H.264硬件解码；API 23+ 尝试 VP9/AV1 硬件解码'),
        ('yt_changelog_0_5_0_4', '加入真HDR显示'),
        ('yt_changelog_0_5_0_5', '优化非登录状态下网络传输库能力'),
        ('yt_changelog_0_5_0_6', '优化错误显示'),
        ('yt_changelog_0_5_0_7', '优化UI和设置选项'),
        ('yt_changelog_0_5_0_8', '应用PipePipe最新版本补丁'),
    ],
    '0.4.1': [
        ('yt_changelog_0_4_1_1', '优化视频加载速度'),
        ('yt_changelog_0_4_1_2', '应用pipepipe5.1.1版本补丁'),
        ('yt_changelog_0_4_1_3', '允许谷歌登录，基本消除bot protection问题'),
        ('yt_changelog_0_4_1_4', '优化多种设备的全屏交互机制'),
        ('yt_changelog_0_4_1_5', '开发播放页面多个模块'),
        ('yt_changelog_0_4_1_6', '初步做完下载功能'),
        ('yt_changelog_0_4_1_7', '完全播放列表功能'),
        ('yt_changelog_0_4_1_8', '接入系统及投屏入口，实验性初步接入应用流转'),
    ],
    '0.4.0': [
        ('yt_changelog_0_4_0_1', '基本完成yt-dlp生态分析与接入接口'),
        ('yt_changelog_0_4_0_2', '允许谷歌登录，基本消除bot protection问题'),
        ('yt_changelog_0_4_0_3', '优化播放机制'),
        ('yt_changelog_0_4_0_4', '使用云端解码替代本地解码，更加稳定'),
    ],
    '0.3.1': [
        ('yt_changelog_0_3_1_1', '完善页面栈与小窗播放'),
        ('yt_changelog_0_3_1_2', '加入服务器缓存，播放更流畅'),
        ('yt_changelog_0_3_1_3', '优化ui与交互方式'),
        ('yt_changelog_0_3_1_4', '更多页面与尺寸适配'),
        ('yt_changelog_0_3_1_5', '继续精简先前代码防bug'),
        ('yt_changelog_0_3_1_6', '初步开发谷歌登录，验证pipepipe登录流程可行性'),
        ('yt_changelog_0_3_1_7', '优化后台播放稳定性'),
    ],
    '0.3.0': [
        ('yt_changelog_0_3_0_1', '最终实验选定中转http服务器方案'),
        ('yt_changelog_0_3_0_2', '回退到系统级播放器完善生命周期'),
        ('yt_changelog_0_3_0_3', '优化ui与交互方式'),
        ('yt_changelog_0_3_0_4', '更多页面与尺寸适配'),
        ('yt_changelog_0_3_0_5', '删除大量先前的库与头文件，精简防bug'),
        ('yt_changelog_0_3_0_6', '初步开发谷歌登录，验证smarttube可行性'),
        ('yt_changelog_0_3_0_7', '优化后台播放稳定性'),
    ],
    '0.2.0': [
        ('yt_changelog_0_2_0_1', '重构项目代码，优化整体生命周期管理与开发速度，全新启程'),
        ('yt_changelog_0_2_0_2', '优化播放与直播部分，直播更流畅，发热更少'),
        ('yt_changelog_0_2_0_3', '更多选项，可自定义的播放选项'),
        ('yt_changelog_0_2_0_4', '更丰富的报错信息与日志管理'),
        ('yt_changelog_0_2_0_5', '增加多国语言优化适配'),
        ('yt_changelog_0_2_0_6', '更新 NewPipe 核心代码，优化网络连接和解码，功能更稳定'),
        ('yt_changelog_0_2_0_7', '优化后台播放稳定性'),
        ('yt_changelog_0_2_0_8', '系统级 AVPlayer 播放，稳定性与功耗优化'),
    ],
    '0.1.2': [
        ('yt_changelog_0_1_2_1', '修复应用 UI 语言切换导致的界面卡死问题'),
        ('yt_changelog_0_1_2_2', '优化内容语言列表中文变体（简体 / 繁体香港 / 繁体台湾）显示'),
        ('yt_changelog_0_1_2_3', '日志下载完成后显示保存路径提示'),
        ('yt_changelog_0_1_2_4', '新增关于页面'),
        ('yt_changelog_0_1_2_5', '修复高级分辨率禁用选项不生效的问题'),
        ('yt_changelog_0_1_2_6', '统一设置页各模块视觉风格'),
    ],
    '0.1.1': [
        ('yt_changelog_0_1_1_1', '接入 MPV 播放内核，支持硬件解码与高分辨率视频'),
        ('yt_changelog_0_1_1_2', '实现后台播放与系统播控中心集成'),
        ('yt_changelog_0_1_1_3', '完成语言与地区设置，支持内容语言 / 地区切换'),
        ('yt_changelog_0_1_1_4', '添加运行日志系统，支持会话导出'),
        ('yt_changelog_0_1_1_5', '优化平板横屏播放器布局'),
    ],
    '0.1.0': [
        ('yt_changelog_0_1_0_1', '首次发布：基础 YouTube 视频浏览与搜索'),
        ('yt_changelog_0_1_0_2', '接入 NewPipe Extractor 提取引擎'),
        ('yt_changelog_0_1_0_3', '支持订阅频道、收藏夹与播放列表管理'),
        ('yt_changelog_0_1_0_4', '支持直播流播放'),
        ('yt_changelog_0_1_0_5', '评论列表与频道页面'),
    ],
}

# For non-Chinese locales, leave the Chinese text temporarily (will be translated by humans later)
# For base (zh_CN), add the original Chinese text
# For en_US, we'll add a "machine translation" placeholder using English (best effort)

ENGLISH_TRANSLATIONS = {
    '0.5.4': {
        1: 'Improved local JS signature decryption with disk cache, cold-start prewarm, and failure fallback, reducing waits and failures when remote decryption is needed',
        2: 'Filled DASH audio-track metadata (xtags/acont) and auto-select default tracks by content language / original preference, reducing wrong-dub picks on multi-language videos',
        3: 'Added a sleep timer on the player page that stops playback and exits when due; localized like/view counts by language and refined info-area colors',
        4: 'Aligned UI string keys across all locales, fixed [object Object] labels in settings and About, and completed Simplified Chinese resources',
        5: 'Changed the default theme accent to red and added player control/info background colors for better contrast',
        6: 'Added pull-to-refresh on Home; clearing all app data also clears auth preferences, thumbnail cache, and cipher cache while preserving downloads',
        7: 'Improved network request logging and extraction diagnostics to help locate load failures and auth-related issues',
        8: 'Updated the vendored MPV runtime and fixed multiple playback and UI stability issues',
    },
    '0.5.3': {
        1: 'Added YouTube SABR/UMP streaming support, improving compatibility for new-format, high-resolution, and restricted videos',
        2: 'Refactored video extraction and client selection, aligned with PipePipe request behavior, restored remote signature decryption, reduced duplicate extraction and startup wait',
        3: 'Improved local DASH media proxy: separated A/V tracks, segmented cache, precise seeking, stream break recovery, and playback end handling',
        4: 'Added SABR PoToken support; optimized signature parameters, request headers, and binary response handling, reducing 403 / unable to play / loading failures',
        5: 'Improved player state sync, quality and audio track switching, fixed endless loading after playback, seek offset and audio track menu issues',
        6: 'Upgraded playlist parsing and pagination, compatible with new list structures, locked content, and continuation; improved list loading and continuous playback',
        7: 'Reorganized account and data management entry, improved linkage between sign-in state, watch history, local page, download options, and playback preferences',
        8: 'Improved home recommendations, video cards, theme color, picture-in-picture, and system media session; fixed multiple UI and playback stability issues',
    },
    '0.5.2': {
        1: 'Player page adds Audio-only: turn off video and listen to sound, cover replaces picture, progress and controls still available',
        2: 'In audio-only mode, no picture-in-picture; returning to foreground keeps audio-only, manual resume required',
        3: 'Background can delay turning off video to save power (adjustable in playback settings)',
        4: 'Fixed system broadcast interruption: correct duck volume reduction, avoid secondary compression causing silence',
        5: 'Smoother landscape/portrait, fullscreen, and windowed playback, reduced screen black and blur',
        6: 'Home page after login better matches account state, can sync cloud watch history and subscriptions',
        7: 'Clearer video cards, live badges, and page safe area display',
        8: 'Support app handoff and tap-to-share video links',
    },
    '0.5.1': {
        1: 'Fixed some known bugs',
        2: 'Aligned with PipePipe issues',
        3: 'Fixed inability to watch after login',
        4: 'Fixed information bar popping up incorrectly in landscape mode',
        5: 'Optimized settings page UI',
        6: 'Completed local decryption logic verification, ready for deployment',
    },
    '0.5.0': {
        1: 'Replaced system playback engine and third-party FFMpeg with MPVPlayer',
        2: 'Restored high-resolution playback and subtitle features',
        3: 'Support HEVC/H.264 hardware decoding; on API 23+ try VP9/AV1 hardware decoding',
        4: 'Added true HDR display',
        5: 'Optimized network transport library capabilities in non-login state',
        6: 'Optimized error display',
        7: 'Optimized UI and settings options',
        8: 'Applied PipePipe latest version patches',
    },
    '0.4.1': {
        1: 'Optimized video loading speed',
        2: 'Applied pipepipe 5.1.1 patches',
        3: 'Allowed Google sign-in, basically eliminated bot protection issues',
        4: 'Optimized fullscreen interaction for various devices',
        5: 'Developed multiple modules of the player page',
        6: 'Initial download feature completed',
        7: 'Complete playlist feature',
        8: 'Integrated system and cast entry, experimental initial app handoff',
    },
    '0.4.0': {
        1: 'Basically completed yt-dlp ecosystem analysis and integration interface',
        2: 'Allowed Google sign-in, basically eliminated bot protection issues',
        3: 'Optimized playback mechanism',
        4: 'Used cloud decoding instead of local decoding, more stable',
    },
    '0.3.1': {
        1: 'Improved page stack and mini-window playback',
        2: 'Added server cache for smoother playback',
        3: 'Optimized UI and interaction',
        4: 'More page and size adaptation',
        5: 'Continued to simplify previous code to prevent bugs',
        6: 'Initial Google sign-in development, verified pipepipe sign-in feasibility',
        7: 'Optimized background playback stability',
    },
    '0.3.0': {
        1: 'Final experimental selection of relay HTTP server solution',
        2: 'Reverted to system-level player to improve lifecycle',
        3: 'Optimized UI and interaction',
        4: 'More page and size adaptation',
        5: 'Removed many previous libraries and headers, simplified to prevent bugs',
        6: 'Initial Google sign-in development, verified smarttube feasibility',
        7: 'Optimized background playback stability',
    },
    '0.2.0': {
        1: 'Refactored project code, optimized lifecycle management and development speed, fresh start',
        2: 'Optimized playback and live streaming, smoother live, less heating',
        3: 'More options, customizable playback options',
        4: 'Richer error messages and log management',
        5: 'Added multilingual optimization',
        6: 'Updated NewPipe core code, optimized network connection and decoding, more stable',
        7: 'Optimized background playback stability',
        8: 'System-level AVPlayer playback, stability and power optimization',
    },
    '0.1.2': {
        1: 'Fixed UI freeze when switching app UI language',
        2: 'Optimized content language list Chinese variant display (Simplified / Traditional HK / Traditional TW)',
        3: 'Show save path hint after log download completes',
        4: 'Added About page',
        5: 'Fixed high resolution disable option not working',
        6: 'Unified visual style across settings page modules',
    },
    '0.1.1': {
        1: 'Integrated MPV playback core, supports hardware decoding and high-resolution video',
        2: 'Implemented background playback and system media controls integration',
        3: 'Completed language and region settings, supports content language / region switching',
        4: 'Added runtime log system, supports session export',
        5: 'Optimized tablet landscape player layout',
    },
    '0.1.0': {
        1: 'Initial release: basic YouTube video browsing and search',
        2: 'Integrated NewPipe Extractor engine',
        3: 'Support channel subscriptions, favorites, and playlist management',
        4: 'Support live stream playback',
        5: 'Comment list and channel page',
    },
}

for loc in ['en_US', 'zh_HK', 'zh_TW', 'de_DE', 'es_ES', 'fr_FR', 'ru_RU', 'ar_SA']:
    path = os.path.join(RES_DIR, loc, 'element', 'string.json')
    with open(path, 'r', encoding='utf-8-sig') as f:
        data = json.load(f)
    existing = {item['name'] for item in data['string']}

    added = 0
    for ver, entries in CHANGELOG.items():
        for i, (key, zh_text) in enumerate(entries, 1):
            if key in existing:
                continue
            if loc == 'en_US':
                value = ENGLISH_TRANSLATIONS[ver][i]
            else:
                # For other locales, use English temporarily (will be translated)
                value = ENGLISH_TRANSLATIONS[ver][i]
            data['string'].append({'name': key, 'value': value})
            added += 1

    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
        f.write('\n')
    print(f'{loc}: added {added} changelog keys')
