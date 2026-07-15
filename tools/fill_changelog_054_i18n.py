#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fill native 0.5.4 changelog translations for non-CJK locales."""
import json
from pathlib import Path

ROOT = Path('entry/src/main/resources')

TRANSLATIONS = {
    'de_DE': {
        1: 'Lokale JS-Signaturentschlüsselung mit Festplatten-Cache, Kaltstart-Vorwärmung und Fehler-Fallback verbessert – weniger Wartezeiten und Ausfälle bei Bedarf an Remote-Entschlüsselung',
        2: 'DASH-Audio-Track-Metadaten (xtags/acont) ergänzt und Standardspuren nach Inhaltssprache / Original-Präferenz gewählt – weniger falsche Synchronisation bei mehrsprachigen Videos',
        3: 'Schlaf-Timer auf der Player-Seite: stoppt die Wiedergabe und beendet bei Ablauf; Like-/Aufrufzahlen sprachabhängig formatiert und Info-Bereichsfarben verfeinert',
        4: 'UI-String-Keys in allen Sprachen angeglichen, [object Object]-Beschriftungen in Einstellungen und Über-Seite behoben, Ressourcen für vereinfachtes Chinesisch vervollständigt',
        5: 'Standard-Akzentfarbe auf Rot geändert und Hintergrundfarben für Player-Steuerung/Info für besseren Kontrast hinzugefügt',
        6: 'Pull-to-Refresh auf der Startseite; beim Löschen aller App-Daten werden Auth-Einstellungen, Thumbnail-Cache und Cipher-Cache mitgelöscht (Downloads bleiben erhalten)',
        7: 'Netzwerkanfrage-Protokollierung und Extraktionsdiagnosen verbessert, um Ladefehler und Auth-Probleme leichter zu finden',
        8: 'Mitgelieferte MPV-Runtime aktualisiert und mehrere Stabilitätsprobleme bei Wiedergabe und UI behoben',
    },
    'es_ES': {
        1: 'Mejora del descifrado local de firmas JS con caché en disco, precalentamiento en arranque en frío y reintento ante fallos, reduciendo esperas y errores cuando hace falta el descifrado remoto',
        2: 'Completados los metadatos de pistas de audio DASH (xtags/acont) y selección automática de la pista predeterminada por idioma de contenido / preferencia de original, reduciendo doblajes incorrectos en vídeos multilingües',
        3: 'Temporizador de sueño en la página del reproductor que detiene la reproducción y sale al cumplirse; recuentos de me gusta/vistas localizados por idioma y colores del área de información refinados',
        4: 'Claves de cadenas de UI alineadas en todos los idiomas, corregidas las etiquetas [object Object] en ajustes y Acerca de, y completados los recursos de chino simplificado',
        5: 'El acento de tema predeterminado pasa a rojo y se añaden colores de fondo del control/info del reproductor para mejor contraste',
        6: 'Actualización por deslizamiento en Inicio; al borrar todos los datos de la app también se limpian preferencias de auth, caché de miniaturas y caché de cifrado, conservando las descargas',
        7: 'Mejor registro de peticiones de red y diagnósticos de extracción para localizar fallos de carga y problemas de autenticación',
        8: 'Runtime MPV incluido actualizado y varios problemas de estabilidad de reproducción e interfaz corregidos',
    },
    'fr_FR': {
        1: 'Déchiffrement local des signatures JS amélioré avec cache disque, préchauffage au démarrage à froid et repli en cas d’échec, réduisant les attentes et les échecs lorsque le déchiffrement distant est nécessaire',
        2: 'Métadonnées des pistes audio DASH (xtags/acont) complétées et piste par défaut choisie selon la langue du contenu / préférence originale, réduisant les doublages incorrects sur les vidéos multilingues',
        3: 'Minuteur de sommeil sur la page lecteur qui arrête la lecture et quitte à l’échéance ; compteurs j’aime/vues localisés par langue et couleurs de la zone d’info affinées',
        4: 'Clés de chaînes UI alignées sur toutes les langues, libellés [object Object] corrigés dans les réglages et À propos, ressources chinois simplifié complétées',
        5: 'Accent de thème par défaut passé au rouge et couleurs de fond commande/info du lecteur ajoutées pour un meilleur contraste',
        6: 'Tirage pour actualiser sur l’accueil ; l’effacement de toutes les données de l’app nettoie aussi les préférences d’auth, le cache des miniatures et le cache de chiffrement (téléchargements conservés)',
        7: 'Journalisation des requêtes réseau et diagnostics d’extraction améliorés pour localiser les échecs de chargement et les problèmes d’authentification',
        8: 'Runtime MPV embarqué mis à jour et plusieurs problèmes de stabilité lecture/interface corrigés',
    },
    'ru_RU': {
        1: 'Улучшено локальное JS-расшифровывание подписей с дисковым кэшем, прогревом при холодном запуске и откатом при сбоях — меньше ожиданий и ошибок, когда нужен удалённый дешифратор',
        2: 'Дополнены метаданные DASH-аудиодорожек (xtags/acont) и автовыбор дорожки по языку контента / предпочтению оригинала — меньше неверных дубляжей на многоязычных роликах',
        3: 'Таймер сна на странице плеера: по истечении останавливает воспроизведение и выходит; лайки/просмотры локализованы по языку, цвета инфоблока уточнены',
        4: 'Выровнены ключи строк UI во всех локалях, исправлены подписи [object Object] в настройках и «О приложении», дополнены ресурсы упрощённого китайского',
        5: 'Акцентный цвет темы по умолчанию — красный; добавлены фоны панели управления/инфо плеера для лучшего контраста',
        6: 'Потянуть для обновления на главной; при очистке всех данных приложения также очищаются auth-настройки, кэш превью и кэш cipher (загрузки сохраняются)',
        7: 'Улучшены журналы сетевых запросов и диагностика извлечения — проще находить сбои загрузки и проблемы авторизации',
        8: 'Обновлена встроенная runtime MPV и исправлены несколько проблем стабильности воспроизведения и интерфейса',
    },
    'ar_SA': {
        1: 'تحسين فك تشفير توقيعات JS محليًا مع ذاكرة تخزين على القرص وتسخين عند التشغيل البارد والرجوع عند الفشل، مما يقلل الانتظار والأعطال عند الحاجة إلى فك التشفير عن بُعد',
        2: 'استكمال بيانات مسارات الصوت في DASH (xtags/acont) واختيار المسار الافتراضي حسب لغة المحتوى / تفضيل الأصلي، لتقليل اختيار الدبلجة الخاطئة في الفيديوهات متعددة اللغات',
        3: 'مؤقّت نوم في صفحة المشغّل يوقف التشغيل ويخرج عند الانتهاء؛ تنسيق عدد الإعجابات/المشاهدات حسب اللغة وتحسين ألوان منطقة المعلومات',
        4: 'مواءمة مفاتيح نصوص الواجهة في كل اللغات، وإصلاح تسميات [object Object] في الإعدادات وحول التطبيق، وإكمال موارد الصينية المبسّطة',
        5: 'تغيير لون التمييز الافتراضي للسمة إلى الأحمر وإضافة خلفيات منطقة التحكم/المعلومات في المشغّل لتحسين التباين',
        6: 'السحب للتحديث في الصفحة الرئيسية؛ عند مسح كل بيانات التطبيق تُمسح أيضًا تفضيلات المصادقة وذاكرة الصور المصغّرة وذاكرة التشفير (مع الإبقاء على التنزيلات)',
        7: 'تحسين سجلات طلبات الشبكة وتشخيصات الاستخراج لتسهيل تحديد أعطال التحميل ومشاكل المصادقة',
        8: 'تحديث مكتبة MPV المضمّنة وإصلاح عدة مشاكل في استقرار التشغيل والواجهة',
    },
}


def main() -> None:
    for loc, vals in TRANSLATIONS.items():
        path = ROOT / loc / 'element' / 'string.json'
        with open(path, 'r', encoding='utf-8-sig') as f:
            data = json.load(f)
        by_name = {item['name']: item for item in data['string']}
        updated = 0
        for i in range(1, 9):
            key = f'yt_changelog_0_5_4_{i}'
            if key not in by_name:
                raise SystemExit(f'missing key {key} in {loc}')
            by_name[key]['value'] = vals[i]
            updated += 1
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            f.write('\n')
        print(f'{loc}: updated {updated}')


if __name__ == '__main__':
    main()
