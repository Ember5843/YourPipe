#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
from pathlib import Path

ROOT = Path('entry/src/main/resources')

STRINGS = {
    'base': {
        'yt_secure_shield_title': '坚盾守护模式已开启',
        'yt_secure_shield_content': '系统已开启坚盾守护模式并禁用 JIT。本地签名解密不可用，将改用远端解密服务，视频起播可能更慢。',
        'yt_secure_shield_dont_show': '不再提示',
        'yt_action_got_it': '知道了',
    },
    'zh_CN': {
        'yt_secure_shield_title': '坚盾守护模式已开启',
        'yt_secure_shield_content': '系统已开启坚盾守护模式并禁用 JIT。本地签名解密不可用，将改用远端解密服务，视频起播可能更慢。',
        'yt_secure_shield_dont_show': '不再提示',
        'yt_action_got_it': '知道了',
    },
    'zh_HK': {
        'yt_secure_shield_title': '堅盾守護模式已開啟',
        'yt_secure_shield_content': '系統已開啟堅盾守護模式並停用 JIT。本地簽名解密不可用，將改用遠端解密服務，影片起播可能更慢。',
        'yt_secure_shield_dont_show': '不再提示',
        'yt_action_got_it': '知道了',
    },
    'zh_TW': {
        'yt_secure_shield_title': '堅盾守護模式已開啟',
        'yt_secure_shield_content': '系統已開啟堅盾守護模式並停用 JIT。本地簽名解密不可用，將改用遠端解密服務，影片起播可能更慢。',
        'yt_secure_shield_dont_show': '不再提示',
        'yt_action_got_it': '知道了',
    },
    'en_US': {
        'yt_secure_shield_title': 'Secure Shield mode is on',
        'yt_secure_shield_content': 'The system has enabled Secure Shield and disabled JIT. Local signature decryption is unavailable, so remote decryption will be used and video start-up may be slower.',
        'yt_secure_shield_dont_show': "Don't show again",
        'yt_action_got_it': 'Got it',
    },
    'de_DE': {
        'yt_secure_shield_title': 'Secure-Shield-Modus ist aktiv',
        'yt_secure_shield_content': 'Das System hat den Secure-Shield-Modus aktiviert und JIT deaktiviert. Lokale Signaturentschlüsselung ist nicht verfügbar; es wird die Remote-Entschlüsselung genutzt und der Videostart kann langsamer sein.',
        'yt_secure_shield_dont_show': 'Nicht mehr anzeigen',
        'yt_action_got_it': 'Verstanden',
    },
    'es_ES': {
        'yt_secure_shield_title': 'El modo Secure Shield está activado',
        'yt_secure_shield_content': 'El sistema ha activado Secure Shield y ha desactivado JIT. El descifrado local de firmas no está disponible; se usará el descifrado remoto y el inicio del vídeo puede ser más lento.',
        'yt_secure_shield_dont_show': 'No volver a mostrar',
        'yt_action_got_it': 'Entendido',
    },
    'fr_FR': {
        'yt_secure_shield_title': 'Le mode Secure Shield est activé',
        'yt_secure_shield_content': 'Le système a activé le mode Secure Shield et désactivé le JIT. Le déchiffrement local des signatures est indisponible ; le déchiffrement distant sera utilisé et le démarrage de la vidéo peut être plus lent.',
        'yt_secure_shield_dont_show': 'Ne plus afficher',
        'yt_action_got_it': 'Compris',
    },
    'ru_RU': {
        'yt_secure_shield_title': 'Включён режим Secure Shield',
        'yt_secure_shield_content': 'Система включила Secure Shield и отключила JIT. Локальная расшифровка подписей недоступна; будет использоваться удалённая расшифровка, запуск видео может быть медленнее.',
        'yt_secure_shield_dont_show': 'Больше не показывать',
        'yt_action_got_it': 'Понятно',
    },
    'ar_SA': {
        'yt_secure_shield_title': 'وضع Secure Shield مفعّل',
        'yt_secure_shield_content': 'فعّل النظام وضع Secure Shield وعطّل JIT. فك تشفير التوقيع المحلي غير متاح، وسيُستخدم فك التشفير عن بُعد وقد يكون بدء الفيديو أبطأ.',
        'yt_secure_shield_dont_show': 'عدم الإظهار مجددًا',
        'yt_action_got_it': 'حسنًا',
    },
}


def main() -> None:
    for loc, vals in STRINGS.items():
        path = ROOT / loc / 'element' / 'string.json'
        with open(path, 'r', encoding='utf-8-sig') as f:
            data = json.load(f)
        by_name = {item['name']: item for item in data['string']}
        added = 0
        for key, value in vals.items():
            if key in by_name:
                by_name[key]['value'] = value
            else:
                data['string'].append({'name': key, 'value': value})
                added += 1
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            f.write('\n')
        print(f'{loc}: added {added}')


if __name__ == '__main__':
    main()
